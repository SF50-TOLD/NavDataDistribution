import Foundation

/// Samples a `Progress` on a timer and reports mapped updates via `onProgress`.
///
/// KVO (`NSKeyValueObservation`) needs the Objective-C runtime and isn't available on Linux, so
/// parser progress is polled rather than observed. The returned task self-terminates once the
/// progress finishes.
/// - Parameters:
///   - progress: The `Progress` reported by a parser (SwiftNASR/SwiftCIFP/SwiftDOF).
///   - range: The overall-progress percentage range this phase occupies (e.g. `50..<100`).
///   - onProgress: Callback receiving `(completed, 100)`.
/// - Returns: The polling task, which stops on its own when the progress completes.
@discardableResult
func pollProgress(
  _ progress: Progress,
  mappingTo range: Range<Int>,
  onProgress: (@Sendable (Int, Int) async -> Void)?
) -> Task<Void, Never> {
  Task {
    guard let onProgress else { return }
    let rangeSize = range.upperBound - range.lowerBound
    while !Task.isCancelled, !progress.isFinished {
      let mapped = range.lowerBound + Int(Double(rangeSize) * progress.fractionCompleted)
      await onProgress(mapped, 100)
      try? await Task.sleep(for: .milliseconds(100))
    }
  }
}
