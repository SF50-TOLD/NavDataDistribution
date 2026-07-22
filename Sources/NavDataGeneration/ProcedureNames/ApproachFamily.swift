import SwiftCIFP

/// The kind of navigation aid an instrument approach is built on.
///
/// Matching a CIFP approach to its published chart requires a vocabulary both
/// sides can express. CIFP encodes the family as a single leading character of
/// the procedure identifier; charts spell it out in the title. ``ApproachFamily``
/// is that shared vocabulary.
enum ApproachFamily: Hashable, Sendable {
  case ils
  case localizer
  case localizerBackcourse
  case rnav
  case rnp
  case gls
  case gps
  case vor
  case vorDME

  /// A VOR approach that requires DME (CIFP type `S`).
  ///
  /// The FAA charts these as plain `VOR`, `VOR/DME`, or `VOR OR TACAN`, so this
  /// family is satisfied by any charted VOR approach.
  case vorRequiringDME

  case tacan
  case ndb
  case ndbDME
  case lda
  case sdf
  case mls
  case fms
  case igs

  /// The family a CIFP approach type belongs to.
  /// - Parameter approachType: The CIFP approach type.
  /// - Returns: `nil` for record types that are not approaches in their own
  ///   right — transitions and missed approaches.
  init?(approachType: ApproachType) {
    switch approachType {
      case .ils: self = .ils
      case .localizerOnly: self = .localizer
      case .localizerBackcourse: self = .localizerBackcourse
      case .rnav: self = .rnav
      case .rnpAR: self = .rnp
      case .gls: self = .gls
      case .gps: self = .gps
      case .vor: self = .vor
      case .vorDME: self = .vorDME
      case .vorTAC: self = .vorRequiringDME
      case .tacan: self = .tacan
      case .ndb: self = .ndb
      case .ndbDME: self = .ndbDME
      case .lda: self = .lda
      case .sdf: self = .sdf
      case .igs: self = .igs
      case .fms: self = .fms
      case .mls, .mlsTypeA, .mlsTypeBC: self = .mls
      case .transition, .missedApproach: return nil
    }
  }
}
