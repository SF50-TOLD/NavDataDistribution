import Foundation
import NavData
import SwiftAIXM
import Testing

@testable import NavDataGeneration

@Suite
struct `AIXM conversion` {
  private static let displacedThreshold = SwiftAIXM.Location(latitudeDeg: 46, longitudeDeg: 14)

  private static func airport(direction: RunwayDirection) -> SwiftAIXM.Airport {
    .init(
      id: "LJPZ",
      designator: "LJPZ",
      ICAOIdentifier: "LJPZ",
      IATAIdentifier: nil,
      name: "PORTOROZ",
      city: nil,
      type: .aerodrome,
      referencePoint: displacedThreshold,
      magneticVariation: nil,
      runways: [
        .init(
          id: "15/33",
          designator: "15/33",
          isFixedWing: true,
          length: Measurement(value: 1200, unit: .meters),
          width: nil,
          composition: .asphalt,
          directions: [direction]
        )
      ]
    )
  }

  private static func direction(displacement: Double?) -> RunwayDirection {
    .init(
      id: "09",
      designator: "09",
      trueBearing: Measurement(value: 90, unit: .degrees),
      magneticBearing: nil,
      threshold: nil,
      displacedThreshold: displacedThreshold,
      end: nil,
      touchdownZoneElevation: nil,
      declaredDistances: .init(
        TORA: nil,
        TODA: nil,
        ASDA: nil,
        LDA: nil,
        thresholdDisplacement: displacement.map { Measurement(value: $0, unit: .meters) }
      ),
      glidepath: nil,
      visualGlideSlope: nil
    )
  }

  private static func convert(_ direction: RunwayDirection) throws -> SourceRunwayEnd {
    let record = try #require(
      AIXMConversion.sourceAirport(
        airport(direction: direction),
        source: .openFlightmaps,
        identifiers: .init()
      )
    )
    return try #require(record.runwayEnds.only)
  }

  @Test
  func `moves a displaced threshold back to the physical threshold`() throws {
    let end = try Self.convert(Self.direction(displacement: 210))
    let latitude = try #require(end.thresholdLatitude),
      longitude = try #require(end.thresholdLongitude)
    #expect(longitude < Self.displacedThreshold.longitudeDeg)
    let distance = AirportResolver.distanceM(
      (latitude, longitude),
      (Self.displacedThreshold.latitudeDeg, Self.displacedThreshold.longitudeDeg)
    )
    #expect(abs(distance - 210) < 0.5)
    #expect(end.displacedThresholdDistance == 210)
  }

  @Test
  func `leaves the threshold unknown when the displacement is`() throws {
    let end = try Self.convert(Self.direction(displacement: nil))
    #expect(end.thresholdLatitude == nil)
  }
}
