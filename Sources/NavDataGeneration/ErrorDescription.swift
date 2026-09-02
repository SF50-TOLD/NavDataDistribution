import Foundation

/// Renders everything an error knows about itself.
///
/// `localizedDescription` returns only a `LocalizedError`'s `errorDescription`,
/// which is where the detail goes missing: SwiftNASR reports every download
/// problem as "Couldn't download distribution" and puts the offending HTTP
/// response in `failureReason`. Reporting a failure without that detail leaves
/// no way to tell a rate-limited server from an empty download.
/// - Parameter error: The error to describe.
/// - Returns: The description, failure reason, recovery suggestion, and
///            underlying case, one per line.
public func detailedDescription(of error: any Error) -> String {
  var lines = [error.localizedDescription]

  if let error = error as? any LocalizedError {
    if let failureReason = error.failureReason { lines.append(failureReason) }
    if let recoverySuggestion = error.recoverySuggestion { lines.append(recoverySuggestion) }
  }

  let underlying = String(describing: error)
  if !lines.contains(underlying) { lines.append(underlying) }

  return lines.joined(separator: "\n  ")
}
