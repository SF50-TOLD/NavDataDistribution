#if canImport(Darwin)
  import os
#endif

/// Brackets phases of a long-running load with intervals Instruments can plot.
///
/// A load's cost is spread across downloading, decompressing, and parsing, and their relative
/// weights shift with the size of each cycle's dataset, so a slowdown is only diagnosable when
/// each phase reports its own span. The log lines answer “how long” after the fact; the signpost
/// puts the same phase on a timeline, where it can be lined up against the allocations, disk
/// writes, and thread states that explain why.
///
/// Instruments and the `os` framework exist only on Apple platforms, so on Linux — where
/// generation also runs — every member of this type compiles down to the work it wraps.
struct Signposter {
  /// The subsystem the SF50 TOLD app shares with its nav-data tooling, so one recording reads as
  /// a single pipeline rather than two.
  private static let subsystem = "codes.tim.SF50-TOLD"

  #if canImport(Darwin)
    private let signposter: OSSignposter
  #endif

  /// Creates a signposter that emits under `category`.
  /// - Parameter category: Names the emitting type, as the app's logging categories do.
  init(category: String) {
    #if canImport(Darwin)
      signposter = OSSignposter(subsystem: Self.subsystem, category: category)
    #endif
  }

  /// Runs one phase of work, bracketed by a signpost interval.
  /// - Parameters:
  ///   - name: The interval's name, as it appears in Instruments.
  ///   - operation: The phase to time.
  /// - Returns: Whatever `operation` returns.
  func withInterval<T>(
    _ name: StaticString,
    during operation: () async throws -> T
  ) async rethrows -> T {
    #if canImport(Darwin)
      let interval = signposter.beginInterval(name, id: signposter.makeSignpostID())
      defer { signposter.endInterval(name, interval) }
    #endif

    return try await operation()
  }
}
