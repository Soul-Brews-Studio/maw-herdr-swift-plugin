import Foundation
import Network

// RFC 6455 framing done by hand, plus the two session protocols ported from
// `mod.createSocketSession.ts` (the dashboard, `/ws`) and
// `mod.createPtySession.ts` (the terminal stream, `/ws/pty`).
//
// Why by hand: the HTTP server and the socket share one port, so by the time a
// connection reaches here the handshake bytes are already consumed and the 101
// already written. NWProtocolWebSocket only exists as a protocol option on a
// connection that has not started, so it cannot be bolted on afterwards. What
// is left is small — parse a masked frame, write an unmasked one — and doing it
// here keeps the upgrade decision (tickets, origin, capacity) in one place.
//
// The port is deliberately literal. Every place the Bun original does something
// surprising is marked `Bun quirk:` and reproduced rather than corrected: two
// servers that disagree are worse than one server that is odd in a documented
// way.

// MARK: - Limits

/// Bun's `websocket.maxPayloadLength` is `64 << 10`, and its smoke suite asserts
/// that a 65537-byte `send` closes the socket without executing the command.
/// 1 MiB survives only as the absolute framing ceiling — no frame header may
/// ever make us buffer more than that.
private let wsMaxMessageBytes = 64 << 10
private let wsMaxFrameBytes = 1 << 20
/// Bun: `if (pending >= 8) ws.close(1008, 'too many commands')`.
private let wsMaxPendingWork = 8
/// Bun: `Buffer.byteLength(target) > 1024`.
private let wsMaxTargetBytes = 1024

private enum WSOpcode {
  static let continuation: UInt8 = 0x0
  static let text: UInt8 = 0x1
  static let binary: UInt8 = 0x2
  static let close: UInt8 = 0x8
  static let ping: UInt8 = 0x9
  static let pong: UInt8 = 0xA
}

// MARK: - Captured text

/// `undefined` and `""` are different things to the Bun original: a target that
/// the backend did not return is `undefined`, and `JSON.stringify` then drops
/// the key from the frame. Modelling it as `String?` would collapse that into
/// an empty string, so it gets its own type.
private enum WSText: Equatable {
  case missing
  case text(String)

  init(_ value: String?) { self = value.map(WSText.text) ?? .missing }

  var json: JSONValue? {
    if case .text(let value) = self { return .string(value) }
    return nil
  }
}

/// A JavaScript `Map<string, string>`: insertion-ordered, `set` on an existing
/// key keeps its position and replaces the value.
private struct WSPreviews {
  private(set) var keys: [String] = []
  private var store: [String: WSText] = [:]

  var count: Int { keys.count }
  func has(_ key: String) -> Bool { store[key] != nil }
  func value(_ key: String) -> WSText { store[key] ?? .missing }

  mutating func set(_ key: String, _ value: WSText) {
    if store[key] == nil { keys.append(key) }
    store[key] = value
  }

  mutating func remove(_ key: String) {
    guard store.removeValue(forKey: key) != nil else { return }
    keys.removeAll { $0 == key }
  }

  mutating func removeAll() {
    keys = []
    store = [:]
  }
}

// MARK: - Client commands

/// The parsed shape of `mod.validateCommand.ts` in socket mode. `hasText`
/// exists because the original distinguishes an absent `text` key from a
/// present-but-null one: `Object.hasOwn(body, 'text') ? body.text : body.content`.
private struct WSCommand: Sendable {
  var type: String?
  var target: String?
  var targets: [String]?
  var scope: String?
  var hasText = false
  var text: String?
  var command: String?
  var content: String?
  var force: Bool?
  var inbox: Bool?
  var attachments: [String]?
}

/// `validateCommand(value, true)`. Returns nil for anything it would throw
/// `invalid_json` on, which the caller turns into a 1008 close.
///
/// Bun quirk: the key whitelist is checked against the *declared* `type`, so
/// `{"type":"select","command":"x"}` is rejected outright — `command` is only a
/// legal key when `type === "wake"`, and `content` only when `type === "send"`.
/// Same for `{"type":"wake","command":null}`: for `wake` the value must be a
/// string, and null is not, so a null command closes the socket rather than
/// being treated as absent.
private func wsParseCommand(_ text: String) -> WSCommand? {
  // Rejects arrays and scalars, matching `!value || typeof value !== 'object'
  // || Array.isArray(value)`.
  guard let parsed = try? parseJSON(text), let object = parsed.object else { return nil }
  let declaredType = object["type"]?.string
  var command = WSCommand()
  for (key, raw) in object.entries {
    let isNull = raw.isNull
    switch key {
    case "command" where declaredType == "wake":
      guard let value = raw.string else { return nil }
      command.command = value
    case "content" where declaredType == "send":
      if !isNull {
        guard let value = raw.string else { return nil }
        command.content = value
      }
    case "type", "target", "scope", "text":
      var value: String?
      if !isNull {
        guard let parsedValue = raw.string else { return nil }
        value = parsedValue
      }
      switch key {
      case "type": command.type = value
      case "target": command.target = value
      case "scope": command.scope = value
      default:
        command.hasText = true
        command.text = value
      }
    case "targets", "attachments":
      var list: [String]?
      if !isNull {
        guard let array = raw.array else { return nil }
        var items: [String] = []
        items.reserveCapacity(array.count)
        for element in array {
          guard let value = element.string else { return nil }
          items.append(value)
        }
        list = items
      }
      if key == "targets" { command.targets = list } else { command.attachments = list }
    case "force", "inbox":
      var value: Bool?
      if !isNull {
        guard let flag = raw.bool else { return nil }
        value = flag
      }
      if key == "force" { command.force = value } else { command.inbox = value }
    default:
      return nil
    }
  }
  return command
}

// MARK: - Frame encoding

/// Server frames are never masked and never fragmented: everything this server
/// sends is one complete message.
private func wsFrame(opcode: UInt8, payload: Data) -> Data {
  var out = Data()
  out.append(0x80 | opcode)
  let length = payload.count
  if length < 126 {
    out.append(UInt8(length))
  } else if length <= 0xFFFF {
    out.append(126)
    out.append(UInt8((length >> 8) & 0xFF))
    out.append(UInt8(length & 0xFF))
  } else {
    out.append(127)
    for shift in stride(from: 56, through: 0, by: -8) {
      out.append(UInt8((length >> shift) & 0xFF))
    }
  }
  out.append(payload)
  return out
}

private func wsClosePayload(code: UInt16, reason: String) -> Data {
  var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
  // A control frame carries at most 125 bytes, two of which are the code.
  payload.append(contentsOf: Array(reason.utf8.prefix(123)))
  return payload
}

// MARK: - Server

/// Owns every live socket. The HTTP layer decides who may upgrade and writes
/// the 101; from the first byte after that this class owns the connection.
final class WebSocketServer: WebSocketService, @unchecked Sendable {
  private let backend: any HerdrBackend
  private let lock = NSLock()
  private var live: [UUID: WSSocket] = [:]
  /// One queue for every socket's timers. Timers only re-arm work; all real
  /// work happens on the session's own serial chain, so they never contend.
  private let timers = DispatchQueue(label: "maw.herdr.websocket.timers")

  init(backend: any HerdrBackend) {
    self.backend = backend
  }

  /// Read by the HTTP layer before every upgrade, to enforce the 32-socket cap.
  var activeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return live.count
  }

  /// Bun's `open(ws)`: the path decides which session runs on the socket.
  func attach(connection: NWConnection, path: String, readOnly: Bool, leftover: Data) {
    let id = UUID()
    let socket = WSSocket(connection: connection, timers: timers, onFinish: { [weak self] in self?.forget(id) })
    let handler: WSHandler =
      path == "/ws/pty"
      ? WSPtySession(socket: socket, backend: backend, timers: timers)
      : WSDashboardSession(socket: socket, backend: backend, readOnly: readOnly, timers: timers)
    lock.lock()
    live[id] = socket
    lock.unlock()
    socket.start(handler: handler, leftover: leftover)
  }

  /// Not part of `WebSocketService`. Bun's SIGTERM path closes every socket
  /// with 1001 before the listener stops; Integrate can call this if it holds
  /// the concrete type, and nothing breaks if it does not — cancelling the
  /// listener still tears each socket down through its read loop.
  func shutdown() {
    lock.lock()
    let sockets = Array(live.values)
    lock.unlock()
    for socket in sockets { socket.closeWith(1001, "server shutting down") }
  }

  private func forget(_ id: UUID) {
    lock.lock()
    live.removeValue(forKey: id)
    lock.unlock()
  }
}

// MARK: - Transport

/// What a session protocol sees of the socket: Bun's `message(ws, value)` with
/// a string or a Buffer, and `close(ws)`.
private protocol WSHandler: AnyObject, Sendable {
  func open()
  func message(text: String)
  func message(binary: Data)
  func close()
}

/// One socket's framing. Reads masked client frames, writes unmasked server
/// frames, and hands whole messages to the handler.
private final class WSSocket: @unchecked Sendable {
  private let connection: NWConnection
  private let timers: DispatchQueue
  private let onFinish: @Sendable () -> Void
  private let lock = NSLock()
  private var stopped = false
  private var closing = false
  private var finished = false
  private var bufferedBytes = 0
  private var handler: WSHandler?

  init(connection: NWConnection, timers: DispatchQueue, onFinish: @escaping @Sendable () -> Void) {
    self.connection = connection
    self.timers = timers
    self.onFinish = onFinish
  }

  func start(handler: WSHandler, leftover: Data) {
    lock.withLock { self.handler = handler }
    // Bun's `open(ws)` builds the session before any message can be delivered.
    handler.open()
    Task.detached { [self] in await readLoop(leftover: leftover) }
  }

  var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  /// `ws.getBufferedAmount()`: bytes handed to the transport whose send has
  /// not completed yet.
  var bufferedAmount: Int {
    lock.lock()
    defer { lock.unlock() }
    return bufferedBytes
  }

  // MARK: Lifecycle

  /// Send a close frame, then drop the connection. Safe to call from anywhere,
  /// including the framing path and the timer queue.
  func closeWith(_ code: UInt16, _ reason: String) {
    lock.lock()
    if stopped {
      lock.unlock()
      return
    }
    stopped = true
    closing = true
    let handler = self.handler
    lock.unlock()
    handler?.close()

    let frame = wsFrame(opcode: WSOpcode.close, payload: wsClosePayload(code: code, reason: reason))
    connection.send(
      content: frame,
      completion: .contentProcessed { [weak self] _ in
        self?.connection.cancel()
        self?.finish()
      })
    // A send whose completion never fires would leak a slot out of
    // `activeCount` and eventually wedge the 32-socket cap, so the teardown is
    // also scheduled unconditionally. `finish()` is idempotent.
    timers.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
      self?.connection.cancel()
      self?.finish()
    }
  }

  /// Give up without a close frame — the peer is already gone.
  ///
  /// When a close frame is already in flight this must NOT cancel: measured on
  /// 2026-09-22, `cancel()` racing an unflushed `send` loses the close frame, so
  /// a client that rejected a bad frame saw the socket die with no status code
  /// at all instead of 1002/1003/1007/1009. `closeWith` owns the teardown in
  /// that case, from its own send completion.
  private func terminate() {
    let (alreadyClosing, handler) = lock.withLock {
      let closingNow = closing
      stopped = true
      return (closingNow, self.handler)
    }
    if alreadyClosing { return }
    handler?.close()
    connection.cancel()
    finish()
  }

  private func finish() {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    stopped = true
    lock.unlock()
    onFinish()
  }

  // MARK: Transport

  private func receiveChunk() async -> Data? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) {
        data, _, isComplete, error in
        if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else if error != nil || isComplete {
          continuation.resume(returning: nil)
        } else {
          continuation.resume(returning: Data())
        }
      }
    }
  }

  /// Awaited send: true once the transport accepted the frame.
  @discardableResult
  func sendFrame(opcode: UInt8, payload: Data) async -> Bool {
    if isStopped { return false }
    lock.withLock { bufferedBytes += payload.count }
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      connection.send(
        content: wsFrame(opcode: opcode, payload: payload),
        completion: .contentProcessed { [weak self] error in
          self?.lock.withLock { self?.bufferedBytes -= payload.count }
          continuation.resume(returning: error == nil)
        })
    }
  }

  /// Fire-and-forget send for the terminal stream, where output arrives on a
  /// reader thread. Bun's `ws.send()` returning 0 is a transport error here.
  @discardableResult
  func enqueueFrame(opcode: UInt8, payload: Data) -> Bool {
    if isStopped { return false }
    lock.withLock { bufferedBytes += payload.count }
    connection.send(
      content: wsFrame(opcode: opcode, payload: payload),
      completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        self.lock.withLock { self.bufferedBytes -= payload.count }
        if error != nil { self.terminate() }
      })
    return true
  }

  func sendText(_ text: String) async -> Bool {
    await sendFrame(opcode: WSOpcode.text, payload: Data(text.utf8))
  }

  func enqueueText(_ text: String) -> Bool { enqueueFrame(opcode: WSOpcode.text, payload: Data(text.utf8)) }
  func enqueueBinary(_ data: Data) -> Bool { enqueueFrame(opcode: WSOpcode.binary, payload: data) }

  // MARK: Framing

  private func readLoop(leftover: Data) async {
    var buffer = [UInt8](leftover)
    while true {
      if await !consume(&buffer) { break }
      guard let chunk = await receiveChunk() else { break }
      buffer.append(contentsOf: chunk)
    }
    terminate()
  }

  /// Pull every complete frame out of `buffer`. Returns false once the socket
  /// is finished — either the peer closed or we rejected something.
  private func consume(_ buffer: inout [UInt8]) async -> Bool {
    while true {
      if isStopped { return false }
      guard buffer.count >= 2 else { return true }

      let first = buffer[0]
      let second = buffer[1]
      if first & 0x70 != 0 {
        closeWith(1002, "reserved bits must be zero")
        return false
      }
      let fin = first & 0x80 != 0
      let opcode = first & 0x0F
      // Every frame from a client is masked. An unmasked one is either a
      // confused client or a proxy rewriting traffic; both are protocol errors.
      guard second & 0x80 != 0 else {
        closeWith(1002, "client frames must be masked")
        return false
      }

      var length = Int(second & 0x7F)
      var offset = 2
      if length == 126 {
        guard buffer.count >= 4 else { return true }
        length = Int(buffer[2]) << 8 | Int(buffer[3])
        offset = 4
      } else if length == 127 {
        guard buffer.count >= 10 else { return true }
        // The high bit of a 64-bit length must be zero; anything with it set is
        // past every cap below anyway.
        if buffer[2] & 0x80 != 0 {
          closeWith(1009, "frame too large")
          return false
        }
        length = 0
        for index in 2..<10 { length = length << 8 | Int(buffer[index]) }
        offset = 10
      }

      let isControl = opcode & 0x08 != 0
      if isControl && (!fin || length > 125) {
        closeWith(1002, "invalid control frame")
        return false
      }
      // Checked before the payload is waited for, so a lying length header can
      // never make us buffer it.
      if length > wsMaxFrameBytes || (!isControl && length > wsMaxMessageBytes) {
        closeWith(1009, "message too large")
        return false
      }

      guard buffer.count >= offset + 4 + length else { return true }
      let mask = Array(buffer[offset..<(offset + 4)])
      offset += 4
      var payload = Array(buffer[offset..<(offset + length)])
      for index in 0..<length { payload[index] ^= mask[index % 4] }
      buffer.removeFirst(offset + length)

      let handler = lock.withLock { self.handler }
      switch opcode {
      case WSOpcode.continuation:
        // Nothing this protocol sends or expects needs fragmenting; a
        // fragmented client message is rejected rather than reassembled.
        closeWith(1002, "fragmented messages are not supported")
        return false
      case WSOpcode.text:
        guard fin else {
          closeWith(1002, "fragmented messages are not supported")
          return false
        }
        guard let text = String(bytes: payload, encoding: .utf8) else {
          closeWith(1007, "text frames must be valid UTF-8")
          return false
        }
        handler?.message(text: text)
      case WSOpcode.binary:
        guard fin else {
          closeWith(1002, "fragmented messages are not supported")
          return false
        }
        handler?.message(binary: Data(payload))
      case WSOpcode.close:
        var code: UInt16 = 1000
        if payload.count >= 2 {
          let received = UInt16(payload[0]) << 8 | UInt16(payload[1])
          if (1000...1003).contains(received) || (1007...1011).contains(received)
            || (3000...4999).contains(received)
          {
            code = received
          }
        }
        closeWith(code, "")
        return false
      case WSOpcode.ping:
        await sendFrame(opcode: WSOpcode.pong, payload: Data(payload))
      case WSOpcode.pong:
        break
      default:
        closeWith(1002, "unknown opcode")
        return false
      }
    }
  }
}

// MARK: - Serial work chain

/// Bun's `chain = chain.then(...)`: one item at a time, in arrival order. The
/// drain task is cancelled with the session, which is what `controller.abort()`
/// does to any backend call still in flight.
private final class WSChain: @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [@Sendable () async -> Void] = []
  private var draining = false
  private var stopped = false
  private var task: Task<Void, Never>?

  func enqueue(_ work: @escaping @Sendable () async -> Void) {
    lock.lock()
    if stopped {
      lock.unlock()
      return
    }
    queue.append(work)
    let needsDriver = !draining
    draining = true
    lock.unlock()
    if needsDriver {
      let started = Task.detached { [self] in await drain() }
      lock.withLock { task = started }
    }
  }

  private func drain() async {
    while true {
      // `NSLock.lock()` is banned from async contexts; `withLock` keeps every
      // critical section synchronous and entirely inside one statement.
      let next: (@Sendable () async -> Void)? = lock.withLock {
        if stopped || queue.isEmpty {
          draining = false
          return nil
        }
        return queue.removeFirst()
      }
      guard let work = next else { return }
      await work()
    }
  }

  func stop() {
    let running = lock.withLock { () -> Task<Void, Never>? in
      stopped = true
      queue.removeAll()
      return task
    }
    running?.cancel()
  }
}

// MARK: - Dashboard session (mod.createSocketSession.ts)

private final class WSDashboardSession: WSHandler, @unchecked Sendable {
  private let socket: WSSocket
  private let backend: any HerdrBackend
  private let readOnly: Bool
  private let timers: DispatchQueue
  private let chain = WSChain()

  private let lock = NSLock()
  private var stopped = false
  private var pending = 0
  private var pollGeneration = 0

  // Session state. Only ever touched from the chain, which runs one work item
  // at a time, so the poll can never overlap a command or itself.
  private var lastSessions = ""
  private var lastIdentity = ""
  private var feedCursor = 0
  private var feedInitialized = false
  private var available: Set<String> = []
  private var selected = ""
  private var lastContent = WSText.missing
  private var haveContent = false
  private var previews = WSPreviews()
  private var previewSent: Set<String> = []

  init(socket: WSSocket, backend: any HerdrBackend, readOnly: Bool, timers: DispatchQueue) {
    self.socket = socket
    self.backend = backend
    self.readOnly = readOnly
    self.timers = timers
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  /// Bun's `open(ws)` enqueues `roster(true)` the moment the session exists.
  func open() {
    enqueue { [self] in
      if await !roster(force: true) { socket.closeWith(1011, "herdr unavailable") }
      armPoll()
    }
  }

  func message(text: String) {
    guard let command = wsParseCommand(text) else {
      socket.closeWith(1008, "invalid command JSON")
      return
    }
    enqueue { [self] in await run(command) }
  }

  func message(binary: Data) {
    // Bun: `ws.close(1003, 'text JSON required')`.
    socket.closeWith(1003, "text JSON required")
  }

  func close() {
    lock.withLock { stopped = true }
    chain.stop()
  }

  // MARK: Work chain

  /// Bun's `enqueue`: a hard cap on how far a client may run ahead of the
  /// backend.
  private func enqueue(_ work: @escaping @Sendable () async -> Void) {
    lock.lock()
    if stopped {
      lock.unlock()
      return
    }
    if pending >= wsMaxPendingWork {
      lock.unlock()
      socket.closeWith(1008, "too many commands")
      return
    }
    pending += 1
    lock.unlock()
    chain.enqueue { [self] in
      if !isStopped { await work() }
      lock.withLock { pending -= 1 }
    }
  }

  /// Bun schedules the next poll only once the current one has settled, so a
  /// slow backend stretches the interval instead of stacking timers. The
  /// generation counter makes a stale timer a no-op.
  private func armPoll() {
    lock.lock()
    if stopped {
      lock.unlock()
      return
    }
    pollGeneration += 1
    let generation = pollGeneration
    lock.unlock()
    timers.asyncAfter(deadline: .now() + .milliseconds(Protocol.socketPollMilliseconds)) { [weak self] in
      guard let self else { return }
      let current = lock.withLock { !stopped && generation == pollGeneration }
      if current {
        enqueue { [self] in
          if await roster(force: false) { await capture() }
          armPoll()
        }
      }
    }
  }

  // MARK: Writing

  /// Bun's `write()`: serialize, send, and on failure close 1013 and stop.
  @discardableResult
  private func write(_ value: JSONValue) async -> Bool {
    if isStopped { return false }
    guard await socket.sendText(jsonStringify(value)) else {
      socket.closeWith(1013, "slow client")
      return false
    }
    return true
  }

  @discardableResult
  private func error(_ reason: String) async -> Bool {
    await write(jsonObject([("type", .string("error")), ("error", .string(reason))]))
  }

  // MARK: Roster

  private func roster(force: Bool) async -> Bool {
    let sessions: [Session]
    do {
      sessions = try await backend.dashboardSessions()
    } catch {
      _ = await self.error("herdr_unavailable")
      return false
    }
    if isStopped { return false }

    available = Set(sessions.flatMap { session in session.windows.map { "\(session.name):\($0.index)" } })

    // Identity is name + agent per window, not the whole roster: a status flip
    // is not a renamed pane.
    let identity = jsonStringify(
      .array(
        sessions.flatMap { session in
          session.windows.map { window in
            JSONValue.array([
              .string(session.name), .int(window.index), .string(window.name),
              .string(trimmedAgent(window.agent) ?? ""),
            ])
          }
        }))
    let identityChanged = identity != lastIdentity
    lastIdentity = identity

    let data = jsonStringify(sessionsJSON(sessions))
    if force || data != lastSessions {
      lastSessions = data
      guard await write(jsonObject([("type", .string("sessions")), ("sessions", sessionsJSON(sessions))]))
      else { return false }
      let agents: [JSONValue] = sessions.flatMap { session in
        session.windows.compactMap { window -> JSONValue? in
          guard trimmedAgent(window.agent) != nil else { return nil }
          return jsonObject([
            ("target", .string("\(session.name):\(window.index)")),
            ("name", .string(window.name)),
            ("session", .string(session.name)),
          ])
        }
      }
      guard await write(jsonObject([("type", .string("recent")), ("agents", .array(agents))]))
      else { return false }
    }

    if force {
      do {
        let inventory = try backend.teamInventory()
        guard await write(jsonObject([("type", .string("teams")), ("teams", inventory["teams"] ?? .array([]))]))
        else { return false }
      } catch {
        // Unsafe inventory is never reported as an empty team list.
        if await !self.error("teams_unavailable") { return false }
      }
    }

    // Bun quirk: the feed is deliberately one poll behind. The live UI resolves
    // feed event names through its rendered roster, so a roster that just
    // changed identity gets a full render turn before any event referring to it
    // is replayed. That is why `feed-history` arrives ~1s after the first three
    // frames rather than with them.
    if force || identityChanged { return true }
    if !feedInitialized {
      let history = backend.observedFeed.read()
      feedCursor = history.cursor
      feedInitialized = true
      return await write(jsonObject([("type", .string("feed-history")), ("events", .array(history.events))]))
    }
    let feed = backend.observedFeed.read(cursor: feedCursor)
    feedCursor = feed.cursor
    for event in feed.events {
      if await !write(jsonObject([("type", .string("feed")), ("event", event)])) { return false }
    }
    return true
  }

  // MARK: Capture

  private func capture() async {
    var departed = false
    if !selected.isEmpty && !available.contains(selected) {
      selected = ""
      haveContent = false
      departed = true
    }
    for target in previews.keys where !available.contains(target) {
      previews.remove(target)
      previewSent.remove(target)
      departed = true
    }
    if departed { _ = await error("subscription_target_gone") }

    var requests: [String: Int] = [:]
    for target in previews.keys { requests[target] = Protocol.previewLines }
    // Bun quirk: a target that is both selected and previewed is captured once,
    // at the selected line count, and the preview then reports those 80 lines.
    if !selected.isEmpty { requests[selected] = Protocol.selectedLines }
    if requests.isEmpty { return }

    let contents: [String: String]
    do {
      contents = try await backend.captureBatch(requests)
    } catch {
      _ = await self.error("capture_unavailable")
      return
    }

    if !selected.isEmpty {
      let current = WSText(contents[selected])
      if !haveContent || current != lastContent {
        // Bun quirk: when the backend omits the selected target the frame is
        // sent with no `content` key at all, because `JSON.stringify` drops
        // `undefined`. Reproduced here rather than coerced to "".
        _ = await write(
          jsonObject([("type", .string("capture")), ("target", .string(selected)), ("content", current.json)]))
        lastContent = current
        haveContent = true
      }
    }

    var changed: [(String, JSONValue?)] = []
    for target in previews.keys {
      let current = WSText(contents[target])
      if !previewSent.contains(target) || current != previews.value(target) {
        changed.append((target, current.json))
        previews.set(target, current)
        previewSent.insert(target)
      }
    }
    // Bun quirk: the count includes targets whose content is `undefined`, whose
    // keys are then dropped — so a `previews` frame with an empty `data` object
    // is reachable.
    if !changed.isEmpty {
      _ = await write(jsonObject([("type", .string("previews")), ("data", jsonObject(changed))]))
    }
  }

  // MARK: Commands

  private func run(_ body: WSCommand) async {
    switch body.type ?? "" {
    case "select", "subscribe":
      // Bun quirk: `body.scope && !['main','preview'].includes(body.scope)` —
      // an empty-string scope is falsy, so it passes validation and is then
      // treated as "main".
      let scope = body.scope ?? ""
      guard let target = body.target, !target.isEmpty, target.utf8.count <= wsMaxTargetBytes,
        scope.isEmpty || scope == "main" || scope == "preview"
      else {
        _ = await error("subscription_invalid")
        return
      }
      if scope == "preview" {
        if !previews.has(target) && previews.count >= Protocol.maxPreviews {
          _ = await error("too_many_previews")
          return
        }
        // Re-subscribing an existing preview keeps its position but resets it,
        // so the next pass resends the content.
        previews.set(target, .text(""))
        previewSent.remove(target)
      } else {
        selected = target
        haveContent = false
      }
      await capture()

    case "subscribe-previews":
      let targets = body.targets ?? []
      // Length is checked before de-duplication, so 17 copies of one target is
      // still `too_many_previews`.
      if targets.count > Protocol.maxPreviews {
        _ = await error("too_many_previews")
        return
      }
      if targets.contains(where: { $0.isEmpty || $0.utf8.count > wsMaxTargetBytes }) {
        _ = await error("subscription_invalid")
        return
      }
      previews.removeAll()
      for target in targets { previews.set(target, .text("")) }
      previewSent.removeAll()
      await capture()

    case "wake":
      if readOnly {
        _ = await error("operator_token_required_for_writes")
        return
      }
      guard let target = body.target, !target.isEmpty, target.utf8.count <= wsMaxTargetBytes
      else {
        _ = await error("target_required")
        return
      }
      // Bun quirk: `body.command?.length` — an empty-string command is accepted
      // and ignored; any non-empty one is refused rather than executed.
      if let requested = body.command, !requested.isEmpty {
        _ = await error("wake_command_not_supported")
        return
      }
      do {
        _ = try await backend.wake(target: target, task: nil)
      } catch {
        _ = await self.error("wake_failed")
        return
      }
      _ = await write(
        jsonObject([("type", .string("action-ok")), ("action", .string("wake")), ("target", .string(target))]))

    case "send":
      if readOnly {
        _ = await error("operator_token_required_for_writes")
        return
      }
      // `body.target ?? selected` — only an absent or null target falls back to
      // the selection; an explicit "" does not, and fails the check below.
      let target = body.target ?? selected
      let text = body.hasText ? body.text : body.content
      guard !target.isEmpty, let text else {
        _ = await error("target_and_text_required")
        return
      }
      if body.inbox == true || (body.attachments.map { !$0.isEmpty } ?? false) {
        _ = await error("send_options_not_supported")
        return
      }
      do {
        // `body.force === true` IS the press-Enter flag in Bun, so the default
        // types the text and leaves it unsubmitted.
        try await backend.sendLiteral(target: target, text: text, enter: body.force == true)
      } catch {
        _ = await self.error("send_failed")
        return
      }
      _ = await write(
        jsonObject([
          ("type", .string("sent")), ("ok", .bool(true)), ("target", .string(target)), ("text", .string(text)),
          ("state", .string("accepted")),
        ]))

    default:
      _ = await error("command_not_supported")
    }
  }
}

// MARK: - Terminal session (mod.createPtySession.ts)

private final class WSPtySession: WSHandler, @unchecked Sendable {
  private let socket: WSSocket
  private let backend: any HerdrBackend
  private let timers: DispatchQueue
  private let chain = WSChain()
  private let lock = NSLock()
  private var stopped = false
  private var attaching = false
  private var attached = false
  private var pending = 0
  private var queuedBytes = 0
  private var terminal: (any HerdrTerminal)?
  private var attachTimer: DispatchSourceTimer?

  init(socket: WSSocket, backend: any HerdrBackend, timers: DispatchQueue) {
    self.socket = socket
    self.backend = backend
    self.timers = timers
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  func open() {
    // "attach required": a client that never attaches is dropped after 10s.
    let timer = DispatchSource.makeTimerSource(queue: timers)
    timer.schedule(deadline: .now() + 10)
    timer.setEventHandler { [weak self] in self?.fail(1008, "attach required") }
    timer.resume()
    lock.withLock { attachTimer = timer }
  }

  func close() {
    let terminal: (any HerdrTerminal)? = lock.withLock {
      stopped = true
      attachTimer?.cancel()
      attachTimer = nil
      return self.terminal
    }
    chain.stop()
    terminal?.close()
  }

  private func fail(_ code: UInt16, _ reason: String) {
    close()
    socket.closeWith(code, reason)
  }

  /// A queued send is accepted, never resent. Bound backlog independently.
  @discardableResult
  private func write(text: String? = nil, binary: Data? = nil) -> Bool {
    if isStopped { return false }
    let sent: Bool
    if let text {
      sent = socket.bufferedAmount <= 4 * 1024 * 1024 && socket.enqueueText(text)
    } else {
      sent = socket.bufferedAmount <= 4 * 1024 * 1024 && socket.enqueueBinary(binary ?? Data())
    }
    if !sent {
      fail(1013, "slow terminal client")
      return false
    }
    return true
  }

  private func dimensions(_ body: JSONObject) -> (cols: Int, rows: Int)? {
    guard let cols = body["cols"]?.safeInteger, let rows = body["rows"]?.safeInteger, cols >= 1, cols <= 500,
      rows >= 1, rows <= 300
    else { return nil }
    return (cols, rows)
  }

  func message(text: String) { accept(text: text, binary: nil) }
  func message(binary: Data) { accept(text: nil, binary: binary) }

  private func accept(text: String?, binary: Data?) {
    if isStopped { return }
    let bytes = text.map { $0.utf8.count } ?? (binary?.count ?? 0)
    let overflow: Bool = lock.withLock {
      pending += 1
      queuedBytes += bytes
      return pending > 64 || queuedBytes > 256 * 1024
    }
    if overflow {
      fail(1008, "terminal input overflow")
      return
    }
    chain.enqueue { [self] in
      do {
        try await handle(text: text, binary: binary)
      } catch {
        fail(1011, "terminal unavailable")
      }
      lock.withLock {
        pending -= 1
        queuedBytes -= bytes
      }
    }
  }

  private func handle(text: String?, binary: Data?) async throws {
    if isStopped { return }
    if let binary {
      guard let terminal = lock.withLock({ self.terminal }) else {
        fail(1008, "terminal not attached")
        return
      }
      try terminal.input(binary)
      return
    }
    guard let text, let body = try? parseJSON(text).object, let size = dimensions(body) else {
      fail(1008, "invalid terminal command")
      return
    }
    if body["type"]?.string == "attach" {
      let alreadyAttaching = lock.withLock { attaching }
      guard !alreadyAttaching, body.keys.allSatisfy({ ["type", "target", "cols", "rows"].contains($0) }),
        let target = body["target"]?.string, !target.isEmpty, target.utf8.count <= 1024
      else {
        fail(1008, "invalid terminal attach")
        return
      }
      lock.withLock { attaching = true }
      let terminal = try await backend.openTerminal(target: target, cols: size.cols, rows: size.rows) { [weak self] output in
        guard let self else { return }
        let firstOutput: Bool = lock.withLock {
          if attached { return false }
          attached = true
          attachTimer?.cancel()
          attachTimer = nil
          return true
        }
        if firstOutput, !write(text: jsonStringify(jsonObject([("type", .string("attached"))]))) { return }
        if !output.isEmpty { write(binary: output) }
      }
      let stoppedMeanwhile: Bool = lock.withLock {
        if stopped { return true }
        self.terminal = terminal
        return false
      }
      if stoppedMeanwhile {
        terminal.close()
        return
      }
      Task { [weak self] in
        await terminal.waitDone()
        guard let self, !isStopped else { return }
        write(text: jsonStringify(jsonObject([("type", .string("detached"))])))
        fail(1000, "terminal detached")
      }
    } else if body["type"]?.string == "resize", let terminal = lock.withLock({ self.terminal }),
      body.keys.allSatisfy({ ["type", "cols", "rows"].contains($0) })
    {
      try terminal.resize(cols: size.cols, rows: size.rows)
    } else {
      fail(1008, "invalid terminal command")
    }
  }
}
