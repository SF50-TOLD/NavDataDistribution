import SwiftCIFP
import Testing

@testable import NavDataGeneration

@Suite
struct `ApproachKey tests` {
  @Test
  func `parses a plain runway approach`() {
    let key = ApproachKey(approachType: .ils, identifier: "I28L")
    #expect(key == ApproachKey(family: .ils, runway: "28L", designator: nil))
  }

  @Test
  func `parses a multiple-indicator suffix`() {
    let key = ApproachKey(approachType: .rnav, identifier: "R28RZ")
    #expect(key == ApproachKey(family: .rnav, runway: "28R", designator: "Z"))
  }

  @Test
  func `parses a dashed multiple indicator`() {
    let key = ApproachKey(approachType: .rnav, identifier: "R12-Y")
    #expect(key == ApproachKey(family: .rnav, runway: "12", designator: "Y"))
  }

  @Test
  func `parses a circling approach designator`() {
    let key = ApproachKey(approachType: .vor, identifier: "VOR-A")
    #expect(key == ApproachKey(family: .vor, runway: nil, designator: "A"))
  }

  @Test
  func `preserves the runway designator as written`() {
    let key = ApproachKey(approachType: .vorTAC, identifier: "S05")
    #expect(key == ApproachKey(family: .vorRequiringDME, runway: "05", designator: nil))
  }

  @Test
  func `has no key for a non-approach record type`() {
    #expect(ApproachKey(approachType: .transition, identifier: "I28L") == nil)
  }
}
