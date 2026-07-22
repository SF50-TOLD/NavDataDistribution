import SwiftNASR
import Testing

@testable import NavDataGeneration

@Suite("DTPPCycle")
struct DTPPCycleTests {
  @Test(
    "derives the YYNN identifier from a NASR cycle",
    arguments: [
      (Cycle(year: 2026, month: 8, day: 6), "2608"),
      (Cycle(year: 2026, month: 7, day: 9), "2607"),
      (Cycle(year: 2026, month: 1, day: 22), "2601"),
      (Cycle(year: 2025, month: 12, day: 25), "2513")
    ]
  )
  func identifier(cycle: Cycle, expected: String) {
    #expect(DTPPCycle.identifier(for: cycle) == expected)
  }
}
