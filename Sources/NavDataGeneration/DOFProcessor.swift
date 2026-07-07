import Foundation
import Logging
import NavData
import SwiftDOF
import ZIPFoundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Processes FAA Digital Obstacle File (DOF) data.
///
/// ``DOFProcessor`` handles downloading and parsing FAA DOF data using SwiftDOF,
/// converting it to the application's codable format.
///
/// ## See Also
///
/// - ``NavDataProcessor``
/// - ``NASRProcessor``
/// - ``CIFPProcessor``
struct DOFProcessor {
  private static let dofURL = URL(string: "https://aeronav.faa.gov/Obst_Data/DAILY_DOF_DAT.ZIP")!

  // Progress allocation within DOF processing (out of 100):
  // - Download: 0-50
  // - Parse: 50-100
  private static let downloadProgressEnd = 50
  private static let parseProgressEnd = 100

  /// Logger for status messages and errors.
  let logger: Logger

  /// Downloads and parses DOF data.
  /// - Parameter onProgress: Callback for progress updates (completed, total).
  /// - Returns: A `DOFResult` containing the parsed obstacles and cycle.
  func loadDOFData(
    onProgress: (@Sendable (Int, Int) async -> Void)? = nil
  ) async throws -> DOFResult {
    await onProgress?(0, 100)

    logger.notice("Downloading DOF data from \(Self.dofURL)…")

    // Download the ZIP file
    let (downloadedData, response) = try await URLSession.shared.data(from: Self.dofURL)
    await onProgress?(Self.downloadProgressEnd, 100)

    if let httpResponse = response as? HTTPURLResponse,
      !(200..<300).contains(httpResponse.statusCode)
    {
      throw DOFProcessorError.downloadFailed(httpResponse.statusCode)
    }

    try Task.checkCancellation()

    // Extract DOF data from ZIP
    let dofData = try extractDOFFromZip(downloadedData)

    // Parse DOF
    logger.notice("Parsing DOF data…")
    let dof = try DOF(
      data: dofData,
      progressHandler: { progress in
        pollProgress(
          progress,
          mappingTo: Self.downloadProgressEnd..<Self.parseProgressEnd,
          onProgress: onProgress
        )
      },
      errorCallback: { error, lineNumber in
        self.logger.debug("DOF parse error at line \(lineNumber): \(error)")
      }
    )
    await onProgress?(Self.parseProgressEnd, 100)

    // Convert to codable format
    let obstacles = dof.map { obstacle in
      AirportDataCodable.ObstacleCodable(
        heightFtMSL: obstacle.heightFtMSL,
        latitude: obstacle.latitudeDeg,
        longitude: obstacle.longitudeDeg
      )
    }

    logger.notice("Loaded DOF data with \(obstacles.count) obstacles for cycle \(dof.cycle)")

    return DOFResult(cycle: dof.cycle, obstacles: obstacles)
  }

  /// Extracts the DOF.DAT file from the downloaded ZIP archive.
  private func extractDOFFromZip(_ zipData: Data) throws -> Data {
    let archive = try Archive(data: zipData, accessMode: .read)

    guard
      let entry = archive.first(where: {
        $0.path.uppercased().contains("DOF") && $0.path.uppercased().hasSuffix(".DAT")
      })
    else {
      throw DOFProcessorError.dofFileNotFound
    }

    var dofData = Data()
    _ = try archive.extract(entry) { dofData.append($0) }
    return dofData
  }

  // MARK: - Nested Types

  /// Result container for DOF loading.
  struct DOFResult {
    let cycle: SwiftDOF.Cycle?
    let obstacles: [AirportDataCodable.ObstacleCodable]
  }
}

/// Errors that can occur during DOF processing.
enum DOFProcessorError: LocalizedError {
  case invalidURL(String)
  case downloadFailed(Int)
  case dofFileNotFound

  var errorDescription: String? {
    String(localized: "FAA DOF data could not be processed.")
  }

  var failureReason: String? {
    switch self {
      case .invalidURL(let url):
        String(localized: "The URL “\(url)” is invalid.")
      case .downloadFailed(let statusCode):
        String(localized: "Download failed with HTTP status \(statusCode).")
      case .dofFileNotFound:
        String(localized: "DOF.DAT file was not found in archive.")
    }
  }
}
