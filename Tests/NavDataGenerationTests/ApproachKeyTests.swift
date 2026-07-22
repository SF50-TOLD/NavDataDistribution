import SwiftCIFP
import Testing

@testable import NavDataGeneration

@Suite("ApproachKey")
struct ApproachKeyTests {
  @Test("parses a plain runway approach")
  func plainRunway() {
    let key = ApproachKey(approachType: .ils, identifier: "I28L")
    #expect(key == ApproachKey(family: .ils, runway: "28L", designator: nil))
  }

  @Test("parses a multiple-indicator suffix")
  func multipleIndicator() {
    let key = ApproachKey(approachType: .rnav, identifier: "R28RZ")
    #expect(key == ApproachKey(family: .rnav, runway: "28R", designator: "Z"))
  }

  @Test("parses a dashed multiple indicator")
  func dashedIndicator() {
    let key = ApproachKey(approachType: .rnav, identifier: "R12-Y")
    #expect(key == ApproachKey(family: .rnav, runway: "12", designator: "Y"))
  }

  @Test("parses a circling approach designator")
  func circling() {
    let key = ApproachKey(approachType: .vor, identifier: "VOR-A")
    #expect(key == ApproachKey(family: .vor, runway: nil, designator: "A"))
  }

  @Test("preserves the runway designator as written")
  func preservesRunwayDesignator() {
    let key = ApproachKey(approachType: .vorTAC, identifier: "S05")
    #expect(key == ApproachKey(family: .vorRequiringDME, runway: "05", designator: nil))
  }

  @Test("has no key for a non-approach record type")
  func rejectsTransition() {
    #expect(ApproachKey(approachType: .transition, identifier: "I28L") == nil)
  }
}
