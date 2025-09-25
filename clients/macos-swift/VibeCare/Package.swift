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
        .executable(
            name: "TestGRPC",
            targets: ["TestGRPC"]
        ),
        .library(
            name: "VibeCareCore",
            targets: ["VibeCareCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.1.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.1.1"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.1.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "VibeCareCore",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "vibecare",
            exclude: [
                "vibecare.entitlements",
                "Assets.xcassets",
                "TestGRPCMain.swift",
                "App.swift",
                "ContentView.swift"
            ]
        ),
        .executableTarget(
            name: "VibeCare",
            dependencies: ["VibeCareCore"],
            path: "vibecare",
            sources: [
                "App.swift",
                "ContentView.swift"
            ]
        ),
        .executableTarget(
            name: "TestGRPC",
            dependencies: ["VibeCareCore"],
            path: "vibecare",
            sources: [
                "TestGRPCMain.swift"
            ]
        ),
        .testTarget(
            name: "VibeCareTests",
            dependencies: ["VibeCare"],
            path: "vibecareTests"
        )
    ]
)
