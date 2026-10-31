import NavData

/**
 Builds one airport record from the records a ``ResolvedAirport`` gathered.

 A NASR record describes its airport completely and is used as is. Otherwise the
 highest-precedence record that describes runways sets the runway layout and names, and
 every value comes from the highest-precedence record that has it. Runway ends match
 across records by designator, or, since sources renumber runways for magnetic drift in
 different cycles, by heading and threshold position.

 Two values get extra scrutiny because the performance calculations use them directly:

 - **Gradient** is computed only from official national data, whose threshold
   elevations are surveyed. Community elevations are often rounded or estimated, and an
   error at one end becomes a large slope.
 - **Declared distances** that can't be right for the runway are passed over in favor of
   the next source: a takeoff run or landing distance longer than the runway, or a value
   that is the runway's length read in the wrong unit.
 */
struct GoldenRecordBuilder {

  /// The longest distance between two sources' thresholds for the same runway end.
  private static let maxThresholdSeparationM = 300.0

  /// Sources whose threshold elevations are surveyed precisely enough to derive a gradient.
  private static let gradientSources: Set<AirportDataSource> = [.NATS, .LFV]

  /// The steepest runway gradient taken as real; anything steeper is a data error.
  private static let maxGradient = 0.03

  /// How far a declared distance may exceed the runway length: TORA and LDA lie within the
  /// runway (allowing for rounding), while TODA adds any clearway.
  private static let maxRunDistanceShareOfLength = 1.01
  private static let maxTakeoffDistanceShareOfLength = 1.5

  /// How close a distance must come to the runway length read as feet to be taken for a
  /// unit error.
  private static let unitErrorTolerance = 0.01
  private static let metersPerFoot = 0.3048

  /// Looks up an airport's IANA time zone from its position.
  let timeZone: (Double, Double) -> String?

  private static func parallelSuffix(_ name: String) -> Character? {
    name.last.flatMap { $0.isLetter ? $0 : nil }
  }

  /// The runway gradient from this end's threshold toward the opposite one, from the
  /// highest-precedence official source with both thresholds' elevations.
  private static func gradient(
    _ ends: [SourceRunwayEnd],
    reciprocals: [SourceRunwayEnd],
    distance: Double?
  ) -> Float? {
    guard let distance, distance > 0 else { return nil }
    for end in ends {
      guard let source = end.sourceTag, gradientSources.contains(source),
        let elevation = end.thresholdElevation,
        let reciprocal = reciprocals.first(where: { $0.sourceTag == source }),
        let reciprocalElevation = reciprocal.thresholdElevation
      else { continue }
      let gradient = (reciprocalElevation - elevation) / distance
      guard abs(gradient) <= maxGradient else { continue }
      return Float(gradient)
    }
    return nil
  }

  /// Whether a declared distance can be right for a runway of the given length.
  private static func isPlausible(_ distance: Double, length: Double?, maxShareOfLength: Double)
    -> Bool
  {
    guard distance > 0 else { return false }
    guard let length, length > 0 else { return true }
    let isLengthInWrongUnit = abs(distance / metersPerFoot - length) <= length * unitErrorTolerance
    return distance <= length * maxShareOfLength && !isLengthInWrongUnit
  }

  /// Builds the airport record.
  func build(_ resolved: ResolvedAirport) -> AirportDataCodable.AirportCodable? {
    if let NASR = resolved.NASR { return buildNASR(NASR, resolved: resolved) }
    return buildFromSources(resolved)
  }

  private func buildNASR(
    _ airport: AirportDataCodable.AirportCodable,
    resolved: ResolvedAirport
  ) -> AirportDataCodable.AirportCodable {
    AirportDataCodable.AirportCodable(
      recordID: resolved.key,
      locationID: airport.locationID,
      ICAO_ID: airport.ICAO_ID,
      name: airport.name,
      city: airport.city,
      dataSource: AirportDataSource.NASR.rawValue,
      latitude: airport.latitude,
      longitude: airport.longitude,
      elevation: airport.elevation,
      variation: airport.variation,
      timeZone: airport.timeZone,
      runways: airport.runways,
      procedures: airport.procedures,
      aliases: resolved.aliases,
      sources: [.NASR],
      countryCode: resolved.records.lazy.compactMap(\.identifiers.countryCode).first ?? "US"
    )
  }

  private func buildFromSources(_ resolved: ResolvedAirport) -> AirportDataCodable.AirportCodable? {
    let records = resolved.records
    guard let layout = records.first(where: \.describesRunways) else { return nil }

    let runways = layout.runwayEnds.map { end in
      runway(end, layout: layout, records: records)
    }
    guard !runways.isEmpty else { return nil }

    let ourAirports = records.first { $0.source == .ourAirports }
    let elevation = records.lazy.compactMap(\.elevation).first ?? 0

    return AirportDataCodable.AirportCodable(
      recordID: resolved.key,
      locationID: records.lazy.compactMap(\.locationID).first ?? resolved.key,
      ICAO_ID: records.lazy.compactMap(\.identifiers.ICAO).first,
      name: ourAirports?.name ?? records.lazy.compactMap(\.name).first ?? resolved.key,
      city: ourAirports?.city ?? records.lazy.compactMap(\.city).first,
      dataSource: AirportDataSource.ourAirports.rawValue,
      latitude: layout.latitude,
      longitude: layout.longitude,
      elevation: elevation,
      variation: GeoCalculations.calculateMagneticVariation(layout.latitude, layout.longitude),
      timeZone: timeZone(layout.latitude, layout.longitude),
      runways: runways,
      procedures: nil,
      aliases: resolved.aliases,
      sources: records.map(\.source),
      countryCode: records.lazy.compactMap(\.identifiers.countryCode).first
    )
  }

  // MARK: - Runways

  private func runway(
    _ layoutEnd: SourceRunwayEnd,
    layout: SourceAirport,
    records: [SourceAirport]
  ) -> AirportDataCodable.RunwayCodable {
    let ends = matchingEnds(layoutEnd, records: records)
    let reciprocalLayoutEnd = layoutEnd.reciprocalName.flatMap { name in
      layout.runwayEnds.first { $0.normalizedName == RunwayDesignator.normalize(name) }
    }
    let reciprocalEnds = reciprocalLayoutEnd.map { matchingEnds($0, records: records) } ?? []

    func first<T>(_ value: (SourceRunwayEnd) -> T?) -> T? {
      ends.lazy.compactMap(value).first
    }

    let threshold = ends.first { $0.thresholdLatitude != nil && $0.thresholdLongitude != nil }
    let reciprocalThreshold = reciprocalEnds.first {
      $0.thresholdLatitude != nil && $0.thresholdLongitude != nil
    }
    let length = first(\.length)
    let thresholdSeparation = threshold.flatMap { threshold in
      reciprocalThreshold.map { reciprocal in
        AirportResolver.distanceM(
          (threshold.thresholdLatitude ?? 0, threshold.thresholdLongitude ?? 0),
          (reciprocal.thresholdLatitude ?? 0, reciprocal.thresholdLongitude ?? 0)
        )
      }
    }
    func declared(_ value: (SourceRunwayEnd) -> Double?, maxShareOfLength: Double) -> Double? {
      ends.lazy.compactMap(value).first {
        Self.isPlausible($0, length: length, maxShareOfLength: maxShareOfLength)
      }
    }

    let displacedThreshold = first(\.displacedThresholdDistance)
    let takeoffRun =
      declared(\.takeoffRun, maxShareOfLength: Self.maxRunDistanceShareOfLength)
      ?? length.map { $0 - (displacedThreshold ?? 0) }

    return AirportDataCodable.RunwayCodable(
      name: layoutEnd.name,
      elevation: first(\.thresholdElevation),
      trueHeading: first(\.trueHeading) ?? RunwayHeading.fromDesignator(layoutEnd.name),
      gradient: Self.gradient(
        ends,
        reciprocals: reciprocalEnds,
        distance: thresholdSeparation ?? length
      ),
      length: length ?? 0,
      takeoffRun: takeoffRun.flatMap { $0 > 0 ? $0 : nil },
      takeoffDistance: declared(
        \.takeoffDistance,
        maxShareOfLength: Self.maxTakeoffDistanceShareOfLength
      ),
      landingDistance: declared(
        \.landingDistance,
        maxShareOfLength: Self.maxRunDistanceShareOfLength
      ),
      surfaceType: (first(\.surface) ?? .turf).rawValue,
      reciprocalName: layoutEnd.reciprocalName,
      thresholdLatitude: threshold?.thresholdLatitude,
      thresholdLongitude: threshold?.thresholdLongitude,
      width: first(\.width),
      thresholdCrossingHeight: first(\.thresholdCrossingHeight),
      glidepathAngle: first(\.glidepathAngle),
      displacedThresholdDistance: displacedThreshold.flatMap { $0 > 0 ? $0 : nil }
    )
  }

  /// The runway end each record describes that matches the layout's end, highest
  /// precedence first.
  private func matchingEnds(
    _ layoutEnd: SourceRunwayEnd,
    records: [SourceAirport]
  ) -> [SourceRunwayEnd] {
    records.compactMap { record in
      let ends = record.runwayEnds.map { $0.tagged(record.source) }
      return ends.first { $0.normalizedName == layoutEnd.normalizedName }
        ?? ends.first { isSameEnd(layoutEnd, $0) }
    }
  }

  /// Whether two differently named runway ends are the same end: on the same heading,
  /// with the same parallel-runway suffix, and with thresholds close together when both
  /// are known.
  private func isSameEnd(_ lhs: SourceRunwayEnd, _ rhs: SourceRunwayEnd) -> Bool {
    guard let heading = lhs.trueHeading, let otherHeading = rhs.trueHeading,
      Headings.difference(heading, otherHeading) <= AirportResolver.maxRunwayHeadingDifferenceDeg,
      Self.parallelSuffix(lhs.normalizedName) == Self.parallelSuffix(rhs.normalizedName)
    else { return false }

    guard let latitude = lhs.thresholdLatitude, let longitude = lhs.thresholdLongitude,
      let otherLatitude = rhs.thresholdLatitude, let otherLongitude = rhs.thresholdLongitude
    else { return true }
    return AirportResolver.distanceM((latitude, longitude), (otherLatitude, otherLongitude))
      <= Self.maxThresholdSeparationM
  }
}

/// Runway headings implied by designators.
enum RunwayHeading {
  private static let degreesPerDesignatorUnit = 10.0

  /// The approximate heading a designator implies: runway `09L` faces 090°.
  static func fromDesignator(_ designator: String) -> Double {
    let digits = designator.prefix(2).filter(\.isNumber)
    return (Double(digits) ?? 0) * degreesPerDesignatorUnit
  }
}

extension AirportDataCodable.AirportCodable {
  /// This airport with the given procedures.
  func with(procedures: [AirportDataCodable.ProcedureCodable]?) -> Self {
    Self(
      recordID: recordID,
      locationID: locationID,
      ICAO_ID: ICAO_ID,
      name: name,
      city: city,
      dataSource: dataSource,
      latitude: latitude,
      longitude: longitude,
      elevation: elevation,
      variation: variation,
      timeZone: timeZone,
      runways: runways,
      procedures: procedures,
      aliases: aliases,
      sources: sources,
      countryCode: countryCode
    )
  }
}
