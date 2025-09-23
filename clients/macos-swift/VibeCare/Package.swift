// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VibeCare",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "VibeCare",
            targets: ["VibeCare"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.19.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "VibeCare",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "vibecare",
            exclude: [
                "vibecare.entitlements",
                "Assets.xcassets"
            ],
            sources: [
                "ContentView.swift",
                "vibecareApp.swift",
                "Models/",
                "ViewModels/",
                "Views/",
                "Services/",
                "Generated/",
                "Resources/"
            ]
        ),
        .testTarget(
            name: "VibeCareTests",
            dependencies: ["VibeCare"],
            path: "vibecareTests"
        )
    ]
)
