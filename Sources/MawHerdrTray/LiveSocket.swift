import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// maw-herdr-tray — the live socket.
//
// The dashboard WebSocket at /ws, so the tray redraws when the fleet changes
// instead of only when the timer fires. It is a pure OPTIMISATION: every event
// it emits could have come from a poll, and `HerdrFleetMonitor` keeps polling
// when it is down. Nothing here is required for the tray to work.
//
// HANDSHAKE, measured against the live server on 2026-09-22 (127.0.0.1:3467,
// --insecure-no-token) and cross-read in HTTPServer.swift:711-741:
//
//   * An `Origin` header is MANDATORY. Without one the upgrade is
//     `400 {"error":"websocket_request_invalid"}` — verified by hand with curl:
//     the same handshake plus `Origin: http://127.0.0.1:3467` answered
//     `101 Switching Protocols`. The origin must be loopback or allow-listed
//     (Origin.swift), so the tray sends its own base URL's scheme://authority.
//   * A query string is refused the same way, so /ws is requested bare.
//   * Tokenless demo path: NO `Sec-WebSocket-Protocol` header at all. The
//     server's predicate is `offers.count == 1 && offers[0] == ""`, which is
//     what an absent header parses to, and it is only honoured when the server
//     runs `--insecure`. `URLSession.webSocketTask(with:)` with no `protocols:`
//     sends no such header, which is exactly the shape required.
//   * Token path: POST /api/auth/ws-ticket (Origin + Bearer, body
//     `{"path":"/ws"}`) answers `{"protocol":"maw.ws.v1","ticket":"mwt1_<64 hex>"}`.
//     Connect offering EXACTLY ["maw.ws.v1", ticket] in that order. Tickets are
//     single-use, bound to origin+path, and expire in 30s
//     (Protocol.ticketLifetimeSeconds), so one is minted per connect attempt
//     and never cached across a reconnect.
//
// FRAMES the dashboard socket sends (WebSocket.swift roster()/capture()):
//   sessions      {"type":"sessions","sessions":[…]}  ← the only one used
//   recent        {"type":"recent","agents":[…]}
//   teams         {"type":"teams","teams":[…]}
//   feed-history  {"type":"feed-history","events":[…]}
//   feed          {"type":"feed","event":{…}}
//   capture       {"type":"capture","target":…,"content":…}
//   previews      {"type":"previews","data":{…}}
//   error         {"type":"error","error":"<code>"}
// `sessions` carries byte-for-byte what GET /api/sessions returns (both go
// through the server's `sessionsJSON`), and the server republishes it whenever
// the roster JSON changes — verified by reading a raw 101 upgrade with curl:
// the first frame on the wire was `{"type":"sessions","sessions":[{"name":
// "ZGVmYXVsdA/d00",…`. Everything else is ignored here; the tray renders panes.
//
// READ-ONLY. This socket never sends a text frame. The dashboard protocol
// accepts `select`, `wake` and `send` commands from a client — none are
// referenced in this target. The only client frames it emits are the ping
// control frames below, which the server answers with a pong
// (WebSocket.swift:622) and which touch no pane.
// ─────────────────────────────────────────────────────────────────────────────

/// What the socket tells the monitor. Deliberately small: the socket reports
/// connectivity and roster pushes, and the monitor decides what that means for
/// a `FleetSnapshot`.
enum LiveSocketEvent: Sendable, Equatable {
  /// A frame was actually received — the handshake is confirmed, not assumed.
  case connected
  /// A `sessions` frame, decoded with the same types `/api/sessions` uses.
  case sessions([HerdrSession])
  /// A `{"type":"error"}` frame. The payload is a fixed server code.
  case serverError(String)
  /// The socket is gone, with a short token-free reason. A reconnect is
  /// already scheduled; this is not fatal.
  case disconnected(String)
}

/// One self-healing dashboard socket.
///
/// Lifecycle: `start()` spawns a supervisor task that connects, pumps frames,
/// and on any exit sleeps a bounded backoff and reconnects — forever, until
/// `stop()`. That loop is what lets the tray survive `maw herdr serve` being
/// restarted underneath it without being relaunched: the connects simply fail
/// with "connection refused" until the server is back, then succeed.
final actor LiveSocket {
  /// Single-consumer event stream, finished by `stop()`.
  nonisolated let events: AsyncStream<LiveSocketEvent>
  private nonisolated let continuation: AsyncStream<LiveSocketEvent>.Continuation

  private let config: TrayConfig
  private let session: URLSession
  private var supervisor: Task<Void, Never>?
  private var task: URLSessionWebSocketTask?
  private var running = false
  private var attempt = 0

  /// Bounded exponential backoff: 0.5s, 1, 2, 4, 8, 15, 15, … A tray left open
  /// overnight against a stopped server must not become a reconnect storm, and
  /// a server that comes back must be noticed within 15s without a relaunch.
  private static let backoffSteps: [TimeInterval] = [0.5, 1, 2, 4, 8, 15]
  /// The dashboard socket's own roster poll is ~1s; 25s of silence means the
  /// connection is half-open, not quiet.
  private static let pingInterval: TimeInterval = 25

  init(config: TrayConfig = .standard, session: URLSession? = nil) {
    self.config = config
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      // Deliberately NOT `config.requestTimeout`: that is a per-request budget
      // for a poll. A WebSocket is long-lived, and a resource timeout would
      // guillotine a perfectly healthy socket on a quiet fleet.
      configuration.timeoutIntervalForRequest = max(config.requestTimeout, 15)
      configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
      configuration.waitsForConnectivity = false
      configuration.httpShouldSetCookies = false
      self.session = URLSession(configuration: configuration)
    }
    var escapee: AsyncStream<LiveSocketEvent>.Continuation!
    self.events = AsyncStream<LiveSocketEvent>(bufferingPolicy: .bufferingNewest(4)) {
      escapee = $0
    }
    self.continuation = escapee
  }

  /// Idempotent.
  func start() {
    guard !running else { return }
    running = true
    supervisor = Task { [weak self] in await self?.supervise() }
  }

  /// Idempotent, and required before the process exits. Cancels the supervisor,
  /// closes the socket with a proper 1000 close frame, invalidates the session
  /// and finishes the stream.
  func stop() {
    guard running else { return }
    running = false
    supervisor?.cancel()
    supervisor = nil
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
    session.invalidateAndCancel()
    continuation.finish()
  }

  // MARK: The loop

  private func supervise() async {
    while running && !Task.isCancelled {
      let reason: String
      do {
        try await pump()
        reason = "closed by server"
      } catch {
        reason = HerdrAPIClient.transportReason(error)
      }
      guard running, !Task.isCancelled else { break }
      continuation.yield(.disconnected(reason))
      let delay = Self.backoffSteps[min(attempt, Self.backoffSteps.count - 1)]
      attempt += 1
      do {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      } catch {
        break
      }
    }
  }

  /// Connect, then read frames until the socket dies. Returns normally only on
  /// a clean close; everything else throws so `supervise()` can back off.
  private func pump() async throws {
    var request = try makeRequest()
    if let ticket = try await mintTicketIfNeeded() {
      // EXACTLY two offers, subprotocol first. The server regex-checks the
      // second against `^mwt1_[0-9a-f]{64}$` before spending it.
      //
      // Set by hand rather than via `webSocketTask(with:protocols:)`, because
      // that overload takes a URL and there is no URL overload that also
      // carries the MANDATORY `Origin` header. URLSession leaves an explicit
      // `Sec-WebSocket-Protocol` on a URLRequest intact — verified against the
      // live server: the upgrade answered 101 and echoed back
      // `Sec-WebSocket-Protocol: maw.ws.v1`.
      request.setValue("\(Self.subprotocol), \(ticket)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
    }
    // With no ticket the header is absent, which is the server's ticketless
    // demo predicate (`offers.count == 1 && offers[0] == ""`). It is only
    // honoured while the server runs --insecure-no-token.
    let socket = session.webSocketTask(with: request)
    task = socket
    socket.resume()
    defer {
      socket.cancel(with: .normalClosure, reason: nil)
      if task === socket { task = nil }
    }

    // KEEPALIVE, on its own clock.
    //
    // This used to be an `if Date().timeIntervalSince(lastPing) >= pingInterval`
    // at the BOTTOM of the receive loop, which meant a ping could only ever be
    // sent immediately after a frame arrived. On a silent socket — precisely
    // the case a keepalive exists to detect — the loop is parked inside
    // `receive()` forever and no ping was ever sent, so a half-open connection
    // was invisible. It now runs as a sibling task: a failed ping cancels the
    // socket, which makes the parked `receive()` throw, which is what
    // `supervise()` needs to reconnect.
    let pinger = Task {
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
        } catch { return }
        guard !Task.isCancelled else { return }
        guard await Self.sendPing(socket) else {
          socket.cancel(with: .goingAway, reason: nil)
          return
        }
      }
    }
    defer { pinger.cancel() }

    var sawFrame = false
    while running && !Task.isCancelled {
      let message = try await socket.receive()
      if !sawFrame {
        sawFrame = true
        // The handshake is only proven by a frame arriving. `resume()`
        // succeeds before the server has decided anything, so a 401 on the
        // upgrade would otherwise look like a healthy connection.
        attempt = 0
        continuation.yield(.connected)
      }
      switch message {
      case .string(let text):
        handle(text: text)
      case .data(let data):
        // The dashboard protocol is text-only; decode defensively anyway.
        handle(text: String(decoding: data, as: UTF8.self))
      @unknown default:
        break
      }
    }
  }

  /// One ping, awaited. `true` when the server answered the pong. READ-ONLY:
  /// a ping is a control frame — it reaches no pane and carries no payload.
  private static func sendPing(_ socket: URLSessionWebSocketTask) async -> Bool {
    await withCheckedContinuation { continuation in
      socket.sendPing { error in continuation.resume(returning: error == nil) }
    }
  }

  // MARK: Frames

  private static let subprotocol = "maw.ws.v1"

  private struct FrameEnvelope: Decodable { var type: String? }
  private struct SessionsFrame: Decodable { var sessions: [HerdrSession] }
  private struct ErrorFrame: Decodable { var error: String }

  /// Only `sessions` and `error` are acted on. An unknown or unparseable frame
  /// is dropped in silence on purpose: a new server frame type must never be
  /// able to knock the tray offline, and the poll loop is still running.
  private func handle(text: String) {
    guard let type = Self.frameType(text) else { return }
    // Data is built — and JSON is parsed — only for the two types the tray
    // acts on. `recent`, `teams`, `feed-history`, `feed` and `previews` are
    // dropped without ever reaching JSONDecoder.
    switch type {
    case "sessions":
      guard let frame = try? JSONDecoder().decode(SessionsFrame.self, from: Data(text.utf8))
      else { return }
      continuation.yield(.sessions(frame.sessions))
    case "error":
      guard let frame = try? JSONDecoder().decode(ErrorFrame.self, from: Data(text.utf8))
      else { return }
      continuation.yield(.serverError(frame.error))
    default:
      break
    }
  }

  /// The frame's `type` without parsing its body.
  ///
  /// MEASURED 2026-09-22 on a raw 101 upgrade: every dashboard frame begins
  /// literally `{"type":"…"` and the `sessions` frame is ~67 KB. Decoding that
  /// whole body through `FrameEnvelope` just to read an 8-byte discriminator —
  /// and then decoding it a second time for real — cost a full parse per frame
  /// including for the types the tray ignores. A prefix read answers it; any
  /// frame NOT of that measured shape falls back to the real decoder, so a
  /// server that reorders its keys degrades in speed, never in correctness.
  private static func frameType(_ text: String) -> String? {
    let marker = "{\"type\":\""
    if text.hasPrefix(marker) {
      let start = text.index(text.startIndex, offsetBy: marker.count)
      if let close = text[start...].prefix(64).firstIndex(of: "\"") {
        return String(text[start..<close])
      }
    }
    return (try? JSONDecoder().decode(FrameEnvelope.self, from: Data(text.utf8)))?.type
  }

  // MARK: Handshake

  /// `http` → `ws`, `https` → `wss`, path `/ws`, no query (the server refuses
  /// one), plus the mandatory `Origin`.
  private func makeRequest() throws -> URLRequest {
    guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
      throw TrayError.unreachable("bad server URL")
    }
    components.scheme = (components.scheme == "https") ? "wss" : "ws"
    components.path = "/ws"
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw TrayError.unreachable("bad server URL") }

    var request = URLRequest(url: url)
    request.setValue(originHeader, forHTTPHeaderField: "Origin")
    return request
  }

  /// `scheme://host[:port]` of the base URL. Loopback, so `decideOrigin`
  /// admits it without an `--allow-origin` flag.
  private var originHeader: String {
    let scheme = config.baseURL.scheme ?? "http"
    let host = config.baseURL.host ?? "127.0.0.1"
    if let port = config.baseURL.port { return "\(scheme)://\(host):\(port)" }
    return "\(scheme)://\(host)"
  }

  private struct TicketResponse: Decodable {
    var ticket: String
    /// Echoed subprotocol name. Checked so a server that renames it is a clean
    /// failure rather than a 401 on the upgrade.
    var `protocol`: String?
  }

  /// nil when no token file is configured — the demo server's ticketless path.
  /// Otherwise mints a fresh single-use ticket. The token goes into one
  /// `Authorization` header and is never held, logged or returned.
  private func mintTicketIfNeeded() async throws -> String? {
    guard let token = try config.readToken() else { return nil }

    var request = URLRequest(url: config.endpoint("/api/auth/ws-ticket"))
    request.httpMethod = "POST"
    request.timeoutInterval = config.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(originHeader, forHTTPHeaderField: "Origin")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = Data(#"{"path":"/ws"}"#.utf8)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw TrayError.unreachable(HerdrAPIClient.transportReason(error))
    }
    guard let http = response as? HTTPURLResponse else {
      throw TrayError.unreachable("no HTTP response")
    }
    guard http.statusCode == 200 else {
      let code = (try? JSONDecoder().decode(HerdrErrorBody.self, from: data))?.error
      throw TrayError.httpStatus(http.statusCode, code: code)
    }
    guard let body = try? JSONDecoder().decode(TicketResponse.self, from: data) else {
      throw TrayError.malformedBody(path: "/api/auth/ws-ticket", detail: "no ticket")
    }
    if let name = body.protocol, name != Self.subprotocol {
      throw TrayError.malformedBody(
        path: "/api/auth/ws-ticket", detail: "unknown subprotocol `\(name)`")
    }
    return body.ticket
  }
}
