import Foundation
import Logging
import NavData
import StreamingCSV

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

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
/// 5. Returns ``SourceAirport`` records
struct OurAirportsLoader {
  private static let airportsURL = URL(
    string: "https://davidmegginson.github.io/ourairports-data/airports.csv"
  )!
  private static let runwaysURL = URL(
    string: "https://davidmegginson.github.io/ourairports-data/runways.csv"
  )!

  private static let metersPerFoot = 0.3048

  private let logger: Logger

  /// Emits the intervals that put the OurAirports load on an Instruments timeline.
  private let signposter = Signposter(category: "OurAirportsLoader")

  init(logger: Logger) {
    self.logger = logger
  }

  // MARK: - Type Methods

  /// Parses airports and runways data from CSV bytes.
  private static func parseAirports(
    airportsData: Data,
    runwaysData: Data
  ) async throws -> [SourceAirport] {
    let runwaysByAirport = try await groupRunwaysByAirport(runwaysData)

    let reader = StreamingCSVReader(data: airportsData)
    guard let header = try await reader.readRow() else { return [] }
    let columns = CSVColumns(header: header)

    var airports = [SourceAirport]()
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

      let localCode = columns.string(row, "local_code")
      airports.append(
        SourceAirport(
          source: .ourAirports,
          sourceID: String(id),
          identifiers: .init(
            ICAO: AirportKey.ICAOIndicator(columns.string(row, "icao_code")),
            national: localCode,
            countryCode: columns.string(row, "iso_country"),
            ourAirports: String(id)
          ),
          locationID: localCode ?? ident,
          name: name,
          city: columns.string(row, "municipality"),
          latitude: latitude,
          longitude: longitude,
          elevation: columns.int(row, "elevation_ft").map { Double($0) * metersPerFoot },
          runwayEnds: runwaysByAirport[ident] ?? [],
          describesRunways: true
        )
      )
    }

    return airports
  }

  private static func groupRunwaysByAirport(_ runwaysData: Data) async throws -> [String:
    [SourceRunwayEnd]]
  {
    var runwaysByAirport = [String: [SourceRunwayEnd]]()

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
        runwaysByAirport[airportIdent, default: []].append(
          SourceRunwayEnd(
            name: lowIdent,
            reciprocalName: columns.string(row, "he_ident"),
            trueHeading: columns.double(row, "le_heading_degT"),
            length: Double(length) * metersPerFoot,
            width: widthFt.map { $0 * metersPerFoot },
            surface: surfaceType,
            thresholdLatitude: columns.double(row, "le_latitude_deg"),
            thresholdLongitude: columns.double(row, "le_longitude_deg"),
            thresholdElevation: columns.int(row, "le_elevation_ft").map {
              Double($0) * metersPerFoot
            },
            displacedThresholdDistance: columns.int(row, "le_displaced_threshold_ft")
              .map { Double($0) * metersPerFoot }
          )
        )
      }

      // Process high end (reciprocal end)
      if let highIdent = columns.string(row, "he_ident") {
        runwaysByAirport[airportIdent, default: []].append(
          SourceRunwayEnd(
            name: highIdent,
            reciprocalName: columns.string(row, "le_ident"),
            trueHeading: columns.double(row, "he_heading_degT"),
            length: Double(length) * metersPerFoot,
            width: widthFt.map { $0 * metersPerFoot },
            surface: surfaceType,
            thresholdLatitude: columns.double(row, "he_latitude_deg"),
            thresholdLongitude: columns.double(row, "he_longitude_deg"),
            thresholdElevation: columns.int(row, "he_elevation_ft").map {
              Double($0) * metersPerFoot
            },
            displacedThresholdDistance: columns.int(row, "he_displaced_threshold_ft")
              .map { Double($0) * metersPerFoot }
          )
        )
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

  // MARK: - Instance Methods

  func loadAirports(
    onProgress: (@Sendable (Int, Int) async -> Void)? = nil
  ) async throws -> ([SourceAirport], Date) {
    try await signposter.withInterval("load OurAirports data") {
      logger.notice("Downloading OurAirports data…")
      await onProgress?(0, 2)

      // Download CSV files
      let airportsData = try await signposter.withInterval("download OurAirports airports CSV") {
        try await withRetries(logger: logger) {
          try await URLSession.shared.data(from: Self.airportsURL).0
        }
      }
      let runwaysData = try await signposter.withInterval("download OurAirports runways CSV") {
        try await withRetries(logger: logger) {
          try await URLSession.shared.data(from: Self.runwaysURL).0
        }
      }
      await onProgress?(1, 2)

      logger.notice("Parsing OurAirports CSVs…")

      let airports = try await signposter.withInterval("parse OurAirports data") {
        try await Self.parseAirports(
          airportsData: airportsData,
          runwaysData: runwaysData
        )
      }

      // Use current date as last updated
      let lastUpdated = Date()
      await onProgress?(2, 2)

      logger.notice("Loaded \(airports.count) airports from OurAirports")
      return (airports, lastUpdated)
    }
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
