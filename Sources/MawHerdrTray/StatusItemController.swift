import AppKit
import Foundation

// StatusItemController — owns the one NSStatusItem and the one NSMenu.
//
// The NSStatusItem is created once in init and never recreated; the NSMenu
// object is likewise created once — rebuilt while it is closed, patched item
// by item while it is open. Every refresh is a full render from a
// FleetSnapshot value — no half-mutation from a callback, because nothing
// here is callable off the main actor.

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, FleetSnapshotReceiver {
  private let statusItem: NSStatusItem
  private let menu = NSMenu()
  private let config: TrayConfig

  private var snapshot: FleetSnapshot
  private var lifecycle: ServerLifecycle = .unknown
  private var ownsServer = false
  private var lifecycleAvailable = false
  private var busy = false
  private var stale = false

  /// Set by AppDelegate; holds the @objc action handlers.
  weak var actions: (AnyObject & TrayMenuActions)?
  /// Called when the user opens the menu, so the AppDelegate can ask the
  /// monitor for a fresh snapshot. Read-only: it triggers a GET, nothing more.
  var onMenuWillOpen: (() -> Void)?

  /// True between `menuWillOpen` and `menuDidClose`.
  ///
  /// MEASURED 2026-09-22: `MenuBuilder.rebuild` starts with `removeAllItems()`,
  /// and doing that to a menu that is currently TRACKING makes AppKit dismiss
  /// it — observed as the menu vanishing under an AX walk, and as `Can't get
  /// menu item 33 … Invalid index` when the item count changed beneath the
  /// enumerator.
  ///
  /// The first explanation of WHY a poll reached an open menu was wrong, and
  /// the difference matters: it assumed menu tracking parks the main queue, so
  /// snapshots only landed when something else (an AX client) pumped the run
  /// loop, and the freeze was therefore "free". Re-measured with
  /// `.tmp/menuprobe` on this host (macOS 26, Swift 6.3): with a status-item
  /// menu open, `Task { @MainActor }` from a background thread,
  /// `DispatchQueue.main.async`, `MainActor.run` and an `AsyncStream` consumer
  /// all ran within the same second; only a default-mode Timer waited for the
  /// close. So every snapshot arrives while the menu is up, AX client or not.
  /// The rule is not "defer everything" but "never RESTRUCTURE an open menu":
  /// `render()` copies a new snapshot into the existing items in place when
  /// the shape is unchanged (`MenuBuilder.updateInPlace`), and only a shape
  /// change waits for `menuDidClose`.
  private var menuIsOpen = false
  private var needsMenuRebuild = false

  private var watchdog: Timer?
  /// A snapshot older than this with no newer one arriving means the poller
  /// itself stopped — the title must say so rather than keep showing numbers
  /// that are no longer true.
  ///
  /// It must be strictly LARGER than the worst-case gap between updates. It
  /// was `max(12, pollInterval * 4)`, which is character-for-character the
  /// socket-live heartbeat period the monitor computes
  /// (`socketLive ? max(config.pollInterval * 4, 12) : …`, APIClient.swift) —
  /// so on a healthy tray with a live socket the threshold equalled the period
  /// it was measuring and one slow tick painted a false "⚠ stale". The worst
  /// case is one whole heartbeat plus a request that runs to its timeout;
  /// doubling the heartbeat and adding that timeout puts the alarm safely
  /// outside it while still firing inside half a minute.
  private var heartbeatInterval: TimeInterval { max(12, config.pollInterval * 4) }
  private var staleAfter: TimeInterval { heartbeatInterval * 2 + config.requestTimeout }

  init(config: TrayConfig) {
    self.config = config
    self.snapshot = .initial()
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()

    statusItem.button?.imagePosition = .noImage
    statusItem.button?.toolTip = "maw-herdr-tray — \(config.baseURL.absoluteString)"
    // Automation identity. AX addresses a process by NAME, and every instance
    // of this tray is named `maw-herdr-tray`, so two trays (one per port) are
    // indistinguishable to `System Events` by name. A driver can pick the
    // process by pid instead — `first process whose unix id is <pid>`,
    // measured to work — and the button then says WHICH tray it reached: the
    // endpoint sits in its AXIdentifier and in its AXDescription (the label,
    // refreshed by `render()`), while the AXTitle stays the glyph counts.
    // VoiceOver reads the description, which turns "◐2 ✳13 ✓3" into words.
    statusItem.button?.setAccessibilityIdentifier("maw-herdr-tray \(endpointLabel)")
    menu.title = "maw-herdr-tray \(endpointLabel)"
    menu.delegate = self
    menu.autoenablesItems = false
    statusItem.menu = menu

    render()
    startWatchdog()
  }

  // No deinit: the watchdog Timer is main-actor state and a nonisolated deinit
  // may not touch it under strict concurrency. `teardown()` is the one place
  // that invalidates it, and AppDelegate calls it on quit and on terminate.

  // MARK: - Input

  /// FleetSnapshotReceiver. Called on the main actor only — the AppDelegate
  /// hops here from the AsyncStream consumer.
  func fleetDidUpdate(_ snapshot: FleetSnapshot) {
    self.snapshot = snapshot
    self.stale = false
    render()
  }

  func setLifecycle(_ state: ServerLifecycle, owns: Bool, available: Bool, busy: Bool = false) {
    self.lifecycle = state
    self.ownsServer = owns
    self.lifecycleAvailable = available
    self.busy = busy
    render()
  }

  func setBusy(_ busy: Bool) {
    self.busy = busy
    render()
  }

  var currentSnapshot: FleetSnapshot { snapshot }

  func teardown() {
    watchdog?.invalidate()
    watchdog = nil
    menu.delegate = nil
    statusItem.menu = nil
    NSStatusBar.system.removeStatusItem(statusItem)
  }

  // MARK: - Render

  private func render() {
    statusItem.button?.attributedTitle = titleString()
    statusItem.button?.setAccessibilityLabel(accessibilityLabel())
    guard !menuIsOpen else {
      // The menu is tracking. Titles, tooltips and enabled states are copied
      // into the existing items — that is what lets "updated HH:MM:SS", the
      // count row and a pane's glyph move while the menu is being read. A
      // shape change cannot be applied without `removeAllItems()`, which would
      // dismiss the menu, so it waits for `menuDidClose`; whatever arrives in
      // between coalesces into that one rebuild.
      let patched = MenuBuilder.updateInPlace(menu, ctx: menuContext(), target: actions)
      needsMenuRebuild = !patched
      trace(
        patched
          ? "menu open — patched in place (\(menu.items.count) items, snapshot \(snapshotClock))"
          : "menu open — shape changed, rebuild deferred to close")
      return
    }
    rebuildMenu()
  }

  // MARK: - Trace (MAW_HERDR_TRAY_DEBUG)

  /// Stderr trace of the menu lifecycle — open, in-place patch, deferred
  /// rebuild, close — on only when MAW_HERDR_TRAY_DEBUG is set. It exists
  /// because an Accessibility client can read a status-item menu whether or
  /// not it is open (measured 2026-09-22: `get title of every menu item …`
  /// answers in full on a CLOSED menu), so "was it open, and did it repaint"
  /// needs the app's own word. Prints item counts and clock times only —
  /// never a token, never pane text.
  private static let traceEnabled =
    ProcessInfo.processInfo.environment["MAW_HERDR_TRAY_DEBUG"] != nil

  private func trace(_ line: String) {
    guard Self.traceEnabled else { return }
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss.SSS"
    FileHandle.standardError.write(
      Data("maw-herdr-tray \(clock.string(from: Date())) \(line)\n".utf8))
  }

  /// "13:01:38" — when the snapshot on screen was produced.
  private var snapshotClock: String {
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss"
    return clock.string(from: snapshot.updatedAt)
  }

  private func menuContext() -> MenuContext {
    MenuContext(
      snapshot: snapshot,
      lifecycle: lifecycle,
      ownsServer: ownsServer,
      lifecycleAvailable: lifecycleAvailable,
      busy: busy,
      config: config,
      stale: stale
    )
  }

  private func rebuildMenu() {
    MenuBuilder.rebuild(menu, ctx: menuContext(), target: actions)
  }

  /// "127.0.0.1:3467" — what the AX identity and label carry.
  private var endpointLabel: String {
    let host = config.baseURL.host ?? "127.0.0.1"
    let port =
      config.baseURL.port ?? ((config.baseURL.scheme?.lowercased() == "https") ? 443 : 80)
    return "\(host):\(port)"
  }

  /// The title in words, for VoiceOver and for an automation client that has
  /// to tell two trays apart: "maw-herdr-tray 127.0.0.1:3467: 2 working,
  /// 13 idle, 3 done, 13 shells". Token-free by construction.
  private func accessibilityLabel() -> String {
    let prefix = "maw-herdr-tray \(endpointLabel)"
    guard snapshot.reachable else {
      return "\(prefix): \(snapshot.authDenied ? "no token" : "herdr down")"
    }
    var parts: [String] = []
    for status in TrayStatus.summarised where snapshot.counts[status] > 0 {
      parts.append("\(snapshot.counts[status]) \(status.label)")
    }
    if snapshot.counts.noAgent > 0 { parts.append("\(snapshot.counts.noAgent) shells") }
    let body = parts.isEmpty ? "no agents" : parts.joined(separator: ", ")
    return "\(prefix): \(body)\(stale ? ", stale" : "")"
  }

  /// "◐2 ✳14 ✓4" with each glyph in its palette colour and the digits left to
  /// the system tint, in a monospaced-digit font so the item does not jitter
  /// as counts change. Unreachable and stale states say so in words.
  private func titleString() -> NSAttributedString {
    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
    let out = NSMutableAttributedString()

    func append(_ text: String, _ colour: NSColor?) {
      var attrs: [NSAttributedString.Key: Any] = [.font: font]
      if let colour { attrs[.foregroundColor] = colour }
      out.append(NSAttributedString(string: text, attributes: attrs))
    }

    guard snapshot.reachable else {
      append(TrayStatus.unreachable.glyph, TrayStatus.unreachable.nsColor)
      // A 401/403 is the server ANSWERING and refusing us. Calling that "down"
      // sent the reader to look for a dead process instead of a token.
      append(snapshot.authDenied ? " no token" : " herdr down", .systemRed)
      return out
    }

    if stale {
      append(TrayStatus.unreachable.glyph, TrayStatus.blocked.nsColor)
      append(" stale ", .systemOrange)
    }

    var wrote = false
    for status in TrayStatus.summarised {
      let n = snapshot.counts[status]
      guard n > 0 else { continue }
      if wrote { append(" ", nil) }
      append(status.glyph, status.nsColor)
      append("\(n)", nil)
      wrote = true
    }
    if !wrote {
      append(TrayStatus.idle.glyph, TrayStatus.idle.nsColor)
      append("0", nil)
    }
    return out
  }

  // MARK: - Staleness watchdog

  private func startWatchdog() {
    let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let age = Date().timeIntervalSince(self.snapshot.updatedAt)
        let nowStale = self.snapshot.reachable && age > self.staleAfter
        if nowStale != self.stale {
          self.stale = nowStale
          self.render()
        }
      }
    }
    timer.tolerance = 1
    watchdog = timer
  }

  // MARK: - NSMenuDelegate

  func menuWillOpen(_ menu: NSMenu) {
    // Still safe to restructure here: AppKit has not begun tracking yet.
    rebuildMenu()
    needsMenuRebuild = false
    menuIsOpen = true
    trace("menu opened (\(menu.items.count) items, snapshot \(snapshotClock))")
    onMenuWillOpen?()
  }

  func menuDidClose(_ menu: NSMenu) {
    menuIsOpen = false
    trace("menu closed — \(needsMenuRebuild ? "rebuilding for a deferred shape change" : "nothing deferred")")
    if needsMenuRebuild {
      needsMenuRebuild = false
      rebuildMenu()
    }
  }
}
