import Foundation
import Logging
import NavData
import SwiftAIXM

/// The airports, obstacles, and attributions the supplementary sources contributed.
struct SupplementaryData: Sendable {
  var airports = [SourceAirport]()
  var obstacles = [[AirportDataCodable.ObstacleCodable]]()
  var sources = [AirportDataCodable.SupplementarySource]()

  mutating func add(_ other: Self) {
    airports += other.airports
    obstacles += other.obstacles
    sources += other.sources
  }
}

/**
 Loads the sources that supplement NASR, CIFP, DOF, and OurAirports outside the US:
 open flightmaps, the UK AIP and obstacle data sets, Sweden's threshold and obstacle
 feed, and the Austrian and Swiss obstacle data sets.

 Each source is optional: one that fails to load is logged and left out, and the
 others still contribute.
 */
struct SupplementaryDataLoader {
  let logger: Logger

  /// Loads every source concurrently.
  /// - Parameters:
  ///   - AIRAC: The AIRAC cycle identifier (`yymm`).
  ///   - effectiveDate: The date the cycle takes effect.
  func load(AIRAC: String, effectiveDate: Date) async throws -> SupplementaryData {
    let download = SupplementaryDownload(logger: logger)
    let loaders: [(name: String, load: @Sendable () async throws -> SupplementaryData)] = [
      (
        "open flightmaps",
        { try await OpenFlightmapsSource(download: download, logger: logger).load(AIRAC: AIRAC) }
      ),
      (
        "NATS",
        {
          try await NATSSource(download: download).load(
            effectiveDate: effectiveDate,
            logger: logger
          )
        }
      ),
      ("LFV", { try await LFVSource(download: download).load() }),
      (
        "Austro Control",
        { try await AustroControlSource(download: download).load(effectiveDate: effectiveDate) }
      ),
      ("FOCA", { try await FOCASource(download: download).load(effectiveDate: effectiveDate) })
    ]

    return try await withThrowingTaskGroup(of: SupplementaryData.self) { group in
      for (name, load) in loaders {
        group.addTask {
          do {
            return try await load()
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            logger.warning("Could not load \(name) data; continuing without it: \(error)")
            return SupplementaryData()
          }
        }
      }
      return try await group.reduce(into: SupplementaryData()) { $0.add($1) }
    }
  }
}

/// Reads a data set file, logging how many records couldn't be read in full.
func readDataset(_ url: URL, effectiveDate: Date, name: String, logger: Logger) throws
  -> AIXMDataset
{
  var problems = 0
  let dataset = try AIXMDataset(url: url, effectiveDate: effectiveDate) { _ in problems += 1 }
  if problems > 0 { logger.info("\(name): \(problems) records could not be read in full") }
  return dataset
}

// MARK: - open flightmaps

/// open flightmaps OFMX snapshots, one per region.
struct OpenFlightmapsSource {
  private static let baseURL = URL(string: "https://snapshots.openflightmaps.org/live")!
  private static let licenseURL = URL(string: "https://www.openflightmaps.org/about/")!
  private static let feedbackURL = URL(string: "https://gitlab.com/openflightmaps/region-issues")!
  private static let concurrentDownloads = 4

  /// Each region's snapshot folder, and the country it covers.
  private static let regions = [
    "ebbu": "BE", "ed": "DE", "efin": "FI", "ehaa": "NL", "ekdk": "DK", "epww": "PL",
    "esaa": "SE", "fa": "ZA", "fywh": "NA", "lbsr": "BG", "ldzo": "HR", "lf": "FR",
    "lggg": "GR", "lhcc": "HU", "li": "IT", "ljla": "SI", "lkaa": "CZ", "lmmm": "MT",
    "lovv": "AT", "lrbb": "RO", "lsas": "CH", "lzbb": "SK"
  ]

  let download: SupplementaryDownload
  let logger: Logger

  private static func snapshotURL(AIRAC: String, folder: String) -> URL {
    let code = folder.prefix(2)
    return baseURL.appending(path: "\(AIRAC)/ofmx/\(folder)/latest/isolated/ofmx_\(code).ofmx")
  }

  func load(AIRAC: String) async throws -> SupplementaryData {
    let airports = try await withThrowingTaskGroup(of: [SourceAirport].self) { group in
      var pending = Self.regions.sorted { $0.key < $1.key }.makeIterator()
      func next() {
        guard let (folder, country) = pending.next() else { return }
        group.addTask { await self.loadRegion(folder: folder, country: country, AIRAC: AIRAC) }
      }
      for _ in 0..<Self.concurrentDownloads { next() }

      var airports = [SourceAirport]()
      while let regionAirports = try await group.next() {
        airports += regionAirports
        next()
      }
      return airports
    }
    guard !airports.isEmpty else {
      throw SupplementarySourceError.editionNotFound(source: "open flightmaps")
    }

    logger.notice("Loaded \(airports.count) open flightmaps aerodromes")
    return SupplementaryData(
      airports: airports,
      sources: [
        .init(
          name: "open flightmaps",
          source: .openFlightmaps,
          edition: "AIRAC \(AIRAC)",
          retrieved: .now,
          attribution: String(localized: "Contains data from the open flightmaps database."),
          licenseURL: Self.licenseURL,
          feedbackURL: Self.feedbackURL
        )
      ]
    )
  }

  private func loadRegion(folder: String, country: String, AIRAC: String) async -> [SourceAirport] {
    do {
      let data = try await download.data(from: Self.snapshotURL(AIRAC: AIRAC, folder: folder))
      let dataset = try AIXMDataset(data: data)
      return dataset.airports.compactMap { airport in
        AIXMConversion.sourceAirport(
          airport,
          source: .openFlightmaps,
          identifiers: .init(
            ICAO: AirportKey.ICAOIndicator(airport.ICAOIdentifier),
            countryCode: country,
            openFlightmaps: .init(region: folder.uppercased(), code: airport.designator)
          )
        )
      }
    } catch {
      logger.warning("Could not load open flightmaps region \(folder): \(error)")
      return []
    }
  }
}

// MARK: - NATS

/// The UK AIP data set and Area 1 obstacle data set.
struct NATSSource {
  private static let pageURL = URL(
    string: "https://nats-uk.ead-it.com/cms-nats/opencms/en/Publications/digital-datasets/"
  )!
  private static let siteURL = URL(string: "https://nats-uk.ead-it.com")!
  private static let aerodromePattern = #"/cms-nats/[^"]*/EG_AIP_DS_(\d{8})_XML\.zip"#
  private static let obstaclePattern = #"/cms-nats/[^"]*/EG_OBS_DS_AREA1_FULL_(\d{8})_XML\.zip"#

  let download: SupplementaryDownload

  func load(effectiveDate: Date, logger: Logger) async throws -> SupplementaryData {
    let page = try await download.page(at: Self.pageURL)
    guard
      let aerodromes = DatedLinks.latest(
        in: page,
        matching: Self.aerodromePattern,
        onOrBefore: effectiveDate
      )
    else { throw SupplementarySourceError.editionNotFound(source: "UK AIP data set") }

    let aerodromeFile = try await download.extract(
      from: Self.siteURL.appending(path: aerodromes.link),
      entryMatching: { $0.hasPrefix("EG_AIP_DS_FULL_") && $0.hasSuffix(".xml") },
      describedAs: "EG_AIP_DS_FULL"
    )
    defer { download.remove(aerodromeFile) }
    let dataset = try readDataset(
      aerodromeFile,
      effectiveDate: effectiveDate,
      name: "NATS",
      logger: logger
    )
    let airports = dataset.airports.compactMap { airport in
      AIXMConversion.sourceAirport(
        airport,
        source: .NATS,
        identifiers: .init(ICAO: AirportKey.ICAOIndicator(airport.ICAOIdentifier))
      )
    }

    var obstacles = [AirportDataCodable.ObstacleCodable]()
    if let obstacleLink = DatedLinks.latest(
      in: page,
      matching: Self.obstaclePattern,
      onOrBefore: effectiveDate
    ) {
      let obstacleFile = try await download.extract(
        from: Self.siteURL.appending(path: obstacleLink.link),
        entryMatching: { $0.hasSuffix(".xml") },
        describedAs: "EG_OBS_DS_AREA1_FULL"
      )
      defer { download.remove(obstacleFile) }
      obstacles = AIXMConversion.obstacles(
        try readDataset(
          obstacleFile,
          effectiveDate: effectiveDate,
          name: "NATS obstacles",
          logger: logger
        )
        .obstacles
      )
    }

    logger.notice("Loaded \(airports.count) NATS aerodromes and \(obstacles.count) obstacles")
    return SupplementaryData(
      airports: airports,
      obstacles: [obstacles],
      sources: [
        .init(
          name: "NATS",
          source: .NATS,
          edition: aerodromes.date,
          retrieved: .now,
          attribution: String(localized: "Contains UK AIP and obstacle data published by NATS."),
          licenseURL: Self.pageURL,
          feedbackURL: nil
        )
      ]
    )
  }
}

// MARK: - LFV

/// Sweden's threshold points and obstacles, from LFV's map service.
struct LFVSource {
  private static let serviceURL = URL(string: "https://daim.lfv.se/geoserver/wfs")!
  private static let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!

  let download: SupplementaryDownload

  private static func featuresURL(_ layer: String) -> URL {
    serviceURL.appending(queryItems: [
      .init(name: "service", value: "WFS"),
      .init(name: "version", value: "2.0.0"),
      .init(name: "request", value: "GetFeature"),
      .init(name: "typeNames", value: layer),
      .init(name: "outputFormat", value: "application/json")
    ])
  }

  func load() async throws -> SupplementaryData {
    let thresholds = try JSONDecoder().decode(
      FeatureCollection<ThresholdProperties>.self,
      from: try await download.data(from: Self.featuresURL("mais:THR"))
    )
    let obstacles = try JSONDecoder().decode(
      FeatureCollection<ObstacleProperties>.self,
      from: try await download.data(from: Self.featuresURL("mais:OBSE"))
    )

    let airports = Dictionary(grouping: thresholds.features) { $0.properties.POSITIONINDICATOR }
      .compactMap { ICAO, features in airport(ICAO: ICAO, thresholds: features) }
    let edition = thresholds.features.lazy.compactMap(\.properties.WEF).max() ?? ""

    return SupplementaryData(
      airports: airports,
      obstacles: [obstacles.features.compactMap(\.obstacle)],
      sources: [
        .init(
          name: "LFV",
          source: .LFV,
          edition: edition,
          retrieved: .now,
          attribution: String(localized: "Contains data from LFV, licensed under CC BY 4.0."),
          licenseURL: Self.licenseURL,
          feedbackURL: nil
        )
      ]
    )
  }

  /// The threshold points of one airport, positioned at their centroid.
  private func airport(ICAO: String, thresholds: [Feature<ThresholdProperties>]) -> SourceAirport? {
    let ends = thresholds.compactMap { feature -> SourceRunwayEnd? in
      guard feature.properties.TYPEOFPOINT == "THR", let name = feature.properties.NAMEOFPOINT,
        feature.geometry.coordinates.count == 2
      else { return nil }
      return SourceRunwayEnd(
        name: name,
        thresholdLatitude: feature.geometry.coordinates[1],
        thresholdLongitude: feature.geometry.coordinates[0],
        thresholdElevation: feature.properties.MSL
      )
    }
    guard !ends.isEmpty else { return nil }

    return SourceAirport(
      source: .LFV,
      sourceID: ICAO,
      identifiers: .init(ICAO: AirportKey.ICAOIndicator(ICAO), countryCode: "SE"),
      locationID: nil,
      name: nil,
      city: nil,
      latitude: ends.compactMap(\.thresholdLatitude).reduce(0, +) / Double(ends.count),
      longitude: ends.compactMap(\.thresholdLongitude).reduce(0, +) / Double(ends.count),
      elevation: nil,
      runwayEnds: ends,
      describesRunways: false
    )
  }

  fileprivate struct FeatureCollection<Properties: Decodable>: Decodable {
    let features: [Feature<Properties>]
  }

  fileprivate struct Feature<Properties: Decodable>: Decodable {
    let geometry: Point
    let properties: Properties
  }

  fileprivate struct Point: Decodable {
    let coordinates: [Double]
  }

  // swiftlint:disable identifier_name
  /// The service's own (uppercase) property names.
  fileprivate struct ThresholdProperties: Decodable {
    let POSITIONINDICATOR: String
    let TYPEOFPOINT: String?
    let NAMEOFPOINT: String?
    let MSL: Double?
    let WEF: String?
  }

  fileprivate struct ObstacleProperties: Decodable {
    let MSL_VALUE: Double?
    let MSL_UNIT: String?
  }
  // swiftlint:enable identifier_name
}

extension LFVSource.Feature where Properties == LFVSource.ObstacleProperties {
  private static var feetPerMeter: Double { 1 / 0.3048 }

  fileprivate var obstacle: AirportDataCodable.ObstacleCodable? {
    guard let value = properties.MSL_VALUE, geometry.coordinates.count == 2 else { return nil }
    let feet = properties.MSL_UNIT == "FT" ? value : value * Self.feetPerMeter
    return .init(
      heightFtMSL: Int(feet.rounded(.up)),
      latitude: geometry.coordinates[1],
      longitude: geometry.coordinates[0]
    )
  }
}

// MARK: - Austro Control

/// The Austrian Area 1 obstacle data set.
struct AustroControlSource {
  private static let pageURL = URL(
    string:
      "https://www.austrocontrol.at/en/pilots/pre-flight_preparation/aim_products/obstacle_data_set_icao"
  )!
  private static let documentsURL = URL(string: "https://www.austrocontrol.at/jart/prj3/ac/")!
  private static let pattern = #"data/dokumente/LO_OBS_DS_AREA1_(\d{8})_[^"]*\.zip"#

  let download: SupplementaryDownload

  func load(effectiveDate: Date) async throws -> SupplementaryData {
    let page = try await download.page(at: Self.pageURL)
    guard let link = DatedLinks.latest(in: page, matching: Self.pattern, onOrBefore: effectiveDate)
    else {
      throw SupplementarySourceError.editionNotFound(source: "Austrian obstacle data set")
    }
    let file = try await download.extract(
      from: Self.documentsURL.appending(path: link.link),
      entryMatching: { $0.hasSuffix(".xml") },
      describedAs: "LO_OBS_DS_AREA1"
    )
    defer { download.remove(file) }

    let dataset = try AIXMDataset(url: file, effectiveDate: effectiveDate)
    return SupplementaryData(
      obstacles: [AIXMConversion.obstacles(dataset.obstacles)],
      sources: [
        .init(
          name: "Austro Control",
          source: nil,
          edition: link.date,
          retrieved: .now,
          attribution: String(localized: "Contains obstacle data from Austro Control."),
          licenseURL: Self.pageURL,
          feedbackURL: nil
        )
      ]
    )
  }
}

// MARK: - FOCA

/// The Swiss obstacle data set, published by the Federal Office of Civil Aviation.
struct FOCASource {
  private static let archiveURL = URL(
    string:
      "https://data.geo.admin.ch/ch.bazl.luftfahrthindernis/luftfahrthindernis/luftfahrthindernis_4326.aixm.zip"
  )!
  private static let licenseURL = URL(string: "https://opendata.swiss/en/terms-of-use#terms_by")!

  let download: SupplementaryDownload

  /// The publication date in a file named like `Swiss_Obstacle_2026-10-31_004241.aixm.xml`.
  private static func edition(of file: URL) -> String {
    file.lastPathComponent.split(separator: "_").dropFirst(2).first.map(String.init) ?? ""
  }

  func load(effectiveDate: Date) async throws -> SupplementaryData {
    let file = try await download.extract(
      from: Self.archiveURL,
      entryMatching: { $0.hasSuffix(".aixm.xml") },
      describedAs: "Swiss_Obstacle"
    )
    defer { download.remove(file) }

    let dataset = try AIXMDataset(url: file, effectiveDate: effectiveDate)
    return SupplementaryData(
      obstacles: [AIXMConversion.obstacles(dataset.obstacles)],
      sources: [
        .init(
          name: "FOCA",
          source: nil,
          edition: Self.edition(of: file),
          retrieved: .now,
          attribution: String(
            localized: "Contains obstacle data from the Swiss Federal Office of Civil Aviation."
          ),
          licenseURL: Self.licenseURL,
          feedbackURL: nil
        )
      ]
    )
  }
}
