import Foundation
import Synchronization

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

/// Polls a library's `Progress` for the duration of one phase, then stops.
///
/// A parser hands its `Progress` to a callback once, and `pollProgress` samples
/// it on a background task. That task must be cancelled when the phase ends —
/// some parsers hand over a `Progress` they never mark finished, so the poller
/// would otherwise keep reporting a stale value into the next phase. This scopes
/// the poller to `operation` and cancels it however `operation` returns.
/// - Parameters:
///   - range: The overall-progress percentage range this phase occupies.
///   - onProgress: Callback receiving `(completed, 100)`.
///   - operation: Runs the phase, receiving the progress handler to pass to the
///     parser.
/// - Returns: Whatever `operation` returns.
@discardableResult
func withPolledProgress<T>(
  mappingTo range: Range<Int>,
  onProgress: (@Sendable (Int, Int) async -> Void)?,
  during operation: (_ progressHandler: @Sendable (Progress) -> Void) async throws -> T
) async throws -> T {
  let poller = PollerHandle()
  defer { poller.cancel() }
  return try await operation { progress in
    poller.store(pollProgress(progress, mappingTo: range, onProgress: onProgress))
  }
}

/// Carries a poll task out of a synchronous progress callback so the enclosing
/// phase can cancel it.
private final class PollerHandle: Sendable {
  private let task = Mutex<Task<Void, Never>?>(nil)

  /// Replaces any stored task with a new one, cancelling the old.
  func store(_ newTask: Task<Void, Never>) {
    task.withLock { stored in
      stored?.cancel()
      stored = newTask
    }
  }

  /// Cancels and forgets the stored task.
  func cancel() {
    task.withLock { stored in
      stored?.cancel()
      stored = nil
    }
  }
}
