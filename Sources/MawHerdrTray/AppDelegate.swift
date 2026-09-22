import AppKit
import Foundation

// AppDelegate — the main-actor hub. It owns the StatusItemController, consumes
// the monitor's AsyncStream, and turns menu clicks into async work.
//
// Isolation rule of this file: the class is @MainActor, so every stored
// property and every @objc action runs on the main thread. The monitor and the
// lifecycle controller are Sendable protocol existentials whose methods are
// async and NOT main-actor — each call therefore happens inside a Task, and
// the result is applied back here (still on the main actor) after the await.
// Nothing off the main actor ever touches NSStatusItem or NSMenu.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, TrayMenuActions {
  private let config: TrayConfig
  private let monitor: any FleetMonitor
  private let lifecycleController: (any ServerLifecycleController)?
  /// Optional push channel from the lifecycle module (its concrete controller
  /// exposes one; the protocol does not). When present, a server that dies on
  /// its own reaches the menu without waiting for the next probe.
  private let lifecycleEvents: AsyncStream<ServerLifecycle>?

  private var statusItem: StatusItemController?
  private var streamTask: Task<Void, Never>?
  private var lifecycleTask: Task<Void, Never>?
  private var signalSources: [DispatchSourceSignal] = []
  private var isShuttingDown = false

  /// Mirror of what the status item was last told, so `apply(_:)` can notice
  /// the lifecycle view disagreeing with the snapshot without asking the
  /// controller on every tick.
  private var lifecycleState: ServerLifecycle = .unknown
  private var ownsChild = false
  private var lifecycleProbeInFlight = false

  init(
    config: TrayConfig,
    monitor: any FleetMonitor,
    lifecycleController: (any ServerLifecycleController)? = nil,
    lifecycleEvents: AsyncStream<ServerLifecycle>? = nil
  ) {
    self.config = config
    self.monitor = monitor
    self.lifecycleController = lifecycleController
    self.lifecycleEvents = lifecycleEvents
    super.init()
  }

  // MARK: - Lifecycle

  func applicationDidFinishLaunching(_ notification: Notification) {
    let item = StatusItemController(config: config)
    item.actions = self
    item.onMenuWillOpen = { [weak self] in
      guard let self else { return }
      Task { await self.monitor.refreshNow() }
      // The lifecycle half was never re-read on open, so a server the tray did
      // NOT start could die and the menu would keep asserting "running: … on
      // m5-beta" beside a bar reading "⚠ herdr down", with "Start server" still
      // disabled and no way out of the menu itself. /api/identity is the whole
      // probe and measured at 0.6 ms locally; an open is cheap enough to pay it.
      self.probeLifecycle()
    }
    statusItem = item
    setLifecycle(.unknown, owns: false, available: lifecycleController != nil)

    streamTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for await snapshot in self.monitor.snapshots {
        self.apply(snapshot)
      }
    }

    if let events = lifecycleEvents, let controller = lifecycleController {
      lifecycleTask = Task { @MainActor [weak self] in
        for await state in events {
          let owns = await controller.ownsRunningServer()
          self?.setLifecycle(state, owns: owns, available: true)
        }
      }
    }

    Task { await monitor.start() }
    probeLifecycle()
    installSignalHandlers()
  }

  func applicationWillTerminate(_ notification: Notification) {
    statusItem?.teardown()
    // LEAVE NO ORPHAN. This callback cannot await, so the async stop() path is
    // fire-and-forget and a server this app launched could outlive the process
    // (logout, `NSApp.terminate` from anywhere but our own Quit). The lifecycle
    // module's synchronous SIGTERM-then-SIGKILL door exists for exactly this
    // moment; it is a no-op when we started nothing, and it never touches a
    // server we merely found running.
    (lifecycleController as? HerdrServerController)?.terminateChildForQuit()
    (lifecycleController as? HerdrServerController)?.finishEvents()
    let monitor = self.monitor
    Task.detached { await monitor.stop() }
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  // MARK: - Snapshot plumbing

  private func apply(_ snapshot: FleetSnapshot) {
    statusItem?.fleetDidUpdate(snapshot)
    // With no lifecycle controller wired, the snapshot itself is the only
    // evidence about the server — show it, but leave the controls disabled.
    guard lifecycleController != nil else {
      let state: ServerLifecycle
      if let identity = snapshot.identity {
        state = .running(
          version: identity.version, runtime: identity.runtime, node: identity.node)
      } else {
        state = snapshot.reachable ? .unknown : .stopped
      }
      setLifecycle(state, owns: false, available: false)
      return
    }

    // A controller IS wired, but nothing reconciled it against the snapshot:
    // a FOREIGN server (one the tray did not launch) could go away and the menu
    // would keep the `.running` it probed at launch forever, with "Start
    // server" disabled because `lifecycle.isRunning` was still true. A 401 is
    // deliberately NOT a disagreement — `probe()` correctly reads that as
    // running-and-token-protected, and `authDenied` says the server answered.
    guard !ownsChild, !snapshot.authDenied else { return }
    if snapshot.reachable != lifecycleState.isRunning { probeLifecycle() }
  }

  /// Records what the status item is told, so `apply(_:)` can compare against
  /// it without an await. One writer: every lifecycle update goes through here.
  private func setLifecycle(
    _ state: ServerLifecycle, owns: Bool, available: Bool, busy: Bool = false
  ) {
    lifecycleState = state
    ownsChild = owns
    statusItem?.setLifecycle(state, owns: owns, available: available, busy: busy)
  }

  /// Debounced: `apply(_:)` can call this on every tick while the two views
  /// disagree, and a probe in flight must not be stacked behind another.
  private func probeLifecycle() {
    guard let controller = lifecycleController, !lifecycleProbeInFlight else { return }
    lifecycleProbeInFlight = true
    Task { @MainActor in
      defer { self.lifecycleProbeInFlight = false }
      let state = await controller.probe()
      let owns = await controller.ownsRunningServer()
      self.setLifecycle(state, owns: owns, available: true)
    }
  }

  // MARK: - TrayMenuActions

  func trayRefreshNow(_ sender: Any?) {
    Task { await monitor.refreshNow() }
    probeLifecycle()
  }

  func trayStartServer(_ sender: Any?) {
    guard let controller = lifecycleController else { return }
    statusItem?.setBusy(true)
    Task { @MainActor in
      let state = await controller.start()
      let owns = await controller.ownsRunningServer()
      self.setLifecycle(state, owns: owns, available: true, busy: false)
      await self.monitor.refreshNow()
    }
  }

  func trayStopServer(_ sender: Any?) {
    guard let controller = lifecycleController else { return }
    // Second gate, behind the menu item's own: only a server this app started.
    statusItem?.setBusy(true)
    Task { @MainActor in
      guard await controller.ownsRunningServer() else {
        let state = await controller.probe()
        self.setLifecycle(state, owns: false, available: true, busy: false)
        return
      }
      let state = await controller.stop()
      let owns = await controller.ownsRunningServer()
      self.setLifecycle(state, owns: owns, available: true, busy: false)
      await self.monitor.refreshNow()
    }
  }

  func trayOpenDashboard(_ sender: Any?) {
    NSWorkspace.shared.open(config.browseURL)
  }

  /// Copies `FleetPane.captureTarget` — "<session>:<base-36 index>", the key
  /// /api/capture actually accepts — to the pasteboard. Reading a pane's
  /// address is not writing to it; nothing is sent anywhere.
  func trayCopyTarget(_ sender: Any?) {
    guard let item = sender as? NSMenuItem, let target = item.representedObject as? String
    else { return }
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(target, forType: .string)
  }

  func trayQuit(_ sender: Any?) {
    shutdown()
  }

  // MARK: - Shutdown

  private func shutdown() {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    streamTask?.cancel()
    lifecycleTask?.cancel()
    let monitor = self.monitor
    let controller = lifecycleController
    Task { @MainActor in
      await monitor.stop()
      // Leave no orphan: a server THIS app started dies with it. One we merely
      // found running is never touched.
      if let controller, await controller.ownsRunningServer() {
        _ = await controller.stop()
      }
      (self.lifecycleController as? HerdrServerController)?.finishEvents()
      self.statusItem?.teardown()
      NSApp.terminate(nil)
    }
  }

  /// `swift run` from a terminal means Ctrl-C is the normal way out; without
  /// this the app would die before stopping the poller.
  ///
  /// SIGHUP is in the set for the same reason. It is what the launching
  /// terminal's disappearance delivers — a closed window, a closed herdr pane,
  /// a shell or agent harness ending the job it backgrounded the tray from —
  /// and it is exactly the signal a plain `&` launch receives and a `nohup`
  /// launch does not, which is why two trays started from one shell vanished
  /// together while nohup'd ones lived on. Its default action is an immediate
  /// kill: no `applicationWillTerminate`, no `terminateChildForQuit`, so a
  /// server this tray had started could outlive it as an orphan holding the
  /// port. Handled, a hangup is a Quit: poller stopped, child terminated,
  /// status item removed, exit 0.
  private func installSignalHandlers() {
    for sig in [SIGINT, SIGTERM, SIGHUP] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { MainActor.assumeIsolated { self.shutdown() } }
      source.resume()
      signalSources.append(source)
    }
  }
}
