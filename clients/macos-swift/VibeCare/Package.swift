// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "VibeCare",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(
      name: "VibeCare",
      targets: ["VibeCare"]
    ),
    .library(
      name: "VCStubs",
      targets: ["VCStubs"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.1.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.1.1"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.1.1"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    // Main package (contains OTLP gRPC exporter)
    .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", from: "2.2.0"),
    // Core package (contains OpenTelemetryApi and OpenTelemetrySdk)
    .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", from: "2.2.0"),
    // customized notification
    .package(url: "https://github.com/vibecare-io/vibe-notify-macos.git", from: "0.0.7"),
  ],
  targets: [
    .target(
      name: "VCStubs",
      dependencies: [
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ],
      path: "VCStubs"
    ),
    .executableTarget(
      name: "VibeCare",
      dependencies: [
        "VCStubs",
        .product(name: "Logging", package: "swift-log"),
        // Products OpenTelemetryApi and OpenTelemetrySdk are from the core package
        .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
        // The OTLP exporter is from the main package
        .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
        // Custom notification library
        .product(name: "VibeNotify", package: "vibe-notify-macos"),
      ],
      path: "vibecare",
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "vibecareTests",
      // VCStubs so a test can build a real `VCKAlert` and drive
      // `PluginAlert(proto:)` — the one place wire presence
      // (`hasAppearance`) is turned into the model's `String?`, which no
      // test using the in-memory initializer can reach.
      dependencies: ["VibeCare", "VCStubs"],
      path: "vibecareTests",
      // Scoped to the SwiftPM-buildable subset. The rest of vibecareTests/
      // uses `@testable import vibecare` (lowercase) to match the Xcode
      // project's app target (PRODUCT_MODULE_NAME=vibecare, a separate
      // build system from this package's `VibeCare` target) and is
      // exercised there, not via `swift test`. `swift test` previously
      // reported "no tests found" — there was no testTarget at all.
      sources: [
        "PluginRosterTests.swift",
        "PluginAlertAppearanceTests.swift",
        "PluginAlertPresentationTests.swift",
        "PluginInterruptPolicyTests.swift"
      ]
    ),
  ]
)
