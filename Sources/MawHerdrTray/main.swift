import AppKit
import Foundation

// maw-herdr-tray — a menu-bar view of a running `maw herdr serve`.
//
// No app bundle, no Xcode project, no Info.plist: `setActivationPolicy(.accessory)`
// is what makes a bare SwiftPM executable legal in the menu bar with no dock
// icon and no window. Launch it with:
//
//     swift run maw-herdr-tray
//     MAW_HERDR_URL=http://127.0.0.1:3467 swift run maw-herdr-tray
//
// Ctrl-C in that terminal is a clean exit — AppDelegate installs SIGINT/SIGTERM
// handlers that stop the poller before the process goes away — and so is
// closing that terminal: SIGHUP is handled the same way, so a server the tray
// started never outlives it as an orphan.
//
// Top-level code in main.swift is @MainActor-isolated in Swift 6, so the AppKit
// calls below need no annotation. Everything that is NOT main-actor (the
// monitor's polling, its URLSession callbacks) lives behind `FleetMonitor` and
// reaches the UI only as `FleetSnapshot` values over an AsyncStream.
//
// READ-ONLY toward the fleet: nothing in this target calls /api/send or
// /api/wake, and no menu item can put a keystroke in anyone's pane.

var config = TrayConfig.fromEnvironment()

// TOKEN POSTURE, settled once, here, before anything reads the server.
//
// The lifecycle controller starts a server with `--token-file ~/.maw-herdr-token`
// whenever that file is readable, and a token-mode server answers 401 to EVERY
// route including /api/health. A monitor built from a token-less config would
// then render an empty fleet against a healthy server the tray itself just
// launched, with nothing in the UI that looks like an auth problem. Adopting
// the same default up front removes the seam instead of patching it after
// start(): the monitor's config is fixed at construction and cannot be swapped.
//
// MEASURED 2026-09-22: an `--insecure-no-token` server accepts a Bearer header
// and answers 200, so carrying the token is harmless when it is not required.
// Gated on loopback — an operator token is local, and MAW_HERDR_URL can point
// anywhere. The value is read only into an Authorization header: never printed,
// never logged, never in an error string.
if config.tokenFilePath == nil, config.isLoopback {
  let candidate = ("~/.maw-herdr-token" as NSString).expandingTildeInPath
  if FileManager.default.isReadableFile(atPath: candidate) {
    config.tokenFilePath = candidate
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// ── WIRING ───────────────────────────────────────────────────────────────────
// The monitor is the API module's actor (APIClient.swift). The lifecycle
// controller is optional by design: when it is nil the menu still shows what
// the server says about itself and leaves "Start server"/"Stop server"
// disabled, so a missing module is visible rather than silent.
let monitor: any FleetMonitor = HerdrFleetMonitor(config: config)
let serverControl = HerdrServerController(config: config)
let lifecycle: (any ServerLifecycleController)? = serverControl
// ─────────────────────────────────────────────────────────────────────────────

let delegate = AppDelegate(
  config: config,
  monitor: monitor,
  lifecycleController: lifecycle,
  // Push channel the concrete controller offers on top of the protocol: a
  // server that exits on its own updates the menu without waiting for a probe.
  lifecycleEvents: serverControl.lifecycleEvents)
app.delegate = delegate

FileHandle.standardError.write(
  Data(
    """
    maw-herdr-tray: menu-bar item up — \(config.baseURL.absoluteString), polling every \
    \(String(format: "%.1f", config.pollInterval))s. Ctrl-C or the Quit item to exit.

    """.utf8))

app.run()
