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
    // JS `String.prototype.trim()` strips line terminators as well as spaces,
    // so `.whitespaces` (which does not contain \n, \r, \t) is not the same
    // predicate. `.whitespacesAndNewlines` is.
    if let agent, !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try container.encode(agent.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .agent)
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
  /// The pane exists but holds no agent, so `agent prompt` cannot be used on
  /// it. Bun's `target_not_agent`; the HTTP layer answers 409.
  case notAgent(String)
}

/// Bun's `HTTPError`, thrown from inside the backend by the config, team and
/// state readers (`config_unavailable`, `teams_unavailable`, …). The HTTP layer
/// answers with exactly this status and `{"error": code}`; the socket layer
/// treats it as any other backend failure.
struct HTTPStatusError: Error, Sendable {
  let status: Int
  let code: String
}

/// What `/api/wake` reports. Bun's `wake()` returns exactly these three
/// strings: `ready` after `agent start` verified readiness, `already-awake`
/// when the pane already held an agent, `launched` when a configured launch
/// line was submitted and a foreground process was observed.
enum WakeState: String, Sendable {
  case ready = "ready"
  case alreadyAwake = "already-awake"
  case launched = "launched"
}

/// A live `herdr terminal session control` stream behind `/ws/pty`.
protocol HerdrTerminal: AnyObject, Sendable {
  func input(_ bytes: Data) throws
  func resize(cols: Int, rows: Int) throws
  func close()
  /// Resolves when the herdr child has exited — Bun's `done` promise.
  func waitDone() async
}

/// Implemented by `HerdrProcessBackend` in Backend.swift by shelling out to the
/// `herdr` binary — no shell, stdout only, 10s timeout, 4 MiB output cap —
/// exactly as `mod.runHerdr.ts` does. The wake engine (`--wake-engine`) is fixed
/// when the backend is built, as `createHerdrBackend(binary, wakeEngine)` does.
protocol HerdrBackend: AnyObject, Sendable {
  /// The whole roster: `herdr session list --json`, then
  /// `herdr --session <name> api snapshot` for each running session.
  func roster() async throws -> Roster
  /// `dashboardSessions`: the same read, but one acquisition shared by every
  /// socket client asking at once, and observed by `observedFeed` — so an
  /// older roster can never publish a status after a newer one.
  func dashboardSessions() async throws -> [Session]
  /// Status-projection feed (`mod.createObservedFeed.ts`), fed by
  /// `dashboardSessions` and read by the socket's `feed-history` / `feed`.
  var observedFeed: ObservedFeed { get }
  /// `~/.claude/teams` inventory, the `teams` frame and `/api/teams` body.
  func teamInventory() throws -> JSONValue
  /// Visible text of one pane: `pane read <id> --source visible --lines N --format text`.
  func capture(target: String, lines: Int) async throws -> String
  /// Several panes at once, each with its own line count. Any key that is not
  /// in the roster fails the WHOLE batch with `unknownTarget` — Bun checks
  /// every key before it reads a single pane.
  func captureBatch(_ requests: [String: Int]) async throws -> [String: String]
  /// Prompt an agent pane: `agent prompt <id> <text>`. Rejects blank text and
  /// panes with no agent. This is what REST `/api/send` uses.
  func send(target: String, text: String) async throws
  /// Type into any pane: `pane send-text <id> <text>`, followed by
  /// `pane send-keys <id> enter` ONLY when `enter` is true. This is what the
  /// socket `send` command uses, with `enter` = the client's `force` flag —
  /// so the default types the text and leaves it unsubmitted.
  func sendLiteral(target: String, text: String, enter: Bool) async throws
  /// Wake a pane or a registered repository: an existing agent is left alone
  /// (`alreadyAwake`); a configured launch line is submitted (`launched`);
  /// otherwise `agent start <name> --kind <engine> --pane <id> --timeout 8000`
  /// (`ready`). `task` materialises an `agents/<slug>` worktree first. Every
  /// success re-verifies the pane, registers the fleet file and runs the
  /// configured `hooks.postWake`.
  func wake(target: String, task: String?) async throws -> WakeState
  /// `--inbox` delivery: writes `ψ/inbox/<stamp>_<from>_<slug>.md` under the
  /// receiver's repository and returns the path. Never types into the pane.
  func inbox(target: String, text: String, serverRoot: String, from: String) async throws -> String
  /// `herdr terminal session control <pane> --cols --rows`, streaming frames to
  /// `output` until the client detaches. At most 16 at once.
  func openTerminal(
    target: String, cols: Int, rows: Int, output: @escaping @Sendable (Data) -> Void
  ) async throws -> any HerdrTerminal
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
  /// Every query pair in arrival order, repeats included — what
  /// `url.searchParams.entries()` yields. The logger scrubs it.
  var query: [(name: String, value: String)]
  var status: Int
  var bytes: Int?
  var milliseconds: Double
  var origin: String
  var note: String?
}

// MARK: - Named, intentional divergences from the reference
//
// Everything else in this port is parity-or-report. These two are decisions,
// recorded here so the conformance harness can whitelist them and so nobody
// "fixes" them back.
//
//  1. `/api/identity` reports `"runtime": "swift"` where the reference
//     hardcodes `"runtime": "bun"`. The field exists to tell an operator what
//     is actually answering the port; a Swift binary claiming to be Bun is the
//     one lie the field cannot afford. Every other byte of that body, key
//     order included, is identical. This is the ONLY deliberate body-level
//     difference in the port.
//
//  2. `Connection: close` on every non-101 response, one request per
//     connection; the reference keeps the connection alive and emits no
//     Connection header. A graceful half-close was implemented and reverted —
//     it made this server the active closer and exhausted TIME_WAIT (150/150
//     curl failures). Measured 2026-09-22: 300 rapid requests, 0 client-
//     visible failures. See the README parity table.
//
//  3. An UNMASKED WebSocket data frame. RFC 6455 requires the server to fail
//     the connection, and this port answers `1002`. uWebSockets — the
//     reference's socket layer — instead MIS-PARSES it (it reads four payload
//     bytes as a phantom mask key) and LEAVES THE SOCKET OPEN, waiting for
//     bytes that never arrive. Measured 2026-09-22 on /ws. Matching it would
//     mean deliberately mis-parsing and letting a one-frame client pin a
//     connection slot open, so this is the one framing case left divergent on
//     purpose. Every OTHER framing behaviour is now byte-for-byte: a protocol
//     error (bad opcode, invalid control frame, non-UTF-8 text, bad
//     fragmentation, an over-cap message) drops the TCP connection with no
//     close frame, and a client CLOSE is echoed verbatim for an accepted code
//     (1000-1003, 1007-1011, 4000-4999) with a valid-UTF-8 reason and answered
//     with an empty close frame otherwise — see WebSocket.swift.
//
// And one REPORTED BUG that is reproduced rather than fixed, because it is in
// the reference too and parity is the contract:
//
//  * Under `--insecure-no-token`, an unauthenticated caller can mint a
//    `/ws/pty` ticket and open a fully interactive terminal into any pane.
//    `/api/auth/ws-ticket` is excluded from `isWrite`, so it is served
//    token-free in demo mode; it accepts `path: "/ws/pty"`; and the pty
//    session carries no read-only flag on either server
//    (`mod.createPtySession.ts` takes no `readOnly`, and neither does
//    `WSPtySession`) — unlike the dashboard session, which does gate
//    `wake`/`send` on it. The startup banner both servers print —
//    "writes (send, wake, cleanup) still require --token-file" — is therefore
//    wrong about the pty path on BOTH. The banner text is left byte-identical
//    to the reference's on purpose: correcting only this copy would make the
//    two servers disagree about a hole they share. A fix belongs in both, and
//    in one of two places: refuse `path: "/ws/pty"` in the ticket route when
//    the caller is unauthenticated, or thread `readOnly` into the pty session
//    and reject `attach` plus every binary input frame when it is set.
//    Reported upstream against the Bun server, not patched here.

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
  /// `expires: now + 30_000` in mod.runBunServe.ts. Was 60 here — a real 2x
  /// divergence in how long a minted ticket stays spendable.
  static let ticketLifetimeSeconds = 30
  static let paneStatuses: Set<String> = ["idle", "working", "blocked", "done", "unknown"]
  static let wakeEngines: Set<String> = [
    "pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline", "omp", "mastracode",
    "opencode", "copilot", "kimi", "kiro", "droid", "amp", "grok", "hermes", "kilo", "qodercli",
    "qwen", "maki", "muse",
  ]
}
