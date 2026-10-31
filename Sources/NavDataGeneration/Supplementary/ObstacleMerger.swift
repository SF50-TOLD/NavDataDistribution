import NavData

/// Combines obstacle lists from several sources, resolving an obstacle that repeats one
/// from another source: within ``maxSeparationM`` horizontally and ``maxHeightDifferenceFt``
/// vertically. The taller record is kept, since understating an obstacle's height is the
/// unsafe error; on a tie the earlier source, which has higher precedence, wins.
///
/// Obstacles from the same source are never compared with each other, so a source's own
/// closely spaced obstacles all survive.
///
/// Repeats occur where national data sets overlap at borders, and where a data set
/// publishes both a structure and the line strung from it.
enum ObstacleMerger {
  private static let maxSeparationM = 30.0
  private static let maxHeightDifferenceFt = 10

  /// Grid cell size in degrees; larger than the separation limit at any latitude.
  private static let cellDeg = 0.001

  static func merge(
    _ lists: [[AirportDataCodable.ObstacleCodable]]
  ) -> [AirportDataCodable.ObstacleCodable] {
    var kept = [AirportDataCodable.ObstacleCodable]()
    var isSuperseded = [Bool]()
    var keptByCell = [Cell: [Int]]()

    for list in lists {
      let earlierCount = kept.count
      for obstacle in list {
        let cell = Cell(obstacle)
        let repeats = cell.neighborhood.lazy
          .flatMap { keptByCell[$0] ?? [] }
          .filter { !isSuperseded[$0] && isSame(kept[$0], obstacle) }
        guard !repeats.contains(where: { kept[$0].heightFtMSL >= obstacle.heightFtMSL }) else {
          continue
        }
        for index in repeats { isSuperseded[index] = true }
        kept.append(obstacle)
        isSuperseded.append(false)
      }
      for index in earlierCount..<kept.count {
        keptByCell[Cell(kept[index]), default: []].append(index)
      }
    }
    return kept.indices.filter { !isSuperseded[$0] }.map { kept[$0] }
  }

  private static func isSame(
    _ lhs: AirportDataCodable.ObstacleCodable,
    _ rhs: AirportDataCodable.ObstacleCodable
  ) -> Bool {
    abs(lhs.heightFtMSL - rhs.heightFtMSL) <= maxHeightDifferenceFt
      && AirportResolver.distanceM((lhs.latitude, lhs.longitude), (rhs.latitude, rhs.longitude))
        <= maxSeparationM
  }

  private struct Cell: Hashable {
    let row: Int
    let column: Int

    var neighborhood: [Self] {
      (-1...1).flatMap { rowOffset in
        (-1...1).map { Self(row: row + rowOffset, column: column + $0) }
      }
    }

    init(_ obstacle: AirportDataCodable.ObstacleCodable) {
      row = Int((obstacle.latitude / ObstacleMerger.cellDeg).rounded(.down))
      column = Int((obstacle.longitude / ObstacleMerger.cellDeg).rounded(.down))
    }

    init(row: Int, column: Int) {
      self.row = row
      self.column = column
    }
  }
}
