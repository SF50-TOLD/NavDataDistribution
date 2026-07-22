import SwiftCIFP
import Testing

@testable import NavDataGeneration

@Suite("ApproachFamily")
struct ApproachFamilyTests {
  @Test(
    "maps CIFP approach types to navaid families",
    arguments: [
      (ApproachType.ils, ApproachFamily.ils),
      (.localizerOnly, .localizer),
      (.localizerBackcourse, .localizerBackcourse),
      (.rnav, .rnav),
      (.rnpAR, .rnp),
      (.gps, .gps),
      (.gls, .gls),
      (.vor, .vor),
      (.vorDME, .vorDME),
      (.vorTAC, .vorRequiringDME),
      (.tacan, .tacan),
      (.ndb, .ndb),
      (.ndbDME, .ndbDME),
      (.lda, .lda),
      (.sdf, .sdf),
      (.igs, .igs),
      (.fms, .fms),
      (.mlsTypeA, .mls)
    ]
  )
  func mapsApproachType(type: ApproachType, expected: ApproachFamily) {
    #expect(ApproachFamily(approachType: type) == expected)
  }

  @Test("has no family for transitions or missed approaches")
  func rejectsNonApproachTypes() {
    #expect(ApproachFamily(approachType: .transition) == nil)
    #expect(ApproachFamily(approachType: .missedApproach) == nil)
  }
}
