import CryptoKit
import Foundation

// The herdr backend: every fact this server reports about a pane comes from a
// `herdr` subprocess started here, and every write goes back out the same way.
//
// Port of two Bun files, deliberately line-for-line where the behaviour is
// observable:
//   mod.readRoster.ts         — snapshot JSON -> Roster (the critical one)
//   mod.createHerdrBackend.ts — capture / captureBatch / send / wake / inbox / terminal
// with the subprocess runner in Subprocess.swift and the wake and inbox chains
// in WakeSupport.swift and Inbox.swift.
//
// Parity beats taste here. Where the Bun code does something surprising the
// surprise is reproduced, not corrected, and called out in the report.

// MARK: - Operation gate (mod.createHerdrBackend.ts `operation`)

/// FIFO async semaphore: `limit` concurrent holders, `maxWaiters` queued. Past
/// both, callers are refused rather than queued forever — a dashboard that
/// keeps retrying must not build an unbounded backlog of subprocesses. A
/// queued waiter leaves the queue when its task is cancelled or its
/// operation's deadline passes, as Bun's `cancelled` listener splices it out.
private actor AsyncGate {
  private let limit: Int
  private let maxWaiters: Int
  private let fullMessage: String
  private var active = 0
  private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

  init(limit: Int, maxWaiters: Int, fullMessage: String) {
    self.limit = limit
    self.maxWaiters = maxWaiters
    self.fullMessage = fullMessage
  }

  func acquire(deadline: TimeInterval) async throws {
    if active < limit {
      active += 1
      return
    }
    if waiters.count >= maxWaiters { throw backendError(fullMessage) }
    let id = UUID()
    let expiry = Task { [weak self] in
      try await Task.sleep(nanoseconds: UInt64(max(deadline, 0) * 1_000_000_000))
      await self?.cancelWaiter(id)
    }
    defer { expiry.cancel() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: backendError("herdr operation aborted"))
          return
        }
        waiters.append((id, continuation))
      }
    } onCancel: {
      Task { [weak self] in await self?.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: backendError("herdr operation aborted"))
  }

  func release() {
    // The slot is handed straight to the next waiter, so `active` stays put.
    if waiters.isEmpty {
      active -= 1
    } else {
      waiters.removeFirst().continuation.resume()
    }
  }
}

// MARK: - JSON helpers (mod.readRoster.ts)

private let invalidObject = "invalid herdr JSON object"

private func objectValue(_ value: JSONValue?) throws -> JSONObject {
  guard let object = value?.object else { throw backendError(invalidObject) }
  return object
}

/// Go's JSON string fields accept null/missing as empty, but reject other types.
private func stringValue(_ value: JSONValue?) throws -> String {
  guard let value, !value.isNull else { return "" }
  guard let text = value.string else { throw backendError("invalid herdr string field") }
  return text
}

/// Peels `{result:{snapshot:{…}}}` down to the payload, refusing at any level
/// that carries a non-null `error`. `herdr session list --json` arrives bare;
/// `api snapshot` arrives wrapped twice, so both shapes have to pass through
/// the same loop.
private func unwrapHerdrJSON(_ raw: String) throws -> JSONObject {
  guard var value = try? parseJSON(raw) else { throw backendError(invalidObject) }
  while true {
    let object = try objectValue(value)
    if let error = object["error"], !error.isNull { throw backendError("herdr returned an error") }
    if let next = object["result"] {
      value = next
    } else if let next = object["snapshot"] {
      value = next
    } else {
      return object
    }
  }
}

private func base64url(_ text: String) -> String {
  Data(text.utf8).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

/// `Number.MAX_SAFE_INTEGER`, the ceiling `Number.isSafeInteger` enforces.
private let maxSafeInteger = 9_007_199_254_740_991

/// `/^[0-9a-z]+$/i`.
private let base36Digits = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

private func paneWindowName(_ pane: Pane) -> String {
  [pane.workspaceLabel ?? "", pane.label, pane.title, pane.id].first { !$0.isEmpty } ?? pane.id
}

// MARK: - Backend

/// `HerdrBackend` over the real `herdr` binary.
final class HerdrProcessBackend: HerdrBackend, @unchecked Sendable {
  private let binary: String
  private let wakeEngine: String
  private let explicitWakeEngine: String?
  let observedFeed = ObservedFeed()
  private let gate = AsyncGate(limit: 8, maxWaiters: 64, fullMessage: "herdr operation queue is full")
  private let wakeAdmission = AsyncGate(limit: 8, maxWaiters: 0, fullMessage: "wake capacity reached")
  private let wakeSerializer = AsyncGate(limit: 1, maxWaiters: Int.max, fullMessage: "wake capacity reached")
  private let lock = NSLock()
  private var terminals = 0
  private var dashboardSnapshot: Task<[Session], Error>?

  init(binary: String = "herdr", wakeEngine: String = "codex", explicitWakeEngine: String? = nil) {
    self.binary = binary.isEmpty ? "herdr" : binary
    self.wakeEngine = wakeEngine
    self.explicitWakeEngine = explicitWakeEngine
  }

  // MARK: Subprocess

  private func run(_ args: [String], _ op: HerdrOp) async throws -> String {
    try await runCommand(binary: binary, args: args, op: op)
  }

  private func operation<T>(_ body: (HerdrOp) async throws -> T) async throws -> T {
    if Task.isCancelled { throw backendError("herdr operation aborted") }
    let op = HerdrOp()
    try await gate.acquire(deadline: op.remaining)
    defer { Task { [gate] in await gate.release() } }
    if op.aborted { throw backendError("herdr operation aborted") }
    return try await body(op)
  }

  // MARK: Roster (mod.readRoster.ts)

  func roster() async throws -> Roster {
    try await operation { try await self.readRoster($0) }
  }

  /// Share one acquisition + observation among dashboard clients. A slower
  /// old roster can never publish after a newer status observation.
  func dashboardSessions() async throws -> [Session] {
    if Task.isCancelled { throw backendError("herdr operation aborted") }
    let shared: Task<[Session], Error> = lock.withLock {
      if let existing = dashboardSnapshot { return existing }
      let created = Task { [self] in
        defer { lock.withLock { dashboardSnapshot = nil } }
        return try await operation { op in
          let sessions = try await self.readRoster(op).sessions
          self.observedFeed.observe(sessions)
          return sessions
        }
      }
      dashboardSnapshot = created
      return created
    }
    let sessions = try await shared.value
    if Task.isCancelled { throw backendError("herdr operation aborted") }
    return sessions
  }

  func teamInventory() throws -> JSONValue { try readTeamInventory() }

  private func readRoster(_ op: HerdrOp) async throws -> Roster {
    var result = Roster(runningSessions: [], sessions: [], targets: [:])
    let list = try unwrapHerdrJSON(try await run(["session", "list", "--json"], op))
    guard let items = list["sessions"]?.array else { throw backendError("invalid herdr session list") }
    var seenSessions = Set<String>()
    for item in items {
      let server = try objectValue(item)
      let serverName = try stringValue(server["name"])
      guard !serverName.isEmpty, let running = server["running"]?.bool, !seenSessions.contains(serverName)
      else { throw backendError("invalid or duplicate herdr session") }
      seenSessions.insert(serverName)
      if !running { continue }
      result.runningSessions.append(serverName)

      let snapshot = try unwrapHerdrJSON(try await run(["--session", serverName, "api", "snapshot"], op))
      guard snapshot["protocol"] == .number(Double(Protocol.herdrSnapshotVersion)),
        let workspaces = snapshot["workspaces"]?.array, let panes = snapshot["panes"]?.array
      else { throw backendError("invalid herdr protocol-22 snapshot") }

      // Swift dictionaries have no insertion order, and the pre-sort session
      // order is observable, so it is tracked alongside.
      var spaces: [String: Session] = [:]
      var spaceOrder: [String] = []
      var labels: [String: String] = [:]
      for item in workspaces {
        let space = try objectValue(item)
        let id = try stringValue(space["workspace_id"])
        labels[id] = try stringValue(space["label"])
        guard !id.isEmpty, spaces[id] == nil else { throw backendError("invalid or duplicate workspace") }
        spaces[id] = Session(name: base64url(serverName) + "/" + base64url(id), source: "local", windows: [])
        spaceOrder.append(id)
      }

      var seenPanes = Set<String>()
      for item in panes {
        let raw = try objectValue(item)
        let workspaceId = try stringValue(raw["workspace_id"])
        let focused = raw["focused"]?.bool
        let pane = Pane(
          workspaceLabel: labels[workspaceId],
          id: try stringValue(raw["pane_id"]),
          workspace: workspaceId,
          agent: try stringValue(raw["agent"]),
          label: try stringValue(raw["label"]),
          title: try stringValue(raw["title"]),
          cwd: try stringValue(raw["cwd"]),
          focused: focused ?? false,
          status: try stringValue(raw["agent_status"]))
        // Checked before pane identity, as in the Bun original: a bad status
        // reports itself even when the id is bad too.
        guard Protocol.paneStatuses.contains(pane.status) else { throw backendError("invalid pane agent status") }
        let prefix = pane.workspace + ":p"
        let suffix = String(pane.id.dropFirst(prefix.count))
        guard let space = spaces[pane.workspace], focused != nil, pane.id.hasPrefix(prefix), !suffix.isEmpty,
          suffix.allSatisfy({ base36Digits.contains($0) }), let index = Int(suffix, radix: 36), index >= 0,
          index <= maxSafeInteger, !seenPanes.contains(pane.id)
        else { throw backendError("invalid or ambiguous pane identity") }
        seenPanes.insert(pane.id)

        // Bun parity, deliberately kept: the target key carries the RAW suffix
        // while the window carries its base-36 VALUE. Pane "wD:pQ" is published
        // as index 26 and addressed as "<session>:Q".
        let target = space.name + ":" + suffix
        guard result.targets[target] == nil else { throw backendError("duplicate pane target") }
        let agent = jsTrim(pane.agent)
        spaces[pane.workspace]?.windows.append(
          Window(
            index: index,
            name: [pane.label, pane.title, pane.agent, pane.id].first { !$0.isEmpty } ?? pane.id,
            active: pane.focused,
            cwd: pane.cwd.isEmpty ? nil : pane.cwd,
            status: pane.status,
            agent: agent.isEmpty ? nil : agent))
        result.targets[target] = Target(session: serverName, pane: pane)
      }

      for id in spaceOrder {
        guard var space = spaces[id] else { continue }
        // V8's sort is stable and two raw suffixes can share one index ("1"
        // and "01"), so arrival order breaks the tie here as it does there.
        space.windows = space.windows.enumerated()
          .sorted { $0.element.index == $1.element.index ? $0.offset < $1.offset : $0.element.index < $1.element.index }
          .map(\.element)
        result.sessions.append(space)
      }
    }
    result.sessions.sort { jsLess($0.name, $1.name) }
    return result
  }

  // MARK: Capture

  func capture(target: String, lines: Int) async throws -> String {
    let captures = try await captureBatch([target: lines])
    guard let text = captures[target] else { throw BackendError.unknownTarget("unknown or stale target") }
    return text
  }

  func captureBatch(_ requests: [String: Int]) async throws -> [String: String] {
    let keys = requests.keys.sorted(by: jsLess)
    guard keys.count <= 64 else { throw backendError("capture batch exceeds 64 targets") }
    for key in keys {
      guard let lines = requests[key], lines >= 1, lines <= 2000 else {
        throw backendError("capture lines must be between 1 and 2000")
      }
    }
    return try await operation { op in
      var captures: [String: String] = [:]
      if keys.isEmpty { return captures }
      let roster = try await self.readRoster(op)
      // Every key is checked before any pane is read: one unknown target fails
      // the whole batch with target_not_found, never a partial result.
      for key in keys where roster.targets[key] == nil {
        throw BackendError.unknownTarget("unknown or stale target")
      }
      for key in keys {
        let target = roster.targets[key]!
        captures[key] = try await self.run(
          [
            "--session", target.session, "pane", "read", target.pane.id, "--source", "visible", "--lines",
            String(requests[key]!), "--format", "text",
          ], op)
      }
      if op.aborted { throw backendError("herdr operation aborted") }
      return captures
    }
  }

  // MARK: Send

  /// `createHerdrBackend.send` — `agent prompt`. Note the validation is NOT the
  /// same as `sendLiteral`'s: there is no up-front target check (an unknown
  /// target simply misses the roster), blank text is refused, and a pane with
  /// no agent is refused with a distinct error.
  func send(target: String, text: String) async throws {
    guard !jsTrim(text).isEmpty, byteLength(text) <= 64 * 1024, !text.contains("\0") else {
      throw backendError("invalid prompt text")
    }
    try await operation { op in
      guard let pane = try await self.readRoster(op).targets[target] else {
        throw BackendError.unknownTarget("unknown or stale target")
      }
      guard !jsTrim(pane.pane.agent).isEmpty else { throw BackendError.notAgent("target is not an agent pane") }
      _ = try await self.run(["--session", pane.session, "agent", "prompt", pane.pane.id, text], op)
    }
  }

  /// `createHerdrBackend.sendLiteral` — types the text, and presses Enter only
  /// when the caller asked for it. The socket path passes the client's `force`
  /// flag here, so an un-forced send leaves the text sitting unsubmitted.
  func sendLiteral(target: String, text: String, enter: Bool) async throws {
    guard !target.isEmpty, byteLength(target) <= 1024 else { throw BackendError.unknownTarget("unknown or stale target") }
    guard byteLength(text) <= 64 * 1024, !text.contains("\0") else { throw backendError("invalid literal text") }
    try await operation { op in
      guard let pane = try await self.readRoster(op).targets[target] else {
        throw BackendError.unknownTarget("unknown or stale target")
      }
      _ = try await self.run(["--session", pane.session, "pane", "send-text", pane.pane.id, text], op)
      if enter {
        _ = try await self.run(["--session", pane.session, "pane", "send-keys", pane.pane.id, "enter"], op)
      }
    }
  }

  // MARK: Inbox

  func inbox(target: String, text: String, serverRoot: String, from: String) async throws -> String {
    try await operation { op in
      try await deliverReceiverInbox(
        roster: { try await self.readRoster(op) }, target: target, text: text, serverRoot: serverRoot,
        rawFrom: from, op: op)
    }
  }

  // MARK: Wake (mod.createHerdrBackend.ts `wake`)

  func wake(target: String, task: String?) async throws -> WakeState {
    guard !target.isEmpty, byteLength(target) <= 1024 else { throw BackendError.unknownTarget("unknown or stale target") }
    try await wakeAdmission.acquire(deadline: 0)
    defer { Task { [wakeAdmission] in await wakeAdmission.release() } }

    return try await operation { op in
      // Wakes run one at a time: two launches racing into one pane fight over
      // the same terminal.
      try await self.wakeSerializer.acquire(deadline: op.remaining)
      defer { Task { [wakeSerializer] in await wakeSerializer.release() } }
      if op.aborted { throw backendError("herdr operation aborted") }

      var roster = try await self.readRoster(op)
      var pane = roster.targets[target]
      var launchWindow = pane.map { paneWindowName($0.pane) } ?? ""
      var basePath = ""
      var oracle = launchWindow
      if pane != nil && task != nil { throw backendError("task requires a registered repository") }
      if pane == nil {
        var repo = try resolveRegistryWake(target)
        basePath = repo.path
        oracle = repo.name
        let session: String?
        if roster.runningSessions.contains("default") {
          session = "default"
        } else if roster.runningSessions.count == 1 {
          session = roster.runningSessions[0]
        } else {
          session = nil
        }
        guard let session else { throw backendError("running session is ambiguous or missing") }
        if let task {
          let plan = try await planTaskWorktree(repo: repo.path, rawTask: task, op: op)
          let label = repo.name + "-" + plan.slug
          if byteLength(label) > 1024 { throw backendError("invalid task label") }
          for item in roster.targets.values {
            if item.session != session
              || (item.pane.label != label && item.pane.title != label && item.pane.workspaceLabel != label)
            {
              continue
            }
            guard let cwd = try? realPath(item.pane.cwd) else { throw backendError("task pane cwd mismatch") }
            if !NodePath.isAbsolute(item.pane.cwd) || cwd != plan.path { throw backendError("task pane cwd mismatch") }
          }
          try await plan.materialize()
          repo.path = plan.path
          repo.name = label
          roster = try await self.readRoster(op)
        }
        launchWindow = repo.name
        let repoPath = repo.path
        let matches = roster.targets.values.filter { item in
          guard item.session == session, NodePath.isAbsolute(item.pane.cwd) else { return false }
          return (try? realPath(item.pane.cwd)) == repoPath
        }
        if matches.count > 1 { throw backendError("repository pane is ambiguous") }
        pane = matches.first
        if pane == nil {
          let created: JSONValue
          do {
            created = try parseJSON(
              try await self.run(
                ["--session", session, "workspace", "create", "--cwd", repo.path, "--label", repo.name, "--no-focus"],
                op))
          } catch {
            throw backendError("workspace creation failed")
          }
          let result = created["result"]
          guard created["error"] == nil || created["error"]!.isNull, result?["error"] == nil || result!["error"]!.isNull,
            result?["type"]?.string == "workspace_created", result?["tab"]?.object != nil,
            let rootPaneId = result?["root_pane"]?["pane_id"]?.string,
            let workspaceId = result?["workspace"]?["workspace_id"]?.string,
            result?["root_pane"]?["workspace_id"] == .string(workspaceId)
          else { throw backendError("workspace identity not verified") }
          roster = try await self.readRoster(op)
          pane = roster.targets.values.first {
            $0.session == session && $0.pane.id == rootPaneId && $0.pane.workspace == workspaceId
          }
          guard let found = pane, NodePath.isAbsolute(found.pane.cwd) else {
            throw backendError("workspace identity not verified")
          }
          guard let cwd = try? realPath(found.pane.cwd) else { throw backendError("workspace cwd not verified") }
          if cwd != repo.path { throw backendError("workspace cwd not verified") }
          let sameRepo = roster.targets.values.filter { item in
            guard item.session == session, NodePath.isAbsolute(item.pane.cwd) else { return false }
            return (try? realPath(item.pane.cwd)) == repoPath
          }
          if sameRepo.count != 1 { throw backendError("repository pane is ambiguous") }
        }
      }

      let resolvedPane = pane!
      if !NodePath.isAbsolute(resolvedPane.pane.cwd) { throw backendError("pane cwd unavailable") }
      guard let finalCwd = try? realPath(resolvedPane.pane.cwd) else { throw backendError("pane cwd unavailable") }
      if basePath.isEmpty {
        let identity = try await resolveWakeIdentity(cwd: finalCwd, window: launchWindow, op: op)
        basePath = identity.basePath
        oracle = identity.oracle
      }
      let merged: JSONObject
      do {
        merged = try readMawConfig(cwd: finalCwd)
      } catch is MawConfigUnavailable {
        throw HTTPStatusError(status: 503, code: "config_unavailable")
      }

      func finish(_ state: WakeState) async throws -> WakeState {
        if op.aborted { throw backendError("herdr operation aborted") }
        let fresh = try await self.readRoster(op)
        let stillResolved = fresh.targets.values.contains { candidate in
          guard candidate.session == resolvedPane.session, candidate.pane.id == resolvedPane.pane.id,
            candidate.pane.workspace == resolvedPane.pane.workspace, NodePath.isAbsolute(candidate.pane.cwd)
          else { return false }
          return (try? realPath(candidate.pane.cwd)) == finalCwd
        }
        if !stillResolved { throw backendError("wake pane identity changed") }
        let live = fresh.targets.values.filter { $0.session == resolvedPane.session }
          .map { (name: paneWindowName($0.pane), cwd: $0.pane.cwd) }
        if op.aborted { throw backendError("herdr operation aborted") }
        try await registerWakeFleet(session: resolvedPane.session, live: live, basePath: basePath, window: launchWindow)
        await runWakeHooks(config: merged, oracle: oracle, session: resolvedPane.session, window: launchWindow, op: op)
        return state
      }

      if !jsTrim(resolvedPane.pane.agent).isEmpty { return try await finish(.alreadyAwake) }
      if ["commands", "wake", "defaultEngine", "zaiPool"].contains(where: { merged.has($0) }) {
        let launch: WakeLaunch
        do {
          launch = try resolveWakeLaunch(config: merged, window: launchWindow, explicitEngine: self.explicitWakeEngine)
        } catch {
          throw backendError("configured launch unavailable")
        }
        let state = try await launchConfiguredWake(
          run: { args, op in try await self.run(args, op) }, target: resolvedPane, line: launch.line, op: op)
        return try await finish(state)
      }

      let digest = SHA256.hash(data: Data(resolvedPane.pane.id.utf8))
      let name = "maw-" + String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
      let raw = try await self.run(
        [
          "--session", resolvedPane.session, "agent", "start", name, "--kind", self.wakeEngine, "--pane",
          resolvedPane.pane.id, "--timeout", "8000",
        ], op)
      guard let response = try? parseJSON(raw) else { throw backendError("invalid agent start response") }
      let result = response["result"]
      let agent = result?["agent"]
      guard response.object != nil, response["error"] == nil || response["error"]!.isNull,
        result?["error"] == nil || result!["error"]!.isNull, result?["type"]?.string == "agent_started",
        let argv = result?["argv"]?.array, argv.allSatisfy({ $0.string != nil }), agent?.object != nil,
        agent?["pane_id"]?.string == resolvedPane.pane.id, agent?["agent"]?.string == self.wakeEngine,
        agent?["interactive_ready"] == .bool(true),
        agent?["launch_pending"] == nil || agent?["launch_pending"] == .bool(false), !op.aborted
      else { throw backendError("agent readiness not verified") }
      return try await finish(.ready)
    }
  }

  // MARK: Terminal

  func openTerminal(
    target: String, cols: Int, rows: Int, output: @escaping @Sendable (Data) -> Void
  ) async throws -> any HerdrTerminal {
    let admitted: Bool = lock.withLock {
      if terminals >= 16 { return false }
      terminals += 1
      return true
    }
    if !admitted { throw backendError("terminal capacity reached") }
    do {
      let pane = try await operation { op -> Target in
        guard let found = try await self.readRoster(op).targets[target] else {
          throw BackendError.unknownTarget("unknown or stale target")
        }
        return found
      }
      guard let terminal = HerdrTerminalProcess(binary: binary, target: pane, cols: cols, rows: rows, output: output)
      else { throw backendError("terminal aborted") }
      Task { [weak self] in
        await terminal.waitDone()
        guard let self else { return }
        self.lock.withLock { self.terminals -= 1 }
      }
      return terminal
    } catch {
      lock.withLock { terminals -= 1 }
      throw error
    }
  }
}
