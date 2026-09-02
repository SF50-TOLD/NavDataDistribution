import Foundation
import Logging
import SwiftNASR

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// An error that carries the HTTP status a download was refused with.
protocol DownloadStatusReporting {
  var downloadStatusCode: Int? { get }
}

/// Runs a download, retrying transient failures with exponential backoff.
///
/// The FAA's hosts are intermittently unavailable — a scheduled run has failed
/// on a response that succeeded on the very next attempt — and this pipeline
/// runs once per 28-day cycle, so a single flap otherwise costs a whole cycle.
/// Only failures a retry could plausibly fix are retried; a missing file or a
/// malformed archive fails immediately.
/// - Parameters:
///   - attempts: How many times to try in total.
///   - logger: Receives a warning for each attempt that failed retryably.
///   - operation: The download to run.
/// - Returns: Whatever `operation` returns.
/// - Throws: The error from the final attempt, if every attempt failed.
func withRetries<T>(
  attempts: Int = 3,
  logger: Logger,
  during operation: () async throws -> T
) async throws -> T {
  for attempt in 1..<attempts {
    do {
      return try await operation()
    } catch let error where isTransientNetworkFailure(error) {
      let backoff = Duration.seconds(1 << (attempt - 1))
      logger.warning(
        "Download attempt \(attempt) of \(attempts) failed; retrying",
        metadata: [
          "backoff": "\(backoff)",
          "error": "\(detailedDescription(of: error))"
        ]
      )
      try await Task.sleep(for: backoff)
    }
  }

  return try await operation()
}

/// Reports whether an error is worth retrying.
///
/// Cancellation is never retried, nor is any answer the server means to give —
/// only lost or refused connections, timeouts, and the server-side and
/// rate-limit statuses that clear on their own.
/// - Parameter error: The error a download threw.
/// - Returns: Whether another attempt could plausibly succeed.
func isTransientNetworkFailure(_ error: any Swift.Error) -> Bool {
  switch error {
    case is CancellationError: false
    case let error as URLError: isTransient(URLErrorCode: error.code)
    case let error as SwiftNASR.Error: isTransient(NASRError: error)
    case let error as any DownloadStatusReporting: isTransient(statusCode: error.downloadStatusCode)
    default: false
  }
}

/// Server errors and rate limiting clear on their own; every other status is
/// the answer the server means to give.
private func isTransient(statusCode: Int?) -> Bool {
  guard let statusCode else { return false }
  return statusCode >= 500 || statusCode == 429
}

private func isTransient(URLErrorCode code: URLError.Code) -> Bool {
  switch code {
    case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
      .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable, .secureConnectionFailed:
      true
    default:
      false
  }
}

private func isTransient(NASRError error: SwiftNASR.Error) -> Bool {
  switch error {
    case .badResponse(let response):
      isTransient(statusCode: (response as? HTTPURLResponse)?.statusCode)
    case .noData, .downloadFailed:
      true
    default:
      false
  }
}

extension CIFPProcessorError: DownloadStatusReporting {
  var downloadStatusCode: Int? {
    guard case .downloadFailed(let statusCode) = self else { return nil }
    return statusCode
  }
}

extension DOFProcessorError: DownloadStatusReporting {
  var downloadStatusCode: Int? {
    guard case .downloadFailed(let statusCode) = self else { return nil }
    return statusCode
  }
}

extension DTPPLoaderError: DownloadStatusReporting {
  var downloadStatusCode: Int? {
    guard case .downloadFailed(let statusCode) = self else { return nil }
    return statusCode
  }
}
