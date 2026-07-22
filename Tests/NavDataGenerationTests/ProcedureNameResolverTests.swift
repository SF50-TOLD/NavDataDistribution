import SwiftCIFP
import Testing

@testable import NavDataGeneration

@Suite("ProcedureNameResolver")
struct ProcedureNameResolverTests {
  private let resolver = ProcedureNameResolver(
    charts: [
      "KSFO": [
        .init(kind: .approach, name: "ILS OR LOC RWY 28L"),
        .init(kind: .approach, name: "ILS RWY 28L (SA CAT II)"),
        .init(kind: .approach, name: "RNAV (GPS) Z RWY 28R"),
        .init(kind: .approach, name: "RNAV (RNP) Y RWY 28R"),
        .init(kind: .departure, name: "SSTIK FIVE (RNAV)"),
        .init(kind: .departure, name: "GAP SEVEN")
      ]
    ],
    departureNames: ["SSTIK5": "SSTIK FIVE", "GAPP7": "GAP SEVEN", "ZZZZ1": "NOWHERE ONE"]
  )

  /// Builds the key the way `CIFPProcessor` does, so these tests exercise the
  /// same derivation the pipeline uses.
  private func name(_ icao: String, _ type: ApproachType, _ identifier: String) -> String? {
    guard let key = ApproachKey(approachType: type, identifier: identifier) else { return nil }
    return resolver.approachName(icao: icao, key: key)
  }

  @Test("names an ILS approach with its combined chart title")
  func namesILS() {
    #expect(
      name("KSFO", .ils, "I28L")
        == "ILS OR LOC RWY 28L"
    )
  }

  @Test("names a localizer approach with the same combined chart")
  func namesLocalizer() {
    #expect(
      name("KSFO", .localizerOnly, "L28L")
        == "ILS OR LOC RWY 28L"
    )
  }

  @Test("distinguishes RNAV and RNP approaches on the same runway")
  func distinguishesRNAVFromRNP() {
    #expect(
      name("KSFO", .rnav, "R28RZ")
        == "RNAV (GPS) Z RWY 28R"
    )
    #expect(
      name("KSFO", .rnpAR, "H28RY")
        == "RNAV (RNP) Y RWY 28R"
    )
  }

  @Test("returns nil for an airport with no charts")
  func missesUnchartedAirport() {
    #expect(
      name("EGLL", .ils, "I27R") == nil
    )
  }

  @Test("joins a departure to its full chart title")
  func joinsDepartureToChart() {
    #expect(resolver.departureName(icao: "KSFO", identifier: "SSTIK5") == "SSTIK FIVE (RNAV)")
  }

  @Test("falls back to the NASR name when no chart matches")
  func fallsBackToNASRName() {
    #expect(resolver.departureName(icao: "KSFO", identifier: "ZZZZ1") == "NOWHERE ONE")
  }

  @Test("returns nil for a departure NASR does not name")
  func missesUnknownDeparture() {
    #expect(resolver.departureName(icao: "KSFO", identifier: "NOPE9") == nil)
  }
}
