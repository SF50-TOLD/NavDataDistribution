import Foundation
import NavData
import Testing

@testable import NavDataGeneration

@Suite
struct `Airport resolution` {
  private typealias F = ResolverFixtures

  // MARK: Keys

  @Test
  func `keys each airport by its most authoritative identifier`() throws {
    let resolution = F.resolve(
      NASR: [F.NASR()],
      [
        F.record(.ourAirports, ICAO: "EDDM", ourAirportsID: "1", at: (48.35, 11.78)),
        F.record(.ourAirports, national: "XY1", country: "BR", ourAirportsID: "2", at: (-10, -50)),
        F.record(.ourAirports, country: "AR", ourAirportsID: "3", at: (-30, -60)),
        F.record(.openFlightmaps, openFlightmapsCode: "EDXQ", at: (52, 13))
      ]
    )
    #expect(
      Set(resolution.airports.map(\.key))
        == ["FAA:04508.*A", "ICAO:EDDM", "LOC:BR:XY1", "OA:3", "OFM:ED:EDXQ"]
    )
  }

  @Test
  func `aliases every other identifier, including the bare ones older files used`() throws {
    let resolution = F.resolve(
      NASR: [F.NASR()],
      [
        F.record(
          .ourAirports,
          national: "OAK",
          country: "US",
          ourAirportsID: "3384",
          at: (37.721, -122.221)
        ),
        F.record(.ourAirports, ICAO: "EDDM", ourAirportsID: "2212", at: (48.35, 11.78))
      ]
    )
    let oakland = try #require(resolution.airports.first { $0.key == "FAA:04508.*A" })
    #expect(Set(oakland.aliases).isSuperset(of: ["04508.*A", "3384", "ICAO:KOAK", "OA:3384"]))

    let munich = try #require(resolution.airports.first { $0.key == "ICAO:EDDM" })
    #expect(Set(munich.aliases) == ["2212", "OA:2212"])
  }

  @Test
  func `gives a vetoed duplicate the next key so no two airports share one`() throws {
    let resolution = F.resolve([
      F.record(.ourAirports, ICAO: "EDXY", ourAirportsID: "1", at: (48, 11)),
      F.record(.openFlightmaps, ICAO: "EDXY", openFlightmapsCode: "EDXY", at: (49, 11))
    ])
    #expect(resolution.statistics.distanceVetoes == 1)
    #expect(Set(resolution.airports.map(\.key)) == ["ICAO:EDXY", "OFM:ED:EDXY"])
    #expect(resolution.airports.allSatisfy { !$0.aliases.contains("ICAO:EDXY") })
  }

  // MARK: Linking

  @Test
  func `links records that share an ICAO indicator`() throws {
    let resolution = F.resolve([
      F.record(.ourAirports, ICAO: "EDDM", ourAirportsID: "1"),
      F.record(.openFlightmaps, ICAO: "EDDM", openFlightmapsCode: "EDDM", at: (48.01, 11.01))
    ])
    let airport = try #require(resolution.airports.only)
    #expect(airport.records.map(\.source) == [.openFlightmaps, .ourAirports])
  }

  @Test
  func `links a US OurAirports record to NASR by its FAA identifier`() throws {
    let resolution = F.resolve(
      NASR: [F.NASR()],
      [
        F.record(
          .ourAirports,
          national: "OAK",
          country: "US",
          ourAirportsID: "3384",
          at: (37.721, -122.221)
        )
      ]
    )
    #expect(resolution.airports.only?.NASR != nil)
  }

  @Test
  func `links records without shared identifiers that sit together and share a runway`() throws {
    let resolution = F.resolve([
      F.record(.ourAirports, ourAirportsID: "1"),
      F.record(.openFlightmaps, openFlightmapsCode: "EDXQ", at: (48.005, 11.005))
    ])
    #expect(resolution.airports.count == 1)
    #expect(resolution.statistics.geometricLinks == 1)
  }

  @Test
  func `never links airports with different ICAO indicators`() throws {
    let resolution = F.resolve([
      F.record(.ourAirports, ICAO: "EDAA", ourAirportsID: "1"),
      F.record(.openFlightmaps, ICAO: "EDBB", openFlightmapsCode: "EDBB", at: (48.005, 11.005))
    ])
    #expect(resolution.airports.count == 2)
  }

  @Test
  func `keeps a US OurAirports record that NASR does not publish`() throws {
    let resolution = F.resolve(
      NASR: [F.NASR()],
      [F.record(.ourAirports, national: "1C9", country: "US", ourAirportsID: "1", at: (40, -100))]
    )
    #expect(Set(resolution.airports.map(\.key)) == ["FAA:04508.*A", "LOC:US:1C9"])
  }

  @Test
  func `drops records that only add detail when nothing describes the runways`() throws {
    let resolution = F.resolve([
      F.record(.LFV, ICAO: "ESSA", country: "SE", describesRunways: false)
    ])
    #expect(resolution.airports.isEmpty)
  }
}

@Suite
struct `Golden records` {
  private typealias F = ResolverFixtures

  private func airport(_ records: [SourceAirport]) throws -> AirportDataCodable.AirportCodable {
    let resolved = try #require(F.resolve(records).airports.only)
    return try #require(F.build(resolved))
  }

  @Test
  func `takes each value from the highest-precedence source that has it`() throws {
    let airport = try airport([
      F.record(
        .ourAirports,
        ICAO: "ESSA",
        country: "SE",
        ourAirportsID: "1",
        name: "Stockholm-Arlanda Airport",
        runwayEnds: [
          F.end("01L", reciprocal: "19R", heading: 10, length: 3301, elevation: 30, TORA: 3000)
        ]
      ),
      F.record(
        .openFlightmaps,
        ICAO: "ESSA",
        country: "SE",
        openFlightmapsCode: "ESSA",
        name: "STOCKHOLM/ARLANDA",
        runwayEnds: [F.end("01L", reciprocal: "19R", heading: 10, length: 3301, TORA: 3301)]
      ),
      F.record(
        .LFV,
        ICAO: "ESSA",
        country: "SE",
        runwayEnds: [F.end("01L", length: nil, elevation: 36.5)],
        describesRunways: false
      )
    ])

    let runway = try #require(airport.runways.only)
    #expect(runway.takeoffRun == 3301)
    #expect(runway.elevation == 36.5)
    #expect(airport.name == "Stockholm-Arlanda Airport")
    #expect(airport.sources == [.LFV, .openFlightmaps, .ourAirports])
  }

  @Test
  func `keeps the layout's runway names while matching another source's renumbered ends`() throws {
    let airport = try airport([
      F.record(
        .ourAirports,
        ICAO: "EDXY",
        ourAirportsID: "1",
        runwayEnds: [F.end("9", reciprocal: "27", heading: 88, threshold: (48, 11))]
      ),
      F.record(
        .openFlightmaps,
        ICAO: "EDXY",
        openFlightmapsCode: "EDXY",
        runwayEnds: [
          F.end(
            "10",
            reciprocal: "28",
            heading: 92,
            length: 1300,
            threshold: (48, 11.001),
            TORA: 1200
          )
        ]
      )
    ])
    let runway = try #require(airport.runways.only)
    #expect(runway.name == "10")
    #expect(runway.takeoffRun == 1200)
  }

  @Test
  func `computes the gradient only from official threshold elevations`() throws {
    let ends = [
      F.end("09", reciprocal: "27", heading: 90, length: 1000, elevation: 500),
      F.end("27", reciprocal: "09", heading: 270, length: 1000, elevation: 510)
    ]
    let official = try airport([F.record(.NATS, ICAO: "EGXY", runwayEnds: ends)])
    #expect(official.runways.first { $0.name == "09" }?.gradient == 0.01)
    #expect(official.runways.first { $0.name == "27" }?.gradient == -0.01)

    let community = try airport([
      F.record(.ourAirports, ICAO: "EDXY", ourAirportsID: "1", runwayEnds: ends)
    ])
    #expect(community.runways.allSatisfy { $0.gradient == nil })
  }

  @Test
  func `passes over a declared distance that is the runway length in the wrong unit`() throws {
    let airport = try airport([
      F.record(
        .openFlightmaps,
        ICAO: "LOWW",
        openFlightmapsCode: "LOWW",
        runwayEnds: [F.end("29", heading: 290, length: 3500, TORA: 1066.8)]
      ),
      F.record(
        .ourAirports,
        ICAO: "LOWW",
        ourAirportsID: "1",
        runwayEnds: [F.end("29", heading: 290, length: 3500)]
      )
    ])
    #expect(airport.runways.only?.takeoffRun == 3500)
  }

  @Test
  func `uses a NASR record as is, under its new key`() throws {
    let resolved = try #require(F.resolve(NASR: [F.NASR()], []).airports.only)
    let airport = try #require(F.build(resolved))
    #expect(airport.recordID == "FAA:04508.*A")
    #expect(airport.dataSource == "NASR")
    #expect(airport.runways.map(\.name) == ["09"])
  }

  @Test
  func `spells the legacy data source the way released apps expect`() throws {
    let airport = try airport([F.record(.openFlightmaps, ICAO: "EDXY", openFlightmapsCode: "EDXY")])
    #expect(airport.dataSource == "OurAirports")
  }
}

@Suite
struct `Runway designators` {
  @Test(arguments: [("9", "09"), ("09", "09"), ("9L", "09L"), (" 27 ", "27"), ("27r", "27R")])
  func `normalizes each spelling`(_ designator: String, _ expected: String) {
    #expect(RunwayDesignator.normalize(designator) == expected)
  }
}

extension Collection {
  /// The collection's single element, or `nil` if it has none or several.
  var only: Element? { count == 1 ? first : nil }
}
