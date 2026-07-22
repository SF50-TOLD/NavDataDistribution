import Foundation

/// A parsed d-TPP instrument approach chart title.
///
/// Chart titles name the navaid families they serve, the runway they land on,
/// and — for approaches that share a runway — a multiple indicator. A single
/// title often serves several families: `ILS OR LOC RWY 28L` is the published
/// chart for both the CIFP `I28L` and `L28L` procedures.
struct ChartName: Sendable {

  /// The title exactly as published.
  let name: String

  /// Every navaid family this chart serves.
  let families: Set<ApproachFamily>

  /// Runway designator without leading zeros, or nil for a circling approach.
  let runway: String?

  /// Multiple indicator or circling designator.
  let designator: String?

  /// Ranking penalty; lower is more canonical.
  ///
  /// Special-minimums, military, and continuation-sheet variants share a key
  /// with the base chart, so they are demoted to let the base chart win.
  let penalty: Int

  /// Every approach key this chart can satisfy.
  var keys: [ApproachKey] {
    families.map { .init(family: $0, runway: runway, designator: designator) }
  }

  /// Parses a published chart title.
  /// - Parameter name: The `chart_name` value from the d-TPP metafile.
  /// - Returns: `nil` when the title names no runway and no circling
  ///   designator, which means it is not an approach chart.
  init?(_ name: String) {
    var body = name
    var runway: String?
    var designator: String?

    if let match = body.firstMatch(of: /\bRWY\s+(\d{1,2}[LCR]?)/) {
      runway = ApproachKey.normalizeRunway(String(match.1))
      body = String(body[body.startIndex..<match.range.lowerBound])
      designator = Self.multipleIndicator(in: body)
    } else if let match = body.firstMatch(of: /-([A-Z])\s*$/) {
      designator = String(match.1)
      body = String(body[body.startIndex..<match.range.lowerBound])
    } else {
      return nil
    }

    let families = Self.families(in: body)
    guard !families.isEmpty else { return nil }

    self.name = name
    self.families = families
    self.runway = runway
    self.designator = designator
    penalty = Self.penalty(for: name)
  }

  /// The multiple indicator, if the title carries one.
  ///
  /// The indicator's position varies — `ILS Z OR LOC RWY 28` puts it mid-title,
  /// `RNAV (GPS) Z RWY 19R` puts it last — so it is found as a standalone
  /// single-letter token rather than by position.
  private static func multipleIndicator(in body: String) -> String? {
    body.split(whereSeparator: \.isWhitespace)
      .first { $0.count == 1 && ("U"..."Z").contains(String($0)) }
      .map(String.init)
  }

  /// Every navaid family named in the title, excluding the runway clause.
  private static func families(in body: String) -> Set<ApproachFamily> {
    var families = Set<ApproachFamily>()

    if body.contains(/\bBC\b/) {
      families.insert(.localizerBackcourse)
    } else if body.contains(/\bLOC\b/) {
      families.insert(.localizer)
    }

    if body.contains(/\bILS\b/) { families.insert(.ils) }
    if body.contains(/\bIGS\b/) { families.insert(.igs) }
    if body.contains(/\bGLS\b/) { families.insert(.gls) }
    if body.contains(/\bFMS\b/) { families.insert(.fms) }
    if body.contains(/\bLDA\b/) { families.insert(.lda) }
    if body.contains(/\bSDF\b/) { families.insert(.sdf) }
    if body.contains(/\bMLS\b/) { families.insert(.mls) }

    if body.contains("RNAV (RNP)") { families.insert(.rnp) }
    if body.contains("RNAV (GPS)") {
      families.formUnion([.rnav, .gps])
    } else if body.contains(/\bGPS\b/) {
      families.insert(.gps)
    }

    if body.contains(/\bNDB\/DME\b/) {
      families.insert(.ndbDME)
    } else if body.contains(/\bNDB\b/) {
      families.insert(.ndb)
    }

    if body.contains(/\bTACAN\b/) { families.insert(.tacan) }

    if body.contains(/\bVOR\b/) {
      // CIFP type S is charted as plain VOR, VOR/DME, or VOR OR TACAN.
      families.insert(.vorRequiringDME)
      if body.contains(/\bVOR\/DME\b/) {
        families.insert(.vorDME)
      } else {
        families.insert(.vor)
      }
    }

    return families
  }

  /// Demotes titles that share a key with a more canonical chart.
  private static func penalty(for name: String) -> Int {
    var penalty = 0
    if name.contains(/\((SA )?CAT|PRM|CONVERGING|COPTER|VISUAL/) { penalty += 10 }
    if name.hasPrefix("HI-") { penalty += 5 }
    if name.contains(/\([^)]*\)\s*$/) && !name.contains("RNAV") { penalty += 3 }
    if name.contains("CONT.") { penalty += 20 }
    return penalty
  }
}
