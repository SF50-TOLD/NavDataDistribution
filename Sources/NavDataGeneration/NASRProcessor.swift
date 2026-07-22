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

/// Builds the bridge from CIFP SID identifier to official procedure name.
///
/// NASR's `STARDP` records pair a computer code with the procedure's published
/// name — `"GAPP7.GAP"` with `"GAP SEVEN"`. The portion of the computer code
/// before the exit fix is the CIFP procedure identifier, which makes this the
/// authoritative mapping for departures. Reconstructing it from chart titles
/// alone is impossible for navaid-named SIDs, where the chart reads
/// `VENTURA EIGHT` but CIFP reads `VTU8`.
///
/// Transitions are excluded: SwiftNASR nests them under
/// `DepartureArrivalProcedure/transitions`, so reading only the top-level name
/// keeps titles like `"VENTURA TRANSITION"` out of the index.
enum DepartureNameIndex {
  private static let unassignedCode = "NOT ASSIGNED"

  /// Indexes departure procedure names by CIFP identifier.
  /// - Parameter procedures: All parsed NASR departure and arrival procedures.
  /// - Returns: Official names keyed by CIFP procedure identifier.
  static func build(from procedures: [DepartureArrivalProcedure]) -> [String: String] {
    index(
      codesAndNames: procedures.lazy
        .filter { $0.procedureType == .DP }
        .map { (code: $0.computerCode, name: $0.name) }
    )
  }

  /// Indexes official names by the CIFP identifier embedded in each computer
  /// code.
  ///
  /// A usable code pairs the CIFP procedure identifier with an exit fix, as in
  /// `"GAPP7.GAP"`. Codes without a non-empty identifier before that
  /// separator, and the literal `"NOT ASSIGNED"`, name no procedure and are
  /// skipped.
  /// - Parameter codesAndNames: Computer code and name for each departure.
  /// - Returns: Official names keyed by CIFP procedure identifier.
  static func index(
    codesAndNames: some Sequence<(code: String?, name: String?)>
  ) -> [String: String] {
    var index = [String: String]()

    for (code, name) in codesAndNames {
      guard let code, code != Self.unassignedCode,
        let name, !name.isEmpty,
        let separatorIndex = code.firstIndex(of: "."), separatorIndex != code.startIndex
      else { continue }

      index[String(code[code.startIndex..<separatorIndex])] = name
    }

    return index
  }
}

/// The airports and departure names parsed from a NASR cycle.
struct NASRResult: Sendable {

  /// Airports converted to the application's codable format.
  let airports: [AirportDataCodable.AirportCodable]

  /// Official departure procedure names keyed by CIFP procedure identifier.
  let departureNames: [String: String]
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
  // - Parse airports: 22-94
  // - Parse ILS: 94-96
  // - Parse departure procedures: 96-100
  private static let downloadProgressEnd = 22
  private static let airportsProgressEnd = 94
  private static let ilsProgressEnd = 96
  private static let departureProceduresProgressEnd = 100

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
  /// - Returns: The parsed airports and departure procedure names.
  func loadNASRData(
    cycle: SwiftNASR.Cycle,
    timezoneLookup: SwiftTimeZoneLookup,
    onProgress: (@Sendable (Int, Int) async -> Void)? = nil
  ) async throws -> NASRResult {
    await onProgress?(0, 100)

    guard let nasr = NASR.fromInternetToMemory(activeAt: cycle.effectiveDate) else {
      throw NASRProcessorError.failedToCreateNASR
    }

    logger.notice("Loading NASR archive…")
    try await nasr.load { progress in
      // Observe progress from SwiftNASR's load operation
      pollProgress(
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
        pollProgress(
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
        pollProgress(
          progress,
          mappingTo: Self.airportsProgressEnd..<Self.ilsProgressEnd,
          onProgress: onProgress
        )
      },
      errorHandler: { error in self.handleParseError(error, context: "ILS") }
    )
    await onProgress?(Self.ilsProgressEnd, 100)

    try Task.checkCancellation()

    logger.notice("Parsing NASR departure procedures…")
    do {
      try await nasr.parse(
        .departureArrivalProceduresComplete,
        withProgress: { progress in
          pollProgress(
            progress,
            mappingTo: Self.ilsProgressEnd..<Self.departureProceduresProgressEnd,
            onProgress: onProgress
          )
        },
        errorHandler: { error in self.handleParseError(error, context: "departure procedure") }
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      logger.warning(
        "Could not parse NASR departure procedures; departures will have no names: \(error)"
      )
    }
    await onProgress?(Self.departureProceduresProgressEnd, 100)

    let NASRData = await nasr.data
    let departureNames = DepartureNameIndex.build(
      from: await NASRData.departureArrivalProceduresComplete ?? []
    )
    logger.notice("Loaded \(departureNames.count) NASR departure procedure names")

    guard let airports = await NASRData.airports else {
      return .init(airports: [], departureNames: departureNames)
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

    return .init(airports: codableAirports, departureNames: departureNames)
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
