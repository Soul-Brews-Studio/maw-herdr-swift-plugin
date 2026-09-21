// swift-tools-version: 6.0
import PackageDescription

// No dependencies on purpose. The point of a second implementation is that it
// shares nothing with the first — a bug reproduced in both is a bug in the
// protocol, not in one runtime. Network.framework carries TCP and WebSocket
// framing, so nothing needs fetching to build this.
let package = Package(
  name: "maw-herdr-swift",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "MawHerdrServe",
      path: "Sources/MawHerdrServe"
    )
  ]
)
