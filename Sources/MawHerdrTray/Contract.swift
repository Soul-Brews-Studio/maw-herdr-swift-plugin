import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// maw-herdr-tray — the seam.
//
// Every file in this target codes against these declarations and nothing else,
// so the API client, the UI and the lifecycle controller can be written in
// parallel and still compile together.
//
// This target does NOT import MawHerdrServe. The server's Contract.swift was
// read, never linked: a client that shares the server's structs cannot detect a
// server that emits the wrong JSON. Every wire type below was instead derived
// from a payload curled off a LIVE server on 2026-09-22:
//
//   http://127.0.0.1:3467  (--insecure-no-token, read-only demo, node m5-beta)
//   version "herdr-core-dev", runtime "swift", 20 sessions / 34 panes
//
// Each type carries the measured evidence it came from. When a field is
// optional here it is because the live payload omitted it, not because it
// looked safer.
//
// CONCURRENCY RULE, stated once so no module has to guess:
//   * wire types and FleetSnapshot are `Sendable` value types — they are built
//     on whatever thread URLSession answered on and handed across.
//   * anything that touches NSStatusItem / NSMenu / NSColor is `@MainActor`.
//   * the delivery boundary is `AsyncStream<FleetSnapshot>`; the UI consumes it
//     inside `Task { @MainActor in for await s in monitor.snapshots { … } }`.
// FleetSnapshot is deliberately NOT @MainActor: it is produced off the main
// actor by the API client, and a @MainActor value type could not be built
// there. Isolation lives on the consumers, which is where AppKit lives.
//
// READ-ONLY. This target has no send/wake/prompt surface and must never grow
// one: the fleet it watches is real, other people's agents are in it.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Configuration

/// The only place a port, an interval or a token path is written down.
/// Nothing else in this target may hardcode `3467`.
struct TrayConfig: Sendable, Equatable {
  /// Where `maw herdr serve` is answering. Measured default: the read-only
  /// demo on `http://127.0.0.1:3467`.
  var baseURL: URL
  /// How often the monitor refreshes. The server's own socket poll is
  /// `Protocol.socketPollMilliseconds = 1000`; 3s is polite for a menu bar and
  /// still feels live. Never below 1s — each refresh costs the server a full
  /// `herdr` subprocess roster read.
  var pollInterval: TimeInterval
  /// Per-request timeout. The server caps its own herdr calls at 10s.
  var requestTimeout: TimeInterval
  /// Optional path to a token file (`--token-file` on the server side). When
  /// set, the client reads it and sends `Authorization: Bearer <token>`.
  /// The value is NEVER printed, logged, or put in an error string.
  var tokenFilePath: String?
  /// Lines of pane text to ask `/api/capture` for when previewing. The server
  /// ignores the request count and always reads 200 (HTTPServer.swift:858);
  /// this is the tray's own truncation budget.
  var captureLines: Int
  /// Where a human-facing dashboard lives, when one exists. MEASURED
  /// 2026-09-22 against herdr-core-dev: this server serves NO HTML — `/`,
  /// `/dashboard` and `/index.html` are all 404, and `/api/identity` is the
  /// only route a browser can usefully render. So this is nil by default and
  /// `browseURL` falls back to that identity route; a deployment that does
  /// front a dashboard sets MAW_HERDR_DASHBOARD_URL.
  var dashboardURL: URL?

  static let standard = TrayConfig(
    baseURL: URL(string: "http://127.0.0.1:3467")!,
    pollInterval: 3.0,
    requestTimeout: 8.0,
    tokenFilePath: nil,
    captureLines: 40,
    dashboardURL: nil
  )

  /// `TrayConfig.standard`, overridden by environment so the app can be pointed
  /// at another node without a rebuild:
  ///   MAW_HERDR_URL, MAW_HERDR_POLL_SECONDS, MAW_HERDR_TOKEN_FILE
  static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment)
    -> TrayConfig
  {
    var config = TrayConfig.standard
    // Validated once, HERE, so `endpoint()` and LiveSocket.makeRequest never
    // meet a URL they cannot compose: require an http/https scheme, a host,
    // and a body URLComponents also accepts. A rejected value falls back to
    // the standard loopback URL and says so on stderr, naming the VARIABLE —
    // the value is echoed too, which is safe: this one is a server address,
    // never a credential.
    if let raw = env["MAW_HERDR_URL"] {
      if let url = Self.validated(raw) {
        config.baseURL = url
      } else {
        FileHandle.standardError.write(
          Data(
            """
            maw-herdr-tray: ignoring MAW_HERDR_URL=\(raw) — need an http/https URL with a host.
              MAW_HERDR_URL=\(TrayConfig.standard.baseURL.absoluteString) swift run maw-herdr-tray

            """.utf8))
      }
    }
    if let raw = env["MAW_HERDR_POLL_SECONDS"], let seconds = Double(raw), seconds >= 1 {
      config.pollInterval = seconds
    }
    if let path = env["MAW_HERDR_TOKEN_FILE"], !path.isEmpty { config.tokenFilePath = path }
    if let raw = env["MAW_HERDR_DASHBOARD_URL"], let url = Self.validated(raw) {
      config.dashboardURL = url
    }
    return config
  }

  /// An absolute http/https URL with a host that `URLComponents` also accepts.
  /// nil for anything else — including the strings `URL(string:)` happily
  /// builds and `URLComponents(url:)` then refuses.
  static func validated(_ raw: String) -> URL? {
    guard let url = URL(string: raw),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.url != nil
    else { return nil }
    return url
  }

  /// True when `baseURL` points at this machine. The token auto-adoption in
  /// main.swift and any future credential default are gated on this: an
  /// operator token belongs to the local node and must never be sent to a
  /// remote host just because MAW_HERDR_URL was pointed at one.
  var isLoopback: Bool {
    guard let host = baseURL.host?.lowercased() else { return false }
    return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
  }

  /// What "open in browser" should actually open. MEASURED: `/` is 404 on this
  /// server, so opening `baseURL` hands the user an error page. `/api/identity`
  /// is 200 JSON and answers the question the menu item is really asking —
  /// "is this thing alive, and which build is it?".
  var browseURL: URL { dashboardURL ?? endpoint("/api/identity") }

  /// Label for that item, so it never promises a dashboard that is not there.
  var browseLabel: String {
    dashboardURL == nil ? "Open /api/identity in browser" : "Open dashboard in browser"
  }

  /// Absolute URL for an API path, e.g. `endpoint("/api/sessions")`.
  ///
  /// No force-unwrap. `baseURL` can come from MAW_HERDR_URL, and `URL(string:)`
  /// accepts strings `URLComponents(url:)` rejects — that pair of `!` was a
  /// launch-time crash reachable from an environment variable. `fromEnvironment`
  /// now rejects a URL without an http/https scheme and a host before it ever
  /// gets here, and this is the second belt: an un-composable URL degrades to
  /// `baseURL` itself, which the client then reports as unreachable.
  func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return baseURL
    }
    components.path = path
    components.queryItems = query.isEmpty ? nil : query
    return components.url ?? baseURL
  }

  /// The token itself, read fresh from disk. Returns nil when no token file is
  /// configured. Throws `TrayError.tokenUnreadable` when one is configured and
  /// cannot be read — the thrown error names the PATH, never the contents.
  func readToken() throws -> String? {
    guard let tokenFilePath, !tokenFilePath.isEmpty else { return nil }
    let expanded = (tokenFilePath as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: expanded),
      let text = String(data: data, encoding: .utf8)
    else { throw TrayError.tokenUnreadable(path: expanded) }
    let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
  }
}

// MARK: - Wire types (decoded straight off the live server)

/// One pane, from an element of `/api/sessions[].windows[]`.
///
/// MEASURED 2026-09-22, 34 windows over 20 sessions:
///   index   Int     present 34/34, always a NUMBER
///   name    String  present 34/34   ("claude", "codex", "wM:p5", "serve", …)
///   active  Bool    present 34/34
///   cwd     String  present 34/34, but the server OMITS the key when the path
///                   is empty (server Contract.swift encodes conditionally) —
///                   optional here on the server's word, not on the sample's.
///   status  String  present 34/34, one of done | idle | unknown | working.
///                   The server's full vocabulary also contains "blocked"
///                   (Protocol.paneStatuses), unseen in this sample.
///   agent   String  present 20/34, OMITTED (never null) for the other 14 —
///                   values "claude" | "codex".
/// The key is absent, so `decodeIfPresent` is correct and a `null` check alone
/// would not have been.
///
/// CROSSTAB, same sample: status == "unknown" ⟺ agent absent, 14/14 both ways.
/// Do not rely on it as an invariant — treat "a pane with no agent" as the
/// primary fact and let `status` be whatever the server says.
struct HerdrWindow: Decodable, Sendable, Hashable, Identifiable {
  var index: Int
  var name: String
  var active: Bool
  var cwd: String?
  var status: PaneStatus
  var agent: String?

  var id: Int { index }

  enum CodingKeys: String, CodingKey { case index, name, active, cwd, status, agent }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    index = try c.decode(Int.self, forKey: .index)
    name = try c.decode(String.self, forKey: .name)
    active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
    cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
    status = try c.decodeIfPresent(PaneStatus.self, forKey: .status) ?? .unknown
    agent = try c.decodeIfPresent(String.self, forKey: .agent)
  }

  init(index: Int, name: String, active: Bool, cwd: String?, status: PaneStatus, agent: String?) {
    self.index = index
    self.name = name
    self.active = active
    self.cwd = cwd
    self.status = status
    self.agent = agent
  }
}

/// The server's pane-status vocabulary, `Protocol.paneStatuses` on the server
/// side: idle | working | blocked | done | unknown. Decoding is lenient — any
/// string the server adds later lands on `.unknown` instead of failing the
/// whole refresh.
enum PaneStatus: String, Decodable, Sendable, Hashable, CaseIterable {
  case idle, working, blocked, done, unknown

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = PaneStatus(rawValue: raw) ?? .unknown
  }
}

/// One session, from an element of `/api/sessions`.
///
/// MEASURED: `/api/sessions` is a TOP-LEVEL ARRAY (`jq type` → "array",
/// length 20), never an object with a "sessions" key.
///   name     String   present 20/20, e.g. "ZGVmYXVsdA/d0Q"
///   source   String   present 20/20, always "local" in this sample
///   windows  [Window] present 20/20, 1–6 entries
///
/// `name` is `base64url(serverName) + "/" + base64url(workspaceId)` and is the
/// opaque addressing key — never parse it for meaning, only for display.
/// VERIFIED against this payload: "ZGVmYXVsdA/d0Q" decodes to "default/wD",
/// and that session's panes are named "wD:pW". Same for d00 → wM.
struct HerdrSession: Decodable, Sendable, Hashable, Identifiable {
  var name: String
  var source: String?
  var windows: [HerdrWindow]

  var id: String { name }

  enum CodingKeys: String, CodingKey { case name, source, windows }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    source = try c.decodeIfPresent(String.self, forKey: .source)
    windows = try c.decodeIfPresent([HerdrWindow].self, forKey: .windows) ?? []
  }

  init(name: String, source: String?, windows: [HerdrWindow]) {
    self.name = name
    self.source = source
    self.windows = windows
  }

  /// "default/wD" for "ZGVmYXVsdA/d0Q". Falls back to the raw name whenever a
  /// half does not decode — display only, never for addressing.
  var displayName: String {
    let halves = name.split(separator: "/", omittingEmptySubsequences: false)
    let decoded = halves.map { Self.base64URLDecode(String($0)) ?? String($0) }
    return decoded.joined(separator: "/")
  }

  static func base64URLDecode(_ input: String) -> String? {
    var s = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    guard let data = Data(base64Encoded: s), let text = String(data: data, encoding: .utf8),
      !text.isEmpty
    else { return nil }
    return text
  }
}

/// One row of `/api/agents` → `agents[]`.
///
/// MEASURED: `/api/agents` is an OBJECT — keys `agents`, `count`, `node`;
/// `count` 34 matched `agents | length` 34.
///   node     String  present 34/34, "m5-beta"
///   session  String  present 34/34, the same opaque session name
///   window   String  present 34/34 — a STRINGIFIED Int ("4"), unlike
///                    `/api/sessions[].windows[].index` which is a real Int.
///   oracle   String  present 34/34 — this is the PANE NAME, not the agent
///                    kind: it carries values like "wM:p5" for agentless panes.
///   state    String  present 34/34, only "active" | "idle" in this sample.
///   pid      Int?    NULL 34/34 — never once populated. Decode it, do not
///                    render it.
///
/// LOSSY BY CONSTRUCTION: the server builds this endpoint from the same roster
/// as `/api/sessions` and collapses status with
/// `window.status == "working" ? "active" : "idle"` (HTTPServer.swift:849), so
/// `done`, `blocked` and `unknown` all arrive here as "idle" and agentless
/// panes are counted as agents. THE TRAY MUST BUILD ITS COUNTS FROM
/// `/api/sessions`. This type exists to render the server's own agent view and
/// to cross-check the roster, not to drive the glyphs.
struct HerdrAgentRow: Decodable, Sendable, Hashable {
  var node: String?
  var session: String
  var window: String
  var oracle: String?
  var state: String
  var pid: Int?
}

/// The `/api/agents` envelope. `count` and `node` are present in the sample but
/// optional here because the tray never needs them to render.
struct HerdrAgentsEnvelope: Decodable, Sendable {
  var agents: [HerdrAgentRow]
  var count: Int?
  var node: String?
}

/// `/api/identity`.
///
/// MEASURED, every key present:
///   version "herdr-core-dev" · runtime "swift" · node "m5-beta"
///   host "localhost" · uptime 203 (Int seconds) · clockUtc "2026-09-22T04:45:35Z"
///   endpoints ["/api/sessions","/api/capture","/api/send","/api/wake","/ws","/ws/pty"]
///   capabilities ["sessions","capture","agent-prompt","dashboard-ws",
///                 "terminal-stream","existing-pane-wake"]
/// The body also carries `"agents": []` — hardcoded empty on the server
/// (HTTPServer.swift:890) with no element ever produced, so its element type is
/// unknowable from the wire and the key is deliberately NOT modelled here.
/// `runtime` distinguishes this Swift server from the Bun reference; show it.
struct HerdrIdentity: Decodable, Sendable, Hashable {
  var version: String
  var runtime: String
  var node: String
  var host: String?
  var uptime: Int?
  var clockUtc: String?
  var endpoints: [String]
  var capabilities: [String]

  enum CodingKeys: String, CodingKey {
    case version, runtime, node, host, uptime, clockUtc, endpoints, capabilities
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decodeIfPresent(String.self, forKey: .version) ?? "unknown"
    runtime = try c.decodeIfPresent(String.self, forKey: .runtime) ?? "unknown"
    node = try c.decodeIfPresent(String.self, forKey: .node) ?? "unknown"
    host = try c.decodeIfPresent(String.self, forKey: .host)
    uptime = try c.decodeIfPresent(Int.self, forKey: .uptime)
    clockUtc = try c.decodeIfPresent(String.self, forKey: .clockUtc)
    endpoints = try c.decodeIfPresent([String].self, forKey: .endpoints) ?? []
    capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
  }

  init(
    version: String, runtime: String, node: String, host: String?, uptime: Int?,
    clockUtc: String?, endpoints: [String], capabilities: [String]
  ) {
    self.version = version
    self.runtime = runtime
    self.node = node
    self.host = host
    self.uptime = uptime
    self.clockUtc = clockUtc
    self.endpoints = endpoints
    self.capabilities = capabilities
  }
}

/// `/api/capture?target=<session-name>:<index>`.
///
/// MEASURED — the target separator is a COLON, not a slash:
///   target=ZGVmYXVsdA/dzRC:1  → 200, {"content":"…", "target", "resolvedTarget"}
///   target=ZGVmYXVsdA/dzRC/3  → 400, {"content":"", "target", "resolvedTarget",
///                                     "error":"capture_unavailable"}
///   no target at all          → 400, {"error":"target_required"}
/// The 400 failure body carries the SAME four keys, so decode this type on both
/// paths and branch on `error`. Use `FleetPane.target` to build the string.
struct HerdrCapture: Decodable, Sendable {
  var content: String
  var target: String?
  var resolvedTarget: String?
  var error: String?
}

/// Every non-2xx body the server emits is `{"error":"<code>"}` — measured
/// `target_required` (400) and `not_found` (404).
struct HerdrErrorBody: Decodable, Sendable {
  var error: String
}

// MARK: - Errors

enum TrayError: Error, Sendable, Equatable {
  /// No TCP answer, DNS failure, timeout — the server is not up.
  case unreachable(String)
  /// HTTP answered, status was not 2xx. `code` is the server's `error` field
  /// when the body carried one.
  case httpStatus(Int, code: String?)
  /// 2xx, but the body did not decode into the expected shape. Carries the
  /// decoding description and the path — never the raw body (it can contain
  /// pane text from another person's session).
  case malformedBody(path: String, detail: String)
  /// A token file was configured and could not be read. Names the PATH only.
  /// NEVER construct this or any other case with a token value inside.
  case tokenUnreadable(path: String)
  /// The lifecycle controller could not start or stop the server.
  case lifecycle(String)

  /// One short line, safe to put in a menu item. Guaranteed token-free.
  var displayText: String {
    switch self {
    case .unreachable(let why): return "server unreachable — \(why)"
    case .httpStatus(let status, let code):
      return code.map { "HTTP \(status) — \($0)" } ?? "HTTP \(status)"
    case .malformedBody(let path, let detail): return "bad body from \(path) — \(detail)"
    case .tokenUnreadable(let path): return "token file unreadable: \(path)"
    case .lifecycle(let why): return "server control failed — \(why)"
    }
  }

  /// The server answered and refused the credential. 401 is what a token-mode
  /// server returns for EVERY route including /api/health (ServerControl.swift
  /// measured it on 127.0.0.1:3479), so it means "up, but not for us" — not
  /// "down".
  var isAuthDenied: Bool {
    if case .httpStatus(let status, _) = self { return status == 401 || status == 403 }
    if case .tokenUnreadable = self { return true }
    return false
  }
}

// MARK: - Status vocabulary, glyphs and colors — ONE place

/// What the tray renders for a pane. Derived, not decoded: `PaneStatus` is the
/// server's word, `TrayStatus` is the tray's rendering of it plus two states the
/// wire has no name for (`noAgent`, `unreachable`).
///
/// Glyphs follow Nat's convention used elsewhere in the fleet:
///   ✳ idle   ◐ working   ✓ done
enum TrayStatus: String, Sendable, Hashable, CaseIterable {
  case working
  case idle
  case done
  case blocked
  /// A pane with no agent in it — a plain shell. `agent` key absent.
  case noAgent
  /// Not a pane state: the server itself did not answer.
  case unreachable

  /// Map a decoded pane onto what the tray shows. A pane with no agent reads as
  /// `.noAgent` regardless of the status string, because "idle shell" and "idle
  /// agent" are different things to a human scanning the menu.
  static func of(_ window: HerdrWindow) -> TrayStatus {
    let hasAgent = !(window.agent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasAgent else { return .noAgent }
    switch window.status {
    case .working: return .working
    case .idle: return .idle
    case .done: return .done
    case .blocked: return .blocked
    // Agent PRESENT, status the server cannot name. Folded into `.idle`, not
    // `.noAgent`: the rest of the tray reads `.noAgent` as "bare shell", so
    // returning it here drew a real agent as a "·" and dropped it from
    // `StatusCounts.agents` and from the menu-bar title — the opposite of the
    // rule three lines above. Measured on the live fleet 2026-09-22 this
    // combination does not occur (all 15 `unknown` panes have no agent), so
    // this changes no rendering today; it removes a latent miscount.
    case .unknown: return .idle
    }
  }

  /// The single-character marker. Monospaced-friendly, no emoji, no variation
  /// selectors — these sit in an NSMenu and in the status-item title.
  var glyph: String {
    switch self {
    case .working: return "◐"
    case .idle: return "✳"
    case .done: return "✓"
    case .blocked: return "⊘"
    case .noAgent: return "·"
    case .unreachable: return "⚠"
    }
  }

  /// Human label for menu text and tooltips.
  var label: String {
    switch self {
    case .working: return "working"
    case .idle: return "idle"
    case .done: return "done"
    case .blocked: return "blocked"
    case .noAgent: return "no agent"
    case .unreachable: return "unreachable"
    }
  }

  /// Sort order for the menu and for the count row: busiest first.
  var rank: Int {
    switch self {
    case .working: return 0
    case .blocked: return 1
    case .idle: return 2
    case .done: return 3
    case .noAgent: return 4
    case .unreachable: return 5
    }
  }

  /// The statuses that get a number in the menu-bar title, in display order.
  /// `noAgent` is excluded on purpose — 14 of 34 measured panes are bare shells
  /// and a "14" in the menu bar would drown the three that matter.
  static let summarised: [TrayStatus] = [.working, .idle, .done, .blocked]

  /// Color as plain components so the value stays `Sendable` and can be built
  /// off the main actor. Use `nsColor` at the AppKit boundary.
  /// Neo's palette: working = Material Blue 300 (#64b5f6).
  var rgb: RGB {
    switch self {
    case .working: return RGB(0x64, 0xB5, 0xF6)  // #64b5f6
    case .idle: return RGB(0x9E, 0x9E, 0x9E)  // #9e9e9e
    case .done: return RGB(0x66, 0xBB, 0x6A)  // #66bb6a
    case .blocked: return RGB(0xFF, 0xA7, 0x26)  // #ffa726
    case .noAgent: return RGB(0x75, 0x75, 0x75)  // #757575 — dimmest legible
    case .unreachable: return RGB(0xEF, 0x53, 0x50)  // #ef5350
    }
  }
}

/// 8-bit sRGB triple. Sendable so a snapshot can carry colors across actors.
struct RGB: Sendable, Hashable {
  var r: UInt8
  var g: UInt8
  var b: UInt8
  init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
    self.r = r
    self.g = g
    self.b = b
  }
}

@MainActor
extension RGB {
  var nsColor: NSColor {
    NSColor(
      srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
  }
}

@MainActor
extension TrayStatus {
  /// AppKit color. Main-actor only — NSColor is not Sendable.
  var nsColor: NSColor { rgb.nsColor }
}

// MARK: - FleetSnapshot — the ONLY thing the UI renders

/// Counts by tray status. `total` is every pane, agent or not.
struct StatusCounts: Sendable, Hashable {
  var working: Int = 0
  var idle: Int = 0
  var done: Int = 0
  var blocked: Int = 0
  var noAgent: Int = 0

  var total: Int { working + idle + done + blocked + noAgent }
  /// Panes that actually hold an agent — the number a human means by
  /// "how many agents".
  var agents: Int { working + idle + done + blocked }

  subscript(status: TrayStatus) -> Int {
    get {
      switch status {
      case .working: return working
      case .idle: return idle
      case .done: return done
      case .blocked: return blocked
      case .noAgent: return noAgent
      case .unreachable: return 0
      }
    }
    set {
      switch status {
      case .working: working = newValue
      case .idle: idle = newValue
      case .done: done = newValue
      case .blocked: blocked = newValue
      case .noAgent: noAgent = newValue
      case .unreachable: break
      }
    }
  }

  mutating func add(_ status: TrayStatus) { self[status] += 1 }

  /// "◐3 ✳14 ✓3" — zero-count statuses are dropped. Empty string when nothing
  /// holds an agent at all.
  var compactTitle: String {
    TrayStatus.summarised
      .filter { self[$0] > 0 }
      .map { "\($0.glyph)\(self[$0])" }
      .joined(separator: " ")
  }
}

/// One pane as the menu renders it.
struct FleetPane: Sendable, Hashable, Identifiable {
  /// `"<session.name>:<index>"` in DECIMAL. Menu identity and tooltip text
  /// only — it is NOT an addressing key. See `captureTarget`.
  var id: String
  /// The session this pane belongs to (opaque server name).
  var sessionName: String
  /// `windows[].index`, the Int form.
  var index: Int
  /// `windows[].name` — "claude", "codex", "serve", or a herdr pane id
  /// like "wM:p5" when the pane was never named.
  var name: String
  /// `windows[].cwd`, absent when the server omitted it.
  var cwd: String?
  /// `windows[].agent` — "claude" | "codex" in the measured sample, nil for a
  /// bare shell.
  var agent: String?
  /// `windows[].active` — the focused pane of its session.
  var active: Bool
  /// What the server called it, unmapped.
  var rawStatus: PaneStatus
  /// What the tray shows.
  var status: TrayStatus
  /// True when another pane of the SAME session was published with this
  /// `index`. The server keys `/api/capture` by the raw pane-id suffix but
  /// publishes only its base-36 value, and two raw suffixes can share one
  /// value ("1" and "01" — Backend.swift:275 sorts exactly that tie). When it
  /// happens `captureTarget` is a guess for both panes; the menu says so in
  /// the tooltip instead of copying a wrong address in silence.
  var addressAmbiguous: Bool = false

  /// `/api/capture?target=` value: `"<session.name>:<BASE-36 index>"`.
  ///
  /// NOT the decimal `id`. MEASURED 2026-09-22 against 127.0.0.1:3467 —
  /// `target=ZGVmYXVsdA/d0Q:26` answers **400 capture_unavailable** while
  /// `target=ZGVmYXVsdA/d0Q:Q` answers **200**. Backend.swift:255-258 says why:
  /// the roster key is `space.name + ":" + <RAW pane-id suffix>`, and the
  /// published `windows[].index` is that suffix's base-36 VALUE
  /// (`Int(suffix, radix: 36)`). Pane "wD:pQ" is published as index 26 and
  /// addressed as ":Q". So every pane with index >= 10 was previously given an
  /// unusable target — which is exactly the string the menu copies.
  ///
  /// Re-encoding uppercase reproduces every observed suffix (10→A, 22→M, 26→Q,
  /// 27→R, 32→W, 34→Y; cross-checked against pane names "wD:pW" and "wV:pY",
  /// and against 200s on :Q :W :Y :R :A :4).
  ///
  /// How far that round-trip is exact was READ OFF herdr's own generator
  /// (herdrdev/herdr src/workspace.rs:105-123, checkout preview-2026-09-08;
  /// installed herdr 0.9.1): a pane id is `<ws>:p` + `encode_public_number(n)`,
  /// bijective and big-endian over the 32-symbol alphabet
  /// `123456789ABCDEFGHJKMNPQRSTVWXYZ0` — no lowercase, no I/L/O/U, and "0" is
  /// the 32nd symbol (weight 32), not a zero digit. So:
  ///   * a lowercase suffix cannot come out of herdr; the server's
  ///     case-insensitive acceptance (Backend.swift:124) never bites;
  ///   * every suffix that does not START with "0" round-trips exactly through
  ///     `Int(_, radix: 36)` and uppercase base-36 — that is every pane up to
  ///     #1024 of one workspace (the 23 local panes measured today are ≤ #34);
  ///   * panes #1025..#1056 encode as "01".."00" and decode to the same Int as
  ///     "1".."0". Only the raw suffix tells them apart, and `/api/sessions`
  ///     does not carry it. Where `name` IS the pane id ("<ws>:p<suffix>") the
  ///     suffix is parsed straight out of it, which is exact; a labelled pane
  ///     that far up is re-encoded without the "0", and `addressAmbiguous`
  ///     flags the half of that a client can see (two panes, one index).
  var captureTarget: String { "\(sessionName):\(Self.addressSuffix(name: name, index: index))" }

  /// The raw base-36 suffix to address this pane by. Prefers the literal
  /// suffix in `name` when the server fell back to the pane id (label, title
  /// and agent all empty → `name == "<workspace>:p<suffix>"`), which is exact;
  /// otherwise re-encodes the index as uppercase base-36.
  static func addressSuffix(name: String, index: Int) -> String {
    if let range = name.range(of: ":p", options: .backwards) {
      let suffix = String(name[range.upperBound...])
      // Same alphabet the server checks with (Backend.swift:124), both cases.
      if !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
        Int(suffix, radix: 36) == index
      {
        return suffix
      }
    }
    return String(index, radix: 36).uppercased()
  }

  /// The repo a human recognises, in at most two segments.
  ///
  /// The old rule took the last two path components, which answered "which
  /// FOLDER" rather than "which REPO": a worktree rendered as
  /// "wt/maw-cli-neo-21sep-mon2026" and a subdir as "tools/fleet-tui", both
  /// hiding the repo they belong to. In a ghq tree (…/github.com/<org>/<repo>/…)
  /// the repo is identifiable, so:
  ///   /opt/Code/github.com/laris-co/neo-oracle            → laris-co/neo-oracle
  ///   …/neo-oracle/wt/maw-cli-neo-21sep-mon2026           → neo-oracle/maw-cli-neo-21sep-mon2026
  ///   …/neo-oracle/wt/neo-herdr-…/tools/fleet-tui         → neo-oracle/fleet-tui
  ///   /Users/beta/.herdr/worktrees/digger-oracle/digger-fork → digger-oracle/digger-fork
  /// The full cwd is always in the item's tooltip; this is the scannable form.
  var shortCwd: String? {
    guard let cwd, !cwd.isEmpty else { return nil }
    let parts = cwd.split(separator: "/").map(String.init)
    guard parts.count >= 2 else { return cwd }
    if let host = parts.firstIndex(where: { Self.forgeHosts.contains($0) }),
      parts.count > host + 2
    {
      let org = parts[host + 1]
      let repo = parts[host + 2]
      // Exactly at the repo root: org/repo. Below it: repo/<leaf>, which drops
      // the uninformative "wt" / "tools" joint.
      if parts.count == host + 3 { return "\(org)/\(repo)" }
      return "\(repo)/\(parts[parts.count - 1])"
    }
    return parts.suffix(2).joined(separator: "/")
  }

  /// Host directories a ghq-style tree puts `<org>/<repo>` under.
  private static let forgeHosts: Set<String> = [
    "github.com", "gitlab.com", "bitbucket.org", "codeberg.org", "git.sr.ht",
  ]

  /// "◐ claude — laris-co/neo-oracle"
  var menuLine: String {
    var line = "\(status.glyph) \(name)"
    if let shortCwd { line += " — \(shortCwd)" }
    return line
  }

  static func from(_ window: HerdrWindow, sessionName: String) -> FleetPane {
    FleetPane(
      id: "\(sessionName):\(window.index)",
      sessionName: sessionName,
      index: window.index,
      name: window.name,
      cwd: window.cwd,
      agent: window.agent,
      active: window.active,
      rawStatus: window.status,
      status: TrayStatus.of(window)
    )
  }
}

/// One session as the menu renders it: a submenu header plus its panes.
struct FleetSession: Sendable, Hashable, Identifiable {
  /// The opaque server name, e.g. "ZGVmYXVsdA/d0Q". Addressing key.
  var id: String
  /// Decoded for humans, e.g. "default/wD".
  var displayName: String
  /// `source` — "local" in every measured row.
  var source: String?
  var panes: [FleetPane]
  var counts: StatusCounts

  /// The busiest status in this session, for the session's own glyph.
  var headlineStatus: TrayStatus {
    panes.map(\.status).min(by: { $0.rank < $1.rank }) ?? .noAgent
  }

  static func from(_ session: HerdrSession) -> FleetSession {
    var panes = session.windows
      .sorted { $0.index < $1.index }
      .map { FleetPane.from($0, sessionName: session.name) }
    // Two windows with one `index` means two raw suffixes collapsed to one
    // value (see `FleetPane.addressAmbiguous`). Never observed on this fleet;
    // flagged rather than assumed away, because the copy action would
    // otherwise hand over a wrong address with no sign that it is one.
    let perIndex = Dictionary(panes.map { ($0.index, 1) }, uniquingKeysWith: +)
    for i in panes.indices where perIndex[panes[i].index, default: 0] > 1 {
      panes[i].addressAmbiguous = true
    }
    var counts = StatusCounts()
    for pane in panes { counts.add(pane.status) }
    return FleetSession(
      id: session.name,
      displayName: session.displayName,
      source: session.source,
      panes: panes,
      counts: counts
    )
  }
}

/// EVERYTHING the UI renders. The UI reads no other type, makes no request of
/// its own, and derives nothing the API client could have derived.
struct FleetSnapshot: Sendable, Hashable {
  /// Did the most recent refresh reach the server at all?
  var reachable: Bool
  /// `/api/identity`, nil when unreachable or when identity failed to decode.
  var identity: HerdrIdentity?
  /// Sessions in server order, each with its panes sorted by index.
  var sessions: [FleetSession]
  /// Fleet-wide counts across every session.
  var counts: StatusCounts
  /// When this snapshot was produced (local clock, `Date()`).
  var updatedAt: Date
  /// Set when the most recent refresh failed; nil when it succeeded. Already
  /// one short, token-free line — put it straight in a menu item.
  var lastError: String?
  /// The server ANSWERED and refused us: 401/403. Distinct from `reachable`,
  /// because "herdr down" and "herdr is up and wants a token" are different
  /// problems with different fixes, and `ServerControl.probe()` already reads a
  /// 401 as `.running(token-protected)` — without this the menu asserted both
  /// at once. Never carries the token or any part of it.
  var authDenied: Bool = false

  /// Nothing seen yet. The UI shows this before the first refresh lands.
  static func initial(now: Date = Date()) -> FleetSnapshot {
    FleetSnapshot(
      reachable: false, identity: nil, sessions: [], counts: StatusCounts(),
      updatedAt: now, lastError: nil)
  }

  /// A failed refresh. Keeps no stale sessions on purpose — a menu showing
  /// yesterday's panes under a red glyph is worse than an empty one.
  static func failure(_ error: TrayError, now: Date = Date()) -> FleetSnapshot {
    FleetSnapshot(
      reachable: false, identity: nil, sessions: [], counts: StatusCounts(),
      updatedAt: now, lastError: error.displayText, authDenied: error.isAuthDenied)
  }

  /// The one projection from wire types to what the UI renders. Pure, so both
  /// the API agent and the UI agent can call it, and a test can call it with a
  /// saved payload. Counts come from `/api/sessions` only — see the note on
  /// `HerdrAgentRow` for why `/api/agents` must not drive them.
  static func build(
    sessions wire: [HerdrSession],
    identity: HerdrIdentity?,
    now: Date = Date(),
    lastError: String? = nil
  ) -> FleetSnapshot {
    let sessions = wire.map(FleetSession.from)
    var counts = StatusCounts()
    for session in sessions {
      for status in TrayStatus.allCases { counts[status] += session.counts[status] }
    }
    return FleetSnapshot(
      reachable: true, identity: identity, sessions: sessions, counts: counts,
      updatedAt: now, lastError: lastError)
  }

  /// What goes in the menu bar. "⚠" when the server is down, otherwise the
  /// compact count row, falling back to a lone "✳ 0" when the fleet is empty.
  var menuBarTitle: String {
    guard reachable else {
      return authDenied
        ? "\(TrayStatus.unreachable.glyph) no token" : TrayStatus.unreachable.glyph
    }
    let title = counts.compactTitle
    return title.isEmpty ? "\(TrayStatus.idle.glyph)0" : title
  }

  /// Every pane across every session, busiest first — for a flat menu.
  var allPanes: [FleetPane] {
    sessions.flatMap(\.panes).sorted {
      $0.status.rank == $1.status.rank ? $0.id < $1.id : $0.status.rank < $1.status.rank
    }
  }
}

// MARK: - The API client

/// Reads the server. Implemented by the API agent in `HerdrClient.swift`.
///
/// Conformers are `Sendable` and actor- or struct-based; every method is async
/// and may be called from any isolation. NONE of these touch AppKit.
/// This protocol is READ-ONLY and must stay that way: no send, no wake, no
/// prompt. `/api/send` and `/api/wake` exist on the server and are off limits.
protocol FleetAPIClient: Sendable {
  var config: TrayConfig { get }

  /// GET /api/identity. Throws `TrayError.unreachable` when the server is down.
  func identity() async throws -> HerdrIdentity
  /// GET /api/sessions — decodes a TOP-LEVEL ARRAY.
  func sessions() async throws -> [HerdrSession]
  /// GET /api/agents — decodes the `{"agents":[…]}` envelope. Diagnostic only;
  /// never the source of the tray's counts.
  func agents() async throws -> HerdrAgentsEnvelope
  /// GET /api/capture?target=<pane.captureTarget>. Returns the body on the 400
  /// path too, with `error` set, because the failure body carries `content`.
  func capture(target: String) async throws -> HerdrCapture

  /// One full refresh. NEVER throws: a failure becomes
  /// `FleetSnapshot.failure(…)` so the UI always has something to render.
  /// Implementations fetch `/api/sessions` and `/api/identity` concurrently.
  func refresh() async -> FleetSnapshot
}

/// Drives `FleetAPIClient.refresh()` on a timer and publishes the results.
/// Implemented by the API agent (an `actor`). The UI codes against this alone.
///
/// Delivery is a single multicast-free `AsyncStream`: `snapshots` is created
/// once by the conformer and yields every snapshot produced after `start()`,
/// including failures. Exactly one consumer is expected (the tray controller).
/// The stream never finishes until `stop()` is called.
protocol FleetMonitor: AnyObject, Sendable {
  var config: TrayConfig { get }
  /// The snapshot stream. Reading it twice is a programmer error; the second
  /// reader gets nothing.
  var snapshots: AsyncStream<FleetSnapshot> { get }
  /// The most recent snapshot, for a menu opening between ticks.
  func latest() async -> FleetSnapshot
  /// Begin polling at `config.pollInterval`. Idempotent.
  func start() async
  /// Stop polling and finish the stream. Idempotent. MUST be called before the
  /// app exits so no URLSession task outlives it.
  func stop() async
  /// Refresh immediately without waiting for the next tick (menu opened,
  /// "Refresh now" clicked). The result arrives on `snapshots` like any other.
  func refreshNow() async
}

/// The UI side of the delivery, for a conformer that prefers a callback to a
/// stream. Main-actor by construction: everything it does ends in an NSMenu.
@MainActor
protocol FleetSnapshotReceiver: AnyObject {
  func fleetDidUpdate(_ snapshot: FleetSnapshot)
}

// MARK: - Server lifecycle

/// What the lifecycle controller believes about the server process.
enum ServerLifecycle: Sendable, Hashable {
  /// Not probed yet.
  case unknown
  /// `/api/identity` answered. Carries what answered, so the menu can show
  /// "herdr-core-dev (swift) on m5-beta".
  case running(version: String, runtime: String, node: String)
  /// Nothing is answering `config.baseURL`.
  case stopped
  /// A start or stop attempt failed; the string is safe to display.
  case failed(String)

  var isRunning: Bool { if case .running = self { return true } else { return false } }
}

/// Start/stop the local `maw herdr serve` behind the tray. Implemented by the
/// lifecycle agent. `@MainActor` is NOT applied: this shells out and waits, so
/// it must stay off the main thread; its results reach the UI as
/// `ServerLifecycle` values.
///
/// SAFETY, non-negotiable: `stop()` may only terminate a process THIS app
/// started, tracked by pid from `start()`. It must never pkill by name, never
/// kill a server it merely found listening, and never touch a herdr pane. This
/// machine runs a real fleet; another session's server is not ours to stop.
protocol ServerLifecycleController: AnyObject, Sendable {
  var config: TrayConfig { get }
  /// Ask the server, do not guess from a pidfile: GET /api/identity with a
  /// short timeout. Never throws — an unreachable server is `.stopped`.
  func probe() async -> ServerLifecycle
  /// Launch the server if we are not already running one. Returns the state it
  /// reached, `.failed` with a displayable reason if it could not.
  /// Returns `.running` unchanged when `probe()` already says something is
  /// answering — it must NOT start a second server on a taken port.
  func start() async -> ServerLifecycle
  /// Terminate the process this controller started (SIGTERM, then SIGKILL on a
  /// timeout). A no-op returning `.stopped` when we started nothing.
  func stop() async -> ServerLifecycle
  /// True only when the running server was launched by this app — the menu
  /// enables "Stop server" on this and nothing else.
  func ownsRunningServer() async -> Bool
}
