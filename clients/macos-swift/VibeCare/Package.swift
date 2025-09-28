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
        )
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.1.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.1.1"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.1.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "VCStubs",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "VCStubs"
        ),
        .executableTarget(
            name: "VibeCare",
            dependencies: [
                "VCStubs",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "vibecare",
        )
    ]
)
