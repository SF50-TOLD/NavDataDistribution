import Testing

@testable import NavDataGeneration

@Suite("ChartName")
struct ChartNameTests {
  @Test("a combined ILS/LOC chart answers both families")
  func combinedILSAndLocalizer() throws {
    let chart = try #require(ChartName("ILS OR LOC RWY 28L"))
    #expect(chart.families == [.ils, .localizer])
    #expect(chart.runway == "28L")
    #expect(chart.designator == nil)
  }

  @Test("reads a multiple indicator embedded before OR")
  func embeddedIndicator() throws {
    let chart = try #require(ChartName("ILS Z OR LOC Z RWY 23"))
    #expect(chart.runway == "23")
    #expect(chart.designator == "Z")
  }

  @Test("reads a multiple indicator placed before RWY")
  func trailingIndicator() throws {
    let chart = try #require(ChartName("RNAV (GPS) Y RWY 10R"))
    #expect(chart.families == [.rnav, .gps])
    #expect(chart.runway == "10R")
    #expect(chart.designator == "Y")
  }

  @Test("distinguishes RNP from GPS RNAV charts")
  func rnpIsNotGPS() throws {
    let chart = try #require(ChartName("RNAV (RNP) Z RWY 10R"))
    #expect(chart.families == [.rnp])
  }

  @Test("treats a plain VOR chart as satisfying a DME-requiring VOR approach")
  func plainVORSatisfiesVORRequiringDME() throws {
    let chart = try #require(ChartName("VOR RWY 05"))
    #expect(chart.families.contains(.vorRequiringDME))
    #expect(chart.families.contains(.vor))
    #expect(chart.runway == "05")
  }

  @Test("a VOR/DME chart is not also a plain VOR chart")
  func vorDMEIsDistinct() throws {
    let chart = try #require(ChartName("VOR/DME RWY 4"))
    #expect(chart.families.contains(.vorDME))
    #expect(!chart.families.contains(.vor))
  }

  @Test("handles a circling approach designator")
  func circling() throws {
    let chart = try #require(ChartName("VOR-A"))
    #expect(chart.runway == nil)
    #expect(chart.designator == "A")
  }

  @Test("takes the first runway of a dual-runway chart")
  func dualRunway() throws {
    let chart = try #require(ChartName("HI-TACAN Z RWY 23L/R"))
    #expect(chart.families == [.tacan])
    #expect(chart.runway == "23L")
    #expect(chart.designator == "Z")
  }

  @Test("rejects a chart naming no navaid family")
  func rejectsVisualChart() {
    #expect(ChartName("TIPP TOE VISUAL RWY 28L/R") == nil)
  }

  @Test("the base chart outranks its special-minimums variants")
  func penaltyPrefersBaseChart() throws {
    let base = try #require(ChartName("ILS OR LOC RWY 28L"))
    let catII = try #require(ChartName("ILS RWY 28L (SA CAT II)"))
    let military = try #require(ChartName("HI-ILS OR LOC RWY 28L"))
    let continuation = try #require(ChartName("ILS OR LOC RWY 28L, CONT.1"))
    #expect(base.penalty < catII.penalty)
    #expect(base.penalty < military.penalty)
    #expect(base.penalty < continuation.penalty)
  }

  @Test("produces one key per family it satisfies")
  func keysCoverEveryFamily() throws {
    let chart = try #require(ChartName("ILS OR LOC RWY 28L"))
    #expect(
      Set(chart.keys) == [
        ApproachKey(family: .ils, runway: "28L", designator: nil),
        ApproachKey(family: .localizer, runway: "28L", designator: nil)
      ]
    )
  }

  @Test("rejects a chart with neither runway nor designator")
  func rejectsNonApproachChart() {
    #expect(ChartName("AIRPORT DIAGRAM") == nil)
  }
}
