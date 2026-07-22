import Foundation
import SwiftNASR

/// Derives the FAA d-TPP cycle identifier for a NASR cycle.
///
/// d-TPP cycles share the 28-day AIRAC schedule with NASR and are identified as
/// `YYNN`, where `NN` is the ordinal of the cycle's effective date within its
/// calendar year. The cycle effective 2026-08-06 is the eighth of 2026, so
/// `"2608"`.
///
/// The FAA purges superseded cycles, so only the current and next cycles are
/// retrievable.
enum DTPPCycle {

  /// The d-TPP cycle identifier for the given NASR cycle.
  /// - Parameter cycle: The NASR cycle to identify.
  /// - Returns: A four-character identifier such as `"2608"`.
  static func identifier(for cycle: SwiftNASR.Cycle) -> String {
    String(format: "%02d%02d", Int(cycle.year % 100), ordinalWithinYear(of: cycle))
  }

  /// The one-based position of `cycle` among the cycles effective in its year.
  private static func ordinalWithinYear(of cycle: SwiftNASR.Cycle) -> Int {
    var ordinal = 1
    var candidate = cycle
    while let previous = candidate.previous, previous.year == cycle.year {
      candidate = previous
      ordinal += 1
    }
    return ordinal
  }
}
