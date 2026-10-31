import NavData

@testable import NavDataGeneration

/// Builds source records for resolver tests, filling every field a test doesn't care about.
enum ResolverFixtures {

  /// A NASR airport with one runway, 09/27.
  static func NASR(
    siteNumber: String = "04508.*A",
    LID: String = "OAK",
    ICAO: String? = "KOAK",
    at position: (Double, Double) = (37.72, -122.22)
  ) -> AirportDataCodable.AirportCodable {
    .init(
      recordID: siteNumber,
      locationID: LID,
      ICAO_ID: ICAO,
      name: "METROPOLITAN OAKLAND INTL",
      city: "OAKLAND",
      dataSource: AirportDataSource.NASR.rawValue,
      latitude: position.0,
      longitude: position.1,
      elevation: 3,
      variation: 13,
      timeZone: "America/Los_Angeles",
      runways: [
        .init(
          name: "09",
          elevation: nil,
          trueHeading: 90,
          gradient: nil,
          length: 3000,
          takeoffRun: nil,
          takeoffDistance: nil,
          landingDistance: nil,
          surfaceType: SurfaceType.paved.rawValue,
          reciprocalName: "27",
          thresholdLatitude: nil,
          thresholdLongitude: nil,
          width: nil,
          thresholdCrossingHeight: nil,
          glidepathAngle: nil,
          displacedThresholdDistance: nil
        )
      ],
      procedures: nil
    )
  }

  /// A record from a source other than NASR, with a runway 09/27 unless told otherwise.
  static func record(
    _ source: AirportDataSource,
    ICAO: String? = nil,
    national: String? = nil,
    country: String = "DE",
    ourAirportsID: String? = nil,
    openFlightmapsCode: String? = nil,
    name: String? = "AIRFIELD",
    at position: (Double, Double) = (48.0, 11.0),
    runwayEnds: [SourceRunwayEnd]? = nil,
    describesRunways: Bool = true
  ) -> SourceAirport {
    SourceAirport(
      source: source,
      sourceID: ourAirportsID ?? openFlightmapsCode ?? ICAO ?? "id",
      identifiers: .init(
        ICAO: ICAO,
        national: national,
        countryCode: country,
        ourAirports: ourAirportsID,
        openFlightmaps: openFlightmapsCode.map { .init(region: "ED", code: $0) }
      ),
      locationID: national ?? ICAO,
      name: name,
      city: nil,
      latitude: position.0,
      longitude: position.1,
      elevation: 500,
      runwayEnds: runwayEnds ?? [
        end("09", reciprocal: "27", heading: 90), end("27", reciprocal: "09", heading: 270)
      ],
      describesRunways: describesRunways
    )
  }

  static func end(
    _ name: String,
    reciprocal: String? = nil,
    heading: Double? = nil,
    length: Double? = 1000,
    threshold: (Double, Double)? = nil,
    elevation: Double? = nil,
    TORA: Double? = nil
  ) -> SourceRunwayEnd {
    SourceRunwayEnd(
      name: name,
      reciprocalName: reciprocal,
      trueHeading: heading,
      length: length,
      surface: .paved,
      thresholdLatitude: threshold?.0,
      thresholdLongitude: threshold?.1,
      thresholdElevation: elevation,
      takeoffRun: TORA
    )
  }

  static func resolve(
    NASR: [AirportDataCodable.AirportCodable] = [],
    _ records: [SourceAirport]
  ) -> Resolution {
    AirportResolver(NASRAirports: NASR, records: records).resolve()
  }

  static func build(_ resolved: ResolvedAirport) -> AirportDataCodable.AirportCodable? {
    GoldenRecordBuilder { _, _ in nil }.build(resolved)
  }
}
