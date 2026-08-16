// swift-tools-version: 6.0
import PackageDescription

// The blink-jump plugin — the thinnest consumer of the vision provider
// (docs/superpowers/specs/2026-08-15-vision-provider-design.md §4.4: "day one,
// blink-jump is ~50 lines against vision.signals.v1"). It never opens a
// camera, which is why this package has no Info.plist, no -sectcreate and no
// codesign step in its build recipe.
//
// §9 gates this plugin on a measurement, not a guess: a game has a 16 ms frame
// budget and nothing in-tree has measured publish → deliver over the unix
// socket at 60 fps. If the bus does not clear the budget, this plugin's design
// changes — vision's does not.
//
// No grpc-swift / swift-nio / swift-protobuf requirement here on purpose: the
// SDK declares those once (sdk/swift/README.md) and this package inherits
// them, which is what keeps a second, disagreeing Package.resolved from
// appearing in this tree.
let package = Package(
  name: "blink-jump",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "blink-jump", targets: ["blink-jump"]),
  ],
  dependencies: [
    .package(path: "../../sdk/swift/VCPluginSDK"),
  ],
  targets: [
    // The product logic: turn ear_l/ear_r into "blinked", and blinks into
    // game state. §2's rule cuts the other way here — `is_blinking` is a
    // judgement, so the threshold lives in this plugin and must never be
    // asked of vision.
    .target(
      name: "BlinkJumpKit",
      dependencies: [
        .product(name: "VCPluginSDK", package: "VCPluginSDK"),
        .product(name: "VCKStubs", package: "VCPluginSDK"),
      ],
      path: "Sources/BlinkJumpKit"
    ),
    // The composition root. Routes before connect, then park in
    // waitForShutdown() forever — never exit().
    //
    // The target name carries a hyphen so the built binary matches the plugin
    // id (`exec: ./dist/blink-jump`); SwiftPM sanitises the *module* name to
    // blink_jump, which nothing imports.
    .executableTarget(
      name: "blink-jump",
      dependencies: [
        "BlinkJumpKit",
        .product(name: "VCPluginSDK", package: "VCPluginSDK"),
      ],
      path: "Sources/blink-jump",
      // Ships as a .bundle NEXT TO the binary — see
      // `just build-blink-jump-plugin`, which stages both into dist/.
      resources: [.copy("ui")]
    ),
    .testTarget(name: "BlinkJumpKitTests", dependencies: ["BlinkJumpKit"], path: "Tests/BlinkJumpKitTests"),
  ]
)
