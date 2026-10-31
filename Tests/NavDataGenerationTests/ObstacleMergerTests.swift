import NavData
import Testing

@testable import NavDataGeneration

@Suite
struct `Obstacle merging` {
  private func obstacle(
    _ heightFtMSL: Int,
    latitude: Double = 40,
    longitude: Double = -100
  ) -> AirportDataCodable.ObstacleCodable {
    .init(heightFtMSL: heightFtMSL, latitude: latitude, longitude: longitude)
  }

  @Test
  func `keeps near-duplicate obstacles from the same source`() {
    let source = [obstacle(500), obstacle(505, latitude: 40.0001), obstacle(510)]
    #expect(ObstacleMerger.merge([source]).map(\.heightFtMSL) == [500, 505, 510])
  }

  @Test
  func `keeps the taller record of an obstacle repeated by a later source`() {
    let merged = ObstacleMerger.merge([[obstacle(500)], [obstacle(505)]])
    #expect(merged.map(\.heightFtMSL) == [505])
  }

  @Test
  func `keeps the earlier record of an equally tall repeat`() {
    let merged = ObstacleMerger.merge([[obstacle(500)], [obstacle(500, latitude: 40.0001)]])
    #expect(merged.map(\.latitude) == [40])
  }
}
