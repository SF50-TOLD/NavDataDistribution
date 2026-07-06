import Foundation
import Logging
import NavData
import SwiftNASR
import SwiftTimeZoneLookup

/// Errors that can occur during NASR processing.
enum NASRProcessorError: LocalizedError {
  case failedToCreateNASR

  var errorDescription: String? {
    String(localized: "FAA NASR data could not be processed.")
  }

  var failureReason: String? {
    switch self {
      case .failedToCreateNASR:
        String(localized: "Failed to create NASR downloader for the specified cycle.")
    }
  }
}

/// Holds KVO observations to keep them alive during async operations.
/// Thread-safe singleton for storing progress observations.
actor ProgressObservationHolder {
  static let shared = ProgressObservationHolder()

  private var observations: [NSKeyValueObservation] = []

  func add(_ observation: NSKeyValueObservation) {
    observations.append(observation)
  }

  func clearAll() {
    for observation in observations {
      observation.invalidate()
    }
    observations.removeAll()
  }
}

/// Processes FAA NASR (National Airspace System Resources) airport data.
///
/// ``NASRProcessor`` handles downloading and parsing FAA NASR data using SwiftNASR,
/// converting it to the application's codable format.
///
/// ## See Also
///
/// - ``NavDataProcessor``
/// - ``CIFPProcessor``
/// - ``DOFProcessor``
struct NASRProcessor {
  // Progress allocation within NASR processing (out of 100):
  // - Download: 0-22
  // - Parse airports: 22-98
  // - Parse ILS: 98-100
  private static let downloadProgressEnd = 22
  private static let airportsProgressEnd = 98
  private static let ilsProgressEnd = 100

  /// Logger for status messages and errors.
  let logger: Logger

  /// Derives `SurfaceType` from SwiftNASR runway treatment and material data.
  private static func deriveSurfaceType(from runway: SwiftNASR.Runway) -> SurfaceType {
    guard runway.isPaved else { return .turf }

    if runway.treatment == .grooved {
      return .grooved
    }
    if runway.treatment == .PFC || runway.materials.contains(.PFC) {
      return .pfc
    }
    return .paved
  }

  /// Downloads and parses FAA NASR airport data.
  /// - Parameters:
  ///   - cycle: The NASR cycle to download.
  ///   - timezoneLookup: Timezone lookup database for airport locations.
  ///   - onProgress: Callback for progress updates (completed, total).
  /// - Returns: Array of parsed airports in codable format.
  func loadNASRData(
    cycle: SwiftNASR.Cycle,
    timezoneLookup: SwiftTimeZoneLookup,
    onProgress: (@Sendable (Int, Int) async -> Void)? = nil
  ) async throws -> [AirportDataCodable.AirportCodable] {
    await onProgress?(0, 100)

    guard let nasr = NASR.fromInternetToMemory(activeAt: cycle.effectiveDate) else {
      throw NASRProcessorError.failedToCreateNASR
    }

    logger.notice("Loading NASR archive…")
    try await nasr.load { progress in
      // Observe progress from SwiftNASR's load operation
      self.observeProgress(
        progress,
        mappingTo: 0..<Self.downloadProgressEnd,
        onProgress: onProgress
      )
    }
    await onProgress?(Self.downloadProgressEnd, 100)

    try Task.checkCancellation()

    logger.notice("Parsing NASR airports…")
    try await nasr.parse(
      .airports,
      withProgress: { progress in
        // Observe progress from SwiftNASR's airport parsing
        self.observeProgress(
          progress,
          mappingTo: Self.downloadProgressEnd..<Self.airportsProgressEnd,
          onProgress: onProgress
        )
      },
      errorHandler: { error in self.handleParseError(error, context: "airport") }
    )
    await onProgress?(Self.airportsProgressEnd, 100)

    try Task.checkCancellation()

    logger.notice("Parsing NASR ILS data…")
    try await nasr.parse(
      .ILSes,
      withProgress: { progress in
        // Observe progress from SwiftNASR's ILS parsing
        self.observeProgress(
          progress,
          mappingTo: Self.airportsProgressEnd..<Self.ilsProgressEnd,
          onProgress: onProgress
        )
      },
      errorHandler: { error in self.handleParseError(error, context: "ILS") }
    )
    await onProgress?(Self.ilsProgressEnd, 100)

    // Clean up progress observations now that loading/parsing is complete
    await ProgressObservationHolder.shared.clearAll()

    let NASRData = await nasr.data
    guard let airports = await NASRData.airports else {
      return []
    }

    // Build ILS lookup dictionary keyed by (airportSiteNumber, runwayEndId)
    let ilsRecords = await NASRData.ILSFacilities ?? []
    var ilsLookup = [String: ILS]()
    for ils in ilsRecords {
      let key = "\(ils.airportSiteNumber)_\(ils.runwayEndId)"
      ilsLookup[key] = ils
    }
    logger.notice("Loaded \(ilsRecords.count) ILS records")

    var codableAirports = [AirportDataCodable.AirportCodable]()

    for airport in airports {
      guard let elevationFt = airport.referencePoint.elevationFtMSL else { continue }

      // Use SwiftNASR's Measurement-based coordinates and convert to degrees
      let latitude = airport.referencePoint.latitude.converted(to: .degrees)
      let longitude = airport.referencePoint.longitude.converted(to: .degrees)

      let variationDeg =
        airport.magneticVariationDeg.map { Double($0) }
        ?? GeoCalculations.calculateMagneticVariation(latitude.value, longitude.value)

      var runways = [AirportDataCodable.RunwayCodable]()

      for runway in airport.runways {
        if runway.materials.contains(.water) { continue }
        guard let length = runway.length, length.converted(to: .feet).value >= 500 else { continue }

        // Process base end
        if let baseRunway = makeRunwayCodable(
          runway: runway,
          end: runway.baseEnd,
          reciprocalName: runway.reciprocalEnd?.id,
          airportSiteNumber: airport.id,
          ilsLookup: ilsLookup
        ) {
          runways.append(baseRunway)
        }

        // Process reciprocal end
        if let reciprocalEnd = runway.reciprocalEnd,
          let reciprocalRunway = makeRunwayCodable(
            runway: runway,
            end: reciprocalEnd,
            reciprocalName: runway.baseEnd.id,
            airportSiteNumber: airport.id,
            ilsLookup: ilsLookup
          )
        {
          runways.append(reciprocalRunway)
        }
      }

      if runways.isEmpty { continue }

      // Lookup timezone for this airport
      let timeZone = timezoneLookup.simple(
        latitude: Float(latitude.value),
        longitude: Float(longitude.value)
      )

      let codableAirport = AirportDataCodable.AirportCodable(
        recordID: airport.id,
        locationID: airport.LID,
        ICAO_ID: airport.ICAOIdentifier,
        name: airport.name,
        city: airport.city,
        dataSource: "nasr",
        latitude: latitude.value,
        longitude: longitude.value,
        elevation: Double(elevationFt) * 0.3048,  // Convert feet to meters
        variation: variationDeg,
        timeZone: timeZone,
        runways: runways,
        procedures: nil  // Added in DataProcessor from CIFP data
      )

      codableAirports.append(codableAirport)
    }

    return codableAirports
  }

  /// Logs a SwiftNASR record-parse problem and tells the parser to keep going.
  ///
  /// SwiftNASR distinguishes a dropped record (one that couldn't be constructed) from a
  /// kept record with a single unrepresentable field. Both are logged for diagnostics, but
  /// parsing always proceeds so one bad field or record never aborts the entire import.
  /// - Parameters:
  ///   - error: The record-parse problem reported by SwiftNASR.
  ///   - context: Short label for the record category being parsed (e.g. `"airport"`).
  /// - Returns: Always ``ParseDisposition/proceed``.
  private func handleParseError(_ error: RecordParseError, context: String) -> ParseDisposition {
    var metadata: Logger.Metadata = ["context": "\(context)"]

    switch error {
      case let .recordError(recordType, recordID, underlying):
        metadata["recordType"] = "\(recordType.rawValue)"
        if let recordID { metadata["recordID"] = "\(recordID)" }
        metadata["underlying"] = "\(String(describing: underlying))"
        logger.warning("Dropped \(context) record", metadata: metadata)
      case let .fieldError(recordType, recordID, field, value, underlying):
        metadata["recordType"] = "\(recordType.rawValue)"
        if let recordID { metadata["recordID"] = "\(recordID)" }
        metadata["field"] = "\(field)"
        if let value { metadata["value"] = "\(value)" }
        metadata["underlying"] = "\(String(describing: underlying))"
        logger.notice("Kept \(context) record with unrepresentable field", metadata: metadata)
    }

    return .proceed
  }

  /// Sets up KVO observation on a Progress object and maps updates to the target range.
  /// - Parameters:
  ///   - progress: The Progress object from SwiftNASR to observe.
  ///   - range: The range to map progress to (e.g., 0..<35 means 0-35%).
  ///   - onProgress: Callback to report progress.
  private func observeProgress(
    _ progress: Progress,
    mappingTo range: Range<Int>,
    onProgress: (@Sendable (Int, Int) async -> Void)?
  ) {
    guard let onProgress else { return }

    let rangeSize = range.upperBound - range.lowerBound

    // Set up KVO observation on the progress
    // The observation is stored in the ProgressObservationHolder to keep it alive
    // Note: Don't use .initial option to avoid synchronous callback during setup
    let observation = progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
      let fraction = progress.fractionCompleted
      let mapped = range.lowerBound + Int(Double(rangeSize) * fraction)
      Task.detached {
        await onProgress(mapped, 100)
      }
    }

    // Store observation to keep it alive for the duration of the async operation
    Task { await ProgressObservationHolder.shared.add(observation) }
  }

  /// Converts a NASR runway end to the codable format.
  private func makeRunwayCodable(
    runway: SwiftNASR.Runway,
    end: RunwayEnd,
    reciprocalName: String?,
    airportSiteNumber: String,
    ilsLookup: [String: ILS]
  ) -> AirportDataCodable.RunwayCodable? {
    guard let length = runway.length else { return nil }

    // Calculate true heading
    let trueHeading: Double
    if let existingHeading = end.heading?.asTrueBearing().value {
      trueHeading = Double(existingHeading)
    } else if let baseEndLat = runway.baseEnd.threshold?.latitudeArcsec,
      let baseEndLon = runway.baseEnd.threshold?.longitudeArcsec,
      let recipEndLat = runway.reciprocalEnd?.threshold?.latitudeArcsec,
      let recipEndLon = runway.reciprocalEnd?.threshold?.longitudeArcsec
    {
      // Calculate bearing for the current runway end
      if end.id == runway.baseEnd.id {
        trueHeading = Double(
          GeoCalculations.calculateBearing(
            from: (baseEndLat, baseEndLon),
            to: (recipEndLat, recipEndLon)
          )
        )
      } else {
        trueHeading = Double(
          GeoCalculations.calculateBearing(
            from: (recipEndLat, recipEndLon),
            to: (baseEndLat, baseEndLon)
          )
        )
      }
    } else if let reciprocal = runway.reciprocalEnd,
      let reciprocalHeading = reciprocal.heading?.asTrueBearing().value
    {
      let heading = (Int(reciprocalHeading) + 180) % 360
      trueHeading = Double(heading)
    } else {
      return nil
    }

    let elevationMeters = end.touchdownZoneElevation?.converted(to: .meters).value

    // Convert threshold coordinates from arcseconds to decimal degrees
    // Use displaced threshold if available, otherwise use the runway end threshold
    let thresholdLocation = end.displacedThreshold ?? end.threshold,
      thresholdLatitude = thresholdLocation.map { Double($0.latitudeArcsec) / 3600.0 },
      thresholdLongitude = thresholdLocation.map { Double($0.longitudeArcsec) / 3600.0 }

    // Convert width from feet to meters
    let widthMeters = runway.widthFt.map { Double($0) * 0.3048 }

    // Extract threshold crossing height (convert feet to meters)
    let thresholdCrossingHeight = end.thresholdCrossingHeightFtAGL.map { Double($0) * 0.3048 }

    // Calculate glidepath gradient from ILS or visual approach indicator
    // ILS glideslope takes priority over visual glidepath (PAPI/VASI)
    let ilsKey = "\(airportSiteNumber)_\(end.id)"
    let ils = ilsLookup[ilsKey]
    let ilsGlideslopeAngleDeg = ils?.glideSlope?.angleDeg

    // Visual glidepath angle in degrees
    let visualGlidepathAngleDeg = end.visualGlidepathDeg

    // Use ILS glideslope if available, otherwise visual glidepath
    let glidepathAngle = (ilsGlideslopeAngleDeg ?? visualGlidepathAngleDeg).map { Double($0) }

    // Extract displaced threshold distance (convert feet to meters)
    let displacedThresholdDistance = end.thresholdDisplacementFt.map { Double($0) * 0.3048 }

    return AirportDataCodable.RunwayCodable(
      name: end.id,
      elevation: elevationMeters,
      trueHeading: trueHeading,
      gradient: end.gradient.map { Float($0.value / 100) },
      length: length.converted(to: .meters).value,
      takeoffRun: end.TORA?.converted(to: .meters).value,
      takeoffDistance: end.TODA?.converted(to: .meters).value,
      landingDistance: end.LDA?.converted(to: .meters).value,
      surfaceType: Self.deriveSurfaceType(from: runway).rawValue,
      reciprocalName: reciprocalName,
      thresholdLatitude: thresholdLatitude,
      thresholdLongitude: thresholdLongitude,
      width: widthMeters,
      thresholdCrossingHeight: thresholdCrossingHeight,
      glidepathAngle: glidepathAngle,
      displacedThresholdDistance: displacedThresholdDistance
    )
  }
}
