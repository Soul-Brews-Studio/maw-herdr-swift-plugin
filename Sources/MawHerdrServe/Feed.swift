import CryptoKit
import Foundation

// The in-memory feeds and the team inventory reader:
//   mod.createObservedFeed.ts  — status transitions projected as hook-shaped events
//   mod.createDeliveryFeed.ts  — the /api/send delivery history behind /api/feed
//   mod.createDeliveryDedup.ts — idempotency receipts keyed by X-Maw-Timestamp
//   mod.readTeamInventory.ts   — ~/.claude/teams, the `teams` frame and /api/teams
//
// Every object these emit is built as an ordered JSONObject in the exact key
// order the Bun code constructs it, because the bytes go straight to a client.

// MARK: - Observed feed

/// "Compatibility projection from observed Herdr status, never a real tool hook."
final class ObservedFeed: @unchecked Sendable {
  private struct State {
    var status: String
    var name: String
    var emitted: Int
  }

  private let lock = NSLock()
  private var sequence = 0
  private var realActivity: [String: Int] = [:]
  private var events: [(id: Int, event: JSONObject)] = []
  private var states: [String: State] = [:]

  private static let worktreePattern = try! NSRegularExpression(pattern: #"[.-]wt-(?:[0-9]+-)?(.+)$"#)

  static func nowMilliseconds() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

  private func prune(_ now: Int) {
    events = Array(events.filter { now - Int($0.event["ts"]?.number ?? 0) < 60_000 }.suffix(100))
  }

  @discardableResult
  func markActivity(_ oracle: String, now: Int = nowMilliseconds()) -> Bool {
    if jsTrim(oracle).isEmpty || byteLength(oracle) > 1024 { return false }
    lock.lock()
    defer { lock.unlock() }
    for (key, seen) in realActivity where now - seen >= 60_000 { realActivity.removeValue(forKey: key) }
    if realActivity[oracle] == nil && realActivity.count >= 1000 { return false }
    realActivity[oracle] = now
    return true
  }

  func observe(_ sessions: [Session], now: Int = nowMilliseconds()) {
    lock.lock()
    defer { lock.unlock() }
    struct Item {
      let session: Session
      let window: Window
      let target: String
    }
    let windows = sessions.flatMap { session in
      session.windows.map { Item(session: session, window: $0, target: "\(session.name):\($0.index)") }
    }
    var names: [String: (count: Int, target: String)] = [:]
    for item in windows {
      let key = item.window.name.lowercased()
      names[key] = ((names[key]?.count ?? 0) + 1, item.target)
    }
    var next: [String: State] = [:]
    var safe = Set<String>()
    for item in windows {
      let window = item.window
      let session = item.session
      let target = item.target
      guard let agent = window.agent, !jsTrim(agent).isEmpty,
        ["working", "blocked", "done", "idle"].contains(window.status), !window.name.isEmpty,
        window.name.utf16.count <= 1024, session.name.utf16.count <= 1024, next.count < 1000
      else { continue }
      let oracle = window.name.lowercased()
      var worktree: String?
      let range = NSRange(session.name.startIndex..., in: session.name)
      if let match = ObservedFeed.worktreePattern.firstMatch(in: session.name, range: range),
        let captured = Range(match.range(at: 1), in: session.name)
      {
        worktree = String(session.name[captured])
      }
      let preferred: String
      if let worktree {
        preferred = "\(window.name)-\(worktree)".lowercased()
      } else {
        preferred = oracle.hasSuffix("-oracle") ? oracle : oracle + "-oracle"
      }
      var match = names[preferred]
      if worktree == nil && match == nil { match = names[oracle] }
      guard let match, match.count == 1, match.target == target else { continue }
      safe.insert(target)
      let previous = states[target]
      if previous == nil || previous!.status != window.status || previous!.name != window.name
        || (window.status == "working" && now - previous!.emitted >= 10_000)
      {
        var stem = window.name
        if stem.hasSuffix("-oracle") { stem.removeLast("-oracle".count) }
        if let seen = realActivity[stem], now - seen < 60_000 {
          next[target] = State(status: window.status, name: window.name, emitted: previous?.emitted ?? 0)
          continue
        }
        let event = jsonObject([
          ("timestamp", .string(isoTimestamp(milliseconds: now))),
          ("ts", .int(now)),
          ("oracle", .string(window.name)),
          ("project", .string(session.name)),
          ("sessionId", .string("")),
          ("host", .string("local")),
          ("event", .string(window.status == "working" ? "PreToolUse" : "Stop")),
          ("source", .string("herdr-agent-status")),
          ("observedState", .string(window.status)),
          ("target", .string(target)),
          ("message", .string("Herdr observed \(window.status); status projection, not a tool hook")),
        ])
        sequence += 1
        events.append((sequence, event.object!))
        next[target] = State(status: window.status, name: window.name, emitted: now)
      } else {
        next[target] = previous!
      }
    }
    states = next
    // Never replay an old identity onto a removed, renamed, or ambiguous pane.
    events = events.filter { item in
      guard let target = item.event["target"]?.string, safe.contains(target) else { return false }
      return next[target]?.name == item.event["oracle"]?.string
    }
    prune(now)
  }

  func read(cursor: Int = 0, now: Int = nowMilliseconds()) -> (cursor: Int, events: [JSONValue]) {
    lock.lock()
    defer { lock.unlock() }
    prune(now)
    return (sequence, events.filter { $0.id > cursor }.map { .object($0.event) })
  }
}

/// `new Date(ms).toISOString()` — millisecond precision, always `Z`.
func isoTimestamp(milliseconds: Int) -> String {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
  let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
  let millis = ((milliseconds % 1000) + 1000) % 1000
  return String(
    format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1,
    parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, millis)
}

// MARK: - Delivery history

/// "Delivery history, not observed tool-hook/status projection." Bounded to
/// 200 events; text/from/to are cut at 2000 bytes and `error` at 1000, with an
/// ellipsis, counted in code points as `[...value].slice()` does.
final class DeliveryFeed: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [JSONObject] = []

  private static func truncate(_ value: String, _ max: Int) -> String {
    if byteLength(value) <= max { return value }
    var result = String.UnicodeScalarView()
    for scalar in value.unicodeScalars.prefix(max - 1) { result.append(scalar) }
    return String(result) + "…"
  }

  func append(_ event: JSONObject) {
    var copy = event
    for (key, max) in [("text", 2000), ("from", 2000), ("to", 2000)] {
      copy[key] = .string(DeliveryFeed.truncate(copy[key]?.string ?? "", max))
    }
    if let error = event["error"]?.string { copy["error"] = .string(DeliveryFeed.truncate(error, 1000)) }
    lock.lock()
    events.append(copy)
    if events.count > 200 { events.removeFirst(events.count - 200) }
    lock.unlock()
  }

  func snapshot(limit: Int?) -> JSONValue {
    lock.lock()
    defer { lock.unlock() }
    let selected: [JSONObject]
    if let limit, limit >= 0, limit < events.count {
      selected = Array(events.suffix(limit))
    } else {
      selected = events
    }
    var oracles: [String] = []
    var seen = Set<String>()
    for event in selected {
      let oracle = event["oracle"]?.string ?? ""
      if seen.insert(oracle).inserted { oracles.append(oracle) }
    }
    return jsonObject([
      ("events", .array(selected.map(JSONValue.object))),
      ("total", .int(selected.count)),
      ("active_oracles", .strings(oracles)),
    ])
  }
}

// MARK: - Delivery dedup

struct DeliveryClaim {
  /// The receipt to return verbatim when an earlier delivery already claimed
  /// this key; nil means this caller owns the delivery.
  let duplicateState: String?
  let complete: @Sendable (String) -> Void
  let cancel: @Sendable () -> Void
}

struct DeliveryCapacityReached: Error {}

/// "Process-local receipts; an in-flight duplicate is queued, not completed."
final class DeliveryDedup: @unchecked Sendable {
  /// Mutated only under the owning dedup's lock.
  private final class Record: @unchecked Sendable {
    var state = ""
    var seen: Int
    init(seen: Int) { self.seen = seen }
  }

  private let lock = NSLock()
  private var records: [String: Record] = [:]

  func key(source: String, target: String, logical: String, payload: String) -> String? {
    let source = jsTrim(source)
    let target = jsTrim(target)
    let logical = jsTrim(logical)
    if source.isEmpty || target.isEmpty || logical.isEmpty { return nil }
    let material = jsonStringify(.strings([source, target, logical, payload]))
    return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func claim(_ key: String, now: @escaping @Sendable () -> Int = ObservedFeed.nowMilliseconds) throws -> DeliveryClaim {
    lock.lock()
    defer { lock.unlock() }
    let time = now()
    for (existing, record) in records where !record.state.isEmpty && time - record.seen > 86_400_000 {
      records.removeValue(forKey: existing)
    }
    if let previous = records[key] {
      return DeliveryClaim(
        duplicateState: previous.state.isEmpty ? "queued" : previous.state, complete: { _ in }, cancel: {})
    }
    if records.count >= 2048 { throw DeliveryCapacityReached() }
    let owner = Record(seen: time)
    records[key] = owner
    return DeliveryClaim(
      duplicateState: nil,
      complete: { [weak self] state in
        guard let self else { return }
        self.lock.lock()
        if self.records[key] === owner {
          owner.state = state
          owner.seen = now()
        }
        self.lock.unlock()
      },
      cancel: { [weak self] in
        guard let self else { return }
        self.lock.lock()
        if self.records[key] === owner && owner.state.isEmpty { self.records.removeValue(forKey: key) }
        self.lock.unlock()
      })
  }
}

// MARK: - Team inventory

/// `~/.claude/teams` + `~/.claude/tasks`, normalised. Operator home only;
/// every path is walked component by component and refused on a symlink.
/// Failure is `HTTPStatusError(503, teams_unavailable)`, never an empty list.
func readTeamInventory(home: String = homeDirectory(), now: Int = ObservedFeed.nowMilliseconds()) throws -> JSONValue {
  func fail() -> HTTPStatusError { HTTPStatusError(status: 503, code: "teams_unavailable") }
  var bytesRead = 0
  var tasksRead = 0
  var membersRead = 0
  var outputBytes = 0
  let root = NodePath.resolve(home)
  func text(_ value: JSONValue?) -> String { value?.string ?? "" }
  func integer(_ value: JSONValue?) -> Int {
    guard let number = value?.safeInteger, number >= 0 else { return 0 }
    return number
  }
  func local(_ cwd: String) -> Bool {
    NodePath.isAbsolute(cwd) && NodePath.within(root, NodePath.resolve(cwd))
  }

  /// Walks from the home root to `path`, lstat at every step: symlinks and
  /// wrong kinds fail, a missing component returns nil.
  func checked(_ path: String, directory: Bool) throws -> FileStat? {
    let relativePath = NodePath.relative(root, path)
    if relativePath == ".." || relativePath.hasPrefix("../") || NodePath.isAbsolute(relativePath) { throw fail() }
    let parts = relativePath.isEmpty ? [] : relativePath.components(separatedBy: "/")
    var current = root
    var index = -1
    while index < parts.count {
      if index >= 0 { current = NodePath.join(current, parts[index]) }
      let status: FileStat
      do {
        status = try lstatPath(current)
      } catch let error as FileError {
        if error.code == ENOENT { return nil }
        throw fail()
      }
      let wantDirectory = index < parts.count - 1 || directory
      if status.isSymbolicLink || (wantDirectory ? !status.isDirectory : !status.isFile) { throw fail() }
      if index == parts.count - 1 { return status }
      index += 1
    }
    return nil
  }

  var truncated = false
  func entries(_ path: String, limit: Int) throws -> [String] {
    guard try checked(path, directory: true) != nil else { return [] }
    var names: [String] = []
    do {
      let listing = try directoryEntries(path)
      for name in listing {
        if names.count >= limit {
          truncated = true
          break
        }
        names.append(name)
      }
      _ = try checked(path, directory: true)
    } catch {
      throw fail()
    }
    return names.sorted(by: jsLess)
  }

  func json(_ path: String) throws -> JSONObject? {
    guard let before = try checked(path, directory: false) else { return nil }
    if before.size > 1024 * 1024 || bytesRead + before.size > 4 * 1024 * 1024 { throw fail() }
    var content = Data()
    var descriptor: Int32?
    defer { if let descriptor { close(descriptor) } }
    do {
      let opened = try openNoFollow(path)
      descriptor = opened.descriptor
      let status = opened.stat
      if !status.isFile || status.dev != before.dev || status.ino != before.ino || status.size > 1024 * 1024 {
        throw fail()
      }
      let capacity = min(1024 * 1024 + 1, 4 * 1024 * 1024 - bytesRead + 1)
      let data = try readDescriptor(opened.descriptor, upTo: capacity)
      if data.count > 1024 * 1024 || bytesRead + data.count > 4 * 1024 * 1024 { throw fail() }
      guard let after = try checked(path, directory: false), after.dev == status.dev, after.ino == status.ino
      else { throw fail() }
      bytesRead += data.count
      content = data
    } catch {
      throw fail()
    }
    guard let parsed = try? parseJSON(content) else { return nil }
    return parsed.object
  }

  var teams: [JSONObject] = []
  let teamsRoot = NodePath.join(root, ".claude", "teams")
  let tasksRoot = NodePath.join(root, ".claude", "tasks")
  for directory in try entries(teamsRoot, limit: 100) {
    let teamRoot = NodePath.join(teamsRoot, directory)
    let entry: FileStat
    do { entry = try lstatPath(teamRoot) } catch { throw fail() }
    if entry.isFile { continue }
    _ = try checked(teamRoot, directory: true)
    guard let config = try json(NodePath.join(teamRoot, "config.json")) else { continue }
    let name = text(config["name"]).isEmpty ? directory : text(config["name"])
    let leadRepo = text(config["leadRepo"])
    let createdAt = integer(config["createdAt"])
    let leadAgentId = "team-lead@\(name)"
    let rawMembers = config["members"]?.array ?? []
    membersRead += rawMembers.count
    if membersRead > 1000 { throw fail() }
    var normalizedBytes = 0
    var members: [JSONObject] = []
    for value in rawMembers {
      let member = value.object ?? JSONObject()
      var memberName = text(member["name"])
      if memberName.isEmpty {
        let agentId = text(member["agentId"])
        if agentId.contains("@") { memberName = agentId.components(separatedBy: "@")[0] }
      }
      if memberName.isEmpty { memberName = "member" }
      let agentId = text(member["agentId"]).isEmpty ? "\(memberName)@\(name)" : text(member["agentId"])
      var agentType = text(member["agentType"])
      if agentType.isEmpty {
        agentType = agentId == leadAgentId || memberName == "team-lead" || memberName == "lead" ? "lead" : "member"
      }
      var joinedAt = createdAt
      if let joined = member["joinedAt"]?.safeInteger, joined >= 0 { joinedAt = joined }
      var cwd = text(member["cwd"])
      if cwd.isEmpty { cwd = text(member["repo"]) }
      if cwd.isEmpty { cwd = leadRepo }
      let subscriptions = (member["subscriptions"]?.array ?? []).compactMap(\.string)
      let normalized = jsonObject([
        ("name", .string(memberName)),
        ("agentId", .string(agentId)),
        ("agentType", .string(agentType)),
        ("joinedAt", .int(joinedAt)),
        ("tmuxPaneId", .string(text(member["tmuxPaneId"]))),
        ("cwd", .string(cwd)),
        ("subscriptions", .strings(subscriptions)),
        ("backendType", .string(member["backendType"]?.string ?? "in-process")),
        ("model", .string(text(member["model"]))),
        ("repo", .string(text(member["repo"]))),
        ("color", .string(text(member["color"]))),
      ])
      normalizedBytes += byteLength(jsonStringify(normalized))
      if normalizedBytes > 4 * 1024 * 1024 { throw fail() }
      members.append(normalized.object!)
    }
    var tasks: [JSONObject] = []
    let taskRoot = NodePath.join(tasksRoot, directory)
    for filename in try entries(taskRoot, limit: 1001) {
      guard filename.hasSuffix(".json") else { continue }
      tasksRead += 1
      if tasksRead > 1000 { throw fail() }
      guard let task = try json(NodePath.join(taskRoot, filename)) else { continue }
      var value = JSONObject()
      for key in ["id", "subject", "description", "activeForm", "owner", "status"] {
        if let string = task[key]?.string { value[key] = .string(string) }
      }
      if let id = task["id"], case .number = id, id.safeInteger != nil { value["id"] = id }
      for key in ["blocks", "blockedBy"] {
        if let list = task[key]?.array { value[key] = .strings(list.compactMap(\.string)) }
      }
      normalizedBytes += byteLength(jsonStringify(.object(value)))
      if normalizedBytes > 4 * 1024 * 1024 { throw fail() }
      tasks.append(value)
    }
    let alive = members.contains { member in
      let backendType = member["backendType"]?.string ?? ""
      let agentType = member["agentType"]?.string ?? ""
      let memberName = member["name"]?.string ?? ""
      let joinedAt = Int(member["joinedAt"]?.number ?? 0)
      return (backendType == "in-process" || agentType == "team-lead" || memberName == "team-lead")
        && local(member["cwd"]?.string ?? "") && max(0, now - joinedAt) < 2 * 60 * 60 * 1000
    }
    let team = jsonObject([
      ("name", .string(name)),
      ("description", .string(text(config["description"]))),
      ("leadRepo", .string(leadRepo)),
      ("leadSessionId", .string(text(config["leadSessionId"]))),
      ("leadAgentId", .string(leadAgentId)),
      ("createdAt", .int(createdAt)),
      ("members", .array(members.map(JSONValue.object))),
      ("tasks", .array(tasks.map(JSONValue.object))),
      ("alive", .bool(alive)),
    ])
    outputBytes += byteLength(jsonStringify(team))
    if outputBytes > 4 * 1024 * 1024 { throw fail() }
    teams.append(team.object!)
  }
  teams.sort { jsLess($0["name"]?.string ?? "", $1["name"]?.string ?? "") }
  let result = jsonObject([
    ("teams", .array(teams.map(JSONValue.object))),
    ("total", .int(teams.count)),
    ("truncated", truncated ? .bool(true) : nil),
  ])
  if byteLength(jsonStringify(result)) > 4 * 1024 * 1024 { throw fail() }
  return result
}
