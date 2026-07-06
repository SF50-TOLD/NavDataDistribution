import Foundation
import Logging
import NavData
import SwiftCIFP
import SwiftNASR
import ZIPFoundation

/// Processes FAA CIFP (Coded Instrument Flight Procedures) data.
///
/// ``CIFPProcessor`` handles downloading and parsing FAA CIFP data using SwiftCIFP,
/// converting it to the application's codable format.
///
/// ## See Also
///
/// - ``NavDataProcessor``
/// - ``NASRProcessor``
/// - ``DOFProcessor``
struct CIFPProcessor {
  /// Path terminators that use DME distance for termination.
  private static let dmePathTerminators: Set<PathTerminator> = [
    .trackFromFixDME,
    .trackFromFixDistance,  // FC: routeDistanceNMOrMinutes is ground distance, not slant range
    .courseToDME,
    .headingToDME
  ]

  /// Path terminators that use a VOR radial for termination.
  private static let radialPathTerminators: Set<PathTerminator> = [
    .courseToRadial,
    .headingToRadial
  ]

  private static let cifpURLTemplate = "https://aeronav.faa.gov/Upload_313-d/cifp/CIFP_%@.zip"

  // Progress allocation within CIFP processing (out of 100):
  // - Download: 0-30
  // - Parse: 30-90
  // - Link: 90-100
  private static let downloadProgressEnd = 30
  private static let parseProgressEnd = 90
  private static let linkProgressEnd = 100

  /// Logger for status messages and errors.
  let logger: Logger

  // MARK: - Type Methods

  /// Constructs a human-readable approach name from CIFP data.
  ///
  /// The CIFP identifier after the type character contains a runway designator
  /// (1-2 digits + optional L/C/R) and optional multiple indicator letter.
  /// For example: "I19L" → ILS RWY 19L, "H10RZ" → RNP AR Z RWY 10R,
  /// "R12-Y" → RNAV Y RWY 12. Circling approaches use a dash: "VOR-A" → VOR/TAC-A.
  static func approachName(type: String, identifier: String) -> String {
    let afterType = String(identifier.dropFirst())

    // Match runway approaches: 1-2 digits, optional L/C/R, optional dash, optional multiple indicator
    if let match = afterType.wholeMatch(of: /(\d{1,2}[LCR]?)-?([A-Z])?/) {
      let runway = String(match.1)
      if let mult = match.2 {
        return "\(type) \(mult) RWY \(runway)"
      }
      return "\(type) RWY \(runway)"
    }

    // Circling approach: extract designator after last dash
    if let dashIndex = identifier.lastIndex(of: "-") {
      let designator = String(identifier[identifier.index(after: dashIndex)...])
      return "\(type)-\(designator)"
    }

    return "\(type) \(identifier)"
  }

  /// Extracts DME-related fields from a procedure leg, if applicable.
  ///
  /// Returns the recommended navaid identifier, its ICAO region, and the DME
  /// termination distance for legs that use DME distance as a terminator.
  static func dmeFields(
    from leg: ProcedureLeg
  ) -> (navaidIdentifier: String?, navaidICAO: String?, distanceNM: Double?) {
    guard let pt = leg.pathTerminator, dmePathTerminators.contains(pt) else {
      return (nil, nil, nil)
    }
    return (leg.recommendedNavaid, leg.recommendedNavaidICAO, leg.routeDistanceNMOrMinutes)
  }

  /// Extracts radial-related fields from a procedure leg, if applicable.
  ///
  /// Returns the recommended navaid identifier, its ICAO region, and the
  /// magnetic radial bearing for legs that terminate at a VOR radial.
  static func radialFields(
    from leg: ProcedureLeg
  ) -> (navaidIdentifier: String?, navaidICAO: String?, thetaDeg: Double?) {
    guard let pt = leg.pathTerminator, radialPathTerminators.contains(pt) else {
      return (nil, nil, nil)
    }
    return (leg.recommendedNavaid, leg.recommendedNavaidICAO, leg.thetaDeg)
  }

  /// Converts a SwiftCIFP procedure leg to a ``LegTypeCodable``.
  ///
  /// Returns `nil` for unplottable leg types (FM, VM). Throws if required data
  /// (course, arc radius, turn direction) is missing for a leg type that requires it.
  private static func legType(
    from leg: ProcedureLeg
  ) throws -> LegTypeCodable? {
    guard let pt = leg.pathTerminator else { return nil }

    switch pt {
      case .initialFix:
        return .init(type: .initialFix)
      case .trackToFix:
        return .init(type: .trackToFix, course: leg.magneticCourseDeg)
      case .courseToFix:
        return .init(type: .courseToFix, course: try requireCourse(from: leg, for: pt))
      case .directToFix:
        return .init(type: .directToFix)
      case .radiusToFix:
        return .init(
          type: .radiusToFix,
          course: try requireCourse(from: leg, for: pt),
          arcRadius: try requireArcRadius(from: leg, for: pt)
        )
      case .arcToFix:
        return .init(
          type: .arcToFix,
          course: try requireCourse(from: leg, for: pt),
          arcRadius: try requireRho(from: leg, for: pt)
        )
      case .holdToFix:
        return .init(
          type: .holdToFix,
          course: try requireCourse(from: leg, for: pt),
          turnDirection: try requireTurnDirection(from: leg, for: pt)
        )
      case .holdToAltitude:
        return .init(
          type: .holdToAltitude,
          course: try requireCourse(from: leg, for: pt),
          turnDirection: try requireTurnDirection(from: leg, for: pt)
        )
      case .holdManual:
        return .init(
          type: .holdManual,
          course: try requireCourse(from: leg, for: pt),
          turnDirection: try requireTurnDirection(from: leg, for: pt)
        )
      case .fixToAltitude:
        return .init(type: .fixToAltitude, course: try requireCourse(from: leg, for: pt))
      case .trackFromFixDistance:
        return .init(type: .trackFromFixDistance, course: try requireCourse(from: leg, for: pt))
      case .trackFromFixDME:
        return .init(type: .trackFromFixDME, course: try requireCourse(from: leg, for: pt))
      case .courseToAltitude:
        return .init(type: .courseToAltitude, course: try requireCourse(from: leg, for: pt))
      case .courseToDME:
        return .init(type: .courseToDME, course: try requireCourse(from: leg, for: pt))
      case .courseToIntercept:
        return .init(type: .courseToIntercept, course: try requireCourse(from: leg, for: pt))
      case .courseToRadial:
        return .init(type: .courseToRadial, course: try requireCourse(from: leg, for: pt))
      case .headingToAltitude:
        return .init(type: .headingToAltitude, course: try requireCourse(from: leg, for: pt))
      case .headingToDME:
        return .init(type: .headingToDME, course: try requireCourse(from: leg, for: pt))
      case .headingToIntercept:
        return .init(type: .headingToIntercept, course: try requireCourse(from: leg, for: pt))
      case .headingToRadial:
        return .init(type: .headingToRadial, course: try requireCourse(from: leg, for: pt))
      case .procedureTurn:
        return .init(
          type: .procedureTurn,
          course: try requireCourse(from: leg, for: pt),
          turnDirection: try requireTurnDirection(from: leg, for: pt)
        )
      case .fromFixManual, .headingManual:
        return nil
    }
  }

  private static func requireCourse(
    from leg: ProcedureLeg,
    for pathTerminator: PathTerminator
  ) throws -> Double {
    guard let course = leg.magneticCourseDeg else {
      throw CIFPProcessorError.missingLegData(
        pathTerminator: String(describing: pathTerminator),
        field: "magneticCourseDeg"
      )
    }
    return course
  }

  private static func requireArcRadius(
    from leg: ProcedureLeg,
    for pathTerminator: PathTerminator
  ) throws -> Double {
    guard let arcRadius = leg.arcRadiusNM else {
      throw CIFPProcessorError.missingLegData(
        pathTerminator: String(describing: pathTerminator),
        field: "arcRadiusNM"
      )
    }
    return arcRadius
  }

  private static func requireRho(
    from leg: ProcedureLeg,
    for pathTerminator: PathTerminator
  ) throws -> Double {
    guard let rho = leg.rhoNM else {
      throw CIFPProcessorError.missingLegData(
        pathTerminator: String(describing: pathTerminator),
        field: "rhoNM"
      )
    }
    return rho
  }

  private static func requireTurnDirection(
    from leg: ProcedureLeg,
    for pathTerminator: PathTerminator
  ) throws -> String {
    guard let td = leg.turnDirection else {
      throw CIFPProcessorError.missingLegData(
        pathTerminator: String(describing: pathTerminator),
        field: "turnDirection"
      )
    }
    switch td {
      case .left: return "left"
      case .right: return "right"
      case .either: return "either"
    }
  }

  // MARK: - Instance Methods

  /// Downloads and parses CIFP data for the specified cycle.
  /// - Parameters:
  ///   - cycle: The NASR cycle to download CIFP data for.
  ///   - onProgress: Callback for progress updates (completed, total).
  /// - Returns: A `CIFPResult` containing the parsed data and cycle.
  func loadCIFPData(
    cycle: SwiftNASR.Cycle,
    onProgress: (@Sendable (Int, Int) async -> Void)? = nil
  ) async throws -> CIFPResult {
    await onProgress?(0, 100)

    // CIFP data is available from the FAA at this URL pattern
    // Format: CIFP_YYMMDD.zip (e.g., CIFP_250102.zip for January 2, 2025)
    let dateString = formatCIFPDate(cycle)
    let cifpURLString = String(format: Self.cifpURLTemplate, dateString)
    guard let cifpURL = URL(string: cifpURLString) else {
      throw CIFPProcessorError.invalidURL(cifpURLString)
    }

    logger.notice("Downloading CIFP data from \(cifpURL)…")

    // Download the ZIP file
    let (downloadedData, response) = try await URLSession.shared.data(from: cifpURL)
    await onProgress?(Self.downloadProgressEnd, 100)

    if let httpResponse = response as? HTTPURLResponse,
      !(200..<300).contains(httpResponse.statusCode)
    {
      throw CIFPProcessorError.downloadFailed(httpResponse.statusCode)
    }

    try Task.checkCancellation()

    // Extract CIFP data from ZIP
    let cifpData = try extractCIFPFromZip(downloadedData)

    // Parse CIFP
    logger.notice("Parsing CIFP data…")
    let cifp = try CIFP(
      data: cifpData,
      progressHandler: { progress in
        self.observeProgress(
          progress,
          mappingTo: Self.downloadProgressEnd..<Self.parseProgressEnd,
          onProgress: onProgress
        )
      },
      errorCallback: { error, lineNumber in
        if let lineNumber {
          self.logger.debug("CIFP parse error at line \(lineNumber): \(error)")
        } else {
          self.logger.debug("CIFP parse error: \(error)")
        }
      }
    )
    await onProgress?(Self.parseProgressEnd, 100)

    try Task.checkCancellation()

    // Create linked data for fix resolution
    logger.notice("Linking CIFP data…")
    let linked = await cifp.linked()
    await onProgress?(Self.linkProgressEnd, 100)

    let airportCount = await linked.airports.count
    logger.notice("Loaded CIFP data with \(airportCount) airports for cycle \(cifp.cycle)")
    return CIFPResult(cycle: cifp.cycle, data: linked)
  }

  /// Sets up KVO observation on a Progress object and maps updates to the target range.
  /// - Parameters:
  ///   - progress: The Progress object from SwiftCIFP to observe.
  ///   - range: The range to map progress to (e.g., 30..<90 means 30-90%).
  ///   - onProgress: Callback to report progress.
  private func observeProgress(
    _ progress: Progress,
    mappingTo range: Range<Int>,
    onProgress: (@Sendable (Int, Int) async -> Void)?
  ) {
    guard let onProgress else { return }

    let rangeSize = range.upperBound - range.lowerBound

    // Set up KVO observation on the progress
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

  /// Extracts the CIFP file from the downloaded ZIP archive.
  private func extractCIFPFromZip(_ zipData: Data) throws -> Data {
    let archive = try Archive(data: zipData, accessMode: .read)

    guard let entry = archive.first(where: { $0.path.hasPrefix("FAACIFP") }) else {
      throw CIFPProcessorError.cifpFileNotFound
    }

    var cifpData = Data()
    _ = try archive.extract(entry) { cifpData.append($0) }
    return cifpData
  }

  /// Formats NASR cycle date for CIFP URL (YYMMDD format).
  private func formatCIFPDate(_ cycle: SwiftNASR.Cycle) -> String {
    let yearSuffix = cycle.year % 100
    return String(format: "%02d%02d%02d", yearSuffix, cycle.month, cycle.day)
  }

  /// Extracts departure procedures for an airport from CIFP data.
  /// - Parameters:
  ///   - icaoId: The ICAO identifier of the airport.
  ///   - cifpData: The parsed CIFP linked data.
  /// - Returns: Array of departure procedures for the airport.
  func extractDepartureProcedures(
    icaoId: String,
    cifpData: CIFPData
  ) async -> [AirportDataCodable.ProcedureCodable] {
    guard let cifpAirport = await cifpData.airports[icaoId] else {
      return []
    }

    // Group all SID records by identifier to collect runway transitions and common routes
    let sidsByIdentifier = Dictionary(grouping: cifpAirport.sids, by: \.identifier)

    var procedures = [AirportDataCodable.ProcedureCodable]()

    for (identifier, sids) in sidsByIdentifier {
      var segments = [AirportDataCodable.SegmentCodable]()
      var maxGradient: Double?

      for sid in sids {
        // Only include runway transitions and common routes; skip enroute transitions etc.
        let runwayNames: [String]?
        if sid.routeType.isRunwayTransition {
          runwayNames = sid.runwayNames.map { $0.removingRWPrefix() }.sorted()
        } else if sid.routeType == .commonRoute || sid.routeType == .rnavCommonRoute
          || sid.routeType == .fmsCommonRoute
        {
          runwayNames = nil
        } else {
          continue
        }

        let (extractedLegs, requiredGradient) = await extractLegsAndGradient(
          sid: sid,
          cifpData: cifpData
        )
        guard !extractedLegs.isEmpty else { continue }

        if let gradient = requiredGradient {
          maxGradient = max(maxGradient ?? 0, gradient)
        }

        segments.append(
          AirportDataCodable.SegmentCodable(runwayNames: runwayNames, legs: extractedLegs)
        )
      }

      let procedure = AirportDataCodable.ProcedureCodable(
        type: "departure",
        identifier: identifier,
        requiredClimbGradientFtPerNM: maxGradient,
        segments: segments.isEmpty ? nil : segments
      )
      procedures.append(procedure)
    }

    return procedures.sorted { $0.identifier < $1.identifier }
  }

  /// Extracts approach procedures for an airport from CIFP data.
  /// - Parameters:
  ///   - icaoId: The ICAO identifier of the airport.
  ///   - cifpData: The parsed CIFP linked data.
  /// - Returns: Array of approach procedures for the airport.
  func extractApproachProcedures(
    icaoId: String,
    cifpData: CIFPData
  ) async -> [AirportDataCodable.ProcedureCodable] {
    guard let cifpAirport = await cifpData.airports[icaoId] else {
      return []
    }

    var procedures = [AirportDataCodable.ProcedureCodable]()
    var processedIdentifiers = Set<String>()

    for approach in cifpAirport.approaches {
      // Skip transitions and missed approach route types — we only want the main approach
      guard approach.approachType != .transition,
        approach.approachType != .missedApproach
      else { continue }

      // Skip if we've already processed this approach identifier (avoid duplicates)
      guard !processedIdentifiers.contains(approach.identifier) else { continue }
      processedIdentifiers.insert(approach.identifier)

      // Construct the full human-readable name
      let name = Self.approachName(
        type: approach.approachType.description,
        identifier: approach.identifier
      )

      // Extract missed approach legs
      let sortedMissedApproachLegs = approach.missedApproachLegs.sorted()
      var extractedMissedLegs = [AirportDataCodable.LegCodable]()
      for leg in sortedMissedApproachLegs {
        let fix = await leg.fix
        let coordinate = fix?.coordinate
        let fixIdentifier = fix?.identifier

        let altitudeRestriction = leg.altitudeConstraint.flatMap {
          convertAltitudeConstraint($0)
        }

        // Convert leg type (skips unrepresentable types like FM/VM)
        let legTypeCodable: LegTypeCodable
        do {
          guard let result = try Self.legType(from: leg) else { continue }
          legTypeCodable = result
        } catch {
          logger.warning("Skipping missed approach leg in \(approach.identifier): \(error)")
          continue
        }

        // Extract DME and radial fields if applicable
        let dme = Self.dmeFields(from: leg)
        let radial = Self.radialFields(from: leg)

        extractedMissedLegs.append(
          AirportDataCodable.LegCodable(
            identifier: fixIdentifier,
            latitude: coordinate?.latitudeDeg,
            longitude: coordinate?.longitudeDeg,
            altitudeRestriction: altitudeRestriction,
            legType: legTypeCodable,
            recommendedNavaidIdentifier: dme.navaidIdentifier ?? radial.navaidIdentifier,
            recommendedNavaidICAO: dme.navaidICAO ?? radial.navaidICAO,
            dmeDistanceNM: dme.distanceNM,
            thetaDeg: radial.thetaDeg
          )
        )
      }

      // Wrap missed approach legs in a segment
      let segments: [AirportDataCodable.SegmentCodable]?
      if !extractedMissedLegs.isEmpty {
        segments = [AirportDataCodable.SegmentCodable(runwayNames: nil, legs: extractedMissedLegs)]
      } else {
        segments = nil
      }

      let procedure = AirportDataCodable.ProcedureCodable(
        type: "approach",
        identifier: approach.identifier,
        name: name,
        runwayName: approach.runwayId?.removingRWPrefix(),
        segments: segments
      )
      procedures.append(procedure)
    }

    return procedures.sorted { $0.identifier < $1.identifier }
  }

  /// Extracts legs and calculates climb gradient for a SID.
  private func extractLegsAndGradient(
    sid: SID,
    cifpData _: CIFPData
  ) async -> (legs: [AirportDataCodable.LegCodable], gradient: Double?) {
    var legs = [AirportDataCodable.LegCodable]()
    var maxGradient: Double?
    var previousLatitude: Double?
    var previousLongitude: Double?
    var previousAltitude: Int?

    for leg in sid.legs.sorted() {
      let fix = await leg.fix
      let coordinate = fix?.coordinate
      let fixIdentifier = fix?.identifier

      // Convert altitude constraint
      let altitudeRestriction = leg.altitudeConstraint.flatMap {
        convertAltitudeConstraint($0)
      }

      // Convert leg type (skips unrepresentable types like FM/VM)
      let legTypeCodable: LegTypeCodable
      do {
        guard let result = try Self.legType(from: leg) else { continue }
        legTypeCodable = result
      } catch {
        logger.warning("Skipping SID leg in \(sid.identifier): \(error)")
        continue
      }

      // Extract DME and radial fields if applicable
      let dme = Self.dmeFields(from: leg)
      let radial = Self.radialFields(from: leg)

      let currentLat = coordinate?.latitudeDeg
      let currentLon = coordinate?.longitudeDeg

      // Add leg to list (coordinates may be nil for *ToAltitude legs etc.)
      let legCodable = AirportDataCodable.LegCodable(
        identifier: fixIdentifier,
        latitude: currentLat,
        longitude: currentLon,
        altitudeRestriction: altitudeRestriction,
        legType: legTypeCodable,
        recommendedNavaidIdentifier: dme.navaidIdentifier ?? radial.navaidIdentifier,
        recommendedNavaidICAO: dme.navaidICAO ?? radial.navaidICAO,
        dmeDistanceNM: dme.distanceNM,
        thetaDeg: radial.thetaDeg
      )
      legs.append(legCodable)

      // Calculate gradient if we have coordinate + altitude data
      if let currentLat, let currentLon,
        let altitudeConstraint = leg.altitudeConstraint,
        let currentAltitude = extractMinAltitudeFeet(from: altitudeConstraint),
        let prevLat = previousLatitude,
        let prevLon = previousLongitude,
        let prevAlt = previousAltitude
      {
        let distanceNM = GeoCalculations.calculateDistanceNM(
          fromLat: prevLat,
          fromLon: prevLon,
          toLat: currentLat,
          toLon: currentLon
        )

        if distanceNM > 0.1 {
          let altitudeGainFt = Double(currentAltitude - prevAlt)
          let gradient = altitudeGainFt / distanceNM

          if gradient > 0 {
            maxGradient = max(maxGradient ?? 0, gradient)
          }
        }

        previousAltitude = currentAltitude
      } else if let altitudeConstraint = leg.altitudeConstraint,
        let altitude = extractMinAltitudeFeet(from: altitudeConstraint)
      {
        previousAltitude = altitude
      }

      if let currentLat, let currentLon {
        previousLatitude = currentLat
        previousLongitude = currentLon
      }
    }

    return (legs, maxGradient)
  }

  /// Converts a SwiftCIFP altitude constraint to our codable representation.
  private func convertAltitudeConstraint(
    _ constraint: AltitudeConstraint
  ) -> AirportDataCodable.AltitudeRestrictionCodable? {
    switch constraint {
      case .at(let altitude):
        guard let feet = altitude.feetValue else { return nil }
        return .at(feet)

      case .atOrAbove(let altitude):
        guard let feet = altitude.feetValue else { return nil }
        return .atOrAbove(feet)

      case .atOrBelow(let altitude):
        guard let feet = altitude.feetValue else { return nil }
        return .atOrBelow(feet)

      case let .between(lower, upper),
        let .atOrAboveToAtOrBelow(lower, upper),
        let .atOrAboveToAt(lower, upper),
        let .atToAtOrBelow(lower, upper),
        let .atToAtOrAbove(lower, upper),
        let .atOrBelowToAtOrAbove(lower, upper):
        guard let feet1 = lower.feetValue, let feet2 = upper.feetValue else { return nil }
        // ARINC 424 altitude ordering varies by descriptor; normalize so min < max
        return .between(min: Swift.min(feet1, feet2), max: Swift.max(feet1, feet2))

      case .glideSlopeIntercept, .glidePathIntercept:
        // These are approach-specific, not relevant for departure procedures
        return nil
    }
  }

  /// Extracts the minimum altitude value in feet from an altitude constraint (for gradient calculation).
  private func extractMinAltitudeFeet(from constraint: AltitudeConstraint) -> Int? {
    switch constraint {
      case .at(let altitude),
        .atOrAbove(let altitude),
        .atOrBelow(let altitude),
        .glideSlopeIntercept(let altitude),
        .glidePathIntercept(let altitude):
        return altitude.feetValue

      case .between(let lower, _),
        .atOrAboveToAtOrBelow(let lower, _),
        .atOrAboveToAt(let lower, _),
        .atToAtOrBelow(let lower, _),
        .atToAtOrAbove(let lower, _),
        .atOrBelowToAtOrAbove(let lower, _):
        return lower.feetValue
    }
  }

  // MARK: - Nested Types

  /// Result container for CIFP loading.
  struct CIFPResult {
    let cycle: SwiftCIFP.Cycle?
    let data: CIFPData?
  }
}

extension String {
  /// Strips the "RW" prefix from a CIFP runway identifier.
  /// For example, `"RW24L"` → `"24L"`, `"RW09"` → `"09"`.
  func removingRWPrefix() -> String {
    hasPrefix("RW") ? String(dropFirst(2)) : self
  }
}

/// Errors that can occur during CIFP processing.
enum CIFPProcessorError: LocalizedError {
  case invalidURL(String)
  case downloadFailed(Int)
  case cifpFileNotFound
  case missingLegData(pathTerminator: String, field: String)

  var errorDescription: String? {
    String(localized: "FAA CIFP data could not be processed.")
  }

  var failureReason: String? {
    switch self {
      case .invalidURL(let url):
        String(localized: "The URL “\(url)” is invalid.")
      case .downloadFailed(let statusCode):
        String(localized: "Download failed with HTTP status \(statusCode).")
      case .cifpFileNotFound:
        String(localized: "FAACIFP file not found in downloaded archive.")
      case let .missingLegData(pathTerminator, field):
        String(localized: "Path terminator \(pathTerminator) missing required field \(field).")
    }
  }
}
