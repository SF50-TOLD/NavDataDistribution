import SwiftCIFP
import Testing

@testable import NavDataGeneration

@Suite("ApproachFamily")
struct ApproachFamilyTests {
  @Test("treats a DME-requiring VOR approach as its own family")
  func vorRequiringDMEIsDistinct() {
    // CIFP type S is charted as plain VOR, VOR/DME, or VOR OR TACAN, so it must
    // not collapse into .vor or .tacan.
    #expect(ApproachFamily(approachType: .vorTAC) == .vorRequiringDME)
    #expect(ApproachFamily(approachType: .vor) == .vor)
    #expect(ApproachFamily(approachType: .tacan) == .tacan)
  }

  @Test(
    "collapses every MLS variant into one family",
    arguments: [ApproachType.mls, .mlsTypeA, .mlsTypeBC]
  )
  func collapsesMLSVariants(type: ApproachType) {
    #expect(ApproachFamily(approachType: type) == .mls)
  }

  @Test("has no family for transitions or missed approaches")
  func rejectsNonApproachTypes() {
    #expect(ApproachFamily(approachType: .transition) == nil)
    #expect(ApproachFamily(approachType: .missedApproach) == nil)
  }
}
