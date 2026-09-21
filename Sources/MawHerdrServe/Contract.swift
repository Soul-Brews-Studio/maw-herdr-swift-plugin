import Foundation
import Network

// The seam between modules. Every file in this target codes against these
// declarations and nothing else, so the modules can be written in parallel and
// still compile together. Shapes mirror the Bun server's `types.ts` and
// `mod.readRoster.ts` field for field — the JSON a dashboard receives must be
// indistinguishable between the two servers.

// MARK: - Roster (what /api/sessions returns)

/// One tmux-like pane as the dashboard sees it. Key order matters for parity:
/// `index, name, active, cwd?, status, agent?` — `cwd` and `agent` are omitted
/// entirely (not null) when absent, exactly as `mod.readRoster.ts` builds them.
struct Window: Codable, Equatable, Sendable {
  var index: Int
  var name: String
  var active: Bool
  var cwd: String?
  var status: String
  var agent: String?

  enum CodingKeys: String, CodingKey { case index, name, active, cwd, status, agent }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(index, forKey: .index)
    try container.encode(name, forKey: .name)
    try container.encode(active, forKey: .active)
    if let cwd, !cwd.isEmpty { try container.encode(cwd, forKey: .cwd) }
    try container.encode(status, forKey: .status)
    if let agent, !agent.trimmingCharacters(in: .whitespaces).isEmpty {
      try container.encode(agent.trimmingCharacters(in: .whitespaces), forKey: .agent)
    }
  }
}

/// `name` is `base64url(serverName) + "/" + base64url(workspaceId)` — opaque
/// on purpose, so a jump can never land on the wrong pane when two workspaces
/// share a label. `source` is always "local" here.
struct Session: Codable, Equatable, Sendable {
  var name: String
  var source: String = "local"
  var windows: [Window]
}

/// The raw pane behind a window, kept for addressing writes.
struct Pane: Sendable {
  var workspaceLabel: String?
  var id: String          // herdr pane id, e.g. "wD:p4"
  var workspace: String   // herdr workspace id, e.g. "wD"
  var agent: String
  var label: String
  var title: String
  var cwd: String
  var focused: Bool
  var status: String      // idle | working | blocked | done | unknown
}

struct Target: Sendable {
  var session: String     // herdr server name, e.g. "default"
  var pane: Pane
}

struct Roster: Sendable {
  var runningSessions: [String]
  var sessions: [Session]
  /// Keyed by dashboard target `"<session.name>:<window.index>"`.
  var targets: [String: Target]
}

// MARK: - Backend (the herdr process behind everything)

enum BackendError: Error, Sendable {
  /// herdr is not installed, not running, timed out, or returned garbage.
  case unavailable(String)
  /// A target the dashboard named does not exist.
  case unknownTarget(String)
}

/// Implemented by `HerdrProcessBackend` in Backend.swift by shelling out to the
/// `herdr` binary — no shell, stdout only, 10s timeout, 4 MiB output cap —
/// exactly as `mod.runHerdr.ts` does.
protocol HerdrBackend: AnyObject, Sendable {
  /// The whole roster: `herdr session list --json`, then
  /// `herdr --session <name> api snapshot` for each running session.
  func roster() async throws -> Roster
  /// Visible text of one pane: `pane read <id> --source visible --lines N --format text`.
  func capture(target: String, lines: Int) async throws -> String
  /// Several panes at once, each with its own line count; missing targets are
  /// simply absent from the result rather than an error.
  func captureBatch(_ requests: [String: Int]) async throws -> [String: String]
  /// Type into a pane: `pane send-text <id> <text>` then `pane send-keys <id> enter`.
  func send(target: String, text: String) async throws
  /// Wake a pane: `agent start <name> --kind <engine> --pane <id> --timeout 8000`.
  func wake(target: String, engine: String) async throws
}

// MARK: - WebSocket (live streaming)

/// Implemented by `WebSocketServer` in WebSocket.swift. The HTTP server owns
/// the handshake — it validates the ticket or the tokenless demo case and
/// writes the 101 itself — then hands the raw connection here. This module
/// owns RFC 6455 framing and the session protocol from then on.
protocol WebSocketService: AnyObject, Sendable {
  /// Live socket count, for the 32-connection cap enforced before upgrade.
  var activeCount: Int { get }
  /// Take over `connection` after the 101 has been written. `leftover` is any
  /// bytes already read past the end of the HTTP request (a client may send its
  /// first frame in the same packet). `readOnly` gates wake/send.
  func attach(connection: NWConnection, path: String, readOnly: Bool, leftover: Data)
}

// MARK: - Access log

struct AccessEntry: Sendable {
  var ip: String
  var method: String
  var path: String        // pathname only, never the raw query
  var query: [String: String]  // parsed query; the logger scrubs it
  var status: Int
  var bytes: Int?
  var milliseconds: Double
  var origin: String
  var note: String?
}

// MARK: - Constants shared by both sides of the protocol

enum Protocol {
  static let webSocket = "maw.ws.v1"
  static let ticketPrefix = "mwt1_"
  static let herdrSnapshotVersion = 22
  static let maxRequestBody = 257 << 10
  static let maxInFlightRequests = 64
  static let maxSockets = 32
  static let maxPreviews = 16
  static let selectedLines = 80
  static let previewLines = 15
  static let socketPollMilliseconds = 1000
  static let ticketLifetimeSeconds = 60
  static let paneStatuses: Set<String> = ["idle", "working", "blocked", "done", "unknown"]
  static let wakeEngines: Set<String> = [
    "pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline", "omp", "mastracode",
    "opencode", "copilot", "kimi", "kiro", "droid", "amp", "grok", "hermes", "kilo", "qodercli",
    "qwen", "maki", "muse",
  ]
}
