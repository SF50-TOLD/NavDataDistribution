import NavData

/// An airport as one source describes it, before records from different sources are
/// resolved into a single airport.
///
/// Values are in SI units (meters, decimal degrees) and every field a source might lack
/// is optional, so loaders for very different formats can share one shape.
struct SourceAirport: Sendable {

  /// The source the record comes from.
  let source: AirportDataSource

  /// The record's identifier within its source: an OurAirports id, an open flightmaps
  /// aerodrome code, or an AIXM UUID.
  let sourceID: String

  /// The airport's identifiers, used to match records across sources and to key the result.
  let identifiers: Identifiers

  /// The identifier the source shows for the airport.
  let locationID: String?

  /// The airport's name.
  let name: String?

  /// The city the airport serves.
  let city: String?

  /// The airport reference point, in decimal degrees.
  let latitude: Double
  let longitude: Double

  /// Field elevation in meters.
  let elevation: Double?

  /// The runway ends the source describes.
  let runwayEnds: [SourceRunwayEnd]

  /// Whether the record describes the airport's runway layout, rather than only adding
  /// detail to runway ends another source describes.
  let describesRunways: Bool

  /// The identifiers one source gives an airport.
  struct Identifiers: Sendable {

    /// The official ICAO location indicator, if the airport has one.
    var ICAO: String?

    /// A national location identifier: the FAA identifier in the US, or another country's
    /// own code for airports without an ICAO indicator.
    var national: String?

    /// The ISO 3166-1 alpha-2 country code.
    var countryCode: String?

    /// The OurAirports id.
    var ourAirports: String?

    /// The open flightmaps region and aerodrome code.
    var openFlightmaps: OpenFlightmapsCode?
  }

  /// An aerodrome code within an open flightmaps region.
  struct OpenFlightmapsCode: Sendable, Hashable {
    let region: String
    let code: String
  }
}

/// One runway end as one source describes it.
struct SourceRunwayEnd: Sendable {

  /// The runway end's designator as the source writes it.
  let name: String

  /// The opposite end's designator.
  let reciprocalName: String?

  /// True heading in degrees.
  let trueHeading: Double?

  /// Runway length and width in meters.
  let length: Double?
  let width: Double?

  /// The runway surface.
  let surface: SurfaceType?

  /// The physical (not displaced) threshold, in decimal degrees.
  let thresholdLatitude: Double?
  let thresholdLongitude: Double?

  /// Threshold elevation in meters.
  let thresholdElevation: Double?

  /// The distance the landing threshold is displaced, in meters.
  let displacedThresholdDistance: Double?

  /// Declared distances in meters.
  let takeoffRun: Double?
  let takeoffDistance: Double?
  let landingDistance: Double?

  /// Threshold crossing height in meters.
  let thresholdCrossingHeight: Double?

  /// Glide path angle in degrees.
  let glidepathAngle: Double?

  /// The source the end was read from, once it is compared against other sources' ends.
  private(set) var sourceTag: AirportDataSource?

  /// The designator, normalized so different sources' spellings compare equal.
  var normalizedName: String { RunwayDesignator.normalize(name) }

  init(
    name: String,
    reciprocalName: String? = nil,
    trueHeading: Double? = nil,
    length: Double? = nil,
    width: Double? = nil,
    surface: SurfaceType? = nil,
    thresholdLatitude: Double? = nil,
    thresholdLongitude: Double? = nil,
    thresholdElevation: Double? = nil,
    displacedThresholdDistance: Double? = nil,
    takeoffRun: Double? = nil,
    takeoffDistance: Double? = nil,
    landingDistance: Double? = nil,
    thresholdCrossingHeight: Double? = nil,
    glidepathAngle: Double? = nil
  ) {
    self.name = name
    self.reciprocalName = reciprocalName
    self.trueHeading = trueHeading
    self.length = length
    self.width = width
    self.surface = surface
    self.thresholdLatitude = thresholdLatitude
    self.thresholdLongitude = thresholdLongitude
    self.thresholdElevation = thresholdElevation
    self.displacedThresholdDistance = displacedThresholdDistance
    self.takeoffRun = takeoffRun
    self.takeoffDistance = takeoffDistance
    self.landingDistance = landingDistance
    self.thresholdCrossingHeight = thresholdCrossingHeight
    self.glidepathAngle = glidepathAngle
  }

  /// This end, marked as read from the given source.
  func tagged(_ source: AirportDataSource) -> Self {
    var tagged = self
    tagged.sourceTag = source
    return tagged
  }
}
