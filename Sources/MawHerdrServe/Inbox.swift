import Foundation

// `--inbox` delivery, ported from:
//   mod.deliverReceiverInbox.ts — resolve the receiver, verify the pane twice, write
//   mod.writeReceiverInbox.ts   — the file under <repo>/ψ/inbox, hard-linked into place
//   mod.resolveInboxSender.ts   — "Legacy display attribution, not a verified sender"
//
// Nothing here types into a pane: the Bun fixture asserts that the only herdr
// commands run on this path are `session list` and `api snapshot`.

private func inboxUnavailable() -> BackendError { backendError("receiver inbox unavailable") }

func deliverReceiverInbox(
  roster: @escaping @Sendable () async throws -> Roster, target: String, text: String, serverRoot: String,
  rawFrom: String, op: HerdrOp
) async throws -> String {
  let environment = processEnvironment
  let gate = jsTrim(environment["MAW_HEY_INBOX_AUTOWRITE"] ?? "").lowercased()
  let enabled: Bool
  if ["1", "true", "yes", "on"].contains(gate) {
    enabled = true
  } else if ["0", "false", "no", "off"].contains(gate) {
    enabled = false
  } else {
    enabled = environment["MAW_TEST_MODE"] != "1"
  }
  if !enabled { throw backendError("receiver inbox auto-write disabled") }
  if target.isEmpty || byteLength(target) > 1024 { throw BackendError.unknownTarget("unknown or stale target") }
  if byteLength(text) > 64 * 1024 || text.contains("\0") { throw backendError("invalid inbox text") }

  func canonical(_ path: String) throws -> String {
    guard NodePath.isAbsolute(path), let resolved = try? realPath(path),
      (try? statPath(resolved))?.isDirectory == true
    else { throw inboxUnavailable() }
    return resolved
  }
  /// The oracle name behind a display handle: the last of `node:oracle:…`,
  /// then the basename with its numeric suffix, `-oracle` and `NN-` stripped.
  func normalize(_ raw: JSONValue?) -> String {
    guard let string = raw?.string else { return "" }
    var value = jsTrim(string)
    if value.contains(":") {
      let parts = value.components(separatedBy: ":").filter { !$0.isEmpty }
      value = parts.count >= 3 ? parts[2] : (parts.count > 1 ? parts[1] : (parts.first ?? value))
    }
    value = NodePath.basename(value.replacingOccurrences(of: #"\.[0-9]*$"#, with: "", options: .regularExpression))
    value = value.replacingOccurrences(of: #"-oracle$"#, with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: #"^[0-9]*-"#, with: "", options: .regularExpression)
    return value
  }

  guard let pane = try await roster().targets[target] else { throw BackendError.unknownTarget("unknown or stale target") }
  let cwd = try canonical(pane.pane.cwd)
  let window = [pane.pane.workspaceLabel ?? "", pane.pane.label, pane.pane.title, pane.pane.id].first { !$0.isEmpty }
    ?? pane.pane.id
  let identity = try await resolveWakeIdentity(cwd: cwd, window: window, op: op)
  let oracle = normalize(.string(identity.oracle))
  if oracle.isEmpty { throw inboxUnavailable() }
  let config = try readMawConfig(cwd: serverRoot)
  var basePath = try canonical(identity.basePath)
  if normalize(config["oracle"]) == oracle, let psiPath = config["psiPath"]?.string, !jsTrim(psiPath).isEmpty {
    var override = NodePath.resolve(serverRoot, jsTrim(psiPath))
    if ["ψ", "psi"].contains(NodePath.basename(override)) { override = NodePath.dirname(override) }
    do {
      guard try statPath(override).isDirectory else { throw inboxUnavailable() }
      basePath = try canonical(override)
    } catch let error as FileError {
      if error.code != ENOENT { throw inboxUnavailable() }
    }
  }
  let from = try await resolveInboxSender(raw: rawFrom, config: config, serverRoot: serverRoot, op: op)
  guard let fresh = try await roster().targets[target], fresh.session == pane.session,
    fresh.pane.id == pane.pane.id, fresh.pane.workspace == pane.pane.workspace,
    fresh.pane.workspaceLabel == pane.pane.workspaceLabel, fresh.pane.label == pane.pane.label,
    fresh.pane.title == pane.pane.title, (try? canonical(fresh.pane.cwd)) == cwd, !op.aborted
  else { throw inboxUnavailable() }
  do {
    return try writeReceiverInbox(basePath: basePath, oracle: oracle, from: from, message: text)
  } catch {
    throw inboxUnavailable()
  }
}

struct ReceiverInboxError: Error {}

/// basePath is an existing, canonical, trusted receiver repository directory.
func writeReceiverInbox(basePath: String, oracle: String, from: String, message: String, now: Date = Date()) throws -> String {
  for value in [oracle, from] {
    if jsTrim(value).isEmpty || byteLength(value) > 1024
      || containsScalar(value, where: { $0 == "\r" || $0 == "\n" || $0 == "\0" })
    {
      throw ReceiverInboxError()
    }
  }
  if byteLength(message) > 64 * 1024 || message.contains("\0") { throw ReceiverInboxError() }
  let timestamp = isoTimestamp(milliseconds: Int(now.timeIntervalSince1970 * 1000))
  func safeSegment(_ value: String) -> String {
    var segment = whiteSpaceTrim(value)
    segment = segment.replacingOccurrences(of: #"[^A-Za-z0-9_.-]+"#, with: "-", options: .regularExpression)
    segment = segment.replacingOccurrences(of: #"^-+|-+$"#, with: "", options: .regularExpression)
    segment = String(segment.prefix(64))
    return segment.isEmpty ? "unknown" : segment
  }
  // Rust's legacy helper lowercases ASCII only, before sanitizing the six-word slug.
  let words = message.unicodeScalars.split(whereSeparator: { unicodeWhiteSpace.contains($0) })
    .map { String(String.UnicodeScalarView($0)) }.filter { !$0.isEmpty }.prefix(6)
  let joined = words.joined(separator: "-")
  let lowered = String(String.UnicodeScalarView(joined.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 }))
  let slug = String(safeSegment(lowered).prefix(48))
  let date = String(timestamp.prefix(10))
  let clock = String(timestamp.dropFirst(11).prefix(5)).replacingOccurrences(of: ":", with: "-")
  let stem = "\(date)_\(clock)_\(safeSegment(from))_\(slug)"
  let body = "---\nfrom: \(from)\nto: \(oracle)\ntimestamp: \(timestamp)\nread: false\n---\n\n\(message)\n"
  var inbox = basePath
  for segment in ["ψ", "inbox"] {
    inbox = NodePath.join(inbox, segment)
    if mkdir(inbox, 0o700) != 0 && errno != EEXIST { throw FileError(code: errno) }
    guard try lstatPath(inbox).isDirectory else { throw ReceiverInboxError() }
  }
  var random = [UInt8](repeating: 0, count: 16)
  for index in random.indices { random[index] = UInt8.random(in: 0...255) }
  let temporary = NodePath.join(inbox, ".receiver-\(random.map { String(format: "%02x", $0) }.joined()).tmp")
  // Do not clean up a temporary name unless this invocation created it.
  let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
  guard descriptor >= 0 else { throw FileError(code: errno) }
  defer { unlink(temporary) }
  do {
    defer { close(descriptor) }
    fchmod(descriptor, 0o600)
    let bytes = Array(body.utf8)
    var offset = 0
    while offset < bytes.count {
      let count = bytes.withUnsafeBytes { raw in write(descriptor, raw.baseAddress!.advanced(by: offset), bytes.count - offset) }
      if count < 0 {
        if errno == EINTR { continue }
        throw FileError(code: errno)
      }
      offset += count
    }
  }
  for attempt in 1...1000 {
    let path = NodePath.join(inbox, "\(stem)\(attempt == 1 ? "" : "-\(attempt)").md")
    if link(temporary, path) == 0 { return path }
    if errno != EEXIST { throw FileError(code: errno) }
  }
  throw ReceiverInboxError()
}

/// "Legacy display attribution, not a verified or signed sender identity."
func resolveInboxSender(raw rawValue: String, config: JSONObject, serverRoot: String, op: HerdrOp) async throws -> String {
  let raw = jsTrim(rawValue)
  if !raw.isEmpty {
    if let colon = raw.firstIndex(of: ":") {
      let oracle = jsTrim(String(raw[raw.startIndex..<colon]))
      let node = jsTrim(String(raw[raw.index(after: colon)...]))
      if !oracle.isEmpty && !node.isEmpty { return "\(node):\(oracle)" }
    }
    return raw
  }
  let environment = processEnvironment
  func tmuxWindow(_ pane: String?) async -> String {
    var args = ["display-message"]
    if let pane { args += ["-t", pane] }
    args += ["-p", "#{window_name}"]
    guard let output = try? await runCommand(binary: "tmux", args: args, op: op) else { return "" }
    return jsTrim(output)
  }
  func windowOracle(_ value: String) -> String {
    let trimmed = jsTrim(value)
    let tail = trimmed.firstIndex(of: ":").map { String(trimmed[trimmed.index(after: $0)...]) } ?? trimmed
    return jsTrim(jsTrim(tail).replacingOccurrences(of: #"\.[0-9]+$"#, with: "", options: .regularExpression))
  }
  func clean(_ value: String) -> String {
    var first = jsTrim(value).replacingOccurrences(of: #"^["'`]+|["'`]+$"#, with: "", options: .regularExpression)
    if let cut = first.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "@" || $0 == "(" || $0 == "[" }) {
      first = String(first[first.startIndex..<cut])
    }
    first = first.replacingOccurrences(of: #"(?:\.git)+$"#, with: "", options: .regularExpression)
    first = first.replacingOccurrences(of: #"(?:-oracle)+$"#, with: "", options: .regularExpression)
    return first.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil ? first : ""
  }
  var oracle = ""
  if let tmuxPane = environment["TMUX_PANE"], !jsTrim(tmuxPane).isEmpty { oracle = await tmuxWindow(tmuxPane) }
  if oracle.isEmpty {
    var directory = serverRoot
    while true {
      // Follow the ordinary CLAUDE.md -> AGENTS.md link, but never block on a
      // FIFO or trust a path stat before opening the actual descriptor.
      let descriptor = open(NodePath.join(directory, "CLAUDE.md"), O_RDONLY | O_NONBLOCK)
      if descriptor >= 0 {
        defer { close(descriptor) }
        if let status = try? fstatDescriptor(descriptor), status.isFile, status.size <= 1024 * 1024,
          let data = try? readDescriptor(descriptor, upTo: 1024 * 1024 + 1)
        {
          let text = data.count <= 1024 * 1024 ? (strictUTF8(data) ?? "") : ""
          let lines = text.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
          for line in lines.prefix(120) {
            let trimmed = jsTrim(jsTrim(line).replacingOccurrences(of: #"^[#*-]+"#, with: "", options: .regularExpression))
            if let range = trimmed.range(of: #"^(?:oracle:|oracle =|identity:|name:)"#, options: [.regularExpression, .caseInsensitive]) {
              oracle = clean(String(trimmed[range.upperBound...]))
            } else {
              oracle = ""
            }
            if oracle.isEmpty && trimmed.hasSuffix("-oracle") { oracle = clean(trimmed) }
            if !oracle.isEmpty { break }
          }
        }
      }
      let parent = NodePath.dirname(directory)
      if !oracle.isEmpty || parent == directory { break }
      directory = parent
    }
  }
  if oracle.isEmpty { oracle = windowOracle(environment["MAW_SESSION_WINDOW"] ?? "") }
  if oracle.isEmpty, let configured = config["oracle"]?.string { oracle = jsTrim(configured) }
  if oracle.isEmpty, let tmux = environment["TMUX"], !jsTrim(tmux).isEmpty {
    let window = windowOracle(await tmuxWindow(nil))
    oracle = "pane/\(window.isEmpty ? "mawjs" : window)"
  }
  if oracle.isEmpty {
    var directory = serverRoot
    while true {
      if pathExists(NodePath.join(directory, ".git")) {
        oracle = "job/\(NodePath.basename(directory))"
        break
      }
      let parent = NodePath.dirname(directory)
      if parent == directory { break }
      directory = parent
    }
  }
  let node = config["node"]?.string ?? "local"
  return "\(node):\(oracle.isEmpty ? "pane/unknown" : oracle)"
}
