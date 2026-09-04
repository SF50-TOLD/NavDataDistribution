import Testing

@testable import NavDataGeneration

@Suite
struct `ChartName tests` {
  @Test
  func `a combined ILS/LOC chart answers both families`() throws {
    let chart = try #require(ChartName("ILS OR LOC RWY 28L"))
    #expect(chart.families == [.ils, .localizer])
    #expect(chart.runway == "28L")
    #expect(chart.designator == nil)
  }

  @Test
  func `reads a multiple indicator embedded before OR`() throws {
    let chart = try #require(ChartName("ILS Z OR LOC Z RWY 23"))
    #expect(chart.runway == "23")
    #expect(chart.designator == "Z")
  }

  @Test
  func `reads a multiple indicator placed before RWY`() throws {
    let chart = try #require(ChartName("RNAV (GPS) Y RWY 10R"))
    #expect(chart.families == [.rnav, .gps])
    #expect(chart.runway == "10R")
    #expect(chart.designator == "Y")
  }

  @Test
  func `distinguishes RNP from GPS RNAV charts`() throws {
    let chart = try #require(ChartName("RNAV (RNP) Z RWY 10R"))
    #expect(chart.families == [.rnp])
  }

  @Test
  func `treats a plain VOR chart as satisfying a DME-requiring VOR approach`() throws {
    let chart = try #require(ChartName("VOR RWY 05"))
    #expect(chart.families.contains(.vorRequiringDME))
    #expect(chart.families.contains(.vor))
    #expect(chart.runway == "05")
  }

  @Test
  func `a VOR/DME chart is not also a plain VOR chart`() throws {
    let chart = try #require(ChartName("VOR/DME RWY 4"))
    #expect(chart.families.contains(.vorDME))
    #expect(!chart.families.contains(.vor))
  }

  @Test
  func `handles a circling approach designator`() throws {
    let chart = try #require(ChartName("VOR-A"))
    #expect(chart.runway == nil)
    #expect(chart.designator == "A")
  }

  @Test
  func `takes the first runway of a dual-runway chart`() throws {
    let chart = try #require(ChartName("HI-TACAN Z RWY 23L/R"))
    #expect(chart.families == [.tacan])
    #expect(chart.runway == "23L")
    #expect(chart.designator == "Z")
  }

  @Test
  func `rejects a chart naming no navaid family`() {
    #expect(ChartName("TIPP TOE VISUAL RWY 28L/R") == nil)
  }

  @Test
  func `the base chart outranks its special-minimums variants`() throws {
    let base = try #require(ChartName("ILS OR LOC RWY 28L"))
    let catII = try #require(ChartName("ILS RWY 28L (SA CAT II)"))
    let military = try #require(ChartName("HI-ILS OR LOC RWY 28L"))
    let continuation = try #require(ChartName("ILS OR LOC RWY 28L, CONT.1"))
    #expect(base.penalty < catII.penalty)
    #expect(base.penalty < military.penalty)
    #expect(base.penalty < continuation.penalty)
  }

  @Test
  func `produces one key per family it satisfies`() throws {
    let chart = try #require(ChartName("ILS OR LOC RWY 28L"))
    #expect(
      Set(chart.keys) == [
        ApproachKey(family: .ils, runway: "28L", designator: nil),
        ApproachKey(family: .localizer, runway: "28L", designator: nil)
      ]
    )
  }

  @Test
  func `rejects a chart with neither runway nor designator`() {
    #expect(ChartName("AIRPORT DIAGRAM") == nil)
  }
}
