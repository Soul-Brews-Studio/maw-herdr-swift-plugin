import CryptoKit
import Foundation
import Network

// HTTP/1.1 by hand on Network.framework, plus the router.
//
// Port of four Bun files:
//   mod.runBunServe.ts — the fetch handler: busy gate, host, origin, preflight,
//                        method allow-list, auth, /ws upgrade, ws-ticket
//   mod.serveAPI.ts    — the routes themselves
//   mod.claimDelivery.ts / mod.recordDelivery.ts — the /api/send receipts
//   mod.serveFeedActivity.ts — POST /api/feed
//
// The listener is plain TCP on purpose. NWProtocolWebSocket would frame every
// byte on the port, and the same port serves plain HTTP, so the upgrade is done
// by hand here and the connection is handed to the socket module afterwards.
//
// Every body is written through the ordered JSON writer in JSON.swift, in the
// key order the Bun route builds its object literal. JSONSerialization walks a
// dictionary in hash order, and a byte-level diff of the two servers should be
// empty, not "only key order".
//
// Parity beats taste. Where Bun does something surprising the surprise is
// reproduced, not corrected, and called out in the port report.

// MARK: - Header bag (fetch `Headers` semantics)

/// Ordered and case-insensitive: `set` replaces in place, `append` comma-joins,
/// `get` returns the joined value — the three operations the Bun handler uses.
private struct HeaderBag: Sendable {
  private(set) var entries: [(name: String, value: String)] = []

  mutating func set(_ name: String, _ value: String) {
    let key = name.lowercased()
    if let index = entries.firstIndex(where: { $0.name.lowercased() == key }) {
      entries[index].value = value
      var tail = entries.count - 1
      while tail > index {
        if entries[tail].name.lowercased() == key { entries.remove(at: tail) }
        tail -= 1
      }
    } else {
      entries.append((name, value))
    }
  }

  mutating func append(_ name: String, _ value: String) {
    if let existing = get(name) { set(name, existing + ", " + value) } else { set(name, value) }
  }

  func get(_ name: String) -> String? {
    let key = name.lowercased()
    let values = entries.filter { $0.name.lowercased() == key }.map(\.value)
    return values.isEmpty ? nil : values.joined(separator: ", ")
  }
}

// MARK: - Request

private struct HTTPRequestHead: Sendable {
  var method: String
  var version: String
  var target: String
  var path: String
  /// `request.url.includes('?')` in Bun — an empty query still counts.
  var hasQuery: Bool
  /// `searchParams.get`: first value wins for a repeated key.
  var query: [String: String]
  /// `searchParams.entries()`: every pair, in order, repeats included.
  var queryPairs: [(name: String, value: String)]
  /// Lowercased name -> value; repeats joined with ", " like `Headers.get`.
  var headers: [String: String]
  var contentLength: Int?

  /// `searchParams.getAll(name)`.
  func queryAll(_ name: String) -> [String] { queryPairs.filter { $0.name == name }.map(\.value) }
}

private func parseRequestHead(_ block: Data) -> HTTPRequestHead? {
  guard let text = String(data: block, encoding: .utf8) ?? String(data: block, encoding: .isoLatin1)
  else { return nil }
  var lines = text.components(separatedBy: "\r\n")
  if lines.count == 1 { lines = text.components(separatedBy: "\n") }
  guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }

  let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
  guard parts.count >= 3, parts[2].hasPrefix("HTTP/") else { return nil }
  let method = parts[0]
  let version = parts[2]
  var target = parts[1]

  var headers: [String: String] = [:]
  var lastName: String?
  for line in lines.dropFirst() {
    if line.isEmpty { continue }
    if line.hasPrefix(" ") || line.hasPrefix("\t") {
      // Obsolete line folding: append to the previous value rather than drop it.
      if let name = lastName, let existing = headers[name] {
        headers[name] = existing + " " + line.trimmingCharacters(in: .whitespaces)
      }
      continue
    }
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let name = String(line[line.startIndex..<colon]).lowercased()
    guard !name.isEmpty else { return nil }
    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    if let existing = headers[name] { headers[name] = existing + ", " + value } else { headers[name] = value }
    lastName = name
  }

  // absolute-form -> origin-form, then drop the fragment, then split the query.
  for scheme in ["http://", "https://"] where target.lowercased().hasPrefix(scheme) {
    let rest = target.dropFirst(scheme.count)
    target = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
  }
  var withoutFragment = target
  if let hash = withoutFragment.firstIndex(of: "#") {
    withoutFragment = String(withoutFragment[withoutFragment.startIndex..<hash])
  }
  var path = withoutFragment
  var rawQuery: String?
  if let mark = withoutFragment.firstIndex(of: "?") {
    path = String(withoutFragment[withoutFragment.startIndex..<mark])
    rawQuery = String(withoutFragment[withoutFragment.index(after: mark)...])
  }

  var contentLength: Int?
  if let raw = headers["content-length"] {
    // A repeated Content-Length arrives here joined by ", " and fails to parse,
    // which is the outcome that matters: it is never silently half-honoured.
    guard let value = Int(raw.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
    contentLength = value
  }

  let pairs = parseQuery(rawQuery)
  var first: [String: String] = [:]
  for pair in pairs where first[pair.name] == nil { first[pair.name] = pair.value }
  return HTTPRequestHead(
    method: method, version: version, target: target, path: removeDotSegments(path),
    hasQuery: withoutFragment.contains("?") || target.contains("?"),
    query: first, queryPairs: pairs, headers: headers, contentLength: contentLength)
}

/// `new URL()` resolves dot segments before the handler ever sees a pathname,
/// so `/api/../api/send` is `/api/send` on both servers, not an unknown route.
private func removeDotSegments(_ path: String) -> String {
  guard path.hasPrefix("/"), path.contains(".") else { return path }
  let segments = path.dropFirst().components(separatedBy: "/")
  var kept: [String] = []
  var trailing = false
  for (index, segment) in segments.enumerated() {
    let last = index == segments.count - 1
    switch segment {
    case ".":
      trailing = last
    case "..":
      if !kept.isEmpty { kept.removeLast() }
      trailing = last
    default:
      kept.append(segment)
      trailing = false
    }
  }
  var result = "/" + kept.joined(separator: "/")
  if trailing && !result.hasSuffix("/") { result += "/" }
  return result
}

/// `URLSearchParams`: `+` is a space, percent escapes decode, pairs kept in
/// order with repeats.
private func parseQuery(_ raw: String?) -> [(name: String, value: String)] {
  guard let raw, !raw.isEmpty else { return [] }
  var result: [(String, String)] = []
  for pair in raw.components(separatedBy: "&") where !pair.isEmpty {
    let key: String
    let value: String
    if let equals = pair.firstIndex(of: "=") {
      key = String(pair[pair.startIndex..<equals])
      value = String(pair[pair.index(after: equals)...])
    } else {
      key = pair
      value = ""
    }
    result.append((formDecode(key), formDecode(value)))
  }
  return result
}

private func formDecode(_ value: String) -> String {
  let spaced = value.replacingOccurrences(of: "+", with: " ")
  return spaced.removingPercentEncoding ?? spaced
}

// MARK: - Loopback authority

/// `mod.loopbackHost.ts`: authority with optional port, bare or bracketed IPv6,
/// including the IPv4-mapped form a dual-stack client arrives as.
private func loopbackAuthority(_ authority: String) -> Bool {
  if authority.isEmpty { return false }
  var host = authority
  let pattern = #"^(?:\[([^\]]+)\]|([^:]+))(?::([0-9]+))?$"#
  if let match = authority.range(of: pattern, options: .regularExpression) {
    let text = String(authority[match])
    if text.hasPrefix("[") {
      if let close = text.firstIndex(of: "]") { host = String(text[text.index(after: text.startIndex)..<close]) }
    } else if let colon = text.lastIndex(of: ":") {
      host = String(text[text.startIndex..<colon])
    } else {
      host = text
    }
  }
  // `host === 'localhost'` in the reference — case-sensitive, so `Host:
  // LOCALHOST` is refused there and is refused here. IP literals are not
  // affected: digits and hex have no case to differ in.
  if host.lowercased() == "localhost" { return host == "localhost" }
  if isLoopbackHost(host) { return true }
  guard host.contains(":"), let address = IPv6Address(host) else { return false }
  let bytes = [UInt8](address.rawValue)
  guard bytes.count == 16 else { return false }
  if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
  // ::ffff:127.x.y.z — the same host, arriving over a dual-stack socket.
  return bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
    && bytes[12] == 127
}

/// Bun builds `new URL(request.url)` from the Host header before it looks at
/// anything else, so a Host that is not a legal URL authority throws and the
/// server answers 500 `request_failed` — measured with `Host: ::1`, `Host: a b`
/// and `Host: 12%.0.0.1`. It is reproduced rather than "fixed" because the
/// alternative is serving a request the reference server refuses.
private func authorityParses(_ authority: String) -> Bool {
  guard !authority.isEmpty else { return false }
  var rest = authority
  if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
  if let slash = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
    rest = String(rest[rest.startIndex..<slash])
  }
  var host = rest
  var port: String?
  if rest.hasPrefix("[") {
    guard let close = rest.firstIndex(of: "]") else { return false }
    host = String(rest[rest.index(after: rest.startIndex)..<close])
    let tail = String(rest[rest.index(after: close)...])
    if !tail.isEmpty {
      guard tail.hasPrefix(":") else { return false }
      port = String(tail.dropFirst())
    }
    return IPv6Address(host) != nil && (port ?? "").allSatisfy(\.isNumber)
  }
  // The FIRST colon starts the port, so `::1` asks for the port ":1".
  if let colon = rest.firstIndex(of: ":") {
    host = String(rest[rest.startIndex..<colon])
    port = String(rest[rest.index(after: colon)...])
  }
  if let port, !port.isEmpty, !port.allSatisfy(\.isNumber) { return false }
  let forbidden: Set<Character> = [" ", "\t", "\u{0}", "<", ">", "^", "|", "\\", "\""]
  if host.contains(where: { forbidden.contains($0) }) { return false }
  // A `%` in a host is percent-encoding, and a broken escape is a parse error.
  let characters = Array(host)
  var index = 0
  while index < characters.count {
    if characters[index] == "%" {
      guard index + 2 < characters.count, characters[index + 1].isHexDigit, characters[index + 2].isHexDigit
      else { return false }
      index += 3
    } else {
      index += 1
    }
  }
  return true
}

// MARK: - Failures

/// `HTTPError` from serverTypes.ts: a status, a message, and an optional body
/// that replaces the default `{error: message}`.
private struct HTTPFailure: Error, Sendable {
  let status: Int
  let message: String
  let body: JSONValue?
  init(_ status: Int, _ message: String, body: JSONValue? = nil) {
    self.status = status
    self.message = message
    self.body = body
  }
}

private enum RequestOutcome: Sendable {
  case response(status: Int, body: Data?, note: String?)
  case upgrade(path: String, readOnly: Bool)
}

private func jsonBody(_ value: JSONValue) -> Data { Data(jsonStringify(value).utf8) }

private func errorBody(_ code: String) -> JSONValue { jsonObject([("error", .string(code))]) }

/// `/^\p{White_Space}*$/u`.
private func isBlank(_ value: String) -> Bool {
  value.unicodeScalars.allSatisfy { unicodeWhiteSpace.contains($0) }
}

private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
  guard lhs.count == rhs.count else { return false }
  var difference: UInt8 = 0
  for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
  return difference == 0
}

private func iso8601UTC(_ date: Date) -> String {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
  let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
  return String(
    format: "%04d-%02d-%02dT%02d:%02d:%02dZ", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1,
    parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
}

private func unixSeconds() -> Int { Int(Date().timeIntervalSince1970) }

private func reasonPhrase(_ status: Int) -> String {
  switch status {
  case 101: return "Switching Protocols"
  case 200: return "OK"
  case 204: return "No Content"
  case 400: return "Bad Request"
  case 401: return "Unauthorized"
  case 403: return "Forbidden"
  case 404: return "Not Found"
  case 405: return "Method Not Allowed"
  case 409: return "Conflict"
  case 413: return "Request Entity Too Large"
  case 415: return "Unsupported Media Type"
  case 429: return "Too Many Requests"
  case 431: return "Request Header Fields Too Large"
  case 500: return "Internal Server Error"
  case 505: return "HTTP Version Not Supported"
  case 501: return "Not Implemented"
  case 503: return "Service Unavailable"
  default: return "Status"
  }
}

// MARK: - Roster JSON (mod.readRoster.ts shapes)

/// The `/api/sessions` payload and the socket's `sessions` frame: key order
/// `name, source, windows` per session and `index, name, active, cwd?, status,
/// agent?` per window, with `cwd` and `agent` omitted (never null) when absent.
func sessionsJSON(_ sessions: [Session]) -> JSONValue {
  .array(
    sessions.map { session in
      jsonObject([
        ("name", .string(session.name)),
        ("source", .string(session.source)),
        (
          "windows",
          .array(
            session.windows.map { window in
              jsonObject([
                ("index", .int(window.index)),
                ("name", .string(window.name)),
                ("active", .bool(window.active)),
                ("cwd", (window.cwd?.isEmpty == false) ? .string(window.cwd!) : nil),
                ("status", .string(window.status)),
                ("agent", trimmedAgent(window.agent).map(JSONValue.string)),
              ])
            })
        ),
      ])
    })
}

/// `pane.agent.trim()` — nil when blank, so the key is dropped.
func trimmedAgent(_ agent: String?) -> String? {
  guard let agent else { return nil }
  let trimmed = jsTrim(agent)
  return trimmed.isEmpty ? nil : trimmed
}

// MARK: - Server

/// One-shot socket ticket. Bound to the origin that asked for it and the path
/// it will be spent on, so a ticket minted for a dashboard cannot open a pty.
private struct Ticket: Sendable {
  let origin: String
  let path: String
  let expires: Date
  let readOnly: Bool
}

final class HerdrHTTPServer: @unchecked Sendable {
  private var config: ServeConfig
  private let tokenHash: Data
  private let tokenConfigured: Bool
  private let backend: any HerdrBackend
  private let sockets: any WebSocketService
  private let access: AccessLog
  private let deliveryHistory = DeliveryFeed()
  private let delivery = DeliveryDedup()
  private let started = Date()
  private let listenQueue = DispatchQueue(label: "maw.herdr.http.listen")
  private let lock = NSLock()
  private var inFlight = 0
  private var tickets: [String: Ticket] = [:]
  private var listener: NWListener?
  private var stopped = false
  /// The port actually bound — `--listen …:0` asks the kernel for one.
  private(set) var boundPort: Int

  /// The raw token is hashed here and dropped: nothing after this line can
  /// print it, and a core dump of the running server does not contain it.
  init(config: ServeConfig, backend: any HerdrBackend, sockets: any WebSocketService) {
    var scrubbed = config
    self.tokenHash = Data(SHA256.hash(data: Data(config.token.utf8)))
    self.tokenConfigured = !config.token.isEmpty
    scrubbed.token = ""
    self.config = scrubbed
    self.backend = backend
    self.sockets = sockets
    self.access = AccessLog(enabled: config.accessLog)
    self.boundPort = config.port
  }

  // MARK: Lifecycle

  /// Binds loopback only and returns once the listener is ready (or throws
  /// when it is not). `requiredLocalEndpoint` is the difference between a
  /// port the machine exposes and a port only this machine can reach.
  func start() throws {
    guard config.port >= 0, config.port <= 65535 else { throw ConfigError.message("serve: --listen port must be 0..65535") }
    let port: NWEndpoint.Port = config.port == 0 ? .any : NWEndpoint.Port(rawValue: UInt16(config.port))!
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
      tcp.noDelay = true
    }
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: listenHost(config.hostname), port: port)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      // The connection object keeps itself alive until it answers or dies —
      // see HTTPConnection.retain. Dropping it here would deallocate the
      // reader mid-request and the client would hang on a socket nobody owns.
      HTTPConnection(connection: connection, server: self).start()
    }
    let ready = DispatchSemaphore(value: 0)
    let outcome = OutcomeBox()
    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        if let bound = listener.port { self?.lock.withLock { self?.boundPort = Int(bound.rawValue) } }
        if outcome.settle(nil) { ready.signal() }
      case .failed(let error):
        if outcome.settle(error) {
          ready.signal()
        } else {
          FileHandle.standardError.write(
            Data("maw herdr serve: listener failed — \(error)\n  lsof -nP -iTCP:\(self?.boundPort ?? 0) -sTCP:LISTEN\n".utf8))
          exit(1)
        }
      case .cancelled:
        _ = outcome.settle(NWError.posix(.ECANCELED))
        ready.signal()
      default: break
      }
    }
    self.listener = listener
    listener.start(queue: listenQueue)
    ready.wait()
    if let error = outcome.error {
      self.listener = nil
      throw error
    }
  }

  private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private(set) var error: Error?
    /// True the first time only.
    func settle(_ value: Error?) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if settled { return false }
      settled = true
      error = value
      return true
    }
  }

  func stop() {
    lock.lock()
    if stopped { lock.unlock(); return }
    stopped = true
    tickets.removeAll()
    let listener = self.listener
    self.listener = nil
    lock.unlock()
    listener?.cancel()
  }

  private func listenHost(_ hostname: String) -> NWEndpoint.Host {
    let lowered = hostname.lowercased()
    if lowered == "::1" || lowered == "[::1]" { return .ipv6(.loopback) }
    if lowered == "localhost" { return .ipv4(.loopback) }
    if let address = IPv4Address(hostname) { return .ipv4(address) }
    if let address = IPv6Address(hostname) { return .ipv6(address) }
    return .ipv4(.loopback)
  }

  // MARK: Counters and tickets

  private func enterRequest() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if stopped { return false }
    inFlight += 1
    return inFlight <= Protocol.maxInFlightRequests
  }

  private func leaveRequest() {
    lock.lock()
    inFlight -= 1
    lock.unlock()
  }

  /// Sweeps the expired, refuses past 256, mints one. Bun does all three in
  /// this order inside the route, so the cap is on live tickets, not total.
  private func mintTicket(origin: String, path: String, readOnly: Bool) -> String? {
    var bytes = [UInt8]()
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<32 { bytes.append(UInt8.random(in: 0...255, using: &generator)) }
    let value = Protocol.ticketPrefix + bytes.map { String(format: "%02x", $0) }.joined()
    lock.lock()
    defer { lock.unlock() }
    let now = Date()
    tickets = tickets.filter { $0.value.expires > now }
    if tickets.count >= 256 { return nil }
    tickets[value] = Ticket(
      origin: origin, path: path,
      expires: now.addingTimeInterval(TimeInterval(Protocol.ticketLifetimeSeconds)),
      readOnly: readOnly)
    return value
  }

  /// Single use: the ticket is removed as it is read, with nothing awaited in
  /// between, so two sockets can never spend the same one.
  private func claimTicket(_ value: String) -> Ticket? {
    lock.lock()
    defer { lock.unlock() }
    guard let ticket = tickets[value] else { return nil }
    tickets.removeValue(forKey: value)
    return ticket
  }

  // MARK: The handler

  fileprivate func handle(head: HTTPRequestHead, body: Data) async -> (RequestOutcome, HeaderBag) {
    var headers = HeaderBag()
    headers.set("Cache-Control", "no-store")
    headers.set("X-Content-Type-Options", "nosniff")

    func failure(_ status: Int, _ error: String) -> RequestOutcome {
      .response(status: status, body: jsonBody(errorBody(error)), note: error)
    }
    func value(_ payload: JSONValue, _ status: Int = 200) -> RequestOutcome {
      .response(status: status, body: jsonBody(payload), note: nil)
    }

    let admitted = enterRequest()
    defer { leaveRequest() }
    if !admitted { return (failure(503, "server_busy"), headers) }

    let hostHeader = head.headers["host"] ?? ""
    guard authorityParses(hostHeader) else {
      // Bun's own error handler answers this one, and it sets Cache-Control
      // and nothing else — no nosniff, no CORS.
      var bare = HeaderBag()
      bare.set("Cache-Control", "no-store")
      return (.response(status: 500, body: jsonBody(errorBody("request_failed")), note: "request_failed"), bare)
    }
    guard loopbackAuthority(hostHeader) else {
      return (failure(403, "host_not_allowed"), headers)
    }

    var origin = ""
    switch decideOrigin(header: head.headers["origin"], allowed: config.allowOrigins) {
    case .none:
      origin = ""
    case .allowed(let allowed):
      origin = allowed
      headers.set("Access-Control-Allow-Origin", allowed)
      headers.set("Vary", "Origin")
    case .refused:
      // Thrown in Bun, so it lands in the catch that logs without a note.
      return (.response(status: 403, body: jsonBody(errorBody("origin_not_allowed")), note: nil), headers)
    }

    if head.method == "OPTIONS" {
      headers.append(
        "Vary", "Access-Control-Request-Method, Access-Control-Request-Headers, Access-Control-Request-Private-Network")
      let requestedMethod = head.headers["access-control-request-method"] ?? ""
      if origin.isEmpty || !["GET", "POST"].contains(requestedMethod) {
        return (failure(403, "preflight_not_allowed"), headers)
      }
      let requestedHeaders = head.headers["access-control-request-headers"]
      let names = requestedHeaders.map {
        $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      } ?? []
      if Set(names).count != names.count || names.contains(where: { !["authorization", "content-type"].contains($0) }) {
        return (failure(403, "preflight_not_allowed"), headers)
      }
      let privateNetwork = head.headers["access-control-request-private-network"]
      if let privateNetwork, privateNetwork != "true" {
        return (failure(403, "preflight_not_allowed"), headers)
      }
      if privateNetwork != nil { headers.set("Access-Control-Allow-Private-Network", "true") }
      headers.set("Access-Control-Allow-Methods", "GET, POST")
      headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type")
      return (.response(status: 204, body: nil, note: nil), headers)
    }

    let allowed: [String]
    switch head.path {
    case "/api/auth/ws-ticket", "/api/send", "/api/wake", "/api/worktrees/cleanup": allowed = ["POST"]
    case "/api/asks", "/api/ui-state", "/api/feed": allowed = ["GET", "POST"]
    default: allowed = ["GET"]
    }
    func methodError() -> RequestOutcome {
      headers.set("Allow", allowed.joined(separator: ", "))
      return failure(405, "method_not_allowed")
    }

    if head.path == "/ws" || head.path == "/ws/pty" {
      if head.method != "GET" { return (methodError(), headers) }
      if origin.isEmpty || head.hasQuery { return (failure(400, "websocket_request_invalid"), headers) }
      let offers = (head.headers["sec-websocket-protocol"] ?? "")
        .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      var readOnly = false
      // The tokenless demo is /ws only: a pty is a shell, never a demo.
      let ticketless = config.insecure && head.path == "/ws" && offers.count == 1 && offers[0] == ""
      if ticketless {
        readOnly = true
      } else {
        guard offers.count == 2, offers[0] == Protocol.webSocket else {
          return (failure(401, "websocket_ticket_required"), headers)
        }
        let shape = #"^mwt1_[0-9a-f]{64}$"#
        guard offers[1].range(of: shape, options: .regularExpression) != nil,
          let ticket = claimTicket(offers[1]), ticket.origin == origin, ticket.path == head.path,
          ticket.expires > Date()
        else { return (failure(401, "websocket_ticket_invalid"), headers) }
        readOnly = ticket.readOnly
      }
      if sockets.activeCount >= Protocol.maxSockets {
        return (failure(503, "websocket_capacity_reached"), headers)
      }
      if offers.contains(Protocol.webSocket) { headers.set("Sec-WebSocket-Protocol", Protocol.webSocket) }
      guard let accept = websocketAccept(head) else {
        return (failure(400, "websocket_request_invalid"), headers)
      }
      headers.set("Upgrade", "websocket")
      headers.set("Connection", "Upgrade")
      headers.set("Sec-WebSocket-Accept", accept)
      return (.upgrade(path: head.path, readOnly: readOnly), headers)
    }

    let writeRoutes: Set<String> = ["/api/send", "/api/wake", "/api/worktrees/cleanup"]
    let isWrite = head.path != "/api/auth/ws-ticket"
      && (head.method == "POST" || writeRoutes.contains(head.path))
    let authorization = head.headers["authorization"] ?? ""
    var authenticated = false
    if tokenConfigured && authorization.hasPrefix("Bearer ") {
      let presented = Data(String(authorization.dropFirst("Bearer ".count)).utf8)
      authenticated = constantTimeEqual(Data(SHA256.hash(data: presented)), tokenHash)
    }
    if config.insecure && !isWrite {
      // Read-only demo access.
    } else if config.insecure && isWrite {
      return (failure(401, "operator_token_required_for_writes"), headers)
    } else if !authenticated {
      if head.path == "/api/send" && head.method == "POST" {
        deliveryHistory.append(
          jsonObject([
            ("timestamp", .int(unixSeconds())), ("kind", .string("message")), ("direction", .string("inbound")),
            ("state", .string("failed")), ("route", .string("auth")), ("event", .string("auth-reject")),
            ("decision", .string("operator_token_required")), ("source", .string("herdr")), ("from", .string("")),
            ("to", .string("")), ("target", .string("")), ("text", .string("")), ("oracle", .string("")),
          ]).object!)
      }
      return (failure(401, "operator_token_required"), headers)
    }

    if !allowed.contains(head.method) { return (methodError(), headers) }

    if head.path == "/api/auth/ws-ticket" {
      if origin.isEmpty || head.hasQuery { return (failure(400, "ticket_request_invalid"), headers) }
      do {
        let parsed = try readJSON(head: head, body: body, limit: 128)
        guard let object = parsed.object, object.keys.allSatisfy({ $0 == "path" }),
          object["path"] == nil || object["path"]!.string != nil
        else { return (failure(400, "invalid_json"), headers) }
        guard let path = object["path"]?.string, path == "/ws" || path == "/ws/pty" else {
          return (failure(400, "ticket_path_invalid"), headers)
        }
        guard let ticket = mintTicket(origin: origin, path: path, readOnly: config.insecure && !authenticated)
        else { return (failure(429, "too_many_tickets"), headers) }
        return (value(jsonObject([("protocol", .string(Protocol.webSocket)), ("ticket", .string(ticket))])), headers)
      } catch let error as HTTPFailure {
        return (failure(error.status, error.message), headers)
      } catch {
        return (failure(400, "invalid_json"), headers)
      }
    }

    do {
      return (.response(status: 200, body: jsonBody(try await route(head: head, body: body)), note: nil), headers)
    } catch let error as HTTPFailure {
      let payload = error.body ?? errorBody(error.message)
      return (.response(status: error.status, body: jsonBody(payload), note: nil), headers)
    } catch let error as HTTPStatusError {
      return (.response(status: error.status, body: jsonBody(errorBody(error.code)), note: nil), headers)
    } catch BackendError.unknownTarget {
      return (failure(404, "target_not_found"), headers)
    } catch BackendError.notAgent {
      return (failure(409, "target_not_agent"), headers)
    } catch {
      if head.path == "/api/health" || head.path == "/health" {
        return (
          .response(
            status: 503, body: jsonBody(jsonObject([("ok", .bool(false)), ("error", .string("herdr_unavailable"))])),
            note: nil), headers
        )
      }
      return (failure(503, "herdr_unavailable"), headers)
    }
  }

  /// Measured against the reference, not read off RFC 6455. Bun upgrades on a
  /// well-formed `Sec-WebSocket-Key` alone: it answers 101 with no `Upgrade`
  /// header, no `Connection: upgrade`, and `Sec-WebSocket-Version: 8`. Adding
  /// those checks here would refuse clients the reference accepts, so the only
  /// test is the one Bun actually makes — a 24-character key. Not valid
  /// base64, not 16 decoded bytes: 24 characters. `!!!!!!!!!!!!!!!!!!!!!!!!`
  /// gets a 101 out of the reference server, and now out of this one.
  private func websocketAccept(_ head: HTTPRequestHead) -> String? {
    guard let key = head.headers["sec-websocket-key"], key.utf8.count == 24 else { return nil }
    let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
    return Data(digest).base64EncodedString()
  }

  // MARK: Routes (mod.serveAPI.ts)

  private func route(head: HTTPRequestHead, body: Data) async throws -> JSONValue {
    switch head.path {
    case "/api/sessions":
      return sessionsJSON(try await backend.roster().sessions)

    case "/api/agent", "/api/agents":
      var agents: [JSONValue] = []
      for session in try await backend.roster().sessions {
        for window in session.windows {
          agents.append(
            jsonObject([
              ("node", .string(config.node)), ("session", .string(session.name)),
              ("window", .string(String(window.index))), ("oracle", .string(window.name)),
              ("state", .string(window.status == "working" ? "active" : "idle")), ("pid", .null),
            ]))
        }
      }
      return jsonObject([("agents", .array(agents)), ("count", .int(agents.count)), ("node", .string(config.node))])

    case "/api/capture":
      guard let target = head.query["target"], !target.isEmpty else { throw HTTPFailure(400, "target_required") }
      do {
        let content = try await backend.capture(target: target, lines: 200)
        return jsonObject([("content", .string(content)), ("target", .string(target)), ("resolvedTarget", .string(target))])
      } catch {
        throw HTTPFailure(
          400, "capture_unavailable",
          body: jsonObject([
            ("content", .string("")), ("target", .string(target)), ("resolvedTarget", .string(target)),
            ("error", .string("capture_unavailable")),
          ]))
      }

    case "/api/captures":
      var requests: [String: Int] = [:]
      for session in try await backend.roster().sessions {
        for window in session.windows { requests["\(session.name):\(window.index)"] = 200 }
      }
      if requests.count > 64 { throw HTTPFailure(400, "too_many_captures") }
      let captures = try await backend.captureBatch(requests)
      // `Object.keys(targets).sort()` decides the key order of the result.
      return jsonObject([
        ("captures", jsonObject(captures.keys.sorted(by: jsLess).map { ($0, JSONValue.string(captures[$0]!)) }))
      ])

    case "/api/send":
      return try await send(head: head, body: body)

    case "/api/wake":
      return try await wake(head: head, body: body)

    case "/api/identity":
      return jsonObject([
        ("version", .string("herdr-core-dev")), ("runtime", .string("swift")), ("node", .string(config.node)),
        ("host", .string("localhost")), ("agents", .array([])),
        ("uptime", .int(Int(Date().timeIntervalSince(started)))), ("clockUtc", .string(iso8601UTC(Date()))),
        ("endpoints", .strings(["/api/sessions", "/api/capture", "/api/send", "/api/wake", "/ws", "/ws/pty"])),
        (
          "capabilities",
          .strings(["sessions", "capture", "agent-prompt", "dashboard-ws", "terminal-stream", "existing-pane-wake"])
        ),
      ])

    case "/api/teams":
      _ = try await backend.roster()
      return try backend.teamInventory()

    case "/api/feed":
      if head.method == "POST" { return try feedActivity(body: body) }
      let limits = head.queryAll("limit")
      if limits.count > 1 { throw HTTPFailure(400, "invalid_limit") }
      var limit: Int?
      if let raw = limits.first {
        // `/^[0-9]+$/` and at most 2^64-1, then clamped to 200 — so a 30-digit
        // limit is refused while "999" is simply 200.
        guard raw.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil, !raw.isEmpty,
          let parsed = Decimal(string: raw), parsed <= Decimal(string: "18446744073709551615")!
        else { throw HTTPFailure(400, "invalid_limit") }
        limit = parsed > 200 ? 200 : Int(truncating: parsed as NSDecimalNumber)
      }
      return deliveryHistory.snapshot(limit: limit)

    case "/api/health", "/health":
      _ = try await backend.roster()
      return jsonObject([("ok", .bool(true))])

    // Present on the Bun server, not ported: they depend on modules outside
    // this port (federation probes, worktree cleanup, state files, costs).
    case "/api/costs", "/api/config", "/api/asks", "/api/ui-state", "/api/worktrees", "/api/worktrees/cleanup",
      "/api/federation/status", "/fed.json":
      throw HTTPFailure(501, "not_implemented")

    default:
      throw HTTPFailure(404, "not_found")
    }
  }

  // MARK: /api/feed POST (mod.serveFeedActivity.ts)

  /// "Legacy feed POST acknowledges non-JSON/missing oracle without injecting
  /// events." No content-type check, 64 KiB cap, and a body that is not JSON is
  /// simply `{ok:true}`.
  private func feedActivity(body: Data) throws -> JSONValue {
    if body.count > 64 << 10 { throw HTTPFailure(400, "invalid_feed_body") }
    // `new TextDecoder('utf-8', {fatal: true})` strips a leading BOM here.
    guard var text = strictUTF8(body) else { return jsonObject([("ok", .bool(true))]) }
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    guard let parsed = try? parseJSON(text) else { return jsonObject([("ok", .bool(true))]) }
    if let oracle = parsed["oracle"]?.string, !jsTrim(oracle).isEmpty {
      if byteLength(oracle) > 1024 { throw HTTPFailure(400, "invalid_feed_oracle") }
      if !backend.observedFeed.markActivity(oracle) { throw HTTPFailure(429, "feed_activity_capacity_reached") }
    }
    return jsonObject([("ok", .bool(true))])
  }

  // MARK: /api/send (mod.serveAPI.ts + claimDelivery + recordDelivery)

  private func send(head: HTTPRequestHead, body: Data) async throws -> JSONValue {
    let command: SendCommand
    do {
      command = try validateCommand(try readJSON(head: head, body: body, limit: 64 << 10))
    } catch let error as HTTPFailure {
      throw error
    } catch {
      throw HTTPFailure(400, "invalid_json")
    }
    let originalText = command.text
    var text = command.text
    if let attachments = command.attachments, !attachments.isEmpty {
      text = (attachments + [command.text ?? ""]).joined(separator: "\n")
    }
    let target = command.target ?? ""
    if target.isEmpty || isBlank(target) {
      deliveryHistory.append(
        jsonObject([
          ("timestamp", .int(unixSeconds())), ("kind", .string("message")), ("direction", .string("inbound")),
          ("state", .string("failed")), ("route", .string("validate")), ("target", .string(target)),
          ("text", .string(text ?? "")), ("from", .string("")), ("to", .string("")), ("oracle", .string("")),
          ("source", .string("herdr")), ("error", .string("empty-target")),
        ]).object!)
      throw HTTPFailure(
        400, "empty-target",
        body: jsonObject([("ok", .bool(false)), ("error", .string("empty-target")), ("state", .string("failed"))]))
    }
    let from = head.headers["x-maw-from"] ?? ""
    if command.inbox {
      let claim = try await claimDelivery(head: head, target: target, text: text ?? "", responseText: originalText ?? "", source: "inbox")
      if let duplicate = claim.duplicate {
        await recordDelivery(head: head, target: target, text: text ?? "", route: "inbox", state: "deduped")
        return duplicate
      }
      defer { claim.cancel() }
      do {
        let inbox = try await backend.inbox(target: target, text: text ?? "", serverRoot: config.worktreeRoot, from: from)
        claim.complete("queued")
        await recordDelivery(head: head, target: target, text: text ?? "", route: "inbox", state: "queued")
        return jsonObject([
          ("ok", .bool(true)), ("target", .string(target)), ("text", .string(originalText ?? "")),
          ("source", .string("inbox")), ("state", .string("queued")), ("inbox", .string(inbox)),
          ("reason", .string("--inbox requested; pane injection skipped")), ("receipt", .strings(["fallback_queued"])),
        ])
      } catch {
        await recordDelivery(head: head, target: target, text: text ?? "", route: "inbox", state: "failed")
        throw error
      }
    }
    guard let outgoing = text, !outgoing.isEmpty else { throw HTTPFailure(400, "target_and_text_required") }
    if command.force { throw HTTPFailure(501, "send_options_not_supported") }
    let claim = try await claimDelivery(head: head, target: target, text: outgoing, responseText: outgoing, source: "local")
    if let duplicate = claim.duplicate {
      await recordDelivery(head: head, target: target, text: outgoing, route: "local", state: "deduped")
      return duplicate
    }
    defer { claim.cancel() }
    do {
      try await backend.send(target: target, text: outgoing)
      claim.complete("accepted")
      await recordDelivery(head: head, target: target, text: outgoing, route: "local", state: "accepted")
      return jsonObject([
        ("ok", .bool(true)), ("target", .string(target)), ("text", .string(outgoing)), ("source", .string("local")),
        ("lastLine", .string("")), ("state", .string("accepted")),
        ("receipt", .strings(["herdr agent prompt accepted"])),
        (
          "warning",
          .string("Prompt acceptance does not imply consumption or completion; this path does not queue an inbox message.")
        ),
      ])
    } catch {
      await recordDelivery(head: head, target: target, text: outgoing, route: "local", state: "failed")
      throw error
    }
  }

  private struct ClaimOutcome {
    let duplicate: JSONValue?
    let complete: @Sendable (String) -> Void
    let cancel: @Sendable () -> Void
  }

  /// "Correlation metadata under operator auth; these headers do not verify
  /// identity." Without `X-Maw-Timestamp` / `X-Maw-Signed-At` there is no key
  /// and nothing is claimed.
  private func claimDelivery(head: HTTPRequestHead, target: String, text: String, responseText: String, source: String) async throws -> ClaimOutcome {
    var logical = jsTrim(head.headers["x-maw-timestamp"] ?? "")
    if logical.isEmpty { logical = jsTrim(head.headers["x-maw-signed-at"] ?? "") }
    if logical.isEmpty { return ClaimOutcome(duplicate: nil, complete: { _ in }, cancel: {}) }
    let rawFrom = head.headers["x-maw-from"] ?? ""
    if byteLength(logical) > 1024 || byteLength(rawFrom) > 1024 { throw HTTPFailure(400, "invalid_delivery_metadata") }
    let sessions = try await backend.roster().sessions
    guard sessions.contains(where: { session in session.windows.contains { "\(session.name):\($0.index)" == target } })
    else { throw HTTPFailure(404, "target_not_found") }
    var from = jsTrim(rawFrom)
    if from.isEmpty {
      let merged: JSONObject
      do {
        merged = try readMawConfig(cwd: config.worktreeRoot)
      } catch is MawConfigUnavailable {
        throw HTTPStatusError(status: 503, code: "config_unavailable")
      }
      from = try await resolveInboxSender(raw: "", config: merged, serverRoot: config.worktreeRoot, op: HerdrOp())
    }
    let key = delivery.key(source: from, target: target, logical: logical, payload: text)!
    let claim: DeliveryClaim
    do {
      claim = try delivery.claim(key)
    } catch {
      throw HTTPFailure(429, "delivery_capacity_reached")
    }
    if let state = claim.duplicateState {
      let reason = "duplicate delivery dropped by idempotency key"
      return ClaimOutcome(
        duplicate: jsonObject([
          ("ok", .bool(true)), ("target", .string(target)), ("text", .string(responseText)),
          ("source", .string(source)), ("state", .string(state)), ("deduped", .bool(true)),
          ("idempotent", .bool(true)), ("reason", .string(reason)), ("lastLine", .string(reason)),
          ("receipt", .strings(["duplicate_dropped"])),
        ]), complete: { _ in }, cancel: {})
    }
    return ClaimOutcome(duplicate: nil, complete: claim.complete, cancel: claim.cancel)
  }

  private func recordDelivery(head: HTTPRequestHead, target: String, text: String, route: String, state: String) async {
    var oracle = ""
    // Unknown identity must not turn accepted delivery into failure.
    if let sessions = try? await backend.roster().sessions {
      for session in sessions {
        for window in session.windows where "\(session.name):\(window.index)" == target { oracle = window.name }
      }
    }
    deliveryHistory.append(
      jsonObject([
        ("timestamp", .int(unixSeconds())), ("kind", .string(state == "failed" ? "message" : "context.message")),
        ("direction", .string("inbound")), ("state", .string(state)), ("route", .string(route)),
        ("from", .string(jsTrim(head.headers["x-maw-from"] ?? ""))), ("to", .string(oracle)), ("target", .string(target)),
        ("text", .string(text)), ("oracle", .string(oracle)), ("source", .string("herdr")),
      ]).object!)
  }

  // MARK: /api/wake

  private func wake(head: HTTPRequestHead, body: Data) async throws -> JSONValue {
    let parsed = try readJSON(head: head, body: body, limit: 64 << 10)
    guard let object = parsed.object else { throw HTTPFailure(400, "invalid_json") }
    for (key, item) in object.entries {
      guard ["target", "task", "command"].contains(key) else { throw HTTPFailure(400, "invalid_json") }
      guard item.isNull || item.string != nil else { throw HTTPFailure(400, "invalid_json") }
    }
    guard let target = object["target"]?.string, !target.isEmpty, byteLength(target) <= 1024 else {
      throw HTTPFailure(400, "target_required")
    }
    let task = object["task"]?.string
    if let task, byteLength(task) > 1024 { throw HTTPFailure(400, "invalid_task") }
    let state = try await backend.wake(target: target, task: task)
    return jsonObject([("ok", .bool(true)), ("target", .string(target)), ("state", .string(state.rawValue))])
  }

  // MARK: Body (mod.readJSON.ts, mod.validateCommand.ts)

  private func readJSON(head: HTTPRequestHead, body: Data, limit: Int) throws -> JSONValue {
    let contentType = head.headers["content-type"] ?? ""
    guard
      contentType.range(
        of: #"^application/json(?:\s*;.*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    else { throw HTTPFailure(415, "application_json_required") }
    guard body.count <= limit else { throw HTTPFailure(400, "invalid_json") }
    guard let parsed = try? parseJSON(body) else { throw HTTPFailure(400, "invalid_json") }
    return parsed
  }

  private struct SendCommand {
    var target: String?
    var text: String?
    var attachments: [String]?
    var force = false
    var inbox = false
  }

  private func validateCommand(_ value: JSONValue) throws -> SendCommand {
    guard let object = value.object else { throw HTTPFailure(400, "invalid_json") }
    var command = SendCommand()
    for (key, item) in object.entries {
      switch key {
      case "target", "text":
        if item.isNull { continue }
        guard let string = item.string else { throw HTTPFailure(400, "invalid_json") }
        if key == "target" { command.target = string } else { command.text = string }
      case "attachments":
        if item.isNull { continue }
        guard let list = item.array else { throw HTTPFailure(400, "invalid_json") }
        var strings: [String] = []
        for element in list {
          guard let string = element.string else { throw HTTPFailure(400, "invalid_json") }
          strings.append(string)
        }
        command.attachments = strings
      case "force", "inbox":
        if item.isNull { continue }
        guard let flag = item.bool else { throw HTTPFailure(400, "invalid_json") }
        if key == "force" { command.force = flag } else { command.inbox = flag }
      default:
        throw HTTPFailure(400, "invalid_json")
      }
    }
    return command
  }

  // MARK: Response

  fileprivate func log(_ entry: AccessEntry) { access.record(entry) }

  fileprivate func adopt(connection: NWConnection, path: String, readOnly: Bool, leftover: Data) {
    sockets.attach(connection: connection, path: path, readOnly: readOnly, leftover: leftover)
  }
}

// MARK: - Connection

/// One TCP connection: read a request, answer it, close. The exception is a
/// successful upgrade, which hands the socket to the WebSocket module and stops
/// touching it.
private final class HTTPConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let server: HerdrHTTPServer
  private let queue: DispatchQueue
  private var buffer = Data()
  private var head: HTTPRequestHead?
  private var overflow = false
  private var expected = 0
  private var startedAt = DispatchTime.now()
  private var dispatched = false
  private var responded = false
  private var finished = false
  private var idle: DispatchSourceTimer?
  /// Bun's `AbortSignal.any([shutdown, request.signal, deadline])`: the handler
  /// task is cancelled when the client goes away or 15s pass, which kills any
  /// herdr subprocess still running for it.
  private var handler: Task<Void, Never>?
  private var deadline: DispatchSourceTimer?
  /// Self-ownership: nothing else holds this object, so it holds itself from
  /// `start()` until the response is written or the socket is handed off.
  private var retain: HTTPConnection?

  private static let headerLimit = 64 * 1024

  init(connection: NWConnection, server: HerdrHTTPServer) {
    self.connection = connection
    self.server = server
    self.queue = DispatchQueue(label: "maw.herdr.http.connection")
  }

  func start() {
    retain = self
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        self?.handler?.cancel()
        self?.close()
      default: break
      }
    }
    connection.start(queue: queue)
    armIdleTimer()
    receive()
  }

  private func armIdleTimer() {
    idle?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 20)
    timer.setEventHandler { [weak self] in
      guard let self, !self.dispatched else { return }
      self.connection.cancel()
    }
    timer.resume()
    idle = timer
  }

  private func cancelIdle() {
    idle?.cancel()
    idle = nil
  }

  private func release() {
    cancelIdle()
    deadline?.cancel()
    deadline = nil
    retain = nil
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        self.buffer.append(data)
        self.armIdleTimer()
        self.pump()
      }
      if error != nil { self.close(); return }
      if isComplete {
        // A half-closed client with a complete request still gets its answer;
        // the send completion closes the socket afterwards.
        if !self.dispatched { self.close() }
        return
      }
      if !self.dispatched { self.receive() }
    }
  }

  private func pump() {
    if dispatched { return }
    if head == nil {
      let crlf = buffer.range(of: Data("\r\n\r\n".utf8))
      let lf = buffer.range(of: Data("\n\n".utf8))
      // Whichever terminator comes first is the one the client meant.
      let separator: Range<Data.Index>
      switch (crlf, lf) {
      case (let c?, let l?): separator = c.lowerBound <= l.lowerBound ? c : l
      case (let c?, nil): separator = c
      case (nil, let l?): separator = l
      case (nil, nil):
        if buffer.count > HTTPConnection.headerLimit { respondBare(431, note: "request_header_fields_too_large") }
        return
      }
      startedAt = DispatchTime.now()
      let block = buffer.subdata(in: buffer.startIndex..<separator.lowerBound)
      buffer = Data(buffer[separator.upperBound...])
      // Bare LF: the reference's parser reads the version token to the end of
      // the line, never finds one, and answers 505. Measured, not invented.
      let crlfTerminated = crlf != nil && crlf!.lowerBound == separator.lowerBound
      var bareLF = !crlfTerminated
      if !bareLF {
        let bytes = [UInt8](block)
        for (index, byte) in bytes.enumerated() where byte == 0x0a {
          if index == 0 || bytes[index - 1] != 0x0d { bareLF = true; break }
        }
      }
      if bareLF {
        respondBare(505, note: "http_version_not_supported")
        return
      }
      guard let parsed = parseRequestHead(block) else {
        respondBare(400, note: "invalid_request")
        return
      }
      // uWebSockets speaks 1.0 and 1.1 and answers 505 to anything else.
      if parsed.version != "HTTP/1.1" && parsed.version != "HTTP/1.0" {
        head = parsed
        respondBare(505, note: "http_version_not_supported")
        return
      }
      // HTTP/1.1 without Host never reaches the reference's handler either.
      if parsed.version == "HTTP/1.1" && parsed.headers["host"] == nil {
        head = parsed
        respondBare(400, note: "host_required")
        return
      }
      head = parsed
      expected = parsed.contentLength ?? 0
      if expected > Protocol.maxRequestBody { overflow = true }
    }
    guard let head else { return }
    if overflow {
      // Measured against the reference: Bun answers an oversized body at the
      // server level, before the handler exists — "413 Request Entity Too
      // Large", `Connection: close`, no other header and no body at all.
      respondBare(413, note: "request_body_too_large")
      return
    }
    guard buffer.count >= expected else { return }
    let body = Data(buffer.prefix(expected))
    let leftover = Data(buffer.dropFirst(expected))
    dispatch(head: head, body: body, leftover: leftover)
  }

  private func dispatch(head: HTTPRequestHead, body: Data, leftover: Data) {
    dispatched = true
    cancelIdle()
    let began = startedAt
    let ip = clientIP()
    let task = Task { [server] in
      let (outcome, headers) = await server.handle(head: head, body: body)
      self.complete(outcome: outcome, headers: headers, head: head, ip: ip, began: began, leftover: leftover)
    }
    handler = task
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 15)
    timer.setEventHandler { task.cancel() }
    timer.resume()
    deadline = timer
    // One receive stays armed from here on. Before the response it is
    // `request.signal`: a client that hangs up mid-flight cancels the handler,
    // killing any herdr subprocess run for a request nobody awaits. After the
    // response it is the graceful-close wait: the server does NOT close first,
    // so no RST reaches a client still reading the body (Bun's `fetch` reported
    // exactly that on ~10% of requests), and the client — not the server — is
    // the one left in TIME_WAIT. Not for an upgrade: post-101 bytes are the
    // socket module's.
    if head.path != "/ws" && head.path != "/ws/pty" { monitorPeer() }
  }

  /// A single receive stays armed while the handler runs so a client that hangs
  /// up mid-flight cancels it, killing any herdr subprocess run for a request
  /// nobody awaits. Once the response is out the connection is closed
  /// immediately (`Connection: close`); this only matters before then.
  private func monitorPeer() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
      guard let self, !self.finished else { return }
      if !self.responded && (error != nil || isComplete) {
        self.handler?.cancel()
        self.close()
        return
      }
      if self.finished || self.responded { return }
      self.monitorPeer()
    }
  }

  private func complete(
    outcome: RequestOutcome, headers: HeaderBag, head: HTTPRequestHead, ip: String,
    began: DispatchTime, leftover: Data
  ) {
    let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000
    switch outcome {
    case .response(let status, let body, let note):
      let entry = AccessEntry(
        ip: ip, method: head.method, path: head.path, query: head.queryPairs, status: status,
        // Bun reads Content-Length off its own Response, which `Response.json`
        // never sets — so the size column is "-" there, and is here too.
        bytes: nil, milliseconds: milliseconds, origin: head.headers["origin"] ?? "", note: note)
      server.log(entry)
      // Stop the mid-flight disconnect watch, then send and close. Immediate
      // close is standard `Connection: close`: curl, undici and browsers all
      // handle it cleanly. Bun's own `fetch`, which pools aggressively, can
      // race the close and report "socket closed unexpectedly" on a small
      // fraction of rapid requests — a client artifact of the mandated header,
      // reproduced against any Connection: close server; see the report.
      responded = true
      write(serialize(status: status, headers: headers, body: body), thenClose: true)
    case .upgrade(let path, let readOnly):
      let entry = AccessEntry(
        ip: ip, method: head.method, path: head.path, query: head.queryPairs, status: 101, bytes: nil,
        milliseconds: milliseconds, origin: head.headers["origin"] ?? "",
        // A socket carries no response status, so the upgrade is logged as the
        // 101 it is; otherwise the busiest client never appears in the log.
        note: readOnly ? "ws read-only" : "ws")
      server.log(entry)
      let bytes = serialize(status: 101, headers: headers, body: nil)
      connection.send(
        content: bytes,
        completion: .contentProcessed { [weak self] error in
          guard let self else { return }
          if error != nil { self.close(); return }
          self.finished = true
          self.connection.stateUpdateHandler = nil
          // Everything after the handshake belongs to the socket module,
          // including any frame that arrived in the same packet.
          self.server.adopt(
            connection: self.connection, path: path, readOnly: readOnly, leftover: leftover)
          self.release()
        })
    }
  }

  /// RFC 1123, GMT, C locale — never the machine's locale or timezone.
  private static let imfFixdate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter
  }()

  private func httpDate(_ when: Date) -> String { HTTPConnection.imfFixdate.string(from: when) }

  private func serialize(status: Int, headers: HeaderBag, body: Data?) -> Data {
    var bag = headers
    if let body {
      // Bun's header order on a JSON response is Content-Type, Date,
      // Content-Length; HeaderBag preserves insertion order, so setting them in
      // that sequence reproduces it. Bun gets Date from its runtime — without
      // this the port was the only one of the two omitting a Date header.
      bag.set("Content-Type", "application/json;charset=utf-8")
      bag.set("Date", httpDate(Date()))
      bag.set("Content-Length", String(body.count))
    } else if status != 101 && status != 204 {
      bag.set("Date", httpDate(Date()))
      bag.set("Content-Length", "0")
    }
    if status != 101 { bag.set("Connection", "close") }
    var text = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
    for entry in bag.entries { text += "\(entry.name): \(entry.value)\r\n" }
    text += "\r\n"
    var out = Data(text.utf8)
    if let body { out.append(body) }
    return out
  }

  /// A status line and nothing else. Bun's body-size rejection carries no
  /// Cache-Control, no Content-Type and no payload, so neither does this one.
  /// The access line is kept anyway: Bun logs nothing here, and a 413 that
  /// leaves no trace is indistinguishable from a request that never arrived.
  private func respondBare(_ status: Int, note: String) {
    dispatched = true
    cancelIdle()
    server.log(
      AccessEntry(
        ip: clientIP(), method: head?.method ?? "-", path: head?.path ?? "-",
        query: head?.queryPairs ?? [], status: status, bytes: nil,
        milliseconds: Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000,
        origin: head?.headers["origin"] ?? "", note: note))
    let text = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\nConnection: close\r\n\r\n"
    write(Data(text.utf8), thenClose: true)
  }

  private func write(_ data: Data, thenClose: Bool) {
    connection.send(
      content: data,
      completion: .contentProcessed { [weak self] _ in
        if thenClose { self?.close() }
      })
  }

  private func close() {
    if finished { return }
    finished = true
    connection.stateUpdateHandler = nil
    // Cancel the handler too: a client that read its response and hung up must
    // not leave a herdr subprocess running for a request nobody is waiting on.
    handler?.cancel()
    connection.cancel()
    release()
  }

  private func clientIP() -> String {
    guard case .hostPort(let host, _) = connection.endpoint else { return "" }
    var text = "\(host)"
    if let percent = text.firstIndex(of: "%") { text = String(text[text.startIndex..<percent]) }
    return text
  }
}

// MARK: - Process-level helpers used by main.swift

/// Holds the signal sources alive. A `DispatchSource` that nothing retains is
/// cancelled on deinit, which turns a graceful shutdown into an unhandled
/// signal — the failure looks like the handler was never installed.
private final class SignalTrap: @unchecked Sendable {
  private let lock = NSLock()
  private var sources: [DispatchSourceSignal] = []

  func install(_ signals: [Int32], handler: @escaping @Sendable () -> Void) {
    for number in signals {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler(handler: handler)
      source.resume()
      lock.lock()
      sources.append(source)
      lock.unlock()
    }
  }
}

private let signalTrap = SignalTrap()

func installShutdownSignals(_ handler: @escaping @Sendable () -> Void) {
  signalTrap.install([SIGINT, SIGTERM, SIGHUP], handler: handler)
}

func scheduleDemoStop(minutes: Int, _ handler: @escaping @Sendable () -> Void) {
  guard minutes > 0 else { return }
  DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(minutes * 60), execute: handler)
}

func warn(_ text: String) {
  FileHandle.standardError.write(Data((text + "\n").utf8))
}
