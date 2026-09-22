import CryptoKit
import Foundation
import Network

// Port of the federation surface: `/api/federation/status` and `/fed.json`,
// plus the `namedPeers` fallback `/api/config` reads.
//
//   mod.readFederationConfig.ts  — ~/.maw/peers.json, the signing identity
//                                  (MAW_SENDER / merged maw config), the fleet
//                                  token and the peer key, and a fingerprint
//                                  of all five that keys the cache
//   mod.probeFederationPeer.ts   — one signed GET <peer>/api/sessions, pinned
//                                  to the first resolved address, 2.5 s budget
//   mod.createFederation.ts      — at most four probes at once, a 10 s sweep,
//                                  a 15 s cache and one flight per fingerprint
//
// The probe is a hand-rolled HTTP/1.1 client over NWConnection rather than
// URLSession, because node's `lookup` option pins the TCP connection to the
// address it chose while the URL keeps its hostname for Host and SNI — and
// URLSession offers no such pin. Every classification a peer can receive
// (`address_not_allowed`, `network_error`, `timeout`, `http_<n>`,
// `response_too_large`, `invalid_response`) is the reference's, produced at
// the same point in the exchange.

// MARK: - peers.json (mod.readFederationConfig.ts)

struct FederationPeer: Sendable {
  var name: String
  var url: String
  var node: String?
  var oracle: String?
  var authOk: Bool?
}

struct FederationConfig: Sendable {
  var peers: [FederationPeer]
  var sender: String
  var fleet: String
  var key: String
  var fingerprint: String
}

private func federationUnavailable() -> HTTPStatusError { HTTPStatusError(status: 503, code: "federation_unavailable") }

/// The reference's guarded `read`: nil when the file is absent; throws
/// `federation_unavailable` when it exists and cannot be trusted — a symlink
/// anywhere in the path, a device/inode swap between the lstat and the open,
/// a file over `limit`, or invalid UTF-8.
private func federationRead(_ path: String, limit: Int) throws -> String? {
  var ancestors: [String] = []
  var current = NodePath.resolve(path)
  while true {
    ancestors.append(current)
    let parent = NodePath.dirname(current)
    if parent == current { break }
    current = parent
  }
  do {
    for component in ancestors.reversed() {
      if try lstatPath(component).isSymbolicLink { throw federationUnavailable() }
    }
    let before = try lstatPath(path)
    let (descriptor, stat) = try openNoFollow(path)
    defer { close(descriptor) }
    guard stat.isFile, stat.dev == before.dev, stat.ino == before.ino, stat.size <= limit
    else { throw federationUnavailable() }
    let bytes = try readDescriptor(descriptor, upTo: limit + 1)
    guard bytes.count <= limit, let text = strictUTF8(bytes) else { throw federationUnavailable() }
    return text
  } catch let failure as HTTPStatusError {
    throw failure
  } catch let error as FileError where error.code == ENOENT {
    return nil
  } catch {
    throw federationUnavailable()
  }
}

/// The federation reader's URL gauntlet: http(s) only, no credentials, no `@`
/// in the authority, no backslash/control/whitespace, no query or fragment,
/// and no port 0.
private func peerURLValid(_ text: String) -> Bool {
  guard text.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil,
    let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
  else { return false }
  if let user = url.user, !user.isEmpty { return false }
  if let password = url.password, !password.isEmpty { return false }
  let afterScheme = text.range(of: "://").map { String(text[$0.upperBound...]) } ?? ""
  let authority = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
  if authority.contains("@") { return false }
  if containsScalar(text, where: { $0 == "\\" || $0 == "?" || $0 == "#" || $0.value <= 0x20 || $0.value == 0x7F }) {
    return false
  }
  if let port = url.port, port == 0 { return false }
  return true
}

/// `readFederationConfig(signing)`. With `signing` the merged maw config, the
/// fleet token and the peer key are read too, and a failure in the maw config
/// is `config_unavailable` (its own 503), not `federation_unavailable`.
func readFederationConfig(signing: Bool) throws -> FederationConfig {
  let environment = processEnvironment
  let home = homeDirectory()
  let xdg = ["1", "true", "yes", "on"].contains((environment["MAW_XDG"] ?? "").lowercased())
  let state =
    environment["MAW_HOME"] ?? environment["MAW_STATE_DIR"]
    ?? (xdg
      ? NodePath.join(environment["XDG_STATE_HOME"] ?? NodePath.join(home, ".local", "state"), "maw")
      : NodePath.join(home, ".maw"))

  var path = NodePath.resolve(environment["PEERS_FILE"] ?? NodePath.join(state, "peers.json"))
  var raw = try federationRead(path, limit: 1024 * 1024)
  if raw == nil, environment["PEERS_FILE"] == nil, environment["MAW_HOME"] == nil {
    path = NodePath.resolve(home, ".maw", "peers.json")
    raw = try federationRead(path, limit: 1024 * 1024)
  }

  var store: JSONValue = jsonObject([("version", .int(1)), ("peers", jsonObject([]))])
  if let raw {
    guard let parsed = try? parseJSON(raw) else { throw federationUnavailable() }
    store = parsed
  }
  guard let object = store.object, let version = object["version"]?.number, version == 1,
    let peers = object["peers"]?.object
  else { throw federationUnavailable() }
  guard peers.entries.count <= 32 else { throw federationUnavailable() }

  var result: [FederationPeer] = []
  // `Object.entries(...).sort(([a],[b]) => a<b?-1:a>b?1:0)` — JS string order,
  // which is UTF-16 code units, not bytes.
  for (name, value) in peers.entries.sorted(by: { jsLess($0.key, $1.key) }) {
    guard let entry = value.object, let url = entry["url"]?.string, peerURLValid(url) else {
      throw federationUnavailable()
    }
    var node: String?
    if let raw = entry["node"], !raw.isNull {
      guard let text = raw.string else { throw federationUnavailable() }
      node = text
    }
    var authOk: Bool?
    if let raw = entry["authOk"], !raw.isNull {
      guard let flag = raw.bool else { throw federationUnavailable() }
      authOk = flag
    }
    var oracle: String?
    if let identity = entry["identity"], !identity.isNull {
      guard let table = identity.object else { throw federationUnavailable() }
      if let raw = table["oracle"], !raw.isNull {
        guard let text = raw.string else { throw federationUnavailable() }
        // `oracle ? String(oracle) : null` — an empty oracle is published as
        // null, unlike an empty node, which stays "".
        oracle = text.isEmpty ? nil : text
      }
    }
    result.append(FederationPeer(name: name, url: url, node: node, oracle: oracle, authOk: authOk))
  }

  var sender = ""
  var fleet = ""
  var key = ""
  if signing {
    let merged: JSONObject
    do {
      merged = try readMawConfig()
    } catch is MawConfigUnavailable {
      throw HTTPStatusError(status: 503, code: "config_unavailable")
    }
    let oracle = merged["oracle"]?.string.map(jsTrim) ?? ""
    let node = merged["node"]?.string ?? ""
    let configuredSender = !node.isEmpty && !oracle.isEmpty ? "\(node):\(oracle)" : ""
    // `env.MAW_SENDER ?? configuredSender` — a SET but empty MAW_SENDER wins.
    sender = environment["MAW_SENDER"] ?? configuredSender
    let envFleet = jsTrim(environment["MAW_FEDERATION_TOKEN"] ?? "")
    fleet = !envFleet.isEmpty ? envFleet : (merged["federationToken"]?.string.map(jsTrim) ?? "")
    if let envKey = environment["MAW_PEER_KEY"], !envKey.isEmpty {
      key = envKey
    } else {
      key = jsTrim(try federationRead(NodePath.resolve(state, "peer-key"), limit: 4096) ?? "")
    }
  }
  let fingerprintSource = jsonStringify(
    .array([.string(path), raw.map(JSONValue.string) ?? .null, .string(sender), .string(fleet), .string(key)]))
  let fingerprint = SHA256.hash(data: Data(fingerprintSource.utf8)).map { String(format: "%02x", $0) }.joined()
  return FederationConfig(peers: result, sender: sender, fleet: fleet, key: key, fingerprint: fingerprint)
}

/// `backend.federation.namedPeers()`: the display name/url pairs, used by
/// `/api/config` when the merged maw config does not carry a `namedPeers` key
/// of its own. A missing file is an empty list; a file that exists and is
/// wrong is `federation_unavailable`, never a partial peer list — an
/// unreadable peer is a peer you would silently stop talking to.
func federationNamedPeers() throws -> [(name: String, url: String)] {
  try readFederationConfig(signing: false).peers.map { (name: $0.name, url: $0.url) }
}

// MARK: - Address classification (probeFederationPeer's ip / loopback / prohibited)

/// `net.isIP`: 4 for a strict dotted quad, 6 for anything the IPv6 parser
/// takes (a zone id included), else 0.
private func isIP(_ value: String) -> Int {
  if isIPv4Literal(value) { return 4 }
  if value.contains(":"), IPv6Address(value) != nil { return 6 }
  return 0
}

/// WHATWG IPv6 serialisation: lower-case hex, no leading zeros, the longest
/// run of two or more zero groups collapsed to `::` (the first such run wins a
/// tie). This is what `new URL('http://[' + v + ']/').hostname` returns.
private func whatwgIPv6(_ bytes: [UInt8]) -> String {
  var groups = [Int](repeating: 0, count: 8)
  for index in 0..<8 { groups[index] = Int(bytes[index * 2]) << 8 | Int(bytes[index * 2 + 1]) }
  var bestStart = -1
  var bestLength = 0
  var index = 0
  while index < 8 {
    if groups[index] != 0 {
      index += 1
      continue
    }
    var end = index
    while end < 8 && groups[end] == 0 { end += 1 }
    if end - index > bestLength {
      bestStart = index
      bestLength = end - index
    }
    index = end
  }
  if bestLength < 2 { bestStart = -1 }
  var out = ""
  var position = 0
  while position < 8 {
    if position == bestStart {
      out += position == 0 ? "::" : ":"
      position += bestLength
      continue
    }
    out += String(groups[position], radix: 16)
    if position < 7 { out += ":" }
    position += 1
  }
  return out
}

/// `ip(address)`: lower-cased, unbracketed, an IPv6 literal normalised to its
/// WHATWG form and an IPv4-mapped one turned back into dotted decimal.
private func normalizedIP(_ address: String) -> String? {
  var value = address.lowercased()
  if value.hasPrefix("[") { value.removeFirst() }
  if value.hasSuffix("]") { value.removeLast() }
  if isIP(value) == 6 {
    // A zone id makes `new URL('http://[v]/')` throw, which the reference's
    // enclosing try/catch turns into `network_error`.
    guard !value.contains("%"), let parsed = IPv6Address(value) else { return nil }
    value = whatwgIPv6([UInt8](parsed.rawValue))
    if let match = value.range(of: #"^::ffff:([0-9a-f]+):([0-9a-f]+)$"#, options: .regularExpression) {
      let tail = String(value[match]).dropFirst("::ffff:".count).split(separator: ":")
      if tail.count == 2, let high = Int(tail[0], radix: 16), let low = Int(tail[1], radix: 16) {
        value = "\(high >> 8).\(high & 255).\(low >> 8).\(low & 255)"
      }
    }
  }
  return value
}

private func isLoopbackAddress(_ value: String) -> Bool { value == "::1" || value.hasPrefix("127.") }

/// `prohibited(value)`: unspecified, multicast, link-local, and every other
/// `::`-prefixed address except `::1`.
private func isProhibitedAddress(_ value: String) -> Bool {
  if isIP(value) == 4 {
    let parts = value.split(separator: ".").map { Int($0) ?? 0 }
    let a = parts[0]
    let b = parts[1]
    return a == 0 || a >= 224 || (a == 169 && b == 254)
  }
  return value == "::" || value.hasPrefix("ff") || value.range(of: #"^fe[89ab]"#, options: .regularExpression) != nil
    || (value.hasPrefix("::") && value != "::1")
}

private func cStringText(_ buffer: [CChar]) -> String {
  let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
  return String(decoding: bytes, as: UTF8.self)
}

/// `inet_ntop` for a sockaddr of either family, without a zone id — what
/// node's `lookup` and `networkInterfaces()` both report.
private func addressText(_ pointer: UnsafePointer<sockaddr>?) -> String? {
  guard let pointer else { return nil }
  var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
  switch Int32(pointer.pointee.sa_family) {
  case AF_INET:
    return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { raw -> String? in
      var address = raw.pointee.sin_addr
      guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { return nil }
      return cStringText(text)
    }
  case AF_INET6:
    return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { raw -> String? in
      var address = raw.pointee.sin6_addr
      guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { return nil }
      return cStringText(text)
    }
  default:
    return nil
  }
}

/// `dns.lookup(hostname, {all: true, verbatim: true})`: getaddrinfo with
/// SOCK_STREAM hints, every address in the order the resolver returned them.
private func lookupAddresses(_ hostname: String) async throws -> [String] {
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
    herdrRunQueue.async {
      var hints = addrinfo()
      hints.ai_family = AF_UNSPEC
      hints.ai_socktype = SOCK_STREAM
      var result: UnsafeMutablePointer<addrinfo>?
      guard getaddrinfo(hostname, nil, &hints, &result) == 0, let first = result else {
        continuation.resume(throwing: PeerFailure.networkError)
        return
      }
      defer { freeaddrinfo(first) }
      var addresses: [String] = []
      var cursor: UnsafeMutablePointer<addrinfo>? = first
      while let entry = cursor {
        if let text = addressText(UnsafePointer(entry.pointee.ai_addr)) { addresses.append(text) }
        cursor = entry.pointee.ai_next
      }
      continuation.resume(returning: addresses)
    }
  }
}

/// `Object.values(networkInterfaces()).flat()` addresses.
private func interfaceAddresses() -> [String] {
  var list: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&list) == 0, let first = list else { return [] }
  defer { freeifaddrs(first) }
  var addresses: [String] = []
  var cursor: UnsafeMutablePointer<ifaddrs>? = first
  while let entry = cursor {
    if let text = addressText(UnsafePointer(entry.pointee.ifa_addr)) { addresses.append(text) }
    cursor = entry.pointee.ifa_next
  }
  return addresses
}

// MARK: - The probe (mod.probeFederationPeer.ts)

private enum PeerFailure: Error, Equatable {
  case timeout
  case networkError
  case addressNotAllowed
  case responseTooLarge
  case invalidResponse
  case http(Int)

  var code: String {
    switch self {
    case .timeout: return "timeout"
    case .networkError: return "network_error"
    case .addressNotAllowed: return "address_not_allowed"
    case .responseTooLarge: return "response_too_large"
    case .invalidResponse: return "invalid_response"
    case .http(let status): return "http_\(status)"
    }
  }
}

private let peerHeadLimit = 65536
private let peerBodyLimit = 1024 * 1024

/// One `http.request` / `https.request` with `agent: false`, pinned to the
/// address `lookup` chose. `onHead` fires when the status line is in — that is
/// the moment the reference sets `reachable` and `latency`, before it decides
/// whether the status is one it will read a body for.
private final class PeerFetch: @unchecked Sendable {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "maw.herdr.federation.fetch")
  private let request: Data
  private let onHead: @Sendable (Int) -> Void
  private var buffer = Data()
  private var headDone = false
  private var chunked = false
  private var contentLength: Int?
  private var body = Data()
  private var settled = false
  private var continuation: CheckedContinuation<Result<Data, PeerFailure>, Never>?
  private var timer: DispatchSourceTimer?

  init(host: String, port: Int, tlsServerName: String?, request: Data, onHead: @escaping @Sendable (Int) -> Void) {
    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 80)
    let parameters: NWParameters
    if let tlsServerName {
      let tls = NWProtocolTLS.Options()
      // node sets `servername` from the URL hostname unless it is an IP.
      if isIP(tlsServerName) == 0 {
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, tlsServerName)
      }
      parameters = NWParameters(tls: tls)
    } else {
      parameters = NWParameters.tcp
    }
    self.connection = NWConnection(to: endpoint, using: parameters)
    self.request = request
    self.onHead = onHead
  }

  func run(deadline: Date) async -> Result<Data, PeerFailure> {
    await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, PeerFailure>, Never>) in
      queue.async {
        self.continuation = continuation
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + max(deadline.timeIntervalSinceNow, 0))
        timer.setEventHandler { [weak self] in self?.settle(.failure(.timeout)) }
        timer.resume()
        self.timer = timer
        self.connection.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          switch state {
          case .ready:
            self.connection.send(
              content: self.request,
              completion: .contentProcessed { [weak self] error in
                if error != nil { self?.settle(.failure(.networkError)) }
              })
            self.receive()
          // node has no "waiting": a refused or unroutable connect is an
          // immediate `error` event, so `.waiting` fails here too.
          case .failed, .waiting:
            self.settle(.failure(.networkError))
          case .cancelled:
            self.settle(.failure(.networkError))
          default:
            break
          }
        }
        self.connection.start(queue: self.queue)
      }
    }
  }

  private func settle(_ result: Result<Data, PeerFailure>) {
    if settled { return }
    settled = true
    timer?.cancel()
    timer = nil
    connection.cancel()
    continuation?.resume(returning: result)
    continuation = nil
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      guard let self, !self.settled else { return }
      if let data, !data.isEmpty {
        self.buffer.append(data)
        self.consume()
        if self.settled { return }
      }
      if error != nil {
        self.settle(.failure(.networkError))
        return
      }
      if isComplete {
        self.endOfStream()
        return
      }
      self.receive()
    }
  }

  /// Head, then body by whichever framing the peer declared.
  private func consume() {
    if !headDone {
      guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
        // `maxHeaderSize: 65536` — the parser fails the request, and node
        // reports that as an ordinary request error.
        if buffer.count > peerHeadLimit { settle(.failure(.networkError)) }
        return
      }
      if buffer.distance(from: buffer.startIndex, to: separator.lowerBound) > peerHeadLimit {
        settle(.failure(.networkError))
        return
      }
      let head = String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self)
      buffer.removeSubrange(buffer.startIndex..<separator.upperBound)
      let lines = head.components(separatedBy: "\r\n")
      let statusParts = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."), statusParts[1].count == 3,
        let status = Int(statusParts[1])
      else {
        settle(.failure(.networkError))
        return
      }
      for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[line.startIndex..<colon].lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if name == "transfer-encoding", value.lowercased().hasSuffix("chunked") { chunked = true }
        if name == "content-length", let length = Int(value), length >= 0 { contentLength = length }
      }
      headDone = true
      onHead(status)
      if status < 200 || status >= 300 {
        settle(.failure(.http(status)))
        return
      }
    }
    if chunked {
      switch decodeChunkedResponse(buffer) {
      case .need(let decodedSoFar):
        if decodedSoFar > peerBodyLimit { settle(.failure(.responseTooLarge)) }
      case .invalid:
        settle(.failure(.networkError))
      case .done(let decoded):
        if decoded.count > peerBodyLimit { settle(.failure(.responseTooLarge)) } else { settle(.success(decoded)) }
      }
      return
    }
    if buffer.count > peerBodyLimit {
      settle(.failure(.responseTooLarge))
      return
    }
    if let contentLength, buffer.count >= contentLength {
      settle(.success(Data(buffer.prefix(contentLength))))
    }
  }

  /// EOF from the peer: an answer only when nothing declared a length that was
  /// not met; otherwise the `aborted` / `error` node raises on the response.
  private func endOfStream() {
    guard headDone else {
      settle(.failure(.networkError))
      return
    }
    if chunked {
      settle(.failure(.networkError))
      return
    }
    if let contentLength {
      if buffer.count >= contentLength { settle(.success(Data(buffer.prefix(contentLength)))) } else {
        settle(.failure(.networkError))
      }
      return
    }
    settle(.success(buffer))
  }

  private enum ChunkedOutcome {
    case need(Int)
    case invalid
    case done(Data)
  }

  private func decodeChunkedResponse(_ input: Data) -> ChunkedOutcome {
    var body = Data()
    var index = input.startIndex
    let crlf = Data("\r\n".utf8)
    while true {
      guard let line = input.range(of: crlf, in: index..<input.endIndex) else { return .need(body.count) }
      let text = String(decoding: input[index..<line.lowerBound], as: UTF8.self)
      let sizeText = (text.components(separatedBy: ";").first ?? "").trimmingCharacters(in: .whitespaces)
      guard !sizeText.isEmpty, sizeText.count <= 16, let size = Int(sizeText, radix: 16), size >= 0
      else { return .invalid }
      index = line.upperBound
      if size == 0 {
        while true {
          guard let end = input.range(of: crlf, in: index..<input.endIndex) else { return .need(body.count) }
          let blank = end.lowerBound == index
          index = end.upperBound
          if blank { return .done(body) }
        }
      }
      guard input.distance(from: index, to: input.endIndex) >= size + 2 else { return .need(body.count + size) }
      let end = input.index(index, offsetBy: size)
      body.append(input[index..<end])
      guard input[end] == 0x0D, input[input.index(after: end)] == 0x0A else { return .invalid }
      index = input.index(end, offsetBy: 2)
    }
  }
}

private func hmacHex(key: String, message: String) -> String {
  HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
    .map { String(format: "%02x", $0) }.joined()
}

/// `probeFederationPeer(peer, signing, signal)`. Never throws: every failure
/// is a `fetch_error` string on the row. `deadline` is the earlier of this
/// probe's own 2.5 s and the sweep's 10 s.
private func probeFederationPeer(_ peer: FederationPeer, signing: FederationConfig, deadline: Date) async -> JSONObject {
  let start = Date()
  var row = JSONObject([
    ("url", .string(peer.url)), ("node", peer.node.map(JSONValue.string) ?? .null), ("reachable", .bool(false)),
    ("latency", .null), ("agents", .array([])), ("clock_warning", .bool(false)),
    ("oracle", peer.oracle.map(JSONValue.string) ?? .null), ("resolved_ip", .null), ("node_unique", .bool(false)),
    ("auth_ok", peer.authOk.map(JSONValue.bool) ?? .null), ("loopback_self", .bool(false)),
  ])
  func finish(_ failure: PeerFailure?) -> JSONObject {
    var out = row
    if let failure { out["fetch_error"] = .string(failure.code) }
    return out
  }

  guard let components = URLComponents(string: peer.url), let scheme = components.scheme?.lowercased(),
    var hostname = components.host
  else { return finish(.networkError) }
  if hostname.hasPrefix("[") { hostname.removeFirst() }
  if hostname.hasSuffix("]") { hostname.removeLast() }
  let port = components.port ?? (scheme == "https" ? 443 : 80)
  var pathname = components.percentEncodedPath
  while pathname.hasSuffix("/") { pathname.removeLast() }
  pathname += "/api/sessions"
  let hostFamily = isIP(hostname)
  let explicitLoopback: Bool
  if hostname.lowercased() == "localhost" {
    explicitLoopback = true
  } else if hostFamily != 0, let normalized = normalizedIP(hostname) {
    explicitLoopback = isLoopbackAddress(normalized)
  } else {
    explicitLoopback = false
  }

  var headers: [(String, String)] = [("Accept", "application/json"), ("Connection", "close")]
  if let match = signing.sender.range(of: #"^([^:\s]+):([^:\s]+)$"#, options: .regularExpression),
    !signing.fleet.isEmpty, !signing.key.isEmpty
  {
    let parts = String(signing.sender[match]).split(separator: ":", maxSplits: 1).map(String.init)
    // `${sender[2]}:${sender[1]}` — the two halves swap places on the wire.
    let from = "\(parts[1]):\(parts[0])"
    let timestamp = String(Int(Date().timeIntervalSince1970))
    headers.append(("X-Maw-From", from))
    headers.append(("X-Maw-Timestamp", timestamp))
    headers.append(("X-Maw-Auth-Version", "v3"))
    headers.append(("X-Maw-Signature", hmacHex(key: signing.fleet, message: "GET:/api/sessions:\(timestamp)")))
    headers.append(("X-Maw-Signature-V3", hmacHex(key: signing.key, message: "GET:/api/sessions:\(timestamp)::\(from)")))
  }

  if Date() >= deadline { return finish(.timeout) }
  let addresses: [String]
  if hostFamily != 0 {
    addresses = [hostname]
  } else {
    do {
      addresses = try await lookupAddresses(hostname)
    } catch {
      return finish(Date() >= deadline ? .timeout : .networkError)
    }
  }
  if Date() >= deadline { return finish(.timeout) }
  var normalized: [String] = []
  for address in addresses {
    guard let value = normalizedIP(address) else { return finish(.networkError) }
    normalized.append(value)
  }
  if normalized.isEmpty
    || normalized.contains(where: { isProhibitedAddress($0) || (isLoopbackAddress($0) && !explicitLoopback) })
  {
    return finish(.addressNotAllowed)
  }
  let chosen = addresses[0]
  let resolved = normalized[0]
  row["resolved_ip"] = .string(resolved)
  row["loopback_self"] = .bool(
    isLoopbackAddress(resolved) || interfaceAddresses().contains { normalizedIP($0) == resolved })

  // node's request line and header order: the caller's headers first, then
  // the Host it derives from the URL (bracketed for IPv6, port only when it
  // is not the scheme's default).
  var hostHeader = hostFamily == 6 ? "[\(hostname)]" : hostname
  if let explicit = components.port, explicit != (scheme == "https" ? 443 : 80) { hostHeader += ":\(explicit)" }
  var request = "GET \(pathname) HTTP/1.1\r\n"
  for (name, value) in headers { request += "\(name): \(value)\r\n" }
  request += "Host: \(hostHeader)\r\n\r\n"

  let box = ProbeHeadBox()
  let fetch = PeerFetch(
    host: chosen, port: port, tlsServerName: scheme == "https" ? hostname : nil, request: Data(request.utf8),
    onHead: { _ in box.mark(latency: Int((Date().timeIntervalSince(start) * 1000).rounded(.down))) })
  let outcome = await fetch.run(deadline: deadline)
  if let latency = box.latency {
    row["reachable"] = .bool(true)
    row["latency"] = .int(latency)
  }
  switch outcome {
  case .failure(let failure):
    return finish(failure)
  case .success(let data):
    guard let parsed = try? parseJSON(data), let items = parsed.array else { return finish(.invalidResponse) }
    let agents = items.compactMap { item -> JSONValue? in
      guard let object = item.object, let name = object["name"]?.string else { return nil }
      return .string(name)
    }
    row["agents"] = .array(agents)
    return finish(nil)
  }
}

private final class ProbeHeadBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int?
  var latency: Int? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func mark(latency: Int) {
    lock.lock()
    if value == nil { value = latency }
    lock.unlock()
  }
}

// MARK: - The sweep, its cache and its single flight (mod.createFederation.ts)

private actor SweepRows {
  private var rows: [JSONObject?]
  private var next = 0
  init(count: Int) { rows = Array(repeating: nil, count: count) }
  func claim() -> Int? {
    guard next < rows.count else { return nil }
    defer { next += 1 }
    return next
  }
  func store(_ index: Int, _ row: JSONObject) { rows[index] = row }
  func all() -> [JSONObject] { rows.map { $0 ?? JSONObject() } }
}

private func federationSweep(_ config: FederationConfig) async -> JSONValue {
  let sweepDeadline = Date().addingTimeInterval(10)
  let store = SweepRows(count: config.peers.count)
  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<min(4, config.peers.count) {
      group.addTask {
        while let index = await store.claim() {
          let deadline = min(Date().addingTimeInterval(2.5), sweepDeadline)
          let row = await probeFederationPeer(config.peers[index], signing: config, deadline: deadline)
          await store.store(index, row)
        }
      }
    }
  }
  var counts: [String: Int] = [:]
  for peer in config.peers {
    if let node = peer.node, !node.isEmpty { counts[node, default: 0] += 1 }
  }
  var rows = await store.all()
  for index in rows.indices {
    let node = rows[index]["node"]?.string ?? ""
    rows[index]["node_unique"] = .bool(!node.isEmpty && counts[node] == 1)
  }
  let reachable = rows.filter { $0["reachable"]?.bool == true }.count
  return jsonObject([
    ("local_url", .string("")), ("peers", .array(rows.map(JSONValue.object))), ("totalPeers", .int(rows.count)),
    ("reachablePeers", .int(reachable)),
  ])
}

/// `createFederation(shutdown)`: the reader runs on EVERY call (a broken
/// peers.json is a 503 even while a sweep is cached), the cache holds one
/// payload for 15 s per fingerprint, and a sweep already in flight for the
/// same fingerprint is shared rather than repeated.
final class FederationStatus: @unchecked Sendable {
  private let lock = NSLock()
  private var cache: (key: String, expires: Date, value: JSONValue)?
  private var flight: (key: String, task: Task<JSONValue, Never>)?

  func status() async throws -> JSONValue {
    if Task.isCancelled { throw backendError("request aborted") }
    let config = try readFederationConfig(signing: true)
    while true {
      let (cached, other): (JSONValue?, Task<JSONValue, Never>?) = lock.withLock {
        if let cache, cache.key == config.fingerprint, cache.expires > Date() { return (cache.value, nil) }
        if let flight, flight.key != config.fingerprint { return (nil, flight.task) }
        return (nil, nil)
      }
      if let cached { return cached }
      guard let other else { break }
      _ = await other.value
      if Task.isCancelled { throw backendError("request aborted") }
    }
    let task: Task<JSONValue, Never> = lock.withLock {
      if let flight, flight.key == config.fingerprint { return flight.task }
      let key = config.fingerprint
      let created = Task.detached { [self] in
        let value = await federationSweep(config)
        lock.withLock {
          cache = (key, Date().addingTimeInterval(15), value)
          if flight?.key == key { flight = nil }
        }
        return value
      }
      flight = (key, created)
      return created
    }
    let value = await task.value
    if Task.isCancelled { throw backendError("request aborted") }
    return value
  }
}
