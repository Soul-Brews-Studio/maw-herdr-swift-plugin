import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// maw-herdr-tray — the data layer.
//
// Turns a running `maw herdr serve` into `FleetSnapshot` values. Two types:
//
//   HerdrAPIClient    one HTTP request each for /api/identity, /api/sessions,
//                     /api/agents, /api/capture, plus `refresh()` which merges
//                     identity + sessions into one snapshot and never throws.
//   HerdrFleetMonitor an actor that drives `refresh()` on a timer, listens to a
//                     LiveSocket for server pushes, coalesces overlapping
//                     refreshes, and publishes on `AsyncStream<FleetSnapshot>`.
//
// NOTHING in this file imports AppKit or touches the main actor. The single hop
// to the main actor happens in the UI, which consumes `snapshots` inside
// `Task { @MainActor in for await s in monitor.snapshots { … } }`.
//
// READ-ONLY. Only GET /api/identity, /api/sessions, /api/agents, /api/capture
// and POST /api/auth/ws-ticket are ever issued. /api/send and /api/wake are not
// referenced anywhere in this target and must stay that way — this machine runs
// a real fleet and a tray that can type into someone else's pane is a weapon.
//
// TOKENS. `TrayConfig.readToken()` is the only reader, it is called fresh per
// request, and the value goes into an `Authorization: Bearer …` header and
// nowhere else. No error case, log line or snapshot string can contain it: the
// failure path reports the PATH (`TrayError.tokenUnreadable(path:)`), never the
// contents, and JSON decode failures report coding-key NAMES only, never the
// bytes that failed to decode.
//
// Measured against the live demo server on 2026-09-22 (http://127.0.0.1:3467,
// --insecure-no-token, node m5-beta, herdr-core-dev/swift, 20 sessions / 34
// panes). Every shape below came off that wire, not from the server's source.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - HTTP client

/// `FleetAPIClient` over `URLSession`. A value type holding one session, so it
/// is trivially `Sendable` and can be shared by the monitor and any caller.
struct HerdrAPIClient: FleetAPIClient {
  let config: TrayConfig
  private let session: URLSession

  /// `session` is injectable for tests. The default is ephemeral and
  /// cache-free: a cached `/api/sessions` is a tray showing a dead fleet.
  init(config: TrayConfig = .standard, session: URLSession? = nil) {
    self.config = config
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = config.requestTimeout
      configuration.timeoutIntervalForResource = config.requestTimeout
      configuration.waitsForConnectivity = false
      configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      configuration.urlCache = nil
      configuration.httpShouldSetCookies = false
      configuration.httpMaximumConnectionsPerHost = 4
      self.session = URLSession(configuration: configuration)
    }
  }

  /// Release the underlying session's connections. The monitor calls this from
  /// `stop()` so `swift run` can exit without a task outliving the app.
  func invalidate() {
    session.invalidateAndCancel()
  }

  // MARK: Endpoints

  /// GET /api/identity → 200 object. Measured: every key present, and it also
  /// carries a hardcoded-empty `agents` array the seam deliberately does not
  /// model (HTTPServer.swift:890 — its element type is unknowable from the
  /// wire, so decoding it would be a guess).
  func identity() async throws -> HerdrIdentity {
    let data = try await get("/api/identity")
    return try decode(HerdrIdentity.self, from: data, path: "/api/identity")
  }

  /// GET /api/sessions → 200 TOP-LEVEL ARRAY (`jq type` == "array", length 20).
  /// The one source of the tray's counts.
  func sessions() async throws -> [HerdrSession] {
    let data = try await get("/api/sessions")
    return try decode([HerdrSession].self, from: data, path: "/api/sessions")
  }

  /// GET /api/agents → 200 `{"agents":[…],"count":34,"node":"m5-beta"}`.
  /// Diagnostic only. It is lossy by construction: HTTPServer.swift:841-853
  /// collapses pane status with `status == "working" ? "active" : "idle"`, so
  /// done/blocked/unknown all arrive as "idle", its `oracle` field is the PANE
  /// NAME, and `pid` is null on every row. Never let it drive a count.
  func agents() async throws -> HerdrAgentsEnvelope {
    let data = try await get("/api/agents")
    return try decode(HerdrAgentsEnvelope.self, from: data, path: "/api/agents")
  }

  /// GET /api/capture?target=<session.name>:<window.index>
  ///
  /// The separator is a COLON. Measured: a valid target answers 200 with pane
  /// text, an unknown pane answers **400** with the SAME four keys and
  /// `error: "capture_unavailable"`. 400 is therefore accepted here rather than
  /// raised — the body is the answer, not an envelope around a failure. The
  /// server always reads 200 lines and ignores the requested count; `lines` is
  /// sent anyway so the request states the intent `config.captureLines` names.
  func capture(target: String) async throws -> HerdrCapture {
    let data = try await get(
      "/api/capture",
      query: [
        URLQueryItem(name: "target", value: target),
        URLQueryItem(name: "lines", value: String(config.captureLines)),
      ],
      accepting: [400])
    return try decode(HerdrCapture.self, from: data, path: "/api/capture")
  }

  // MARK: Refresh

  /// One full refresh, and the only method the monitor calls. NEVER throws.
  ///
  /// `/api/sessions` and `/api/identity` go out concurrently. Sessions is
  /// load-bearing — losing it means there is nothing to render, so that becomes
  /// `FleetSnapshot.failure`. Identity is decoration: when only identity fails
  /// the snapshot is still `reachable` with the panes intact and the identity
  /// error carried in `lastError`, because a fleet you can see is worth more
  /// than a version string you cannot.
  func refresh() async -> FleetSnapshot {
    async let sessionsResult = sessions()
    async let identityResult = identity()

    let wire: [HerdrSession]
    do {
      wire = try await sessionsResult
    } catch {
      // Awaited so the identity task is reaped here rather than implicitly at
      // scope exit; its outcome is irrelevant once sessions is gone.
      _ = try? await identityResult
      return FleetSnapshot.failure(Self.trayError(error))
    }

    var identity: HerdrIdentity?
    var note: String?
    do {
      identity = try await identityResult
    } catch {
      note = Self.trayError(error).displayText
    }
    return FleetSnapshot.build(sessions: wire, identity: identity, lastError: note)
  }

  // MARK: Transport

  private func get(
    _ path: String, query: [URLQueryItem] = [], accepting extraStatuses: Set<Int> = []
  ) async throws -> Data {
    var request = URLRequest(url: config.endpoint(path, query: query))
    request.httpMethod = "GET"
    request.timeoutInterval = config.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // Fresh read per request: an operator can rotate the token file under a
    // running tray. The value lives only in this header.
    if let token = try config.readToken() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw TrayError.unreachable(Self.transportReason(error))
    }
    guard let http = response as? HTTPURLResponse else {
      throw TrayError.unreachable("no HTTP response")
    }
    if (200..<300).contains(http.statusCode) || extraStatuses.contains(http.statusCode) {
      return data
    }
    // Non-2xx bodies are `{"error":"<code>"}` — measured: 400 target_required,
    // 404 not_found, 401 operator_token_required. The code is a fixed
    // identifier, never user data and never a token, so it is safe to show.
    let code = (try? JSONDecoder().decode(HerdrErrorBody.self, from: data))?.error
    throw TrayError.httpStatus(http.statusCode, code: code)
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch let error as DecodingError {
      throw TrayError.malformedBody(path: path, detail: Self.decodeDetail(error))
    } catch {
      throw TrayError.malformedBody(path: path, detail: "unreadable JSON")
    }
  }

  // MARK: Failure text

  /// Already a `TrayError`, or a transport error wrapped as one. Used so
  /// `refresh()` has exactly one shape of failure to hand the UI.
  static func trayError(_ error: Error) -> TrayError {
    if let tray = error as? TrayError { return tray }
    return .unreachable(transportReason(error))
  }

  /// A short, human, token-free reason for a transport failure. `URLError`
  /// carries the failing URL, which is fine (it is `config.baseURL`), but the
  /// text below is built from the CODE only so nothing from the request — no
  /// header, no token — can leak into a menu item.
  static func transportReason(_ error: Error) -> String {
    guard let urlError = error as? URLError else {
      return error is CancellationError ? "cancelled" : "request failed"
    }
    switch urlError.code {
    case .cannotConnectToHost: return "connection refused"
    case .cannotFindHost: return "host not found"
    case .networkConnectionLost: return "connection lost"
    case .timedOut: return "timed out"
    case .cancelled: return "cancelled"
    case .notConnectedToInternet: return "no network"
    case .secureConnectionFailed, .serverCertificateUntrusted: return "TLS refused"
    case .unsupportedURL, .badURL: return "bad server URL"
    default: return "network error \(urlError.code.rawValue)"
    }
  }

  /// One line naming WHERE the body disagreed with the type, using coding-key
  /// names only. `DecodingError.debugDescription` is deliberately not used — it
  /// can quote the offending value, and values from this server are pane
  /// contents and cwds.
  static func decodeDetail(_ error: DecodingError) -> String {
    func path(_ context: DecodingError.Context) -> String {
      let parts = context.codingPath.map { key -> String in
        if let index = key.intValue { return "[\(index)]" }
        return key.stringValue
      }
      return parts.isEmpty ? "<root>" : parts.joined(separator: ".")
    }
    switch error {
    case .keyNotFound(let key, let context):
      return "missing key `\(key.stringValue)` at \(path(context))"
    case .typeMismatch(let type, let context):
      return "expected \(type) at \(path(context))"
    case .valueNotFound(let type, let context):
      return "null \(type) at \(path(context))"
    case .dataCorrupted(let context):
      return "corrupt JSON at \(path(context))"
    @unknown default:
      return "undecodable body"
    }
  }
}

// MARK: - Monitor

/// `FleetMonitor` as an actor: the timer, the live socket, the coalescing gate
/// and the last snapshot all live behind one isolation domain, so "never more
/// than one refresh in flight" is enforced by the actor rather than by a lock.
///
/// Publication is `AsyncStream<FleetSnapshot>` with a 1-deep newest-wins buffer
/// — a tray that renders slowly should draw the CURRENT fleet, never a queue of
/// stale ones. The stream finishes on `stop()` and only on `stop()`.
final actor HerdrFleetMonitor: FleetMonitor {
  nonisolated let config: TrayConfig
  nonisolated let snapshots: AsyncStream<FleetSnapshot>
  private nonisolated let continuation: AsyncStream<FleetSnapshot>.Continuation

  private let client: HerdrAPIClient
  private let wantsLiveSocket: Bool

  private var running = false
  private var refreshInFlight = false
  private var socket: LiveSocket?
  private var socketTask: Task<Void, Never>?
  private var pollTask: Task<Void, Never>?
  private var socketLive = false
  private var lastSnapshot: FleetSnapshot = .initial()
  /// Monotonic publication clock. Stamped onto a refresh BEFORE the request
  /// goes out and compared against `publishedGeneration` when it lands, so a
  /// slow poll can never overwrite a socket push that started after it.
  private var generation: UInt64 = 0
  private var publishedGeneration: UInt64 = 0
  /// Poll results discarded for being older than what is already on screen.
  private(set) var supersededPolls = 0

  /// Counters a harness or a diagnostics menu can read. `droppedPolls` is the
  /// coalescing gate doing its job, not an error.
  private(set) var droppedPolls = 0
  private(set) var pushUpdates = 0
  private(set) var pollUpdates = 0

  init(
    config: TrayConfig = .standard,
    client: HerdrAPIClient? = nil,
    liveSocket: Bool = true
  ) {
    self.config = config
    self.client = client ?? HerdrAPIClient(config: config)
    self.wantsLiveSocket = liveSocket
    var escapee: AsyncStream<FleetSnapshot>.Continuation!
    self.snapshots = AsyncStream<FleetSnapshot>(bufferingPolicy: .bufferingNewest(1)) {
      escapee = $0
    }
    self.continuation = escapee
  }

  func latest() -> FleetSnapshot { lastSnapshot }

  func diagnostics() -> (dropped: Int, push: Int, poll: Int, socketLive: Bool) {
    (droppedPolls, pushUpdates, pollUpdates, socketLive)
  }

  func supersededCount() -> Int { supersededPolls }

  /// Idempotent. Opens the socket, starts the timer, and does one refresh
  /// immediately so the menu bar has a real title before the first tick.
  func start() async {
    guard !running else { return }
    running = true
    if wantsLiveSocket { openSocket() }
    pollTask = Task { [weak self] in await self?.pollLoop() }
    await performRefresh(source: .poll)
  }

  /// Idempotent, and the app MUST call it before exiting: it cancels the timer,
  /// closes the socket, invalidates the URLSession and finishes the stream, so
  /// no network task outlives the process.
  func stop() async {
    guard running else { return }
    running = false
    pollTask?.cancel()
    pollTask = nil
    socketTask?.cancel()
    socketTask = nil
    if let socket { await socket.stop() }
    socket = nil
    socketLive = false
    client.invalidate()
    continuation.finish()
  }

  /// An out-of-band refresh (menu opened, "Refresh now"). Subject to the same
  /// coalescing gate as a tick — clicking twice does not double the load.
  func refreshNow() async {
    await performRefresh(source: .poll)
  }

  // MARK: Polling

  private enum Source { case poll, push }

  /// Sleeps FIRST: `start()` already did the initial refresh.
  ///
  /// While the socket is live the timer backs off to a slow heartbeat — the
  /// socket republishes `sessions` whenever the roster changes, so the timer's
  /// only remaining jobs are refreshing `/api/identity` and noticing a socket
  /// that is silently half-open. When the socket is down it is the sole source
  /// of updates and runs at `config.pollInterval`.
  private func pollLoop() async {
    while running && !Task.isCancelled {
      let interval = socketLive ? max(config.pollInterval * 4, 12) : config.pollInterval
      do {
        try await Task.sleep(nanoseconds: UInt64(max(0.25, interval) * 1_000_000_000))
      } catch {
        return
      }
      guard running, !Task.isCancelled else { return }
      await performRefresh(source: .poll)
    }
  }

  /// The coalescing gate. One refresh in flight at a time; anything arriving
  /// during one is DROPPED, not queued — a queued poll would arrive with data
  /// older than the one that just landed.
  ///
  /// The gate only ever serialised poll against poll. A socket push does not
  /// go through it, so an in-flight poll could still land AFTER a newer push
  /// and roll the roster backwards, and a poll that merely failed could blank a
  /// fleet the socket was pushing successfully. Both are closed below with a
  /// generation stamp taken before the request leaves.
  private func performRefresh(source: Source) async {
    guard running || source == .poll else { return }
    if refreshInFlight {
      droppedPolls += 1
      return
    }
    refreshInFlight = true
    generation += 1
    let mine = generation
    let snapshot = await client.refresh()
    refreshInFlight = false
    guard running else { return }

    // Something newer (a push) was published while this request was out.
    guard mine > publishedGeneration else {
      supersededPolls += 1
      return
    }
    pollUpdates += 1

    // A failed poll does NOT wipe a fleet the socket is still feeding. Keep the
    // panes, say what went wrong, and let the title fall back to the error only
    // when there is nothing newer to show.
    if !snapshot.reachable, lastSnapshot.reachable, socketLive {
      var annotated = lastSnapshot
      annotated.lastError = snapshot.lastError
      annotated.authDenied = snapshot.authDenied
      publish(annotated, generation: mine)
      return
    }
    publish(snapshot, generation: mine)
  }

  private func publish(_ snapshot: FleetSnapshot, generation stamp: UInt64? = nil) {
    if let stamp {
      publishedGeneration = max(publishedGeneration, stamp)
    } else {
      generation += 1
      publishedGeneration = generation
    }
    lastSnapshot = snapshot
    continuation.yield(snapshot)
  }

  // MARK: Live socket

  private func openSocket() {
    let socket = LiveSocket(config: config)
    self.socket = socket
    socketTask = Task { [weak self] in
      for await event in socket.events {
        guard let self else { return }
        await self.handle(event)
      }
    }
    Task { await socket.start() }
  }

  /// The push path. A `sessions` frame carries exactly the array `/api/sessions`
  /// returns, so it rebuilds a snapshot through the same
  /// `FleetSnapshot.build` the poll path uses — one projection, two transports.
  /// Identity is not on the socket, so the last known identity is carried
  /// forward; the heartbeat poll refreshes it.
  private func handle(_ event: LiveSocketEvent) async {
    switch event {
    case .connected:
      socketLive = true
    case .sessions(let wire):
      socketLive = true
      guard running else { return }
      pushUpdates += 1
      publish(FleetSnapshot.build(sessions: wire, identity: lastSnapshot.identity))
    case .serverError(let code):
      // A frame-level error (`herdr_unavailable`, `teams_unavailable`) means
      // the socket is up but the backend stumbled. HTTP is the arbiter of
      // reachability, so this only annotates.
      socketLive = true
      if running, lastSnapshot.reachable {
        var annotated = lastSnapshot
        annotated.lastError = "server: \(code)"
        publish(annotated)
      }
    case .disconnected:
      socketLive = false
      // Do NOT mark the fleet unreachable here — HTTP may be perfectly fine
      // and only the socket died. Take one HTTP reading to find out, rather
      // than waiting out a heartbeat interval that was sized for a live socket.
      guard running else { return }
      await performRefresh(source: .push)
    }
  }
}
