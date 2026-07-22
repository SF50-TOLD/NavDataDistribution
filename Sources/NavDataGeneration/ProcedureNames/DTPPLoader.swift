import Foundation
import Logging
import SwiftNASR

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(FoundationXML)
  import FoundationXML
#endif

/// A charted procedure listed in the d-TPP metafile.
struct ChartRecord: Sendable {

  /// Which kind of procedure this chart depicts.
  let kind: Kind

  /// The published chart title, such as `"ILS OR LOC RWY 28L"`.
  let name: String

  /// The kinds of chart this pipeline cares about.
  enum Kind: String, Sendable {
    /// Instrument approach procedure.
    case approach = "IAP"

    /// Standard instrument departure.
    case departure = "DP"

    /// Obstacle departure procedure.
    case obstacleDeparture = "ODP"
  }
}

/// Charted procedures for every airport in a d-TPP cycle, keyed by ICAO
/// identifier.
typealias DTPPIndex = [String: [ChartRecord]]

/// Downloads and parses the FAA Digital Terminal Procedures Publication
/// metafile.
///
/// The metafile lists every charted procedure in a cycle along with its
/// official title, which is the authority for how a procedure is named. Only
/// approach and departure records are retained; the file's minimums, airport
/// diagram, hot spot, and arrival records are discarded.
///
/// ## See Also
///
/// - ``ProcedureNameResolver``
/// - ``DTPPCycle``
struct DTPPLoader {
  private static let urlTemplate =
    "https://aeronav.faa.gov/d-tpp/%@/xml_data/d-TPP_Metafile.xml"

  // The download is a few hundred kilobytes of gzip and finishes in well under a
  // second; parsing the 16 MB it expands to takes the rest of the phase.
  private static let downloadProgressEnd = 5

  /// Logger for status messages and errors.
  let logger: Logger

  /// Downloads and parses the metafile for the given cycle.
  /// - Parameters:
  ///   - cycle: The cycle to fetch charts for.
  ///   - onProgress: Callback for progress updates (completed, total).
  /// - Returns: Charted procedures keyed by ICAO identifier.
  func loadCharts(
    cycle: SwiftNASR.Cycle,
    onProgress: (@Sendable (Int, Int) async -> Void)? = nil
  ) async throws -> DTPPIndex {
    await onProgress?(0, 100)

    let identifier = DTPPCycle.identifier(for: cycle)
    let urlString = String(format: Self.urlTemplate, identifier)
    guard let url = URL(string: urlString) else {
      throw DTPPLoaderError.invalidURL(urlString)
    }

    logger.notice("Downloading d-TPP metafile from \(url)…")

    let (data, response) = try await URLSession.shared.data(from: url)
    await onProgress?(Self.downloadProgressEnd, 100)

    if let httpResponse = response as? HTTPURLResponse,
      !(200..<300).contains(httpResponse.statusCode)
    {
      throw DTPPLoaderError.downloadFailed(httpResponse.statusCode)
    }

    try Task.checkCancellation()

    logger.notice("Parsing d-TPP metafile (\(data.count) bytes)…")
    let index = try await parseCharts(from: data, onProgress: onProgress)
    await onProgress?(100, 100)

    logger.notice("Loaded charts for \(index.count) airports from d-TPP cycle \(identifier)")
    return index
  }

  /// Parses the metafile, collecting approach and departure records.
  ///
  /// The parser reads from a stream rather than from `Data` because
  /// swift-corelibs-foundation's data-based parser reports failure at the end of
  /// a document it has in fact parsed completely. Its `parse()` result is
  /// unreliable in both directions on Linux — it also reports success for
  /// truncated input — so an empty index, which the metafile never legitimately
  /// produces, is what actually distinguishes a failed parse.
  ///
  /// `XMLParser` has no progress of its own and blocks until the document is
  /// consumed, so the delegate counts newlines as it goes against the total in
  /// the payload, and the parse runs off the cooperative pool so that progress
  /// can be polled while it works.
  private func parseCharts(
    from data: Data,
    onProgress: (@Sendable (Int, Int) async -> Void)?
  ) async throws -> DTPPIndex {
    let lineCount = data.withUnsafeBytes { buffer in
      buffer.reduce(into: Int64(0)) { count, byte in if byte == 0x0A { count += 1 } }
    }

    // `Progress` is not `Sendable`, but the only cross-task access is the
    // parser thread advancing its count while the poller reads it, which its
    // counters support.
    nonisolated(unsafe) let progress = Progress(totalUnitCount: max(lineCount, 1))

    let polling = pollProgress(
      progress,
      mappingTo: Self.downloadProgressEnd..<100,
      onProgress: onProgress
    )
    defer { polling.cancel() }

    let outcome = await Task.detached {
      let delegate = MetafileDelegate(progress: progress)
      let parser = XMLParser(stream: InputStream(data: data))
      parser.delegate = delegate
      let succeeded = parser.parse()
      return ParseOutcome(
        index: delegate.index,
        succeeded: succeeded,
        failure: parser.parserError?.localizedDescription,
        line: parser.lineNumber,
        column: parser.columnNumber
      )
    }.value

    progress.completedUnitCount = progress.totalUnitCount

    guard !outcome.index.isEmpty else {
      throw DTPPLoaderError.parseFailed(
        "\(outcome.failure ?? "no charts found") at line \(outcome.line), "
          + "column \(outcome.column)"
      )
    }

    if !outcome.succeeded {
      logger.warning(
        """
        d-TPP parser reported an error at line \(outcome.line) but returned \(outcome.index.count) \
        airports; using them.
        """
      )
    }

    return outcome.index
  }

  /// What a parse run produced, in a form that can cross task boundaries.
  private struct ParseOutcome: Sendable {
    let index: DTPPIndex
    let succeeded: Bool
    let failure: String?
    let line: Int
    let column: Int
  }
}

/// Accumulates approach and departure records while streaming the metafile.
///
/// The metafile nests `<record>` elements inside `<airport_name>` elements, and
/// each record's chart code and title arrive as separate child elements, so
/// both are buffered until the record closes.
private final class MetafileDelegate: NSObject, XMLParserDelegate {
  private(set) var index = DTPPIndex()

  /// Tracks how far through the document the parser has read, in lines.
  private let progress: Progress

  private var currentICAO: String?
  private var currentChartCode: String?
  private var currentChartName: String?
  private var currentText = ""

  init(progress: Progress) {
    self.progress = progress
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI _: String?,
    qualifiedName _: String?,
    attributes: [String: String]
  ) {
    currentText = ""

    switch elementName {
      case "airport_name":
        currentICAO = attributes["icao_ident"]
        // Sampling once per airport is frequent enough for a smooth bar and far
        // cheaper than updating on every one of the file's millions of elements.
        progress.completedUnitCount = min(Int64(parser.lineNumber), progress.totalUnitCount)
      case "record":
        currentChartCode = nil
        currentChartName = nil
      default:
        break
    }
  }

  func parser(_: XMLParser, foundCharacters string: String) {
    currentText += string
  }

  func parser(
    _: XMLParser,
    didEndElement elementName: String,
    namespaceURI _: String?,
    qualifiedName _: String?
  ) {
    let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

    switch elementName {
      case "chart_code":
        currentChartCode = text
      case "chart_name":
        currentChartName = text
      case "record":
        appendCurrentRecord()
      case "airport_name":
        currentICAO = nil
      default:
        break
    }

    currentText = ""
  }

  /// Files the buffered record under its airport, if it is one we keep.
  private func appendCurrentRecord() {
    guard let icao = currentICAO, !icao.isEmpty,
      let code = currentChartCode,
      let kind = ChartRecord.Kind(rawValue: code),
      let name = currentChartName, !name.isEmpty
    else { return }

    index[icao, default: []].append(.init(kind: kind, name: name))
  }
}

/// Errors that can occur while loading d-TPP data.
enum DTPPLoaderError: LocalizedError {
  case invalidURL(String)
  case downloadFailed(Int)
  case parseFailed(String)

  var errorDescription: String? {
    String(localized: "FAA d-TPP data could not be processed.")
  }

  var failureReason: String? {
    switch self {
      case .invalidURL(let url):
        String(localized: "The URL “\(url)” is invalid.")
      case .downloadFailed(let statusCode):
        String(localized: "Download failed with HTTP status \(statusCode).")
      case .parseFailed(let reason):
        String(localized: "The metafile could not be parsed: \(reason).")
    }
  }
}
