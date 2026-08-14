// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "vibecheck",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "vibecheck", targets: ["vibecheck"]),
  ],
  dependencies: [
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.2.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.1.1"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.3.1"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.31.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
  ],
  targets: [
    .target(
      name: "VCKStubs",
      dependencies: [
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ],
      path: "Sources/VCKStubs"
    ),
    .target(
      name: "VCPluginSDK",
      dependencies: [
        "VCKStubs",
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
      ],
      path: "Sources/VCPluginSDK"
    ),
    .target(
      name: "VibeCheckKit",
      dependencies: ["VCPluginSDK"],
      path: "Sources/VibeCheckKit"
    ),
    .executableTarget(
      name: "vibecheck",
      dependencies: ["VCPluginSDK", "VibeCheckKit"],
      path: "Sources/vibecheck",
      resources: [.copy("ui")]
    ),
    .testTarget(name: "VCPluginSDKTests", dependencies: ["VCPluginSDK"], path: "Tests/VCPluginSDKTests"),
    .testTarget(name: "VibeCheckKitTests", dependencies: ["VibeCheckKit"], path: "Tests/VibeCheckKitTests"),
  ]
)
