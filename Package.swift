// swift-tools-version: 6.0
import PackageDescription

// No dependencies on purpose. The point of a second implementation is that it
// shares nothing with the first — a bug reproduced in both is a bug in the
// protocol, not in one runtime. Network.framework carries TCP and WebSocket
// framing, so nothing needs fetching to build this.
//
// MawHerdrTray is additive and separate: a menu-bar client that talks to a
// running server over HTTP only. It shares NO source with MawHerdrServe — it
// re-derives the wire shapes from measured payloads, which keeps the parity
// argument above intact for the client side too.
//
// Both products are named after their targets on purpose. `.build/release/
// MawHerdrServe` is load-bearing — index.mjs:17 and `just run` hardcode that
// path — so the serve product must not rename its binary.
let package = Package(
  name: "maw-herdr-swift",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "MawHerdrServe", targets: ["MawHerdrServe"]),
    .executable(name: "maw-herdr-tray", targets: ["MawHerdrTray"]),
  ],
  targets: [
    .executableTarget(
      name: "MawHerdrServe",
      path: "Sources/MawHerdrServe"
    ),
    .executableTarget(
      name: "MawHerdrTray",
      path: "Sources/MawHerdrTray"
    ),
  ]
)
