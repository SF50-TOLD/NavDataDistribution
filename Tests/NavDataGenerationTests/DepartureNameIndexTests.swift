import Testing

@testable import NavDataGeneration

private typealias CodeAndName = (code: String?, name: String?)

@Suite("DepartureNameIndex")
struct DepartureNameIndexTests {
  @Test("keys the official name by the CIFP identifier in the computer code")
  func indexesByComputerCodeRoot() {
    let codesAndNames: [CodeAndName] = [
      (code: "SSTIK5.SSTIK", name: "SSTIK FIVE"),
      (code: "GAPP7.GAP", name: "GAP SEVEN"),
      (code: "VTU8.VTU", name: "VENTURA EIGHT")
    ]
    let index = DepartureNameIndex.index(codesAndNames: codesAndNames)
    #expect(index["SSTIK5"] == "SSTIK FIVE")
    #expect(index["GAPP7"] == "GAP SEVEN")
    #expect(index["VTU8"] == "VENTURA EIGHT")
  }

  @Test("skips unassigned codes, codes without an exit fix, and missing fields")
  func skipsUnusableRecords() {
    let codesAndNames: [CodeAndName] = [
      (code: "NOT ASSIGNED", name: "SOMETHING"),
      (code: "NOEXITFIX", name: "NO EXIT FIX"),
      (code: nil, name: "NO CODE"),
      (code: "OKAY1.FIX", name: nil),
      (code: "BLANK1.FIX", name: "")
    ]
    let index = DepartureNameIndex.index(codesAndNames: codesAndNames)
    #expect(index.isEmpty)
  }
}
