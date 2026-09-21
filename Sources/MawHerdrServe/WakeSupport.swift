import Foundation

// Everything `wake` leans on besides `agent start`, ported module for module:
//   mod.resolveRegistryWake.ts   — a dashboard target that is not a pane is a
//                                  registered repository (~/.maw/oracles.json)
//   mod.resolveWakeIdentity.ts   — which registered oracle owns a pane's cwd,
//                                  proven by git worktree membership
//   mod.resolveWakeLaunch.ts     — the configured launch line, rendered
//   mod.launchConfiguredWake.ts  — submit it and prove a foreground process
//   mod.runWakeHooks.ts          — hooks.postWake, sequential, 10s budget
//   mod.registerWakeFleet.ts     — ~/.maw/fleet/<session>.json bookkeeping
//   mod.planTaskWorktree.ts      — agents/<slug> worktree for a task wake
//
// Parity beats taste: every limit, every failure string and every ordering
// below is the Bun one, including the ones that look like accidents.

/// `runHerdr` with the git environment: no `GIT_*` inherited, hooks and
/// fsmonitor off, no system/global config, no prompts.
func runGit(_ path: String, _ args: [String], op: HerdrOp) async throws -> String {
  try await runCommand(
    binary: "git",
    args: ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", path] + args,
    environment: gitEnvironment(), op: op)
}

// MARK: - Registry (mod.resolveRegistryWake.ts)

struct RegistryEntry {
  var name: JSONValue?
  var org: JSONValue?
  var repo: JSONValue?
  var localPath: JSONValue?
}

struct RegisteredRepository {
  var name: String
  var path: String
}

private func registryUnavailable() -> BackendError { backendError("registry unavailable") }

func readWakeRegistryEntries() throws -> [RegistryEntry] {
  let path = NodePath.resolve(processEnvironment["MAW_ORACLES_JSON"] ?? NodePath.join(homeDirectory(), ".maw", "oracles.json"))
  var descriptor: Int32?
  defer { if let descriptor { close(descriptor) } }
  do {
    var ancestors: [String] = []
    var current = path
    while true {
      ancestors.append(current)
      let parent = NodePath.dirname(current)
      if parent == current { break }
      current = parent
    }
    for component in ancestors.reversed() {
      if try lstatPath(component).isSymbolicLink { throw registryUnavailable() }
    }
    let before = try lstatPath(path)
    if !before.isFile || before.size > 1024 * 1024 { throw registryUnavailable() }
    let opened = try openNoFollow(path)
    descriptor = opened.descriptor
    if !opened.stat.isFile || opened.stat.dev != before.dev || opened.stat.ino != before.ino {
      throw registryUnavailable()
    }
    let data = try readDescriptor(opened.descriptor, upTo: 1024 * 1024 + 1)
    if data.count > 1024 * 1024 { throw registryUnavailable() }
    guard let text = strictUTF8(data), let store = try? parseJSON(text).object,
      let oracles = store["oracles"]?.array, oracles.count <= 1024
    else { throw registryUnavailable() }
    var entries: [RegistryEntry] = []
    for entry in oracles {
      guard let object = entry.object else { throw registryUnavailable() }
      for key in ["name", "org", "repo", "local_path"] {
        if let value = object[key], !value.isNull, value.string == nil { throw registryUnavailable() }
      }
      entries.append(
        RegistryEntry(
          name: object["name"], org: object["org"], repo: object["repo"], localPath: object["local_path"]))
    }
    return entries
  } catch let error as BackendError {
    throw error
  } catch let error as FileError where error.code == ENOENT {
    return []
  } catch {
    throw registryUnavailable()
  }
}

func validateWakeRegistryEntry(_ entry: RegistryEntry) throws -> RegisteredRepository {
  guard let name = entry.name?.string, !name.isEmpty, byteLength(name) <= 1024, !name.hasPrefix("-"),
    !containsScalar(name, where: isControlC0),
    let localPath = entry.localPath?.string, NodePath.isAbsolute(localPath),
    !containsScalar(localPath, where: isControlC0),
    let checkout = try? realPath(localPath), (try? statPath(checkout))?.isDirectory == true,
    let git = try? lstatPath(NodePath.join(checkout, ".git")), git.isFile || git.isDirectory
  else { throw registryUnavailable() }
  return RegisteredRepository(name: name, path: checkout)
}

func resolveRegistryWake(_ target: String) throws -> RegisteredRepository {
  func missing() -> BackendError { .unknownTarget("registered repository unavailable") }
  let parts = target.components(separatedBy: "/")
  if target.isEmpty || containsScalar(target, where: { $0.value <= 0x20 || $0.value == 0x7F })
    || target.hasPrefix("-") || target.contains("\\")
    || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) || parts.count > 2
  {
    throw missing()
  }
  let matches = try readWakeRegistryEntries().filter { entry in
    if entry.name?.string == target { return true }
    if let org = entry.org?.string, !org.isEmpty, let repo = entry.repo?.string, !repo.isEmpty {
      return "\(org)/\(repo)" == target
    }
    return false
  }
  guard matches.count == 1 else { throw missing() }
  return try validateWakeRegistryEntry(matches[0])
}

// MARK: - Identity (mod.resolveWakeIdentity.ts)

struct WakeIdentity {
  var basePath: String
  var oracle: String
}

/// "Only exact registered roots or Git-proven worktree membership, never
/// label/path guesses."
func resolveWakeIdentity(cwd rawCwd: String, window: String, op parent: HerdrOp) async throws -> WakeIdentity {
  func fail() -> BackendError { registryUnavailable() }
  if parent.aborted || !NodePath.isAbsolute(rawCwd) { throw fail() }
  guard let cwd = try? realPath(rawCwd), (try? statPath(cwd))?.isDirectory == true else { throw fail() }
  let entries = try readWakeRegistryEntries().map(validateWakeRegistryEntry)
  if entries.isEmpty { return WakeIdentity(basePath: cwd, oracle: window) }
  let op = HerdrOp(timeout: 10, parent: parent)

  struct GitIdentity {
    var top: String
    var common: String
  }
  func identity(_ path: String) async throws -> GitIdentity {
    let top = try realPath(jsTrim(try await runGit(path, ["rev-parse", "--show-toplevel"], op: op)))
    let common = try realPath(
      NodePath.resolve(path, jsTrim(try await runGit(path, ["rev-parse", "--git-common-dir"], op: op))))
    return GitIdentity(top: top, common: common)
  }

  var members = Set<String>()
  var common = ""
  var candidate: GitIdentity?
  let hasGit = (try? lstatPath(NodePath.join(cwd, ".git"))) != nil
  if hasGit {
    do { candidate = try await identity(cwd) } catch { if op.aborted { throw fail() } }
  }
  if let candidate, candidate.top == cwd {
    let raw = try await runGit(cwd, ["worktree", "list", "--porcelain", "-z"], op: op)
    guard raw.hasSuffix("\0\0") else { throw fail() }
    let groups = String(raw.dropLast(2)).components(separatedBy: "\0\0")
    if groups.count > 128 { throw fail() }
    var seen = Set<String>()
    for group in groups {
      let lines = group.components(separatedBy: "\0")
      let path = String(lines[0].dropFirst(9))
      guard lines[0].hasPrefix("worktree "), NodePath.isAbsolute(path), !seen.contains(path) else { throw fail() }
      seen.insert(path)
      if lines.contains(where: { $0 == "prunable" || $0.hasPrefix("prunable ") }) { continue }
      if let resolved = try? realPath(path) { members.insert(resolved) }
    }
    if members.contains(cwd) { common = candidate.common }
  }
  var matches: [RegisteredRepository] = []
  for entry in entries {
    if op.aborted { throw fail() }
    var match = entry.path == cwd
    if !match && !common.isEmpty && members.contains(entry.path) {
      let value = try await identity(entry.path)
      if value.top != entry.path || value.common != common { throw fail() }
      match = true
    }
    if match { matches.append(entry) }
  }
  if matches.count > 1 { throw fail() }
  if let first = matches.first { return WakeIdentity(basePath: first.path, oracle: first.name) }
  return WakeIdentity(basePath: cwd, oracle: window)
}

// MARK: - Launch line (mod.resolveWakeLaunch.ts)

struct WakeLaunch {
  var selectedKey: String
  var line: String
  var family: String?
  var warnings: [String]
}

struct WakeLaunchUnavailable: Error {}

/// "Pure legacy shell-line rendering, not argv parsing or execution. Config
/// commands are trusted shell programs; callers must preserve that boundary."
func resolveWakeLaunch(
  config: JSONObject, window: String, explicitEngine: String?, fallback: String = "codex"
) throws -> WakeLaunch {
  let commands = config["commands"]?.object ?? JSONObject()
  let wake = config["wake"]?.object ?? JSONObject()
  func text(_ value: JSONValue?) -> String? {
    guard let string = value?.string else { return nil }
    let trimmed = whiteSpaceTrim(string)
    return trimmed.isEmpty ? nil : trimmed
  }
  func command(_ key: String) -> String? { commands.has(key) ? text(commands[key]) : nil }
  let keys = commands.keys.sorted(by: bytesLess)
  func asciiLower(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 }))
  }
  func entry(_ candidate: String) -> (String, String)? {
    if let exact = command(candidate) { return (candidate, exact) }
    for key in keys where asciiLower(key) == asciiLower(candidate) {
      if let value = command(key) { return (key, value) }
    }
    return nil
  }

  var resolved: (String, String)?
  if let explicitEngine, let value = command(explicitEngine) { resolved = (explicitEngine, value) }
  if resolved == nil, let value = command(window) { resolved = (window, value) }
  if resolved == nil {
    var stem = whiteSpaceTrim(window)
    if stem.utf16.count > 7 && asciiLower(String(stem.suffix(7))) == "-oracle" {
      stem = whiteSpaceTrim(String(stem.dropLast(7)))
    }
    stem = stem.lowercased()
    if !stem.isEmpty {
      for candidate in [stem + "-oracle", stem] where candidate != window {
        resolved = entry(candidate)
        if resolved != nil { break }
      }
    }
  }
  if resolved == nil {
    for key in keys {
      if key == "default" || key == window { continue }
      let suffixMatch = key.hasPrefix("*") && window.hasSuffix(String(key.dropFirst()))
      let prefixMatch = key.hasSuffix("*") && window.hasPrefix(String(key.dropLast()))
      if suffixMatch || prefixMatch, let value = command(key) {
        resolved = (key, value)
        break
      }
    }
  }
  if resolved == nil, let explicitEngine { resolved = (explicitEngine, explicitEngine) }
  if resolved == nil, let engine = text(wake["engine"]) ?? text(config["defaultEngine"]) {
    resolved = (engine, command(engine) ?? engine)
  }
  if resolved == nil, let value = command("default") { resolved = ("default", value) }
  let (selectedKey, selected) = resolved ?? (fallback, command(fallback) ?? fallback)

  func quote(_ value: String) -> String {
    if value.range(of: #"^[a-zA-Z0-9/._:=\-]*$"#, options: .regularExpression) != nil { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
  func prefixPool(_ line: String) -> String {
    if let pool = config["zaiPool"]?.string,
      pool.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil,
      !line.hasPrefix("MAW_ZAI_POOL=")
    {
      return "MAW_ZAI_POOL=\(pool) \(line)"
    }
    return line
  }
  /// The first whitespace-delimited word that is neither `command` nor a
  /// `NAME=value` assignment; `end` is the scalar offset just past it.
  func binary(_ line: String) -> (family: String, end: Int)? {
    let scalars = Array(line.unicodeScalars)
    var index = 0
    while index < scalars.count {
      if unicodeWhiteSpace.contains(scalars[index]) {
        index += 1
        continue
      }
      let start = index
      while index < scalars.count && !unicodeWhiteSpace.contains(scalars[index]) { index += 1 }
      let word = String(String.UnicodeScalarView(scalars[start..<index]))
      if word == "command" || word.range(of: #"^[a-zA-Z_][a-zA-Z0-9_]*="#, options: .regularExpression) != nil {
        continue
      }
      return (word.components(separatedBy: "/").last ?? word, index)
    }
    return nil
  }
  func slice(_ line: String, to end: Int) -> (head: String, tail: String) {
    let scalars = Array(line.unicodeScalars)
    return (
      String(String.UnicodeScalarView(scalars[0..<end])), String(String.UnicodeScalarView(scalars[end...]))
    )
  }

  var warnings: [String] = []
  var line = prefixPool(selected)
  let resume = wake["resume"]?.bool == true
  if resume {
    if let replacement = command(selectedKey + "-resume") {
      line = prefixPool(replacement)
    } else {
      let token = binary(line)
      if token?.family == "claude" {
        line += " --continue"
      } else if token?.family == "codex" || token?.family == "omx" {
        let parts = slice(line, to: token!.end)
        line = parts.head + " resume" + parts.tail
      } else {
        line += " resume"
        warnings.append("unknown_resume_form")
      }
    }
  }
  if wake["channels"]?.bool == true {
    let replacement = !resume ? command(selectedKey + "-channels") : nil
    if let replacement {
      line = prefixPool(replacement)
    } else if binary(line)?.family == "claude" {
      line += " --channels plugin:discord@claude-plugins-official"
    } else {
      warnings.append("channels_not_claude")
    }
  }
  if let prompt = text(wake["prompt"]) {
    let words = whiteSpaceTrim(line).unicodeScalars.split(whereSeparator: { unicodeWhiteSpace.contains($0) })
      .map { String(String.UnicodeScalarView($0)) }
    if binary(line)?.family == "claude",
      words.contains(where: { $0 == "--channels" || $0.hasPrefix("--channels=") }), words.last != "--"
    {
      line += " --"
    }
    line += " " + quote(prompt)
  }
  let family = binary(line)?.family
  line = "MAW_SESSION_WINDOW=\(quote(window)) \(line)"
  if line.contains("\0") || byteLength(line) > 64 * 1024 { throw WakeLaunchUnavailable() }
  return WakeLaunch(selectedKey: selectedKey, line: line, family: family, warnings: warnings)
}

// MARK: - Configured launch (mod.launchConfiguredWake.ts)

/// "Submit trusted operator configuration and prove foreground launch, not
/// agent readiness."
func launchConfiguredWake(
  run: @escaping @Sendable ([String], HerdrOp) async throws -> String, target: Target, line: String,
  op parent: HerdrOp
) async throws -> WakeState {
  func fail() -> BackendError { backendError("configured launch not verified") }
  guard let cwd = try? realPath(target.pane.cwd) else { throw fail() }
  if !NodePath.isAbsolute(target.pane.cwd) { throw fail() }
  let op = HerdrOp(timeout: 8, parent: parent)
  let shellNames: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu"]
  func positive(_ value: JSONValue?) -> Int? {
    guard let number = value?.safeInteger, number > 0 else { return nil }
    return number
  }
  struct ProcessInfo {
    var shellPid: Int
    var foregroundGroup: Int
    var processes: [(pid: Int, name: String, cwd: String)]
  }
  func info() async throws -> ProcessInfo {
    guard let response = try? parseJSON(
      try await run(["--session", target.session, "pane", "process-info", "--pane", target.pane.id], op))
    else { throw fail() }
    let result = response["result"]
    let details = result?["process_info"]
    guard response["error"] == nil || response["error"]!.isNull,
      result?["error"] == nil || result!["error"]!.isNull,
      result?["type"]?.string == "pane_process_info", details?["pane_id"]?.string == target.pane.id,
      let shellPid = positive(details?["shell_pid"]),
      let foregroundGroup = positive(details?["foreground_process_group_id"]),
      let list = details?["foreground_processes"]?.array, list.count <= 128
    else { throw fail() }
    var seen = Set<Int>()
    var processes: [(Int, String, String)] = []
    for process in list {
      guard let pid = positive(process["pid"]), !seen.contains(pid), let name = process["name"]?.string,
        !name.isEmpty, let processCwd = process["cwd"]?.string, NodePath.isAbsolute(processCwd)
      else { throw fail() }
      seen.insert(pid)
      guard let resolved = try? realPath(processCwd), resolved == cwd else { throw fail() }
      processes.append((pid, name, processCwd))
    }
    return ProcessInfo(shellPid: shellPid, foregroundGroup: foregroundGroup, processes: processes)
  }
  do {
    let before = try await info()
    if before.foregroundGroup != before.shellPid || before.processes.count != 1
      || before.processes[0].pid != before.shellPid
      || !shellNames.contains(NodePath.basename(before.processes[0].name))
    {
      throw fail()
    }
    let ack = try await run(["--session", target.session, "pane", "run", target.pane.id, line], op)
    if !jsTrim(ack).isEmpty { throw fail() }
    var confirmations = 0
    while !op.aborted {
      let state = try await info()
      if state.shellPid != before.shellPid { throw fail() }
      let screen = try await run(
        [
          "--session", target.session, "pane", "read", target.pane.id, "--source", "visible", "--lines", "200",
          "--format", "text",
        ], op)
      if byteLength(screen) > 64 * 1024 { throw fail() }
      if screen.contains("Do you trust the contents of this directory")
        || screen.contains("Do you trust the files in this folder")
      {
        throw fail()
      }
      let launched =
        state.foregroundGroup != state.shellPid
        && state.processes.contains { $0.pid != state.shellPid && !shellNames.contains(NodePath.basename($0.name)) }
      confirmations = launched ? confirmations + 1 : 0
      if confirmations >= 3 && !op.aborted { return .launched }
      try await Task.sleep(nanoseconds: UInt64(launched ? 200 : 100) * 1_000_000)
      if op.aborted { throw fail() }
    }
    throw fail()
  } catch {
    throw fail()
  }
}

// MARK: - Hooks (mod.runWakeHooks.ts)

/// "Trusted merged operator config and resolved identity only; never browser
/// commands. Best effort, sequential, process cwd/env inherited." Closed stdin,
/// 10-second total ceiling, process-group cleanup.
func runWakeHooks(config: JSONObject, oracle: String, session: String, window: String, op: HerdrOp) async {
  guard let entries = config["hooks"]?.object?["postWake"]?.array else { return }
  // The hooks' own 10s ceiling, and the operation's abort kills a running hook
  // just as Bun's `signal` listener does.
  let deadline = Date().addingTimeInterval(max(0, min(10, op.remaining)))
  var environment = processEnvironment
  environment["MAW_ORACLE"] = oracle
  environment["MAW_SESSION"] = session
  environment["MAW_WINDOW"] = window
  for entry in entries {
    if op.aborted || Date() >= deadline { break }
    guard let text = entry.string, !jsTrim(text).isEmpty else { continue }
    await runShellLine(jsTrim(text), environment: environment, deadline: deadline)
  }
}

// MARK: - Fleet registration (mod.registerWakeFleet.ts)

struct FleetWindow {
  var name: String
  var repo: String
  var kind: String?
}

private let fleetLimit = 1_048_576
private func fleetFailure() -> BackendError { backendError("wake fleet registration failed") }

private func fleetStorage(_ value: String) -> String {
  var trimmed = jsTrim(value)
  if trimmed.hasPrefix("github.com/") { trimmed.removeFirst("github.com/".count) }
  return trimmed
}

private func fleetStem(_ value: String) -> String {
  value.replacingOccurrences(of: #"^[0-9]+-"#, with: "", options: .regularExpression)
}

private func fleetCanonical(_ path: String) -> String { (try? realPath(path)) ?? path }

private func fleetKey(root: String, repo: String) -> String {
  let stored = fleetStorage(repo)
  if stored.isEmpty { return "" }
  return fleetCanonical(NodePath.isAbsolute(stored) ? stored : NodePath.join(root, "github.com", stored))
}

private func fleetKind(_ value: JSONValue?) -> String? {
  guard let text = value?.string, ["oracle", "project"].contains(jsTrim(text)) else { return nil }
  return jsTrim(text)
}

private func fleetSlug(_ path: String) -> String {
  let parts = fleetCanonical(path).components(separatedBy: "/")
  guard let index = parts.firstIndex(of: "github.com"), index + 2 < parts.count else { return "" }
  return "github.com/\(parts[index + 1])/\(parts[index + 2])"
}

private func fleetSafe(_ path: String) throws {
  if !NodePath.isAbsolute(path) { throw fleetFailure() }
  var current = NodePath.resolve(path)
  while true {
    do {
      if try lstatPath(current).isSymbolicLink { throw fleetFailure() }
    } catch let error as FileError {
      if error.code != ENOENT { throw fleetFailure() }
    }
    let parent = NodePath.dirname(current)
    if current == parent { break }
    current = parent
  }
}

private func fleetRead(_ path: String) throws -> JSONObject {
  try fleetSafe(path)
  guard try lstatPath(path).isFile else { throw fleetFailure() }
  let descriptor = open(path, O_RDONLY)
  guard descriptor >= 0 else { throw FileError(code: errno) }
  defer { close(descriptor) }
  let status = try fstatDescriptor(descriptor)
  if !status.isFile || status.size > fleetLimit { throw fleetFailure() }
  let data = try readDescriptor(descriptor, upTo: fleetLimit + 1)
  if data.count > fleetLimit { throw fleetFailure() }
  // `new TextDecoder("utf-8", {fatal: true})` with `ignoreBOM` unset: unlike the
  // config and registry readers, this one strips a leading BOM before parsing.
  guard var text = strictUTF8(data) else { throw fleetFailure() }
  if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
  guard let object = try? parseJSON(text).object else { throw fleetFailure() }
  return object
}

func collectWakeFleet(live: [(name: String, cwd: String)], base: String, window: String, root: String) -> [FleetWindow] {
  var out: [FleetWindow] = []
  var seen = Set<String>()
  for item in live {
    let repo = fleetSlug(item.cwd)
    let name = item.name.isEmpty ? "main" : item.name
    if repo.isEmpty || seen.contains(name) { continue }
    seen.insert(name)
    out.append(FleetWindow(name: name, repo: repo, kind: jsTrim(name).hasSuffix("-oracle") ? "oracle" : "project"))
  }
  let repo = fleetSlug(base)
  if !repo.isEmpty {
    var oracle = NodePath.basename(base).hasSuffix("-oracle")
    if !oracle, let psi = try? statPath(NodePath.join(base, "ψ")), psi.isDirectory,
      let claude = try? statPath(NodePath.join(base, "CLAUDE.md")), claude.isFile
    {
      oracle = true
    }
    let type = oracle ? "oracle" : "project"
    var found = false
    for index in out.indices {
      if out[index].name == window {
        out[index].repo = repo
        out[index].kind = type
        found = true
      } else if fleetKey(root: root, repo: out[index].repo) == fleetKey(root: root, repo: repo) {
        out[index].kind = type
      }
    }
    if !found { out.append(FleetWindow(name: window, repo: repo, kind: type)) }
  }
  return out
}

func mergeWakeFleet(existing: JSONValue?, updates: [FleetWindow], root: String) -> [FleetWindow] {
  var out: [FleetWindow] = []
  if let items = existing?.array {
    for item in items {
      guard let object = item.object, let name = object["name"]?.string, !jsTrim(name).isEmpty else { continue }
      out.append(FleetWindow(name: name, repo: fleetStorage(object["repo"]?.string ?? ""), kind: fleetKind(object["kind"])))
    }
  }
  func counts(_ items: [FleetWindow]) -> [String: Int] {
    var table: [String: Int] = [:]
    for window in items where !jsTrim(window.name).isEmpty {
      table[fleetKey(root: root, repo: window.repo), default: 0] += 1
    }
    return table
  }
  let old = counts(out)
  let next = counts(updates)
  for item in updates {
    if jsTrim(item.name).isEmpty { continue }
    var update = item
    update.repo = fleetStorage(item.repo)
    let key = fleetKey(root: root, repo: update.repo)
    if let exact = out.firstIndex(where: { $0.name == update.name }) {
      out[exact].repo = update.repo
      if let kind = update.kind { out[exact].kind = kind }
      continue
    }
    var alias = -1
    if old[key] == 1 && next[key] == 1 {
      alias = out.firstIndex { fleetKey(root: root, repo: $0.repo) == key } ?? -1
    }
    if alias >= 0 { out[alias] = update } else { out.append(update) }
  }
  return out
}

private func fleetDirectories(home: String) -> [String] {
  let environment = processEnvironment
  let legacy = NodePath.join(home, ".maw")
  let xdg = ["1", "true", "yes", "on"].contains((environment["MAW_XDG"] ?? "").lowercased())
  let state: String
  if let mawHome = environment["MAW_HOME"] {
    state = mawHome
  } else if let stateDirectory = environment["MAW_STATE_DIR"] {
    state = stateDirectory
  } else if xdg {
    let xdgState = environment["XDG_STATE_HOME"] ?? ""
    state = NodePath.join(NodePath.isAbsolute(xdgState) ? xdgState : NodePath.join(home, ".local", "state"), "maw")
  } else {
    state = legacy
  }
  let config: String
  if let mawHome = environment["MAW_HOME"] {
    config = NodePath.join(mawHome, "config")
  } else if let configDirectory = environment["MAW_CONFIG_DIR"] {
    config = configDirectory
  } else {
    let xdgConfig = environment["XDG_CONFIG_HOME"] ?? ""
    config = NodePath.join(NodePath.isAbsolute(xdgConfig) ? xdgConfig : NodePath.join(home, ".config"), "maw")
  }
  var out: [String] = []
  for directory in [state, legacy, config].map({ NodePath.join($0, "fleet") }) where !out.contains(directory) {
    out.append(directory)
  }
  return out
}

/// `spawnSync("git", ["config", "--get", "ghq.root"], {timeout: 1000})` — the
/// ghq root, or "" when git is missing, slow or unconfigured.
private func ghqRootFromGit() async -> String {
  let op = HerdrOp(timeout: 1)
  guard let output = try? await runCommand(binary: "git", args: ["config", "--get", "ghq.root"], op: op) else {
    return ""
  }
  return jsTrim(output)
}

func registerWakeFleet(session: String, live: [(name: String, cwd: String)], basePath: String, window: String) async throws {
  if session.isEmpty || byteLength(session) > 255 || jsTrim(session) != session
    || session.hasPrefix("-")
    || containsScalar(session, where: { $0 == "/" || $0 == "\\" || $0.properties.generalCategory == .control })
    || session == "." || session == ".." || live.count > 1024
  {
    throw fleetFailure()
  }
  let home = processEnvironment["HOME"] ?? ""
  if !NodePath.isAbsolute(home) { throw fleetFailure() }
  var root: String
  if let configured = processEnvironment["GHQ_ROOT"] {
    root = configured
  } else {
    root = await ghqRootFromGit()
    if root.hasPrefix("~/") { root = NodePath.join(home, String(root.dropFirst(2))) }
    if root.isEmpty { root = NodePath.join(home, "Code") }
  }
  if NodePath.basename(root) == "github.com" { root = NodePath.dirname(root) }
  let updates = collectWakeFleet(live: live, base: basePath, window: window, root: root)
  if updates.isEmpty { return }

  struct Entry {
    var path: String
    var name: String
    var value: JSONObject
  }
  var entries: [Entry] = []
  var seen = Set<String>()
  var count = 0
  var aggregate = 0
  for directory in fleetDirectories(home: home) {
    try fleetSafe(directory)
    var files: [String]
    do {
      files = try directoryEntries(directory)
      count += files.count
      if count > 1024 { throw fleetFailure() }
      files.sort(by: jsLess)
    } catch let error as FileError {
      if error.code == ENOENT { continue }
      throw fleetFailure()
    } catch {
      throw fleetFailure()
    }
    var current = Set<String>()
    for file in files where file.hasSuffix(".json") {
      let path = NodePath.join(directory, file)
      aggregate += (try? lstatPath(path))?.size ?? 0
      if aggregate > 4 * fleetLimit { throw fleetFailure() }
      let value = try fleetRead(path)
      guard let name = value["name"]?.string, !name.isEmpty, !seen.contains(name), !value.has("members")
      else { continue }
      entries.append(Entry(path: path, name: name, value: value))
      current.insert(name)
    }
    seen.formUnion(current)
  }
  let keys = Set(updates.map { fleetKey(root: root, repo: $0.repo) })
  var entry = entries.first { $0.name == session }
  if entry == nil {
    entry = entries.first { candidate in
      fleetStem(candidate.name) == fleetStem(session)
        && mergeWakeFleet(existing: candidate.value["windows"], updates: [], root: root).contains {
          keys.contains(fleetKey(root: root, repo: $0.repo))
        }
    }
  }
  let target = entry?.path ?? NodePath.join(home, ".maw", "fleet", "\(session).json")
  var value = entry?.value
  if value == nil {
    do {
      let existing = try fleetRead(target)
      if existing.has("members") { throw fleetFailure() }
      value = existing
    } catch let error as FileError {
      if error.code != ENOENT { throw fleetFailure() }
      value = JSONObject()
    } catch {
      throw fleetFailure()
    }
  }
  var object = value!
  object["name"] = .string(session)
  object["created_by"] = .string("maw wake")
  object["auto_registered"] = .bool(true)
  if !object.has("created_at") {
    object["created_at"] = .string(isoTimestamp(milliseconds: ObservedFeed.nowMilliseconds()))
  }
  let windows = mergeWakeFleet(existing: object["windows"], updates: updates, root: root)
  object["windows"] = .array(
    windows.map { window in
      jsonObject([("name", .string(window.name)), ("repo", .string(window.repo)), ("kind", window.kind.map(JSONValue.string))])
    })
  let data = jsonStringifyPretty(.object(object)) + "\n"
  if byteLength(data) > fleetLimit { throw fleetFailure() }
  try fleetSafe(target)
  try? FileManager.default.createDirectory(
    atPath: NodePath.dirname(target), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let temporary = NodePath.join(NodePath.dirname(target), ".wake-fleet-\(UUID().uuidString.lowercased())")
  let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
  guard descriptor >= 0 else { throw fleetFailure() }
  var written = false
  defer { if !written { unlink(temporary) } }
  var success = true
  data.withCString { pointer in
    let length = strlen(pointer)
    var offset = 0
    while offset < length {
      let count = write(descriptor, pointer.advanced(by: offset), length - offset)
      if count < 0 {
        if errno == EINTR { continue }
        success = false
        return
      }
      offset += count
    }
  }
  fsync(descriptor)
  close(descriptor)
  guard success else { throw fleetFailure() }
  try fleetSafe(target)
  guard rename(temporary, target) == 0 else { throw fleetFailure() }
  written = true
}

/// `JSON.stringify(value, null, 2)`.
func jsonStringifyPretty(_ value: JSONValue, indent: String = "") -> String {
  switch value {
  case .array(let items):
    if items.isEmpty { return "[]" }
    let inner = indent + "  "
    return "[\n" + items.map { inner + jsonStringifyPretty($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
  case .object(let object):
    if object.isEmpty { return "{}" }
    let inner = indent + "  "
    return "{\n"
      + object.entries.map { inner + jsonStringLiteral($0.key) + ": " + jsonStringifyPretty($0.value, indent: inner) }
      .joined(separator: ",\n") + "\n" + indent + "}"
  default:
    return jsonStringify(value)
  }
}

// MARK: - Task worktrees (mod.planTaskWorktree.ts)

func taskSlug(_ raw: String) throws -> String {
  if byteLength(raw) > 1024 || raw.hasPrefix("-") || raw.contains("\0") { throw backendError("invalid task") }
  var slug = String(String.UnicodeScalarView(raw.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 }))
  slug = slug.replacingOccurrences(of: #"[\t\n\x0B\x0C\r ]+"#, with: "-", options: .regularExpression)
  slug = slug.replacingOccurrences(of: #"[^a-z0-9._-]"#, with: "", options: .regularExpression)
  while slug.contains("..") { slug = slug.replacingOccurrences(of: "..", with: ".") }
  slug = slug.replacingOccurrences(of: #"^[-.]+|[-.]+$"#, with: "", options: .regularExpression)
  slug = String(slug.prefix(50))
  if slug.isEmpty { throw backendError("invalid task") }
  return slug
}

struct TaskWorktreePlan {
  var slug: String
  var path: String
  var branch: String
  var create: Bool
  var materialize: @Sendable () async throws -> Void
}

/// "Plan only. The returned create operation runs after pane-label conflicts
/// are checked."
func planTaskWorktree(repo: String, rawTask: String, op: HerdrOp) async throws -> TaskWorktreePlan {
  let slug = try taskSlug(rawTask)
  @Sendable func fail() -> BackendError { backendError("task worktree unavailable") }
  let root = try realPath(repo)
  if root != repo { throw fail() }
  if jsTrim(try await runGit(root, ["rev-parse", "--show-toplevel"], op: op)) != root { throw fail() }
  let common = try realPath(NodePath.resolve(root, jsTrim(try await runGit(root, ["rev-parse", "--git-common-dir"], op: op))))
  let agents = NodePath.join(root, "agents")
  @Sendable func safePath(_ path: String, missing: Bool = false) throws {
    if !NodePath.isAbsolute(path) || containsScalar(path, where: isControlC0C1) { throw fail() }
    var parts: [String] = []
    var current = NodePath.resolve(path)
    while true {
      parts.append(current)
      let parent = NodePath.dirname(current)
      if parent == current { break }
      current = parent
    }
    for part in parts.reversed() {
      do {
        if try lstatPath(part).isSymbolicLink { throw fail() }
      } catch let error as FileError {
        if missing && error.code == ENOENT { return }
        throw error
      }
    }
  }
  try safePath(agents, missing: true)
  struct Candidate {
    var path: String
    var name: String
    var branch: String
  }
  @Sendable func scan() async throws -> [Candidate] {
    let raw = try await runGit(root, ["worktree", "list", "--porcelain", "-z"], op: op)
    guard raw.hasSuffix("\0\0") else { throw fail() }
    let groups = String(raw.dropLast(2)).components(separatedBy: "\0\0")
    if groups.count > 128 { throw fail() }
    var seen = Set<String>()
    var candidates: [Candidate] = []
    for group in groups {
      let lines = group.components(separatedBy: "\0")
      guard lines[0].hasPrefix("worktree ") else { throw fail() }
      let path = String(lines[0].dropFirst(9))
      guard NodePath.isAbsolute(path), !seen.contains(path) else { throw fail() }
      seen.insert(path)
      let nested = NodePath.dirname(path) == agents
      let sibling = NodePath.dirname(path) == NodePath.dirname(root)
        && NodePath.basename(path).hasPrefix(NodePath.basename(root) + ".wt-")
      if !nested && !sibling { continue }
      if lines.contains(where: { $0 == "prunable" || $0.hasPrefix("prunable ") }) { continue }
      try safePath(path)
      guard try realPath(path) == path, try lstatPath(path).isDirectory else { throw fail() }
      let branch = lines.first { $0.hasPrefix("branch refs/heads/") }.map { String($0.dropFirst(18)) } ?? ""
      guard jsTrim(try await runGit(path, ["rev-parse", "--show-toplevel"], op: op)) == path,
        try realPath(NodePath.resolve(path, jsTrim(try await runGit(path, ["rev-parse", "--git-common-dir"], op: op)))) == common
      else { throw fail() }
      let name = nested ? NodePath.basename(path) : String(NodePath.basename(path).dropFirst(NodePath.basename(root).count + 4))
      candidates.append(Candidate(path: path, name: name, branch: branch))
    }
    return candidates
  }
  let candidates = try await scan()
  func choose(_ predicate: (String) -> Bool) throws -> Candidate? {
    let matches = candidates.filter { predicate($0.name.lowercased()) }
    if matches.count > 1 { throw fail() }
    return matches.first
  }
  let lowered = slug.lowercased()
  let match = try choose { $0 == lowered } ?? choose { $0.hasSuffix("-" + lowered) }
    ?? choose { $0.hasPrefix(lowered + "-") || $0.contains("-" + lowered + "-") }
  if let match {
    let matchPath = match.path
    let matchBranch = match.branch
    return TaskWorktreePlan(slug: slug, path: matchPath, branch: matchBranch, create: false) {
      let fresh = try await scan()
      if !fresh.contains(where: { $0.path == matchPath && $0.branch == matchBranch }) { throw fail() }
    }
  }
  let branches = jsTrim(try await runGit(root, ["for-each-ref", "--format=%(refname:short)", "refs/heads/agents"], op: op))
    .components(separatedBy: "\n").filter { !$0.isEmpty }
  if branches.count > 1000 { throw fail() }
  var name = slug
  if branches.contains("agents/" + name) {
    var maximum = 0
    for item in candidates.map(\.name) + branches.map({ $0.hasPrefix("agents/") ? String($0.dropFirst(7)) : $0 }) {
      if let range = item.range(of: #"^([0-9]+)-"#, options: .regularExpression) {
        let digits = String(item[range].dropLast())
        guard let number = Int(digits), number <= 9_007_199_254_740_991 else { throw fail() }
        maximum = max(maximum, number)
      }
    }
    var found = false
    for offset in 1...1000 {
      name = "\(maximum + offset)-\(slug)"
      if !branches.contains("agents/" + name) {
        found = true
        break
      }
    }
    if !found { throw fail() }
  }
  let path = NodePath.join(agents, name)
  let branch = "agents/" + name
  @Sendable func vacant() throws {
    try safePath(path, missing: true)
    do {
      _ = try lstatPath(path)
      throw fail()
    } catch let error as FileError {
      if error.code != ENOENT { throw error }
    }
  }
  try vacant()
  return TaskWorktreePlan(slug: slug, path: path, branch: branch, create: true) {
    try vacant()
    guard try realPath(root) == root, jsTrim(try await runGit(root, ["rev-parse", "--show-toplevel"], op: op)) == root,
      try realPath(NodePath.resolve(root, jsTrim(try await runGit(root, ["rev-parse", "--git-common-dir"], op: op)))) == common
    else { throw fail() }
    _ = try await runGit(root, ["worktree", "add", path, "-b", branch], op: op)
    let fresh = try await scan()
    if !fresh.contains(where: { $0.path == path && $0.branch == branch }) { throw fail() }
  }
}
