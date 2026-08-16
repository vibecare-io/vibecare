// swift-tools-version: 6.0
import PackageDescription

// The vision provider plugin — the one process that owns the camera and
// publishes what it sees as bus topics
// (docs/superpowers/specs/2026-08-15-vision-provider-design.md).
//
// Every target is declared up front, including ones whose sources are still
// placeholders, so that the people filling in §4/§5/§6/§7 never have to touch
// this file and never race each other in it. Add a source file to the right
// directory and it compiles.
//
// No grpc-swift / swift-nio / swift-protobuf requirement here on purpose: the
// SDK declares those once (sdk/swift/README.md) and this package inherits
// them, which is what keeps a second, disagreeing Package.resolved from
// appearing in this tree.
let package = Package(
  name: "vision",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "vision", targets: ["vision"]),
  ],
  dependencies: [
    .package(path: "../../sdk/swift/VCPluginSDK"),
  ],
  targets: [
    // §4.2 — the signals tier. Pure math over landmarks: EAR, yaw/pitch/roll,
    // shoulder angle, fingertip distances, plus §4.3's ViewerSpace mapping.
    // Deliberately NOT a shipped package for consumers to link.
    .target(
      name: "VCGeometry",
      dependencies: [
        .product(name: "VCKStubs", package: "VCPluginSDK"),
      ],
      path: "Sources/VCGeometry"
    ),
    // §6 — capture and inference: AVCaptureSession, the four VNRequests
    // constructed lazily per live demand, JPEG/preview encoding, and the
    // per-topic rate gate.
    .target(
      name: "VisionKit",
      dependencies: [
        .product(name: "VCPluginSDK", package: "VCPluginSDK"),
        .product(name: "VCKStubs", package: "VCPluginSDK"),
        "VCGeometry",
      ],
      path: "Sources/VisionKit"
    ),
    // §7 — the HTTP surface: GET /, /api/state (the privacy readout, which is
    // load-bearing per §5.3), /preview.mjpeg, and the UI assets.
    .target(
      name: "VisionAPI",
      dependencies: [
        .product(name: "VCPluginSDK", package: "VCPluginSDK"),
        "VisionKit",
      ],
      path: "Sources/VisionAPI",
      // Ships as vision_VisionAPI.bundle NEXT TO the binary — see
      // `just build-vision-plugin`, which stages both into dist/.
      resources: [.copy("ui")]
    ),
    // The composition root. Routes before connect, then park in
    // waitForShutdown() forever — never exit().
    .executableTarget(
      name: "vision",
      dependencies: [
        "VisionKit",
        "VisionAPI",
        .product(name: "VCPluginSDK", package: "VCPluginSDK"),
      ],
      path: "Sources/vision"
    ),
    .testTarget(name: "VCGeometryTests", dependencies: ["VCGeometry"], path: "Tests/VCGeometryTests"),
    .testTarget(name: "VisionKitTests", dependencies: ["VisionKit"], path: "Tests/VisionKitTests"),
    .testTarget(name: "VisionAPITests", dependencies: ["VisionAPI"], path: "Tests/VisionAPITests"),
  ]
)
