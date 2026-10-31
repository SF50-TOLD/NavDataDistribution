import Foundation
import Logging
import ZIPFoundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Errors that keep a supplementary source from loading.
enum SupplementarySourceError: LocalizedError, DownloadStatusReporting {
  case downloadFailed(URL, statusCode: Int)
  case editionNotFound(source: String)
  case fileNotInArchive(String)
  case unreadablePage(URL)

  var downloadStatusCode: Int? {
    guard case let .downloadFailed(_, statusCode) = self else { return nil }
    return statusCode
  }

  var errorDescription: String? {
    String(localized: "Supplementary data could not be loaded.")
  }

  var failureReason: String? {
    switch self {
      case let .downloadFailed(url, statusCode):
        String(
          localized: "Downloading “\(url.absoluteString)” failed with HTTP status \(statusCode)."
        )
      case .editionNotFound(let source):
        String(localized: "No \(source) edition for the cycle was found.")
      case .fileNotInArchive(let name):
        String(localized: "The archive has no file matching “\(name)”.")
      case .unreadablePage(let url):
        String(localized: "The page at “\(url.absoluteString)” is not UTF-8 text.")
    }
  }
}

/// Downloads and unpacks the files supplementary sources publish.
struct SupplementaryDownload {
  let logger: Logger

  /// Downloads a file, retrying transient failures.
  func data(from url: URL) async throws -> Data {
    try await withRetries(logger: logger) {
      let (data, response) = try await URLSession.shared.data(from: url)
      if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
        throw SupplementarySourceError.downloadFailed(url, statusCode: response.statusCode)
      }
      return data
    }
  }

  /// Downloads a web page as text.
  func page(at url: URL) async throws -> String {
    guard let page = String(bytes: try await data(from: url), encoding: .utf8) else {
      throw SupplementarySourceError.unreadablePage(url)
    }
    return page
  }

  /**
   Downloads a ZIP archive and extracts the first entry whose name passes the test into a
   new temporary directory.

   Extracting to disk rather than memory lets very large data sets be streamed.
   - Returns: The extracted file. The caller removes its directory when done.
   */
  func extract(
    from url: URL,
    entryMatching isWanted: (String) -> Bool,
    describedAs description: String
  ) async throws -> URL {
    let archive = try Archive(data: try await data(from: url), accessMode: .read)
    guard let entry = archive.first(where: { isWanted($0.path) }) else {
      throw SupplementarySourceError.fileNotInArchive(description)
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(
      URL(fileURLWithPath: entry.path).lastPathComponent
    )
    _ = try archive.extract(entry, to: file)
    return file
  }

  /// Removes a file returned by ``extract(from:entryMatching:describedAs:)`` and its directory.
  func remove(_ file: URL) {
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
  }
}

/// Finds dated files in a publication page's links.
enum DatedLinks {

  /**
   The link whose `yyyyMMdd` date is latest without falling after the given date.

   - Parameters:
     - html: The page.
     - pattern: A regular expression matching a link, with one capture group for the date.
     - date: The latest date to accept.
   */
  static func latest(in html: String, matching pattern: String, onOrBefore date: Date) -> (
    link: String, date: String
  )? {
    guard let regex = try? Regex(pattern) else { return nil }
    let limit = stamp(date)
    return html.matches(of: regex)
      .compactMap { match -> (String, String)? in
        guard match.output.count > 1, let date = match.output[1].substring else { return nil }
        return (String(match.output[0].substring ?? ""), String(date))
      }
      .filter { $0.1 <= limit }
      .max { $0.1 < $1.1 }
      .map { (link: $0.0, date: $0.1) }
  }

  /// A date as `yyyyMMdd` in UTC.
  static func stamp(_ date: Date) -> String {
    date.formatted(
      Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)",
        timeZone: .gmt,
        calendar: Calendar(identifier: .gregorian)
      )
    )
  }
}
