// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let approachableConcurrency: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances")
]

let package = Package(
  name: "NavDataDistribution",
  defaultLocalization: "en",
  platforms: [.macOS(.v26)],
  products: [
    .executable(
      name: "nav-data-generator",
      targets: ["nav-data-generator"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/SF50-TOLD/NavData", from: "1.0.0"),
    .package(url: "https://github.com/RISCfuture/SwiftNASR", from: "4.0.0"),
    .package(url: "https://github.com/RISCfuture/SwiftCIFP", from: "1.1.0"),
    .package(url: "https://github.com/RISCfuture/SwiftDOF", from: "1.1.0"),
    .package(url: "https://github.com/patrick-zippenfenig/SwiftTimeZoneLookup", from: "1.0.8"),
    .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.20"),
    .package(url: "https://github.com/RISCfuture/StreamingLZMA", from: "1.3.0"),
    .package(url: "https://github.com/RISCfuture/StreamingCSV", from: "2.1.0"),
    .package(url: "https://github.com/apple/swift-log", from: "1.14.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2")
  ],
  targets: [
    .executableTarget(
      name: "nav-data-generator",
      dependencies: [
        .product(name: "NavData", package: "NavData"),
        .product(name: "SwiftNASR", package: "SwiftNASR"),
        .product(name: "SwiftCIFP", package: "SwiftCIFP"),
        .product(name: "SwiftDOF", package: "SwiftDOF"),
        .product(name: "SwiftTimeZoneLookup", package: "SwiftTimeZoneLookup"),
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        .product(name: "StreamingLZMAXZ", package: "StreamingLZMA"),
        .product(name: "StreamingCSV", package: "StreamingCSV"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      swiftSettings: approachableConcurrency
    )
  ],
  swiftLanguageModes: [.v6]
)
