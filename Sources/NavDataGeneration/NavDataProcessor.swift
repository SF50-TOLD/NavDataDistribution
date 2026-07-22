import Foundation
import Logging
import NavData
import StreamingLZMAXZ
import SwiftCIFP
import SwiftDOF
import SwiftNASR
import SwiftTimeZoneLookup

/// Errors that can occur during data processing.
enum NavDataProcessorError: LocalizedError {
  case missingCycleDates(source: String)

  var errorDescription: String? {
    String(localized: "Missing cycle dates")
  }

  var failureReason: String? {
    switch self {
      case .missingCycleDates(let source):
        String(localized: "Failed to determine cycle dates for \(source) data.")
    }
  }
}

/// Orchestrates the complete airport and obstacle data processing pipeline.
///
/// ``NavDataProcessor`` coordinates the loading, merging, and output of data from multiple sources:
///
/// 1. Initialize timezone lookup database
/// 2. Download and parse FAA NASR data using SwiftNASR
/// 3. Download and parse OurAirports CSV data
/// 4. Download and parse CIFP data for departure procedures
/// 5. Download and parse DOF obstacle data
/// 6. Merge datasets (NASR takes priority)
/// 7. Write to property list format
/// 8. Compress using XZ/LZMA
///
/// ## Progress Tracking
///
/// The processor reports progress through the ``onProgress`` callback with
/// 100 total units distributed across each major step. Unit allocations are
/// derived from measured processing times (Release build, ~29,269 airports,
/// ~650,600 obstacles, cycle 2026-07-09, total ~50 s):
///
/// | Step             | Time | Units | Cumulative |
/// |------------------|------|-------|------------|
/// | NASR loading     |  12s |    24 |         24 |
/// | OurAirports      |   2s |     4 |         28 |
/// | CIFP             |   1s |     2 |         30 |
/// | d-TPP            |  12s |    24 |         54 |
/// | DOF              |   2s |     4 |         58 |
/// | Merge            |  10s |    20 |         78 |
/// | Write + compress |  11s |    22 |        100 |
///
/// ## See Also
///
/// - ``NASRProcessor``
/// - ``CIFPProcessor``
/// - ``DOFProcessor``
/// - ``OurAirportsLoader``
public struct NavDataProcessor: Sendable {

  // MARK: - Progress Phase Boundaries

  /// Cumulative progress boundaries for each processing phase.
  ///
  /// Derived from measured Release-build processing times (cycle 2026-07-09,
  /// ~29,269 airports, ~650,600 obstacles, ~50 s total). See class-level doc
  /// for the full timing table.
  private static let nasrEnd: Int64 = 24
  private static let ourAirportsEnd: Int64 = 28
  private static let cifpEnd: Int64 = 30
  private static let dtppEnd: Int64 = 54
  private static let dofEnd: Int64 = 58
  private static let mergeEnd: Int64 = 78

  /// The NASR cycle to download (e.g., 2501 for January 2025).
  let cycle: SwiftNASR.Cycle

  /// Directory where output files will be written.
  let outputLocation: URL

  /// Logger for status messages and errors.
  let logger: Logger

  /// Callback for progress updates (completed units out of 100, status message).
  public var onProgress: (@MainActor @Sendable (_ completed: Int64, _ description: String) -> Void)?

  // MARK: - Initializers

  /// Creates a processor for the given cycle.
  /// - Parameters:
  ///   - cycle: The NASR cycle to generate.
  ///   - outputLocation: Directory where the `<cycle>.plist.lzma` file will be written.
  ///   - logger: Logger for status messages and errors.
  public init(cycle: SwiftNASR.Cycle, outputLocation: URL, logger: Logger) {
    self.cycle = cycle
    self.outputLocation = outputLocation
    self.logger = logger
  }

  // MARK: - Main Processing Pipeline

  /// Executes the complete data processing pipeline.
  /// - Returns: The URL of the written `<cycle>.plist.lzma` file.
  @discardableResult
  public func process() async throws -> URL {
    // Load and merge all data (0 → mergeEnd)
    let loadedData = try await loadAndMergeAllData()

    // Build cycle information with effective/expiration dates
    guard let nasrEffective = cycle.effectiveDate,
      let nasrExpires = cycle.expirationDate
    else {
      throw NavDataProcessorError.missingCycleDates(source: "NASR")
    }

    var cifpInfo: AirportDataCodable.CycleInfo?
    if let cifpCycle = loadedData.cifpCycle {
      guard let effective = cifpCycle.effectiveDate,
        let expires = cifpCycle.expirationDate
      else {
        throw NavDataProcessorError.missingCycleDates(source: "CIFP")
      }
      cifpInfo = AirportDataCodable.CycleInfo(
        name: "\(cifpCycle)",
        effective: effective,
        expires: expires
      )
    }

    var dofInfo: AirportDataCodable.CycleInfo?
    if let dofCycle = loadedData.dofCycle {
      guard let effective = dofCycle.effectiveDate,
        let expires = dofCycle.expirationDate
      else {
        throw NavDataProcessorError.missingCycleDates(source: "DOF")
      }
      dofInfo = AirportDataCodable.CycleInfo(
        name: "\(dofCycle)",
        effective: effective,
        expires: expires
      )
    }

    let cycles = AirportDataCodable.DataCycles(
      nasr: AirportDataCodable.CycleInfo(
        name: "\(cycle)",
        effective: nasrEffective,
        expires: nasrExpires
      ),
      cifp: cifpInfo,
      dof: dofInfo
    )

    // Create combined codable data structure with airports, obstacles, and navaids
    let codableData = AirportDataCodable(
      cycles: cycles,
      nasrCycle: .init(year: cycle.year, month: cycle.month, day: cycle.day),
      ourAirportsLastUpdated: loadedData.ourAirportsLastUpdated,
      airports: loadedData.airports,
      obstacles: loadedData.obstacles,
      navaids: loadedData.navaids
    )

    // Write and compress combined data (100 - mergeEnd units)
    let lzmaFile = try writeAndCompressData(
      codableData,
      filename: "\(cycle)",
      dataDescription: "airport and obstacle"
    )
    await reportProgress(100, String(localized: "Complete!"))

    let airportCount = loadedData.airports.count
    let obstacleCount = loadedData.obstacles.count
    logger.notice("Complete - processed \(airportCount) airports and \(obstacleCount) obstacles")

    return lzmaFile
  }

  // MARK: - Progress Reporting

  /// Reports progress via the callback.
  private func reportProgress(_ completed: Int64, _ description: String) async {
    if let onProgress {
      await onProgress(completed, description)
    }
  }

  // MARK: - Data Loading

  /// Loads all data sources and merges them into the final airport list.
  private func loadAndMergeAllData() async throws -> LoadedData {
    logger.notice("Initializing timezone lookup database…")
    await reportProgress(0, String(localized: "Initializing…"))
    let timezoneLookup = try SwiftTimeZoneLookup()

    try Task.checkCancellation()

    // Load NASR data (0 → nasrEnd)
    logger.notice("Loading NASR data for cycle \(cycle)…")
    await reportProgress(0, String(localized: "Loading NASR data…"))
    let nasrProcessor = NASRProcessor(logger: logger)
    let nasrResult = try await nasrProcessor.loadNASRData(
      cycle: cycle,
      timezoneLookup: timezoneLookup
    ) { completed, total in
      let mapped = Int64(Double(completed) / Double(total) * Double(Self.nasrEnd))
      await self.reportProgress(mapped, String(localized: "Loading NASR data…"))
    }

    try Task.checkCancellation()

    // Load OurAirports data (nasrEnd → ourAirportsEnd)
    let ourAirportsSpan = Self.ourAirportsEnd - Self.nasrEnd
    logger.notice("Loading OurAirports data…")
    await reportProgress(Self.nasrEnd, String(localized: "Loading OurAirports data…"))
    let ourAirportsLoader = OurAirportsLoader(logger: logger)
    let (ourAirports, ourAirportsLastUpdated) = try await ourAirportsLoader.loadAirports {
      completed,
      total in
      let mapped = Self.nasrEnd + Int64(Double(completed) / Double(total) * Double(ourAirportsSpan))
      await self.reportProgress(mapped, String(localized: "Loading OurAirports data…"))
    }

    try Task.checkCancellation()

    // Load CIFP data (ourAirportsEnd → cifpEnd)
    let cifpSpan = Self.cifpEnd - Self.ourAirportsEnd
    logger.notice("Loading CIFP data…")
    await reportProgress(Self.ourAirportsEnd, String(localized: "Loading CIFP data…"))
    let cifpProcessor = CIFPProcessor(logger: logger)
    let cifpResult = try await cifpProcessor.loadCIFPData(cycle: cycle) { completed, total in
      let mapped = Self.ourAirportsEnd + Int64(Double(completed) / Double(total) * Double(cifpSpan))
      await self.reportProgress(mapped, String(localized: "Loading CIFP data…"))
    }
    await reportProgress(Self.cifpEnd, String(localized: "Loading CIFP data…"))

    try Task.checkCancellation()

    // Load d-TPP chart names (cifpEnd → dtppEnd). Naming is a nicety, so a
    // failure here degrades procedure names rather than failing the build.
    let dtppSpan = Self.dtppEnd - Self.cifpEnd
    logger.notice("Loading d-TPP chart data…")
    await reportProgress(Self.cifpEnd, String(localized: "Loading d-TPP chart data…"))
    let dtppLoader = DTPPLoader(logger: logger)
    var nameResolver: ProcedureNameResolver?
    do {
      let charts = try await dtppLoader.loadCharts(cycle: cycle) { completed, total in
        let mapped = Self.cifpEnd + Int64(Double(completed) / Double(total) * Double(dtppSpan))
        await self.reportProgress(mapped, String(localized: "Loading d-TPP chart data…"))
      }
      nameResolver = .init(charts: charts, departureNames: nasrResult.departureNames)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      logger.warning("Could not load d-TPP data; procedures will use generated names: \(error)")
    }
    await reportProgress(Self.dtppEnd, String(localized: "Loading d-TPP chart data…"))

    // Load DOF data (dtppEnd → dofEnd)
    let dofSpan = Self.dofEnd - Self.dtppEnd
    logger.notice("Loading DOF data…")
    await reportProgress(Self.dtppEnd, String(localized: "Loading DOF data…"))
    let dofProcessor = DOFProcessor(logger: logger)
    let dofResult = try await dofProcessor.loadDOFData { completed, total in
      let mapped = Self.dtppEnd + Int64(Double(completed) / Double(total) * Double(dofSpan))
      await self.reportProgress(mapped, String(localized: "Loading DOF data…"))
    }
    await reportProgress(Self.dofEnd, String(localized: "Loading DOF data…"))

    try Task.checkCancellation()

    // Merge and de-duplicate (dofEnd → mergeEnd)
    logger.notice("Merging and de-duplicating airport data…")
    await reportProgress(Self.dofEnd, String(localized: "Merging and de-duplicating airport data…"))
    let mergedAirports = await mergeAirports(
      NASRAirports: nasrResult.airports,
      ourAirports: ourAirports,
      timezoneLookup: timezoneLookup,
      cifpData: cifpResult.data,
      cifpProcessor: cifpProcessor,
      nameResolver: nameResolver
    )
    await reportProgress(Self.mergeEnd, String(localized: "Merging complete"))

    try Task.checkCancellation()

    // Extract DME-capable navaids from CIFP data
    let navaids: [NavaidCodable]?
    if let cifpData = cifpResult.data {
      navaids = await extractDMENavaids(from: cifpData)
    } else {
      navaids = nil
    }

    return LoadedData(
      airports: mergedAirports,
      ourAirportsLastUpdated: ourAirportsLastUpdated,
      cifpCycle: cifpResult.cycle,
      dofCycle: dofResult.cycle,
      obstacles: dofResult.obstacles,
      navaids: navaids
    )
  }

  // MARK: - File Output

  /// Writes data to plist and compresses with XZ/LZMA.
  private func writeAndCompressData<T: Encodable>(
    _ data: T,
    filename: String,
    dataDescription: String
  ) throws -> URL {
    logger.notice("Writing \(dataDescription) data to file…")

    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let encodedData = try encoder.encode(data)

    let plistFile = outputLocation.appendingPathComponent("\(filename).plist")
    if FileManager.default.fileExists(atPath: plistFile.path) {
      logger.warning("Overwriting existing file: \(plistFile.lastPathComponent)")
    }
    try encodedData.write(to: plistFile)

    logger.notice("Compressing \(dataDescription) data…")

    let compressedData = try encodedData.xzCompressed()
    let lzmaFile = outputLocation.appendingPathComponent("\(filename).plist.lzma")
    if FileManager.default.fileExists(atPath: lzmaFile.path) {
      logger.warning("Overwriting existing file: \(lzmaFile.lastPathComponent)")
    }
    try compressedData.write(to: lzmaFile)

    return lzmaFile
  }

  // MARK: - Airport Merging

  /// Merges NASR and OurAirports data, deduplicating by location ID.
  private func mergeAirports(
    NASRAirports: [AirportDataCodable.AirportCodable],
    ourAirports: [OurAirportData],
    timezoneLookup: SwiftTimeZoneLookup,
    cifpData: CIFPData?,
    cifpProcessor: CIFPProcessor,
    nameResolver: ProcedureNameResolver?
  ) async -> [AirportDataCodable.AirportCodable] {
    var mergedAirports = [AirportDataCodable.AirportCodable]()
    var NASRLocationIds = Set<String>()
    var stats = NamingStats()

    // Add all NASR airports first (they have priority)
    for airport in NASRAirports {
      // Add procedures from CIFP if available
      let procedures: [AirportDataCodable.ProcedureCodable]?
      if let cifpData, let icaoId = airport.ICAO_ID {
        let departures = await cifpProcessor.extractDepartureProcedures(
          icaoId: icaoId,
          cifpData: cifpData,
          nameResolver: nameResolver
        )
        let approaches = await cifpProcessor.extractApproachProcedures(
          icaoId: icaoId,
          cifpData: cifpData,
          nameResolver: nameResolver
        )
        stats += departures.stats
        stats += approaches.stats
        let combined = departures.procedures + approaches.procedures
        procedures = combined.isEmpty ? nil : combined
      } else {
        procedures = nil
      }

      let airportWithProcedures = AirportDataCodable.AirportCodable(
        recordID: airport.recordID,
        locationID: airport.locationID,
        ICAO_ID: airport.ICAO_ID,
        name: airport.name,
        city: airport.city,
        dataSource: airport.dataSource,
        latitude: airport.latitude,
        longitude: airport.longitude,
        elevation: airport.elevation,
        variation: airport.variation,
        timeZone: airport.timeZone,
        runways: airport.runways,
        procedures: procedures
      )

      mergedAirports.append(airportWithProcedures)
      NASRLocationIds.insert(airport.locationID)
    }

    // Add OurAirports data that doesn't exist in NASR
    var ourAirportsAdded = 0
    for ourAirport in ourAirports {
      // Skip if this airport's local_id matches a NASR locationID
      if !ourAirport.localId.isEmpty && NASRLocationIds.contains(ourAirport.localId) {
        continue
      }

      // Convert OurAirports data to our codable format
      var runways = [AirportDataCodable.RunwayCodable]()
      for runway in ourAirport.runways {
        let takeoffRun = runway.lengthFt - runway.displacedThresholdFt

        runways.append(
          AirportDataCodable.RunwayCodable(
            name: runway.name,
            elevation: runway.elevationFt.map { $0 * 0.3048 },  // Convert feet to meters
            trueHeading: runway.trueHeading,
            gradient: nil,  // OurAirports doesn't provide gradient
            length: runway.lengthFt * 0.3048,  // Convert feet to meters
            takeoffRun: takeoffRun > 0 ? takeoffRun * 0.3048 : nil,
            takeoffDistance: nil,  // Not available in OurAirports
            landingDistance: nil,  // Not available in OurAirports
            surfaceType: runway.surfaceType.rawValue,
            reciprocalName: runway.reciprocalName,
            thresholdLatitude: runway.thresholdLatitude,
            thresholdLongitude: runway.thresholdLongitude,
            width: runway.widthFt.map { $0 * 0.3048 },  // Convert feet to meters
            thresholdCrossingHeight: nil,  // Not available in OurAirports
            glidepathAngle: nil,  // Not available in OurAirports
            displacedThresholdDistance: runway.displacedThresholdFt > 0
              ? runway.displacedThresholdFt * 0.3048 : nil
          )
        )
      }

      if runways.isEmpty { continue }

      // Calculate magnetic variation for this location
      let variation = GeoCalculations.calculateMagneticVariation(
        ourAirport.latitude,
        ourAirport.longitude
      )

      // Lookup timezone for this airport
      let timeZone = timezoneLookup.simple(
        latitude: Float(ourAirport.latitude),
        longitude: Float(ourAirport.longitude)
      )

      // Add procedures from CIFP if available (OurAirports may have ICAO IDs too)
      let procedures: [AirportDataCodable.ProcedureCodable]?
      if let cifpData, let icaoId = ourAirport.ICAO_ID {
        let departures = await cifpProcessor.extractDepartureProcedures(
          icaoId: icaoId,
          cifpData: cifpData,
          nameResolver: nameResolver
        )
        let approaches = await cifpProcessor.extractApproachProcedures(
          icaoId: icaoId,
          cifpData: cifpData,
          nameResolver: nameResolver
        )
        stats += departures.stats
        stats += approaches.stats
        let combined = departures.procedures + approaches.procedures
        procedures = combined.isEmpty ? nil : combined
      } else {
        procedures = nil
      }

      let codableAirport = AirportDataCodable.AirportCodable(
        recordID: ourAirport.id,
        locationID: ourAirport.localId,
        ICAO_ID: ourAirport.ICAO_ID,
        name: ourAirport.name,
        city: ourAirport.municipality,
        dataSource: "ourAirports",
        latitude: ourAirport.latitude,
        longitude: ourAirport.longitude,
        elevation: ourAirport.elevationFt * 0.3048,  // Convert feet to meters
        variation: variation,
        timeZone: timeZone,
        runways: runways,
        procedures: procedures
      )

      mergedAirports.append(codableAirport)
      ourAirportsAdded += 1
    }

    logger.notice("Added \(ourAirportsAdded) airports from OurAirports (non-duplicates)")
    logger.notice("Total airports after merge: \(mergedAirports.count)")

    logger.notice(
      """
      Named \(stats.approachesNamed)/\(stats.approachesTotal) approaches \
      (\(NamingStats.percentage(stats.approachesNamed, of: stats.approachesTotal)))
      """
    )
    logger.notice(
      """
      Named \(stats.departuresNamed)/\(stats.departuresTotal) departures \
      (\(NamingStats.percentage(stats.departuresNamed, of: stats.departuresTotal)))
      """
    )

    return mergedAirports
  }

  // MARK: - Navaid Extraction

  /// Extracts DME-capable navaids from CIFP data.
  private func extractDMENavaids(from cifpData: CIFPData) async -> [NavaidCodable] {
    let vhfNavaids = await cifpData.vhfNavaids
    var navaids = [NavaidCodable]()

    for (_, navaid) in vhfNavaids {
      guard navaid.hasDME else { continue }

      // Prefer DME transponder coordinate, fall back to VOR
      guard let coordinate = navaid.dmeCoordinate ?? navaid.vorCoordinate else { continue }

      let navaidCodable = NavaidCodable(
        identifier: navaid.identifier,
        icaoRegion: navaid.icaoRegion,
        type: navaid.navaidClass.description,
        latitude: coordinate.latitudeDeg,
        longitude: coordinate.longitudeDeg,
        elevationFt: navaid.dmeElevationFt.map { Double($0) }
      )
      navaids.append(navaidCodable)
    }

    logger.notice("Extracted \(navaids.count) DME-capable navaids from CIFP data")
    return navaids
  }

  // MARK: - Nested Types

  /// Container for all loaded data sources.
  private struct LoadedData {
    let airports: [AirportDataCodable.AirportCodable]
    let ourAirportsLastUpdated: Date?
    let cifpCycle: SwiftCIFP.Cycle?
    let dofCycle: SwiftDOF.Cycle?
    let obstacles: [AirportDataCodable.ObstacleCodable]
    let navaids: [NavaidCodable]?
  }
}
