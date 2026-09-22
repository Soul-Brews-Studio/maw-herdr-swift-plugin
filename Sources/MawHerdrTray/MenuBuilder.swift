import AppKit
import Foundation

// MenuBuilder — the ONLY place an NSMenu is assembled.
//
// Pure function of a snapshot: `MenuBuilder.build(ctx, target:)` returns a
// fresh NSMenu every time; `rebuild` repopulates a CLOSED menu, and
// `updateInPlace` patches an OPEN one item-by-item without restructuring it.
// Nothing here fetches, nothing here sends. Read-only toward the fleet: the only outward
// actions any item can trigger are the lifecycle controller's start/stop and
// opening the server URL in a browser.
//
// Everything is @MainActor — NSMenu, NSMenuItem, NSColor and NSFont all are.

/// Menu item actions, implemented by AppDelegate. `@objc` because NSMenuItem
/// dispatches through the ObjC runtime; `@MainActor` because every handler
/// lands in AppKit.
@MainActor
@objc protocol TrayMenuActions: NSObjectProtocol {
  func trayRefreshNow(_ sender: Any?)
  func trayStartServer(_ sender: Any?)
  func trayStopServer(_ sender: Any?)
  func trayOpenDashboard(_ sender: Any?)
  func trayCopyTarget(_ sender: Any?)
  func trayQuit(_ sender: Any?)
}

/// Everything the menu renders, gathered by the AppDelegate from the monitor
/// and the lifecycle controller. One value in, one menu out.
@MainActor
struct MenuContext {
  var snapshot: FleetSnapshot
  var lifecycle: ServerLifecycle = .unknown
  var ownsServer: Bool = false
  /// False when no lifecycle controller was wired in — the start/stop items
  /// are then shown disabled rather than hidden, so the absence is visible.
  var lifecycleAvailable: Bool = false
  /// A start/stop is in flight; the controls are disabled while it runs.
  var busy: Bool = false
  var config: TrayConfig = .standard
  /// True when snapshots stopped arriving even though the last one succeeded.
  var stale: Bool = false
}

@MainActor
enum MenuBuilder {
  // ── Readability caps for a ~20-session / ~34-pane fleet. See report.
  /// Sessions rendered at the top level, busiest first; the rest go into one
  /// "Other sessions (N)" submenu.
  static let maxTopLevelSessions = 12
  /// Panes listed inside one session submenu before "… N more panes".
  static let maxPanesPerSession = 24
  /// Panes in the flat "Working now" section at the top of the menu.
  static let maxHighlights = 8

  static func build(_ ctx: MenuContext, target: (AnyObject & TrayMenuActions)?) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    populate(menu, ctx: ctx, target: target)
    return menu
  }

  /// Rebuilds an existing menu in place (`removeAllItems` then repopulate) so
  /// the NSStatusItem keeps the same NSMenu object across refreshes.
  static func rebuild(_ menu: NSMenu, ctx: MenuContext, target: (AnyObject & TrayMenuActions)?) {
    menu.removeAllItems()
    menu.autoenablesItems = false
    populate(menu, ctx: ctx, target: target)
  }

  /// Refreshes an OPEN menu without restructuring it, so tracking survives.
  ///
  /// MEASURED 2026-09-22 (`.tmp/menuprobe`, macOS 26 / Swift 6.3): main-actor
  /// work is NOT deferred while a status-item menu is tracking — a
  /// `Task { @MainActor }` from a background thread, `DispatchQueue.main.async`,
  /// `MainActor.run` and an `AsyncStream` consumer all ran with the menu open;
  /// only a default-mode Timer waited for the close. So snapshots DO land on an
  /// open menu, and the one thing that must not happen then is
  /// `removeAllItems()`, which dismisses a tracking menu. This renders the new
  /// snapshot into a scratch menu and, when the scratch has the same SHAPE as
  /// the live one (item count, separators and submenus in the same places,
  /// recursively), copies each item's title, tooltip, enabled state and
  /// represented object across — property edits AppKit redraws in place. A
  /// shape change (a pane came or went, a section appeared) returns false and
  /// the caller rebuilds on close.
  @discardableResult
  static func updateInPlace(
    _ menu: NSMenu, ctx: MenuContext, target: (AnyObject & TrayMenuActions)?
  ) -> Bool {
    let fresh = build(ctx, target: target)
    guard sameShape(menu, fresh) else { return false }
    copyItems(from: fresh, into: menu)
    return true
  }

  private static func sameShape(_ live: NSMenu, _ fresh: NSMenu) -> Bool {
    guard live.items.count == fresh.items.count else { return false }
    for (a, b) in zip(live.items, fresh.items) {
      guard a.isSeparatorItem == b.isSeparatorItem else { return false }
      switch (a.submenu, b.submenu) {
      case (nil, nil): continue
      case let (x?, y?): guard sameShape(x, y) else { return false }
      default: return false
      }
    }
    return true
  }

  /// Property edits only — never add, remove or reorder an item. Guarded by
  /// `sameShape`, so the zip is exact and recursion into submenus is safe.
  private static func copyItems(from fresh: NSMenu, into live: NSMenu) {
    for (item, source) in zip(live.items, fresh.items) where !item.isSeparatorItem {
      if item.attributedTitle != source.attributedTitle {
        item.attributedTitle = source.attributedTitle
      }
      if item.title != source.title { item.title = source.title }
      if item.toolTip != source.toolTip { item.toolTip = source.toolTip }
      if item.isEnabled != source.isEnabled { item.isEnabled = source.isEnabled }
      if item.indentationLevel != source.indentationLevel {
        item.indentationLevel = source.indentationLevel
      }
      if item.keyEquivalent != source.keyEquivalent { item.keyEquivalent = source.keyEquivalent }
      item.representedObject = source.representedObject
      item.target = source.target
      item.action = source.action
      if let liveSub = item.submenu, let freshSub = source.submenu {
        copyItems(from: freshSub, into: liveSub)
      }
    }
  }

  // MARK: - Sections

  private static func populate(
    _ menu: NSMenu, ctx: MenuContext, target: (AnyObject & TrayMenuActions)?
  ) {
    header(into: menu, ctx: ctx)

    if ctx.snapshot.reachable {
      highlights(into: menu, ctx: ctx, target: target)
      sessions(into: menu, ctx: ctx, target: target)
    } else {
      separate(menu)
      // "not answering" and "answering, and refusing us" are different
      // problems with different fixes. `ServerControl.probe()` already reads a
      // 401 as `.running (token-protected)`, so saying "not answering" here
      // made the menu contradict its own lifecycle line.
      if ctx.snapshot.authDenied {
        menu.addItem(disabled(plain("Server is up but refused this client (401/403).")))
        menu.addItem(
          disabled(
            secondary("MAW_HERDR_TOKEN_FILE=~/.maw-herdr-token swift run maw-herdr-tray")))
      } else {
        menu.addItem(disabled(plain("No fleet data — the server is not answering.")))
      }
    }

    separate(menu)
    controls(into: menu, ctx: ctx, target: target)
  }

  private static func header(into menu: NSMenu, ctx: MenuContext) {
    let snapshot = ctx.snapshot

    if let identity = snapshot.identity {
      menu.addItem(
        disabled(bold("\(identity.version) · \(identity.runtime) · \(identity.node)")))
      // `?? 80` printed the WRONG address for any URL without an explicit
      // port — an https endpoint was shown as ":80". Fall back to the scheme's
      // own default instead.
      var second = "\(ctx.config.baseURL.host ?? "127.0.0.1"):\(defaultPort(ctx.config.baseURL))"
      if let uptime = identity.uptime { second += " · up \(durationText(uptime))" }
      menu.addItem(disabled(secondary(second)))
    } else {
      menu.addItem(disabled(bold(lifecycleHeadline(ctx))))
      menu.addItem(disabled(secondary(ctx.config.baseURL.absoluteString)))
    }

    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss"
    var updated = "updated \(clock.string(from: snapshot.updatedAt))"
    if ctx.stale { updated += " · STALE — no refresh landed" }
    menu.addItem(disabled(secondary(updated)))

    if let error = snapshot.lastError {
      menu.addItem(disabled(coloured("\(TrayStatus.unreachable.glyph) \(error)", .systemRed)))
    }

    if snapshot.reachable {
      menu.addItem(.separator())
      menu.addItem(disabled(countsLine(snapshot.counts)))
    }
  }

  /// The working/blocked panes, flat, at the top — the "what is moving right
  /// now" answer that should not need a submenu hover.
  private static func highlights(
    into menu: NSMenu, ctx: MenuContext, target: (AnyObject & TrayMenuActions)?
  ) {
    let busy = ctx.snapshot.allPanes.filter { $0.status == .working || $0.status == .blocked }
    guard !busy.isEmpty else { return }

    separate(menu)
    menu.addItem(disabled(sectionTitle("WORKING NOW")))

    // `uniqueKeysWithValues:` TRAPS on a duplicate key — a hard crash, and the
    // menu-bar item simply vanishes. It was the one place in an otherwise
    // deliberately fail-soft client where server data could kill the process.
    // The server does reject duplicate session names today (Backend.swift:204),
    // but the tray must not depend on that to stay alive.
    let sessionNames = Dictionary(
      ctx.snapshot.sessions.map { ($0.id, $0.displayName) },
      uniquingKeysWith: { first, _ in first })

    for pane in busy.prefix(maxHighlights) {
      let suffix = sessionNames[pane.sessionName].map { "  (\($0))" } ?? ""
      let item = paneItem(pane, extra: suffix, target: target)
      item.indentationLevel = 1
      menu.addItem(item)
    }
    if busy.count > maxHighlights {
      menu.addItem(indentedNote("… \(busy.count - maxHighlights) more working"))
    }
  }

  private static func sessions(
    into menu: NSMenu, ctx: MenuContext, target: (AnyObject & TrayMenuActions)?
  ) {
    let sessions = ctx.snapshot.sessions.sorted {
      if $0.headlineStatus.rank != $1.headlineStatus.rank {
        return $0.headlineStatus.rank < $1.headlineStatus.rank
      }
      if $0.panes.count != $1.panes.count { return $0.panes.count > $1.panes.count }
      return $0.displayName < $1.displayName
    }

    separate(menu)
    menu.addItem(
      disabled(sectionTitle("SESSIONS (\(sessions.count)) · \(ctx.snapshot.counts.total) PANES")))

    guard !sessions.isEmpty else {
      menu.addItem(indentedNote("no sessions"))
      return
    }

    for session in sessions.prefix(maxTopLevelSessions) {
      menu.addItem(sessionItem(session, target: target))
    }

    let overflow = sessions.dropFirst(maxTopLevelSessions)
    if !overflow.isEmpty {
      let item = NSMenuItem()
      item.attributedTitle = plain("Other sessions (\(overflow.count))")
      item.indentationLevel = 1
      let sub = NSMenu()
      sub.autoenablesItems = false
      for session in overflow { sub.addItem(sessionItem(session, target: target)) }
      item.submenu = sub
      menu.addItem(item)
    }
  }

  /// A session with exactly one pane renders flat — with ~20 sessions, most of
  /// them single-pane, a submenu per session would hide everything behind a
  /// hover for no gain. Multi-pane sessions get a submenu.
  private static func sessionItem(
    _ session: FleetSession, target: (AnyObject & TrayMenuActions)?
  ) -> NSMenuItem {
    if session.panes.count == 1, let pane = session.panes.first {
      let item = paneItem(pane, extra: "  (\(session.displayName))", target: target)
      item.indentationLevel = 1
      return item
    }

    let item = NSMenuItem()
    let title = NSMutableAttributedString()
    title.append(glyphRun(session.headlineStatus))
    title.append(plain(" \(session.displayName)  "))
    title.append(secondary("\(session.panes.count) panes  \(session.counts.compactTitle)"))
    item.attributedTitle = title
    item.indentationLevel = 1

    let sub = NSMenu()
    sub.autoenablesItems = false
    sub.addItem(disabled(secondary(session.id)))
    sub.addItem(.separator())
    for pane in session.panes.prefix(maxPanesPerSession) {
      sub.addItem(paneItem(pane, extra: "", target: target))
    }
    if session.panes.count > maxPanesPerSession {
      sub.addItem(indentedNote("… \(session.panes.count - maxPanesPerSession) more panes"))
    }
    item.submenu = sub
    return item
  }

  /// One pane. Clicking copies its `/api/capture` target to the pasteboard —
  /// the only per-pane action, and it sends nothing anywhere.
  private static func paneItem(
    _ pane: FleetPane, extra: String, target: (AnyObject & TrayMenuActions)?
  ) -> NSMenuItem {
    let item = NSMenuItem()
    let title = NSMutableAttributedString()
    title.append(glyphRun(pane.status))

    let kind = pane.agent ?? "shell"
    title.append(plain(" \(kind)"))
    if pane.name != kind { title.append(secondary("  \(pane.name)")) }
    if let cwd = pane.shortCwd { title.append(plain(" — \(cwd)")) }
    if !extra.isEmpty { title.append(secondary(extra)) }
    if pane.active { title.append(secondary("  ·active")) }

    item.attributedTitle = title
    // The tooltip shows the CAPTURE TARGET, not the decimal id — it is what
    // the click copies and the only one of the two the server accepts.
    var tip = "\(pane.status.label) · copies \(pane.captureTarget)"
    if pane.addressAmbiguous {
      tip += " — AMBIGUOUS: another pane in this session shares index \(pane.index)"
    }
    if let cwd = pane.cwd { tip += " · \(cwd)" }
    item.toolTip = tip
    item.representedObject = pane.captureTarget
    if let target {
      item.target = target
      item.action = #selector(TrayMenuActions.trayCopyTarget(_:))
      item.isEnabled = true
    } else {
      item.isEnabled = false
    }
    return item
  }

  private static func controls(
    into menu: NSMenu, ctx: MenuContext, target: (AnyObject & TrayMenuActions)?
  ) {
    let refresh = NSMenuItem()
    refresh.attributedTitle = plain("Refresh now")
    refresh.keyEquivalent = "r"
    refresh.target = target
    refresh.action = #selector(TrayMenuActions.trayRefreshNow(_:))
    refresh.isEnabled = target != nil
    menu.addItem(refresh)

    let open = NSMenuItem()
    // The label follows the config: this server serves no HTML, so promising a
    // "dashboard" and delivering a 404 would be the menu lying about the fleet.
    open.attributedTitle = plain(ctx.config.browseLabel)
    open.toolTip = ctx.config.browseURL.absoluteString
    open.keyEquivalent = "d"
    open.target = target
    open.action = #selector(TrayMenuActions.trayOpenDashboard(_:))
    open.isEnabled = target != nil
    menu.addItem(open)

    separate(menu)
    menu.addItem(disabled(secondary(lifecycleHeadline(ctx))))

    let start = NSMenuItem()
    start.attributedTitle = plain("Start server")
    start.target = target
    start.action = #selector(TrayMenuActions.trayStartServer(_:))
    start.isEnabled =
      target != nil && ctx.lifecycleAvailable && !ctx.busy && !ctx.lifecycle.isRunning
    menu.addItem(start)

    let stop = NSMenuItem()
    stop.attributedTitle = plain("Stop server")
    // Enabled ONLY for a server this app started. A server someone else is
    // running on this machine is not ours to stop.
    stop.toolTip =
      ctx.ownsServer
      ? "Terminates the server this tray launched" : "Only a server this tray started can be stopped"
    stop.target = target
    stop.action = #selector(TrayMenuActions.trayStopServer(_:))
    stop.isEnabled = target != nil && ctx.lifecycleAvailable && !ctx.busy && ctx.ownsServer
    menu.addItem(stop)

    separate(menu)
    let quit = NSMenuItem()
    quit.attributedTitle = plain("Quit maw-herdr-tray")
    quit.keyEquivalent = "q"
    quit.target = target
    quit.action = #selector(TrayMenuActions.trayQuit(_:))
    quit.isEnabled = true
    menu.addItem(quit)
  }

  /// One separator, never two in a row and never a leading one — sections are
  /// conditional, so the joins have to be idempotent.
  private static func separate(_ menu: NSMenu) {
    guard let last = menu.items.last, !last.isSeparatorItem else { return }
    menu.addItem(.separator())
  }

  // MARK: - Text

  private static func lifecycleHeadline(_ ctx: MenuContext) -> String {
    guard ctx.lifecycleAvailable else { return "server control unavailable" }
    if ctx.busy { return "server control busy…" }
    switch ctx.lifecycle {
    case .unknown: return "server state unknown"
    case .running(let version, let runtime, let node):
      return "running: \(version) (\(runtime)) on \(node)\(ctx.ownsServer ? " · ours" : "")"
    case .stopped: return "server stopped"
    case .failed(let why): return "server control failed — \(why)"
    }
  }

  /// The explicit port, or the scheme's default (443 for https, else 80).
  private static func defaultPort(_ url: URL) -> Int {
    if let port = url.port { return port }
    return (url.scheme?.lowercased() == "https") ? 443 : 80
  }

  static func durationText(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(sec)s" }
    return "\(sec)s"
  }

  private static func countsLine(_ counts: StatusCounts) -> NSAttributedString {
    let line = NSMutableAttributedString()
    line.append(plain("\(counts.total) panes · \(counts.agents) agents   "))
    for status in TrayStatus.allCases where status != .unreachable {
      let n = counts[status]
      guard n > 0 else { continue }
      line.append(glyphRun(status))
      line.append(plain("\(n) "))
    }
    return line
  }

  // MARK: - Attributed runs
  //
  // Colours come from TrayStatus.nsColor (the seam's palette) for glyphs only.
  // Text uses .labelColor / .secondaryLabelColor so it follows the system
  // appearance — never a hardcoded black or white.

  private static func glyphRun(_ status: TrayStatus) -> NSAttributedString {
    NSAttributedString(
      string: status.glyph,
      attributes: [
        .foregroundColor: status.nsColor,
        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
      ])
  }

  private static func plain(_ text: String) -> NSAttributedString {
    NSAttributedString(
      string: text,
      attributes: [
        .foregroundColor: NSColor.labelColor,
        .font: NSFont.menuFont(ofSize: 0),
      ])
  }

  private static func bold(_ text: String) -> NSAttributedString {
    NSAttributedString(
      string: text,
      attributes: [
        .foregroundColor: NSColor.labelColor,
        .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
      ])
  }

  private static func secondary(_ text: String) -> NSAttributedString {
    NSAttributedString(
      string: text,
      attributes: [
        .foregroundColor: NSColor.secondaryLabelColor,
        .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
      ])
  }

  private static func sectionTitle(_ text: String) -> NSAttributedString {
    NSAttributedString(
      string: text,
      attributes: [
        .foregroundColor: NSColor.tertiaryLabelColor,
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
      ])
  }

  private static func coloured(_ text: String, _ colour: NSColor) -> NSAttributedString {
    NSAttributedString(
      string: text,
      attributes: [.foregroundColor: colour, .font: NSFont.menuFont(ofSize: 0)])
  }

  private static func disabled(_ title: NSAttributedString) -> NSMenuItem {
    let item = NSMenuItem()
    item.attributedTitle = title
    item.isEnabled = false
    return item
  }

  private static func indentedNote(_ text: String) -> NSMenuItem {
    let item = disabled(secondary(text))
    item.indentationLevel = 1
    return item
  }
}
