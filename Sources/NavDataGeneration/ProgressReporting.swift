import Foundation
import Observation

/// Reports a `ProgressManager`'s completion to a percentage callback until it finishes.
///
/// `ProgressManager` is observable, so this follows the run's own progress rather than sampling it
/// on a timer the way `pollProgress` must for the libraries that still report a `Progress`. The
/// returned task ends of its own accord once the manager finishes.
/// - Parameters:
///   - manager: The progress every phase of a run reports into.
///   - onProgress: Callback receiving `(completed, 100)`.
/// - Returns: The reporting task, which stops on its own when the progress completes.
@discardableResult
func reportProgress(
  of manager: ProgressManager,
  to onProgress: (@Sendable (Int, Int) async -> Void)?
) -> Task<Void, Never> {
  Task {
    guard let onProgress else { return }

    let percentages = Observations<Int, Never>.untilFinished {
      manager.isFinished ? .finish : .next(percentComplete(of: manager))
    }

    var lastReported = -1
    for await percent in percentages where percent != lastReported {
      lastReported = percent
      await onProgress(percent, 100)
    }

    if lastReported < 100 { await onProgress(100, 100) }
  }
}

/// The manager's completion as a whole percentage, clamped to 0…100.
private func percentComplete(of manager: ProgressManager) -> Int {
  let fraction = Swift.max(0, Swift.min(1, manager.fractionCompleted))
  return Int((fraction * 100).rounded())
}
