import Foundation
import SwiftCIFP

/// How many procedures received an official FAA name.
struct NamingStats: Sendable {
  var approachesNamed = 0
  var approachesTotal = 0
  var departuresNamed = 0
  var departuresTotal = 0

  static func += (lhs: inout Self, rhs: Self) {
    lhs.approachesNamed += rhs.approachesNamed
    lhs.approachesTotal += rhs.approachesTotal
    lhs.departuresNamed += rhs.departuresNamed
    lhs.departuresTotal += rhs.departuresTotal
  }

  /// A percentage string for logging, or `"n/a"` when nothing was counted.
  static func percentage(_ named: Int, of total: Int) -> String {
    guard total > 0 else { return "n/a" }
    return String(format: "%.1f%%", Double(named) / Double(total) * 100)
  }
}

/// Resolves official FAA names for CIFP procedures.
///
/// Approaches are matched directly against d-TPP chart titles on navaid family,
/// runway, and multiple indicator. Departures take an extra hop: NASR maps the
/// CIFP identifier to the official name, and that name is then joined to its
/// chart title to recover suffixes the NASR name omits, turning `SSTIK FIVE`
/// into `SSTIK FIVE (RNAV)`.
///
/// Every lookup is optional. d-TPP covers US procedures only, so international
/// airports miss by construction and callers fall back to generated names.
///
/// ## See Also
///
/// - ``DTPPLoader``
/// - ``DepartureNameIndex``
struct ProcedureNameResolver: Sendable {

  /// The best chart title for each approach key, per airport.
  private let approachCharts: [String: [ApproachKey: String]]

  /// Chart titles for departures, keyed by airport and then by the title with
  /// any trailing parenthetical removed.
  private let departureCharts: [String: [String: String]]

  /// Official departure names keyed by CIFP procedure identifier.
  private let departureNames: [String: String]

  /// Builds a resolver from loaded chart and NASR data.
  /// - Parameters:
  ///   - charts: Charted procedures keyed by ICAO identifier.
  ///   - departureNames: Official departure names keyed by CIFP identifier.
  init(charts: DTPPIndex, departureNames: [String: String]) {
    self.departureNames = departureNames

    var approachCharts = [String: [ApproachKey: String]]()
    var departureCharts = [String: [String: String]]()

    for (icao, records) in charts {
      var best = [ApproachKey: (title: String, penalty: Int)]()
      var departures = [String: String]()
      var ambiguousRoots = Set<String>()

      for record in records {
        switch record.kind {
          case .approach:
            guard let chart = ChartName(record.name) else { continue }
            for key in chart.keys where (best[key]?.penalty ?? .max) > chart.penalty {
              best[key] = (chart.name, chart.penalty)
            }
          case .departure, .obstacleDeparture:
            let root = Self.strippingTrailingParenthetical(record.name)
            // A root matching several charts is ambiguous; refuse to guess.
            if departures.updateValue(record.name, forKey: root) != nil {
              ambiguousRoots.insert(root)
            }
        }
      }

      approachCharts[icao] = best.mapValues(\.title)
      departureCharts[icao] = departures.filter { !ambiguousRoots.contains($0.key) }
    }

    self.approachCharts = approachCharts
    self.departureCharts = departureCharts
  }

  /// Removes one or more trailing qualifiers such as `" (OBSTACLE) (RNAV)"` so
  /// a NASR name and its chart title compare equal.
  private static func strippingTrailingParenthetical(_ name: String) -> String {
    name.replacing(/(\s*\([^)]*\))+\s*$/, with: "")
      .trimmingCharacters(in: .whitespaces)
  }

  /// The official chart title for a CIFP approach.
  ///
  /// Callers derive the key themselves so a procedure's runway and the key used
  /// to name it cannot disagree.
  /// - Parameters:
  ///   - icao: The airport's ICAO identifier.
  ///   - key: The approach's match key.
  /// - Returns: The published title, or nil if no chart matches.
  func approachName(icao: String, key: ApproachKey) -> String? {
    approachCharts[icao]?[key]
  }

  /// The official name for a CIFP departure procedure.
  /// - Parameters:
  ///   - icao: The airport's ICAO identifier.
  ///   - identifier: The CIFP procedure identifier, such as `"SSTIK5"`.
  /// - Returns: The full chart title when one matches, otherwise the NASR name,
  ///   or nil if NASR does not name the procedure.
  func departureName(icao: String, identifier: String) -> String? {
    guard let name = departureNames[identifier] else { return nil }
    return departureCharts[icao]?[name] ?? name
  }
}
