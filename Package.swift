// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let upcomingFeatures: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault")
]

let package = Package(
  name: "NavDataDistribution",
  defaultLocalization: "en",
  platforms: [.macOS(.v27)],
  products: [
    .executable(
      name: "nav-data-generator",
      targets: ["nav-data-generator"]
    ),
    .library(
      name: "NavDataGeneration",
      targets: ["NavDataGeneration"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/SF50-TOLD/NavData", branch: "main"),
    .package(url: "https://github.com/RISCfuture/SwiftNASR", branch: "main"),
    .package(url: "https://github.com/RISCfuture/SwiftCIFP", branch: "main"),
    .package(url: "https://github.com/RISCfuture/SwiftDOF", branch: "main"),
    .package(url: "https://github.com/patrick-zippenfenig/SwiftTimeZoneLookup", from: "1.0.8"),
    .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.20"),
    .package(url: "https://github.com/RISCfuture/StreamingLZMA", branch: "main"),
    .package(url: "https://github.com/RISCfuture/StreamingCSV", branch: "main"),
    .package(url: "https://github.com/apple/swift-log", from: "1.15.1"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.5.0")
  ],
  targets: [
    .target(
      name: "NavDataGeneration",
      dependencies: [
        .product(name: "NavData", package: "NavData"),
        .product(name: "SwiftNASR", package: "SwiftNASR"),
        .product(name: "SwiftCIFP", package: "SwiftCIFP"),
        .product(name: "SwiftDOF", package: "SwiftDOF"),
        .product(name: "SwiftTimeZoneLookup", package: "SwiftTimeZoneLookup"),
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        .product(name: "StreamingLZMAXZ", package: "StreamingLZMA"),
        .product(name: "StreamingCSV", package: "StreamingCSV"),
        .product(name: "Logging", package: "swift-log")
      ],
      swiftSettings: upcomingFeatures
    ),
    .executableTarget(
      name: "nav-data-generator",
      dependencies: [
        "NavDataGeneration",
        .product(name: "SwiftNASR", package: "SwiftNASR"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      swiftSettings: upcomingFeatures
    ),
    .testTarget(
      name: "NavDataGenerationTests",
      dependencies: [
        "NavDataGeneration",
        .product(name: "SwiftCIFP", package: "SwiftCIFP"),
        .product(name: "SwiftNASR", package: "SwiftNASR")
      ],
      swiftSettings: upcomingFeatures
    )
  ],
  swiftLanguageModes: [.v6]
)
