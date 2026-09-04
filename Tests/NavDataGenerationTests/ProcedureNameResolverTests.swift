import SwiftCIFP
import Testing

@testable import NavDataGeneration

@Suite
struct `ProcedureNameResolver tests` {
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

  @Test
  func `names an ILS approach with its combined chart title`() {
    #expect(
      name("KSFO", .ils, "I28L")
        == "ILS OR LOC RWY 28L"
    )
  }

  @Test
  func `names a localizer approach with the same combined chart`() {
    #expect(
      name("KSFO", .localizerOnly, "L28L")
        == "ILS OR LOC RWY 28L"
    )
  }

  @Test
  func `distinguishes RNAV and RNP approaches on the same runway`() {
    #expect(
      name("KSFO", .rnav, "R28RZ")
        == "RNAV (GPS) Z RWY 28R"
    )
    #expect(
      name("KSFO", .rnpAR, "H28RY")
        == "RNAV (RNP) Y RWY 28R"
    )
  }

  @Test
  func `returns nil for an airport with no charts`() {
    #expect(
      name("EGLL", .ils, "I27R") == nil
    )
  }

  @Test
  func `joins a departure to its full chart title`() {
    #expect(resolver.departureName(icao: "KSFO", identifier: "SSTIK5") == "SSTIK FIVE (RNAV)")
  }

  @Test
  func `falls back to the NASR name when no chart matches`() {
    #expect(resolver.departureName(icao: "KSFO", identifier: "ZZZZ1") == "NOWHERE ONE")
  }

  @Test
  func `returns nil for a departure NASR does not name`() {
    #expect(resolver.departureName(icao: "KSFO", identifier: "NOPE9") == nil)
  }
}
