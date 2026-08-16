// swift-tools-version: 6.0
import PackageDescription

// VCPluginSDK and its generated VCKStubs used to be targets of this package.
// They now live in sdk/swift/VCPluginSDK/ and are shared by every Swift
// plugin — see sdk/swift/README.md. This package therefore declares NO
// grpc-swift / swift-nio / swift-protobuf requirement of its own: those are
// declared once in the SDK and inherited, which is what keeps a second,
// disagreeing Package.resolved from appearing.
let package = Package(
  name: "vibecheck",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "vibecheck", targets: ["vibecheck"]),
  ],
  dependencies: [
    .package(path: "../../sdk/swift/VCPluginSDK"),
  ],
  targets: [
    .target(
      name: "VibeCheckKit",
      dependencies: [
        .product(name: "VCPluginSDK", package: "VCPluginSDK"),
      ],
      path: "Sources/VibeCheckKit"
    ),
    .executableTarget(
      name: "vibecheck",
      dependencies: [
        .product(name: "VCPluginSDK", package: "VCPluginSDK"),
        "VibeCheckKit",
      ],
      path: "Sources/vibecheck",
      resources: [.copy("ui")]
    ),
    .testTarget(name: "VibeCheckKitTests", dependencies: ["VibeCheckKit"], path: "Tests/VibeCheckKitTests"),
  ]
)
