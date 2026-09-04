import SwiftCIFP
import Testing

@testable import NavDataGeneration

@Suite
struct `ApproachFamily tests` {
  @Test
  func `treats a DME-requiring VOR approach as its own family`() {
    // CIFP type S is charted as plain VOR, VOR/DME, or VOR OR TACAN, so it must
    // not collapse into .vor or .tacan.
    #expect(ApproachFamily(approachType: .vorTAC) == .vorRequiringDME)
    #expect(ApproachFamily(approachType: .vor) == .vor)
    #expect(ApproachFamily(approachType: .tacan) == .tacan)
  }

  @Test(arguments: [ApproachType.mls, .mlsTypeA, .mlsTypeBC])
  func `collapses every MLS variant into one family`(type: ApproachType) {
    #expect(ApproachFamily(approachType: type) == .mls)
  }

  @Test
  func `has no family for transitions or missed approaches`() {
    #expect(ApproachFamily(approachType: .transition) == nil)
    #expect(ApproachFamily(approachType: .missedApproach) == nil)
  }
}
