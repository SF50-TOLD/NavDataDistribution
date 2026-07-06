import Foundation
import Logging
import NavData
import StreamingCSV

/// Downloads and parses airport data from the OurAirports database.
///
/// ``OurAirportsLoader`` fetches CSV data from OurAirports (a community-maintained
/// database) to supplement FAA NASR data with international airports.
///
/// ## Data Source
///
/// CSV files are hosted at `davidmegginson.github.io/ourairports-data/`:
/// - `airports.csv`: Airport records
/// - `runways.csv`: Runway records
///
/// ## Processing
///
/// The loader:
/// 1. Downloads both CSV files
/// 2. Parses using StreamingCSV
/// 3. Filters to small/medium/large airports (excludes heliports, seaplane bases)
/// 4. Filters runways ≥500 feet (excludes water runways)
/// 5. Returns ``OurAirportData`` structs
///
/// ## See Also
///
/// - ``OurAirportData``
/// - ``OurRunwayData``
struct OurAirportsLoader {
  private static let airportsURL = URL(
    string: "https://davidmegginson.github.io/ourairports-data/airports.csv"
  )!
  private static let runwaysURL = URL(
    string: "https://davidmegginson.github.io/ourairports-data/runways.csv"
  )!

  private let logger: Logger

  init(logger: Logger) {
    self.logger = logger
  }

  // MARK: - Type Methods

  /// Parses airports and runways data from CSV bytes.
  private static func parseAirports(
    airportsData: Data,
    runwaysData: Data
  ) async throws -> [OurAirportData] {
    let runwaysByAirport = try await groupRunwaysByAirport(runwaysData)

    let reader = StreamingCSVReader(data: airportsData)
    guard let header = try await reader.readRow() else { return [] }
    let columns = CSVColumns(header: header)

    var airports = [OurAirportData]()
    while let row = try await reader.readRow() {
      guard let id = columns.int(row, "id"),
        let ident = columns.string(row, "ident"),
        let type = columns.string(row, "type"),
        // Only include airports (not heliports, seaplane bases, etc.)
        ["small_airport", "medium_airport", "large_airport"].contains(type),
        let name = columns.string(row, "name"),
        let latitude = columns.double(row, "latitude_deg"),
        let longitude = columns.double(row, "longitude_deg")
      else {
        continue
      }

      let localId = columns.string(row, "local_code") ?? ""
      let locationId = localId.isEmpty ? ident : localId
      let ICAO_ID = columns.string(row, "icao_code")
      let elevation = Double(columns.int(row, "elevation_ft") ?? 0)
      let municipality = columns.string(row, "municipality")

      let runways = runwaysByAirport[ident] ?? []
      let airport = OurAirportData(
        id: String(id),
        localId: locationId,
        ICAO_ID: ICAO_ID,
        name: name,
        municipality: municipality,
        latitude: latitude,
        longitude: longitude,
        elevationFt: elevation,
        runways: runways
      )
      airports.append(airport)
    }

    return airports
  }

  private static func groupRunwaysByAirport(_ runwaysData: Data) async throws -> [String:
    [OurRunwayData]]
  {
    var runwaysByAirport = [String: [OurRunwayData]]()

    let reader = StreamingCSVReader(data: runwaysData)
    guard let header = try await reader.readRow() else { return runwaysByAirport }
    let columns = CSVColumns(header: header)

    while let row = try await reader.readRow() {
      guard let airportIdent = columns.string(row, "airport_ident"),
        let length = columns.int(row, "length_ft"),
        length >= 500
      else {
        continue
      }

      let surface = columns.string(row, "surface") ?? ""
      let surfaceType = Self.deriveSurfaceType(surface)

      // Skip water runways
      if surface.lowercased().contains("water") {
        continue
      }

      // Parse width (shared between both ends)
      let widthFt = columns.int(row, "width_ft").map { Double($0) }

      // Process low end (base end)
      if let lowIdent = columns.string(row, "le_ident") {
        let lowElevation = columns.int(row, "le_elevation_ft").map { Double($0) }
        let lowHeading =
          columns.double(row, "le_heading_degT")
          ?? calculateHeadingFromIdent(
            lowIdent
          )
        let lowDisplaced = Double(columns.int(row, "le_displaced_threshold_ft") ?? 0)
        let lowLatitude = columns.double(row, "le_latitude_deg")
        let lowLongitude = columns.double(row, "le_longitude_deg")

        let runway = OurRunwayData(
          name: lowIdent,
          elevationFt: lowElevation,
          trueHeading: lowHeading,
          lengthFt: Double(length),
          displacedThresholdFt: lowDisplaced,
          surfaceType: surfaceType,
          reciprocalName: columns.string(row, "he_ident"),
          thresholdLatitude: lowLatitude,
          thresholdLongitude: lowLongitude,
          widthFt: widthFt
        )

        runwaysByAirport[airportIdent, default: []].append(runway)
      }

      // Process high end (reciprocal end)
      if let highIdent = columns.string(row, "he_ident") {
        let highElevation = columns.int(row, "he_elevation_ft").map { Double($0) }
        let highHeading =
          columns.double(row, "he_heading_degT") ?? calculateHeadingFromIdent(highIdent)
        let highDisplaced = Double(columns.int(row, "he_displaced_threshold_ft") ?? 0)
        let highLatitude = columns.double(row, "he_latitude_deg")
        let highLongitude = columns.double(row, "he_longitude_deg")

        let runway = OurRunwayData(
          name: highIdent,
          elevationFt: highElevation,
          trueHeading: highHeading,
          lengthFt: Double(length),
          displacedThresholdFt: highDisplaced,
          surfaceType: surfaceType,
          reciprocalName: columns.string(row, "le_ident"),
          thresholdLatitude: highLatitude,
          thresholdLongitude: highLongitude,
          widthFt: widthFt
        )

        runwaysByAirport[airportIdent, default: []].append(runway)
      }
    }

    return runwaysByAirport
  }

  private static func isHardSurface(_ surface: String) -> Bool {
    // Check for hard surface indicators - be inclusive to catch variations
    let hardSurfaceIndicators = ["asp", "conc", "pem", "bit", "tarmac", "paved", "macadam"]
    let lowercased = surface.lowercased()

    // Return true if any hard surface indicator is found
    for indicator in hardSurfaceIndicators where lowercased.contains(indicator) {
      return true
    }

    // CON by itself (not part of "concrete") is also hard surface
    if surface == "CON" { return true }

    return false
  }

  /// Derives ``SurfaceType`` from OurAirports surface description string.
  private static func deriveSurfaceType(_ surface: String) -> SurfaceType {
    guard isHardSurface(surface) else { return .turf }

    let lowercased = surface.lowercased()
    if lowercased.contains("groov") { return .grooved }
    if lowercased.contains("pfc") { return .pfc }
    return .paved
  }

  private static func calculateHeadingFromIdent(_ ident: String) -> Double {
    // Extract numeric part from runway identifier (e.g., "09L" -> 09)
    let digits = ident.prefix(2).filter(\.isNumber)
    guard let runwayNumber = Double(digits) else { return 0 }
    return runwayNumber * 10  // Convert to degrees (09 -> 090)
  }

  // MARK: - Instance Methods

  func loadAirports(
    onProgress: (@Sendable (Int, Int) async -> Void)? = nil
  ) async throws -> ([OurAirportData], Date) {
    logger.notice("Downloading OurAirports data…")
    await onProgress?(0, 2)

    // Download CSV files
    let (airportsData, _) = try await URLSession.shared.data(from: Self.airportsURL)
    let (runwaysData, _) = try await URLSession.shared.data(from: Self.runwaysURL)
    await onProgress?(1, 2)

    logger.notice("Parsing OurAirports CSVs…")

    let airports = try await Self.parseAirports(
      airportsData: airportsData,
      runwaysData: runwaysData
    )

    // Use current date as last updated
    let lastUpdated = Date()
    await onProgress?(2, 2)

    logger.notice("Loaded \(airports.count) airports from OurAirports")
    return (airports, lastUpdated)
  }
}

/// Looks up CSV field values by column name for a header-indexed row.
///
/// Empty fields are treated as absent, matching how CSV consumers typically
/// distinguish a blank cell from a real value.
private struct CSVColumns {
  private let indices: [String: Int]

  init(header: [String]) {
    indices = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
  }

  private func rawValue(_ row: [String], _ name: String) -> String? {
    guard let index = indices[name], row.indices.contains(index) else { return nil }
    let value = row[index]
    return value.isEmpty ? nil : value
  }

  func string(_ row: [String], _ name: String) -> String? {
    rawValue(row, name)
  }

  func int(_ row: [String], _ name: String) -> Int? {
    rawValue(row, name).flatMap(Int.init)
  }

  func double(_ row: [String], _ name: String) -> Double? {
    rawValue(row, name).flatMap(Double.init)
  }
}

/// Airport data parsed from OurAirports CSV.
///
/// Contains airport metadata needed for the app's airport database.
/// Values are in OurAirports native units (feet, degrees).
struct OurAirportData {
  /// Unique ID from OurAirports database (used as recordID).
  let id: String

  /// FAA location ID (local_code field).
  let localId: String

  /// ICAO identifier if available.
  let ICAO_ID: String?

  /// Airport name.
  let name: String

  /// City/municipality name.
  let municipality: String?

  /// Latitude in decimal degrees.
  let latitude: Double

  /// Longitude in decimal degrees.
  let longitude: Double

  /// Field elevation in feet.
  let elevationFt: Double

  /// Runways at this airport.
  let runways: [OurRunwayData]
}

/// Runway data parsed from OurAirports CSV.
///
/// Contains runway properties needed for performance calculations.
/// Values are in OurAirports native units (feet, degrees).
struct OurRunwayData {
  /// Runway designator (e.g., "09L").
  let name: String

  /// Threshold elevation in feet.
  let elevationFt: Double?

  /// True heading in degrees.
  let trueHeading: Double

  /// Runway length in feet.
  let lengthFt: Double

  /// Displaced threshold distance in feet.
  let displacedThresholdFt: Double

  /// Runway surface type.
  let surfaceType: SurfaceType

  /// Name of the reciprocal runway end.
  let reciprocalName: String?

  /// Threshold latitude in decimal degrees.
  let thresholdLatitude: Double?

  /// Threshold longitude in decimal degrees.
  let thresholdLongitude: Double?

  /// Runway width in feet.
  let widthFt: Double?
}
