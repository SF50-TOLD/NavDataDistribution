import ArgumentParser
import Foundation
import Logging
import SwiftNASR

/// Errors that can occur while resolving the requested cycle from the command line.
enum NavDataGeneratorError: LocalizedError {
  case couldNotDetermineNextCycle
  case invalidCycleFormat(String)

  var errorDescription: String? {
    String(localized: "Couldn’t determine the requested NASR cycle.")
  }

  var failureReason: String? {
    switch self {
      case .couldNotDetermineNextCycle:
        String(localized: "Could not determine the next NASR cycle after the effective one.")
      case .invalidCycleFormat(let value):
        String(
          localized: "Invalid cycle format “\(value)”. Use “current”, “next”, or “YYYY-MM-DD”."
        )
    }
  }
}

/// Generates the compressed SF50 TOLD navigation database for a given NASR cycle.
///
/// Downloads and merges FAA NASR, OurAirports, CIFP, and DOF data, then writes the
/// combined result as an XZ/LZMA-compressed binary property list suitable for
/// distribution to the app.
@main
struct NavDataGenerator: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "nav-data-generator",
    abstract: "Generates the compressed SF50 TOLD navigation database for a given NASR cycle."
  )

  @Option(
    name: .long,
    help: "The NASR cycle to generate: \"current\", \"next\", or a specific date (YYYY-MM-DD)."
  )
  var cycle = "current"

  @Option(
    name: .long,
    help: "Directory to write the generated data files to."
  )
  var output = FileManager.default.currentDirectoryPath

  @Flag(
    name: .long,
    help: "Print the resolved cycle identifier and exit without running the pipeline."
  )
  var printCycle = false

  // MARK: - Type Methods

  /// Resolves a `--cycle` argument into a concrete ``SwiftNASR/Cycle``.
  private static func resolveCycle(_ cycleString: String) throws -> Cycle {
    switch cycleString.lowercased() {
      case "current":
        return .effective
      case "next":
        guard let nextCycle = Cycle.effective.next else {
          throw NavDataGeneratorError.couldNotDetermineNextCycle
        }
        return nextCycle
      default:
        let parts = cycleString.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
          let year = UInt(exactly: parts[0]),
          let month = UInt8(exactly: parts[1]),
          let day = UInt8(exactly: parts[2])
        else {
          throw NavDataGeneratorError.invalidCycleFormat(cycleString)
        }
        return Cycle(year: year, month: month, day: day)
    }
  }

  // MARK: - Instance Methods

  func run() async throws {
    LoggingSystem.bootstrap { label in
      var handler = StreamLogHandler.standardOutput(label: label)
      handler.logLevel = .notice
      return handler
    }
    let logger = Logger(label: "codes.tim.nav-data-generator")

    let resolvedCycle = try Self.resolveCycle(cycle)

    if printCycle {
      print("\(resolvedCycle)")
      return
    }

    let outputURL = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

    logger.notice("Generating nav data for cycle \(resolvedCycle) to \(outputURL.path)…")

    var processor = NavDataProcessor(
      cycle: resolvedCycle,
      outputLocation: outputURL,
      logger: logger
    )
    processor.onProgress = { completed, description in
      logger.info("Progress: \(completed)/100 - \(description)")
    }

    try await processor.process()
    logger.notice("Processing complete. Output saved to: \(outputURL.path)")
  }
}
