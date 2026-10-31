import Foundation
import NavData
import SwiftAIXM

/// Converts SwiftAIXM records into the generator's source-neutral model.
enum AIXMConversion {

  /// Runways shorter than this, in meters (500 ft), are left out, as for every source.
  private static let minimumRunwayLength = 152.4

  /// The height of an obstacle top is rounded up to whole feet, erring high.
  private static let feetPerMeter = 1 / 0.3048

  /**
   A source record for an AIXM aerodrome, or `nil` if it has no runway an aeroplane
   could use.
   */
  static func sourceAirport(
    _ airport: SwiftAIXM.Airport,
    source: AirportDataSource,
    identifiers: SourceAirport.Identifiers
  ) -> SourceAirport? {
    guard airport.type?.hasRunways == true, let referencePoint = airport.referencePoint else {
      return nil
    }
    let ends = airport.runways.filter(isUsable).flatMap(runwayEnds)
    guard !ends.isEmpty else { return nil }

    return SourceAirport(
      source: source,
      sourceID: airport.id,
      identifiers: identifiers,
      locationID: airport.designator,
      name: airport.name,
      city: airport.city,
      latitude: referencePoint.latitudeDeg,
      longitude: referencePoint.longitudeDeg,
      elevation: referencePoint.elevation?.converted(to: .meters).value,
      runwayEnds: ends,
      describesRunways: true
    )
  }

  /// One obstacle per position of every obstacle part whose top elevation is known.
  static func obstacles(_ obstacles: [SwiftAIXM.Obstacle]) -> [AirportDataCodable.ObstacleCodable] {
    obstacles.flatMap(\.parts).flatMap { part -> [AirportDataCodable.ObstacleCodable] in
      guard let top = part.topElevation?.converted(to: .meters).value else { return [] }
      let heightFtMSL = Int((top * feetPerMeter).rounded(.up))
      return part.geometry.locations.map {
        .init(heightFtMSL: heightFtMSL, latitude: $0.latitudeDeg, longitude: $0.longitudeDeg)
      }
    }
  }

  private static func isUsable(_ runway: SwiftAIXM.Runway) -> Bool {
    guard runway.isFixedWing, runway.composition != .water else { return false }
    guard let length = runway.length?.converted(to: .meters).value else { return true }
    return length >= minimumRunwayLength
  }

  private static func runwayEnds(_ runway: SwiftAIXM.Runway) -> [SourceRunwayEnd] {
    runway.directions.map { direction in
      let reciprocal = runway.directions.first { $0.designator != direction.designator }
      return runwayEnd(direction, reciprocal: reciprocal, runway: runway)
    }
  }

  private static func runwayEnd(
    _ direction: RunwayDirection,
    reciprocal: RunwayDirection?,
    runway: SwiftAIXM.Runway
  ) -> SourceRunwayEnd {
    let distances = direction.declaredDistances
    let threshold = physicalThreshold(direction)
    let displacement =
      distances.thresholdDisplacement?.converted(to: .meters).value
      ?? displacementBetweenPoints(direction)

    return SourceRunwayEnd(
      name: direction.designator,
      reciprocalName: reciprocal?.designator,
      trueHeading: direction.trueBearing?.converted(to: .degrees).value,
      length: runway.length?.converted(to: .meters).value,
      width: runway.width?.converted(to: .meters).value,
      surface: runway.composition.map { $0.isPaved ? .paved : .turf },
      thresholdLatitude: threshold?.latitudeDeg,
      thresholdLongitude: threshold?.longitudeDeg,
      thresholdElevation: (direction.threshold ?? direction.displacedThreshold)?.elevation?
        .converted(to: .meters).value,
      displacedThresholdDistance: displacement,
      takeoffRun: distances.TORA?.converted(to: .meters).value,
      takeoffDistance: distances.TODA?.converted(to: .meters).value,
      landingDistance: distances.LDA?.converted(to: .meters).value,
      thresholdCrossingHeight: direction.glidepath?.referenceDatumHeight?.converted(to: .meters)
        .value,
      glidepathAngle: (direction.glidepath?.angle ?? direction.visualGlideSlope?.angle)?
        .converted(to: .degrees).value
    )
  }

  /// The threshold, or where it lies behind a displaced threshold whose displacement and
  /// bearing are known.
  private static func physicalThreshold(_ direction: RunwayDirection) -> Location? {
    if let threshold = direction.threshold { return threshold }
    guard let displaced = direction.displacedThreshold,
      let displacement = direction.declaredDistances.thresholdDisplacement?.converted(to: .meters)
        .value,
      let bearing = direction.trueBearing?.converted(to: .degrees).value
    else { return nil }

    let (latitude, longitude) = GeoCalculations.destination(
      latitudeDeg: displaced.latitudeDeg,
      longitudeDeg: displaced.longitudeDeg,
      bearingDeg: bearing + 180,
      distanceM: displacement
    )
    return Location(latitudeDeg: latitude, longitudeDeg: longitude)
  }

  private static func displacementBetweenPoints(_ direction: RunwayDirection) -> Double? {
    guard let threshold = direction.threshold,
      let displaced = direction.displacedThreshold
    else { return nil }
    return AirportResolver.distanceM(
      (threshold.latitudeDeg, threshold.longitudeDeg),
      (displaced.latitudeDeg, displaced.longitudeDeg)
    )
  }
}
