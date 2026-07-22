import Foundation
import SwiftCIFP

/// Identifies an instrument approach precisely enough to match a CIFP procedure
/// against its published chart.
///
/// A key is the navaid family plus either a runway (with an optional multiple
/// indicator) or, for circling approaches, a bare designator letter.
struct ApproachKey: Hashable, Sendable {

  /// The navigation aid the approach is built on.
  let family: ApproachFamily

  /// Runway designator without the `RW` prefix and without leading zeros
  /// (`"28R"`, `"5"`). Nil for circling approaches.
  let runway: String?

  /// The multiple indicator distinguishing same-runway approaches (`"Z"`), or
  /// the circling designator (`"A"`). Nil when neither applies.
  let designator: String?

  /// Derives a key from a CIFP approach's type and procedure identifier.
  ///
  /// SwiftCIFP leaves `Approach.runwayId` and `Approach.multipleIndicator` nil
  /// for airport approaches, so both are parsed out of the identifier instead:
  /// `"R28RZ"` yields runway `28R` and designator `Z`; `"VOR-A"` yields the
  /// circling designator `A`.
  /// - Parameters:
  ///   - approachType: The CIFP approach type.
  ///   - identifier: The CIFP procedure identifier.
  /// - Returns: `nil` when the type is not an approach, or the identifier does
  ///   not parse.
  init?(approachType: ApproachType, identifier: String) {
    guard let family = ApproachFamily(approachType: approachType) else { return nil }
    let remainder = identifier.dropFirst()

    if let match = remainder.wholeMatch(of: /(\d{1,2}[LCR]?)-?([A-Z])?/) {
      self.init(
        family: family,
        runway: Self.normalizeRunway(String(match.1)),
        designator: match.2.map(String.init)
      )
    } else if let match = remainder.firstMatch(of: /-([A-Z])$/) {
      self.init(family: family, runway: nil, designator: String(match.1))
    } else {
      return nil
    }
  }

  /// Creates a key from its components.
  init(family: ApproachFamily, runway: String?, designator: String?) {
    self.family = family
    self.runway = runway
    self.designator = designator
  }

  /// Drops leading zeros so CIFP's `"05"` and a chart's `"5"` compare equal.
  static func normalizeRunway(_ runway: String) -> String {
    let stripped = runway.drop(while: { $0 == "0" })
    return stripped.isEmpty ? runway : String(stripped)
  }
}
