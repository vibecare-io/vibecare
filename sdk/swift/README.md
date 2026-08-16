# Swift plugin SDK

`VCPluginSDK/` is the Swift half of the plugin SDK — the counterpart to Go's
`backend/pkg/vc`. It is **shared by every Swift plugin in this repo**
(`plugins/vision`, `plugins/vibecheck`, `plugins/postures`,
`plugins/blink-jump`), each of which takes a local path dependency:

```swift
dependencies: [
  .package(path: "../../sdk/swift/VCPluginSDK"),
],
targets: [
  .target(name: "MyKit", dependencies: [
    .product(name: "VCPluginSDK", package: "VCPluginSDK"),
    .product(name: "VCKStubs", package: "VCPluginSDK"),
  ]),
]
```

It used to live under `plugins/vibecheck/Sources/VCPluginSDK/`. It was lifted
out when a second Swift plugin appeared, because a copied SDK is exactly how
the two disagreeing `Package.resolved` files already in this tree came to
exist. **Do not vendor a second copy**, and do not add grpc-swift, swift-nio
or swift-protobuf to a plugin's own `dependencies` — this package declares
those versions once and consumers inherit them.

Two products:

| Product | What it is |
|---|---|
| `VCPluginSDK` | `VCHost.connect()`, the router, the HTTP server, the reconnect ladder, `VCEnvironment`, alert types |
| `VCKStubs` | the **generated** protobuf/gRPC types |

## VCKStubs is generated — never hand-edit it

`Sources/VCKStubs/*.swift` is written by
`scripts/generate_proto.sh -t plugin-swift` from `proto/plugin/v1/plugin.proto`
and `proto/topics/v1/*.proto`. Any edit there is silently reverted on the next
proto change. Change the `.proto` and regenerate.

## Rules the SDK does not enforce for you

The SDK cannot make these mistakes impossible, so they are listed where a
plugin author will read them (full list: `docs/plugin-architecture.md`
§"Rules that bite"):

- **Never call `exit()` on an error.** Core charges any unrequested exit as a
  failed start; five park the plugin in `StateFailed`. Degrade in-process.
  The one sanctioned exit is a malformed spawn environment, where there is no
  core connection to degrade against.
- **A clean end of the `Register` stream is not an error.** It must feed the
  reconnect ladder, not fall out of it.
- **Register only after the HTTP server is accepting.** `VCHost.connect()`
  already orders this correctly — register routes on the `VCRouter` *before*
  calling it.
- **Put a deadline on `publish` and `alert`.**
- **Publishing a topic not declared in `manifest.yaml` is a dropped message.**
- State goes in `$VIBECARE_DATA_DIR` (`VCHost.dataDir`). A plugin binary has
  no bundle identifier, so `UserDefaults` has nowhere to write.
- Plugin HTML uses **relative URLs only**, and no `localStorage`,
  `sessionStorage` or cookies.

## Tests

```bash
cd sdk/swift/VCPluginSDK && swift test
```
