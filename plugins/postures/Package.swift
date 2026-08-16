// swift-tools-version: 6.0
import PackageDescription

// The postures plugin — a *consumer* of the vision provider
// (docs/superpowers/specs/2026-08-15-vision-provider-design.md §1). It reads
// vision.body_pose.v1 and vision.signals.v1 off the bus and decides what
// "slouching" means; it never opens a camera, which is why this package has
// no Info.plist, no -sectcreate and no codesign step in its build recipe.
//
// No grpc-swift / swift-nio / swift-protobuf requirement here on purpose: the
// SDK declares those once (sdk/swift/README.md) and this package inherits
// them, which is what keeps a second, disagreeing Package.resolved from
// appearing in this tree.
let package = Package(
  name: "postures",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "postures", targets: ["postures"]),
  ],
  dependencies: [
    .package(path: "../../sdk/swift/VCPluginSDK"),
  ],
  targets: [
    // The product logic: decode VCT frames, hold the "how long has this been
    // true" state, decide when a nudge is earned. §2's rule cuts the other
    // way here — `is_slouching` is a judgement, so it belongs in this plugin
    // and must never be asked of vision.
    .target(
      name: "PosturesKit",
      dependencies: [
        .product(name: "VCPluginSDK", package: "VCPluginSDK"),
        .product(name: "VCKStubs", package: "VCPluginSDK"),
      ],
      path: "Sources/PosturesKit"
    ),
    // The composition root. Routes before connect, then park in
    // waitForShutdown() forever — never exit().
    .executableTarget(
      name: "postures",
      dependencies: [
        "PosturesKit",
        .product(name: "VCPluginSDK", package: "VCPluginSDK"),
      ],
      path: "Sources/postures",
      // Ships as postures_postures.bundle NEXT TO the binary — see
      // `just build-postures-plugin`, which stages both into dist/.
      resources: [.copy("ui")]
    ),
    .testTarget(name: "PosturesKitTests", dependencies: ["PosturesKit"], path: "Tests/PosturesKitTests"),
  ]
)
