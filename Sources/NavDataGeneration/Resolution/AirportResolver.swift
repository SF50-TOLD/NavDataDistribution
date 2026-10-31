import NavData

/**
 Resolves airport records from every source into one record per airport.

 Records are clustered with a union-find:

 1. **Identifier links** join records that share an official ICAO location indicator, or
    a country and national code. Each link is vetoed when the records' reference points
    are more than ``maxIdentifierLinkDistanceM`` apart, which signals a relocated airport
    or a data error.
 2. **Geometric links** join remaining clusters whose reference points are within
    ``maxGeometricLinkDistanceM`` and that share a runway end.

 Two clusters never merge if they hold records from the same source or different ICAO
 indicators. Clusters with no record describing a runway layout are dropped.

 Each cluster is then keyed by its most authoritative identifier (see ``AirportKey``) and
 given every other identifier as an alias.
 */
struct AirportResolver {

  /// Sources in order of precedence, highest first.
  static let precedence: [AirportDataSource] = [.NASR, .NATS, .LFV, .openFlightmaps, .ourAirports]

  /// Countries whose airports NASR publishes. National codes in these share the FAA
  /// identifier namespace.
  static let FAACountries: Set<String> = ["US", "PR", "VI", "GU", "AS", "MP", "UM"]

  private static let maxIdentifierLinkDistanceM = 10_000.0
  private static let maxGeometricLinkDistanceM = 1500.0
  static let maxRunwayHeadingDifferenceDeg = 10.0

  /// Grid cell size for finding nearby clusters, in degrees. Larger than the geometric
  /// link distance at any latitude airports are found at.
  private static let gridCellDeg = 0.05

  private static let metersPerNauticalMile = 1852.0

  private let nodes: [Node]

  init(NASRAirports: [AirportDataCodable.AirportCodable], records: [SourceAirport]) {
    nodes = NASRAirports.map(Node.init(NASR:)) + records.map(Node.init(record:))
  }

  static func rank(of source: AirportDataSource) -> Int {
    precedence.firstIndex(of: source) ?? precedence.count
  }

  static func distanceM(_ lhs: (Double, Double), _ rhs: (Double, Double)) -> Double {
    GeoCalculations.calculateDistanceNM(fromLat: lhs.0, fromLon: lhs.1, toLat: rhs.0, toLon: rhs.1)
      * metersPerNauticalMile
  }

  /// Clusters the records and keys each cluster.
  func resolve() -> Resolution {
    var clusters = UnionFind(nodes: nodes)
    var statistics = Resolution.Statistics()

    linkByIdentifiers(&clusters, statistics: &statistics)
    linkByGeometry(&clusters, statistics: &statistics)

    let kept = clusters.groups().filter { members in
      keep(members, statistics: &statistics)
    }
    let airports = assignKeys(to: kept)
    statistics.airports = airports.count
    return Resolution(airports: airports, statistics: statistics)
  }

  // MARK: - Linking

  private func linkByIdentifiers(
    _ clusters: inout UnionFind,
    statistics: inout Resolution.Statistics
  ) {
    var nodesByKey = [String: [Int]]()
    for (index, node) in nodes.enumerated() {
      for key in node.linkKeys { nodesByKey[key, default: []].append(index) }
    }

    for key in nodesByKey.keys.sorted() {
      guard let members = nodesByKey[key], members.count > 1 else { continue }
      let ordered = members.sorted { nodes[$0].rank < nodes[$1].rank }
      let anchor = ordered[0]
      for member in ordered.dropFirst() {
        guard
          Self.distanceM(nodes[anchor].position, nodes[member].position)
            <= Self.maxIdentifierLinkDistanceM
        else {
          statistics.distanceVetoes += 1
          continue
        }
        if clusters.union(anchor, member) {
          statistics.identifierLinks += 1
        } else if clusters.find(anchor) != clusters.find(member) {
          statistics.conflictVetoes += 1
        }
      }
    }
  }

  private func linkByGeometry(_ clusters: inout UnionFind, statistics: inout Resolution.Statistics)
  {
    var nodesByCell = [Cell: [Int]]()
    for (index, node) in nodes.enumerated() {
      nodesByCell[Cell(node.position, size: Self.gridCellDeg), default: []].append(index)
    }

    for (index, node) in nodes.enumerated() {
      let neighbors = Cell(node.position, size: Self.gridCellDeg).neighborhood
        .flatMap { nodesByCell[$0] ?? [] }
        .filter { $0 > index }
      for neighbor in neighbors where clusters.find(index) != clusters.find(neighbor) {
        guard !clusters.sharesIdentifier(index, neighbor),
          Self.distanceM(node.position, nodes[neighbor].position) <= Self.maxGeometricLinkDistanceM,
          node.sharesRunwayEnd(with: nodes[neighbor])
        else { continue }
        if clusters.union(index, neighbor) { statistics.geometricLinks += 1 }
      }
    }
  }

  // MARK: - Filtering

  private func keep(_ members: [Int], statistics: inout Resolution.Statistics) -> Bool {
    let clusterNodes = members.map { nodes[$0] }
    guard clusterNodes.contains(where: \.describesRunways) else {
      statistics.droppedWithoutRunways += 1
      return false
    }
    return true
  }

  // MARK: - Keys

  private func assignKeys(to groups: [[Int]]) -> [ResolvedAirport] {
    let candidates = groups.map { members -> (members: [Int], keys: [String]) in
      let ordered = members.sorted { nodes[$0].rank < nodes[$1].rank }
      return (ordered, candidateKeys(ordered))
    }
    .sorted { ($0.keys.first ?? "") < ($1.keys.first ?? "") }

    var taken = Set<String>()
    var keyed = [(members: [Int], key: String, aliases: [String])]()
    for (members, keys) in candidates {
      guard let key = keys.first(where: { !taken.contains($0) }) else { continue }
      taken.insert(key)
      let aliases = keys.filter { $0 != key } + members.compactMap { nodes[$0].legacyRecordID }
      keyed.append((members, key, aliases))
    }

    let aliasCounts = keyed.flatMap(\.aliases).reduce(into: [String: Int]()) {
      $0[$1, default: 0] += 1
    }
    return keyed.map { members, key, aliases in
      ResolvedAirport(
        key: key,
        aliases: Array(Set(aliases.filter { aliasCounts[$0] == 1 && !taken.contains($0) }))
          .sorted(),
        NASR: members.compactMap { nodes[$0].NASR }.first,
        records: members.compactMap { nodes[$0].record }
      )
    }
  }

  private func candidateKeys(_ members: [Int]) -> [String] {
    let clusterNodes = members.map { nodes[$0] }
    var keys = clusterNodes.compactMap(\.FAAKey)
    for tier in 0..<Node.keyTierCount {
      keys += clusterNodes.compactMap { $0.keys(tier: tier) }.flatMap(\.self)
    }
    var seen = Set<String>()
    return keys.filter { seen.insert($0).inserted }
  }
}

// MARK: - Results

/// The airports resolved from every source.
struct Resolution: Sendable {
  let airports: [ResolvedAirport]
  let statistics: Statistics

  /// Counts that describe how the records were resolved.
  struct Statistics: Sendable {
    var identifierLinks = 0
    var geometricLinks = 0
    var distanceVetoes = 0
    var conflictVetoes = 0
    var droppedWithoutRunways = 0
    var airports = 0
  }
}

/// One airport and the records that describe it.
struct ResolvedAirport: Sendable {

  /// The airport's key.
  let key: String

  /// The airport's other identifiers, each unique to this airport.
  let aliases: [String]

  /// The NASR record, which describes the airport completely when present.
  let NASR: AirportDataCodable.AirportCodable?

  /// The other sources' records, highest precedence first.
  let records: [SourceAirport]
}

// MARK: - Nodes

/// A record from any source, with what clustering needs to know about it.
private struct Node {
  static let keyTierCount = 4

  let NASR: AirportDataCodable.AirportCodable?
  let record: SourceAirport?
  let source: AirportDataSource
  let ICAO: String?
  let identifiers: SourceAirport.Identifiers
  let position: (Double, Double)
  let runwayEnds: [(name: String, heading: Double?)]
  let describesRunways: Bool

  var rank: Int { AirportResolver.rank(of: source) }

  /// Keys that link records across sources: the ICAO indicator, and the national code
  /// within its country. Codes in FAA-jurisdiction countries share one namespace.
  var linkKeys: [String] {
    var keys = [String]()
    if let ICAO { keys.append(AirportKey.ICAO(ICAO)) }
    if let code = identifiers.national, let country = identifiers.countryCode {
      let namespace = AirportResolver.FAACountries.contains(country) ? "US" : country
      keys.append(AirportKey.national(country: namespace, code: code))
    }
    return keys
  }

  var FAAKey: String? { NASR.map { AirportKey.FAA(siteNumber: $0.recordID) } }

  /// The identifier older data files used as this record's `recordID`.
  var legacyRecordID: String? {
    NASR?.recordID ?? (source == .ourAirports ? identifiers.ourAirports : nil)
  }

  init(NASR airport: AirportDataCodable.AirportCodable) {
    NASR = airport
    record = nil
    source = .NASR
    ICAO = AirportKey.ICAOIndicator(airport.ICAO_ID)
    identifiers = .init(ICAO: ICAO, national: airport.locationID, countryCode: "US")
    position = (airport.latitude, airport.longitude)
    runwayEnds = airport.runways.map { (RunwayDesignator.normalize($0.name), $0.trueHeading) }
    describesRunways = true
  }

  init(record: SourceAirport) {
    NASR = nil
    self.record = record
    source = record.source
    ICAO = AirportKey.ICAOIndicator(record.identifiers.ICAO)
    identifiers = record.identifiers
    position = (record.latitude, record.longitude)
    runwayEnds = record.runwayEnds.map { ($0.normalizedName, $0.trueHeading) }
    describesRunways = record.describesRunways
  }

  func keys(tier: Int) -> [String]? {
    switch tier {
      case 0: ICAO.map { [AirportKey.ICAO($0)] }
      case 1:
        identifiers.national.flatMap { code in
          identifiers.countryCode.map { [AirportKey.national(country: $0, code: code)] }
        }
      case 2: identifiers.ourAirports.map { [AirportKey.ourAirports($0)] }
      case 3:
        identifiers.openFlightmaps.map {
          [AirportKey.openFlightmaps(region: $0.region, code: $0.code)]
        }
      default: nil
    }
  }

  /// Whether the two records describe a runway end in common: one with the same
  /// designator, or the same heading.
  func sharesRunwayEnd(with other: Self) -> Bool {
    runwayEnds.contains { end in
      other.runwayEnds.contains { otherEnd in
        if end.name == otherEnd.name { return true }
        guard let heading = end.heading, let otherHeading = otherEnd.heading else { return false }
        return Headings.difference(heading, otherHeading)
          <= AirportResolver.maxRunwayHeadingDifferenceDeg
      }
    }
  }
}

/// Angular arithmetic on true headings.
enum Headings {

  /// The smallest angle between two headings, in degrees.
  static func difference(_ lhs: Double, _ rhs: Double) -> Double {
    let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
    return min(difference, 360 - difference)
  }
}

// MARK: - Spatial grid

private struct Cell: Hashable {
  let row: Int
  let column: Int

  var neighborhood: [Self] {
    (-1...1).flatMap { rowOffset in
      (-1...1).map { Self(row: row + rowOffset, column: column + $0) }
    }
  }

  init(_ position: (Double, Double), size: Double) {
    row = Int((position.0 / size).rounded(.down))
    column = Int((position.1 / size).rounded(.down))
  }

  init(row: Int, column: Int) {
    self.row = row
    self.column = column
  }
}

// MARK: - Union-find

/// Disjoint sets of nodes that refuse to merge clusters holding the same source twice or
/// two different ICAO indicators.
private struct UnionFind {
  private var parents: [Int]
  private var sources: [Set<AirportDataSource>]
  private var ICAOs: [Set<String>]
  private var keys: [Set<String>]

  init(nodes: [Node]) {
    parents = Array(nodes.indices)
    sources = nodes.map { [$0.source] }
    ICAOs = nodes.map { Set([$0.ICAO].compactMap(\.self)) }
    keys = nodes.map { Set($0.linkKeys) }
  }

  mutating func find(_ node: Int) -> Int {
    var root = node
    while parents[root] != root { root = parents[root] }
    var current = node
    while parents[current] != root {
      (current, parents[current]) = (parents[current], root)
    }
    return root
  }

  /// Merges the two nodes' clusters, unless that would break a rule. Returns whether the
  /// clusters are now one that weren't before.
  mutating func union(_ lhs: Int, _ rhs: Int) -> Bool {
    let (left, right) = (find(lhs), find(rhs))
    guard left != right, sources[left].isDisjoint(with: sources[right]),
      ICAOs[left].union(ICAOs[right]).count <= 1
    else { return false }

    parents[right] = left
    sources[left].formUnion(sources[right])
    ICAOs[left].formUnion(ICAOs[right])
    keys[left].formUnion(keys[right])
    return true
  }

  /// Whether the two nodes' clusters share an identifier, and so were already considered
  /// for an identifier link.
  mutating func sharesIdentifier(_ lhs: Int, _ rhs: Int) -> Bool {
    !keys[find(lhs)].isDisjoint(with: keys[find(rhs)])
  }

  /// The node indices in each cluster.
  mutating func groups() -> [[Int]] {
    var groups = [Int: [Int]]()
    for node in parents.indices { groups[find(node), default: []].append(node) }
    return groups.keys.sorted().compactMap { groups[$0] }
  }
}
