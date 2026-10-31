/// The namespaced identifiers airports are keyed and aliased by.
///
/// An airport's key is its most authoritative identifier, in this order: FAA site number,
/// official ICAO location indicator, national code, OurAirports id, open flightmaps code.
/// Each is assigned by an authority and persists across data cycles, so a key changes only
/// when an airport gains a more authoritative identifier.
enum AirportKey {
  private static let ICAOIndicatorLength = 4

  static func FAA(siteNumber: String) -> String { "FAA:\(siteNumber)" }
  static func ICAO(_ indicator: String) -> String { "ICAO:\(indicator)" }
  static func national(country: String, code: String) -> String { "LOC:\(country):\(code)" }
  static func ourAirports(_ id: String) -> String { "OA:\(id)" }
  static func openFlightmaps(region: String, code: String) -> String { "OFM:\(region):\(code)" }

  /// The code, if it has the shape of an ICAO location indicator.
  static func ICAOIndicator(_ code: String?) -> String? {
    guard let code, code.count == ICAOIndicatorLength,
      code.allSatisfy({ $0.isASCII && $0.isUppercase })
    else { return nil }
    return code
  }

  /// The keys for a source record's identifiers, most authoritative first.
  static func keys(for identifiers: SourceAirport.Identifiers) -> [String] {
    var keys = [String]()
    if let ICAO = identifiers.ICAO { keys.append(Self.ICAO(ICAO)) }
    if let country = identifiers.countryCode, let code = identifiers.national {
      keys.append(national(country: country, code: code))
    }
    if let id = identifiers.ourAirports { keys.append(ourAirports(id)) }
    if let code = identifiers.openFlightmaps {
      keys.append(openFlightmaps(region: code.region, code: code.code))
    }
    return keys
  }
}

/// Runway designator handling shared by every source.
enum RunwayDesignator {

  /// Normalizes a runway end designator so different sources' spellings compare equal:
  /// leading zeros are restored (`9` becomes `09`), and spaces dropped.
  static func normalize(_ designator: String) -> String {
    let trimmed = designator.uppercased().filter { !$0.isWhitespace }
    let digits = trimmed.prefix(while: \.isNumber)
    guard digits.count == 1 else { return trimmed }
    return "0" + trimmed
  }

  /// The two end designators of a runway designator such as `"08/26"` or `"15 / 33"`.
  static func ends(of runwayDesignator: String) -> [String] {
    runwayDesignator.split(separator: "/").map { normalize(String($0)) }
  }
}
