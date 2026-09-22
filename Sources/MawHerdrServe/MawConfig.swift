import Foundation

// Port of mod.readMawConfig.ts: the layered, read-only maw configuration and
// the projection the server publishes from it (`node`, `agents`, `namedPeers`).
//
// This is where `/api/identity` gets its `node`. Bun reads the merged config's
// `node` field first and only falls back to $HOSTNAME / the short hostname
// when it is missing, so a machine whose maw config names itself ("m5-beta")
// reports that name, not "m5". Everything below — the search order, the
// weight/rank sort, the symlink refusals, the 1 MiB / 4 MiB / 64-depth /
// 128-layer / 1024-entry caps — is reproduced so the same files load in the
// same order on both servers.

/// Bun throws `HTTPError(503, 'config_unavailable')`; the HTTP layer maps this
/// to the same status and body, and on the socket it is just a failed wake.
struct MawConfigUnavailable: Error {}

func readMawConfig(cwd: String = FileManager.default.currentDirectoryPath) throws -> JSONObject {
  let environment = processEnvironment

  /// Refuses a symlink anywhere on the path; stops quietly at the first
  /// component that does not exist.
  func safe(_ path: String) throws {
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
        if try lstatPath(part).isSymbolicLink { throw MawConfigUnavailable() }
      } catch let error as FileError {
        if error.code == ENOENT { return }
        throw error
      }
    }
  }

  let xdgConfigHome = environment["XDG_CONFIG_HOME"]
  let singleton = NodePath.join(
    xdgConfigHome != nil && NodePath.isAbsolute(xdgConfigHome!) ? xdgConfigHome! : NodePath.join(homeDirectory(), ".config"),
    "maw")
  let active: String
  if let mawHome = environment["MAW_HOME"] {
    active = NodePath.join(mawHome, "config")
  } else {
    active = environment["MAW_CONFIG_DIR"] ?? singleton
  }

  struct Layer {
    var path: String
    var weight: Double
    var rank: Int
    var local: Bool
  }
  var layers: [Layer] = []
  func add(_ layer: Layer) throws {
    layers.append(layer)
    if layers.count > 128 { throw MawConfigUnavailable() }
  }

  let numbered = try! NSRegularExpression(pattern: #"^maw\.config\.([0-9]+)(\.local)?\.json$"#)
  func scan(_ directory: String, rank: Int, legacy: Bool) throws {
    var sawNumbered = false
    do {
      try safe(directory)
      guard try lstatPath(directory).isDirectory else { throw MawConfigUnavailable() }
      let entries = try directoryEntries(directory)
      var count = 0
      for name in entries {
        count += 1
        if count > 1024 { throw MawConfigUnavailable() }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = numbered.firstMatch(in: name, range: range) else { continue }
        let digits = String(name[Range(match.range(at: 1), in: name)!])
        // `Number(match[1]) > 0xffffffff` — a huge digit string is skipped, never
        // an error, and Double("999…") is exactly what `Number("999…")` is.
        let weight = Double(digits) ?? .infinity
        if weight > 4_294_967_295 { continue }
        sawNumbered = true
        try add(
          Layer(
            path: NodePath.resolve(directory, name), weight: weight, rank: rank,
            local: match.range(at: 2).location != NSNotFound))
      }
    } catch is MawConfigUnavailable {
      throw MawConfigUnavailable()
    } catch {
      // A missing or unreadable directory contributes nothing.
    }
    if legacy && !sawNumbered {
      let path = NodePath.resolve(directory, "maw.config.json")
      if (try? lstatPath(path)) != nil {
        try add(Layer(path: path, weight: 50, rank: rank, local: false))
      }
    }
  }

  try scan(active, rank: 20, legacy: true)
  var ancestors: [String] = []
  var current = NodePath.resolve(cwd)
  while ancestors.count < 32 {
    ancestors.append(current)
    let parent = NodePath.dirname(current)
    if parent == current { break }
    current = parent
  }
  for (index, path) in ancestors.reversed().enumerated() {
    try scan(NodePath.join(path, ".maw"), rank: 30 + index, legacy: false)
  }
  if environment["MAW_TEST_MODE"] != "1", environment["MAW_HOME"] != nil,
    environment["MAW_CONFIG_DIR"] == nil, NodePath.resolve(singleton) != NodePath.resolve(active)
  {
    try scan(singleton, rank: 10, legacy: true)
  }
  layers.sort { left, right in
    if left.weight != right.weight { return left.weight < right.weight }
    if left.rank != right.rank { return left.rank < right.rank }
    if left.local != right.local { return !left.local && right.local }
    return bytesLess(left.path, right.path)
  }

  var bytes = 0
  func read(_ path: String) throws -> JSONObject? {
    var descriptor: Int32?
    defer { if let descriptor { close(descriptor) } }
    do {
      try safe(path)
      let before = try lstatPath(path)
      if !before.isFile { throw MawConfigUnavailable() }
      if before.size > 1024 * 1024 { throw MawConfigUnavailable() }
      let opened = try openNoFollow(path)
      descriptor = opened.descriptor
      let status = opened.stat
      if !status.isFile || status.ino != before.ino || status.dev != before.dev { throw MawConfigUnavailable() }
      let data = try readDescriptor(opened.descriptor, upTo: 1024 * 1024 + 1)
      bytes += data.count
      if data.count > 1024 * 1024 || bytes > 4 * 1024 * 1024 { throw MawConfigUnavailable() }
      guard let raw = strictUTF8(data) else { return nil }
      // A nesting count over the raw text, before parsing: 64 levels is the cap.
      var depth = 0
      var quoted = false
      var escaped = false
      for character in raw.unicodeScalars {
        if quoted {
          if escaped {
            escaped = false
          } else if character == "\\" {
            escaped = true
          } else if character == "\"" {
            quoted = false
          }
        } else if character == "\"" {
          quoted = true
        } else if character == "{" || character == "[" {
          depth += 1
          if depth > 64 { throw MawConfigUnavailable() }
        } else if character == "}" || character == "]" {
          depth -= 1
        }
      }
      let value = try parseJSON(raw)
      return value.object
    } catch is MawConfigUnavailable {
      throw MawConfigUnavailable()
    } catch {
      return nil
    }
  }

  func merge(_ base: inout JSONObject, _ layer: JSONObject) {
    for (key, value) in layer.entries {
      if value.isNull {
        base[key] = nil
        continue
      }
      if let nested = value.object {
        var target = base[key]?.object ?? JSONObject()
        merge(&target, nested)
        base[key] = .object(target)
      } else if key == "namedPeers", let existing = base[key]?.array, let incoming = value.array {
        var out = existing
        for item in incoming {
          var index = -1
          if let name = item["name"]?.string {
            index = out.firstIndex { $0["name"]?.string == name } ?? -1
          }
          if index < 0 { out.append(item) } else { out[index] = item }
        }
        base[key] = .array(out)
      } else {
        base[key] = value
      }
    }
  }

  var result = JSONObject()
  var loaded = false
  for layer in layers {
    if let value = try read(layer.path) {
      merge(&result, value)
      loaded = true
    }
  }
  let fallback = NodePath.resolve(active, "maw.config.json")
  if !loaded && !layers.contains(where: { $0.path == fallback }) {
    if let value = try read(fallback) { merge(&result, value) }
  }
  return result
}

struct MawProjection {
  var node: String
  /// Insertion-ordered, as `Object.entries(value.agents)` would walk it.
  var agents: [(name: String, entry: String)]
  var namedPeers: [(name: String, url: String)]?
}

/// `projectMawConfig`: the public, credential-free view of the merged config.
func projectMawConfig(_ value: JSONObject) -> MawProjection {
  func display(_ candidate: JSONValue?) -> String? {
    guard let text = candidate?.string, !jsTrim(text).isEmpty else { return nil }
    return text
  }
  var node: String
  if let configured = display(value["node"]) {
    node = configured
  } else if let hostnameVariable = processEnvironment["HOSTNAME"] {
    let trimmed = jsTrim(hostnameVariable)
    node = trimmed.isEmpty ? "local" : trimmed
  } else {
    let short = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? ""
    node = short.isEmpty ? "local" : short
  }
  if display(.string(node)) == nil { node = "local" }

  var agents: [(String, String)] = []
  if let table = value["agents"]?.object {
    for (name, entry) in table.entries {
      if let text = entry.string { agents.append((name, text)) }
    }
  }

  var namedPeers: [(String, String)]?
  if value.has("namedPeers") {
    var peers: [(String, String)] = []
    var entries: [JSONValue] = []
    if let list = value["namedPeers"]?.array {
      entries = list
    } else if let table = value["namedPeers"]?.object {
      entries = table.entries.sorted { bytesLess($0.key, $1.key) }.map { pair in
        jsonObject([("name", .string(pair.key)), ("url", pair.value)])
      }
    }
    for entry in entries {
      guard let name = entry["name"]?.string, let url = entry["url"]?.string else { continue }
      if peerURLAccepted(url) { peers.append((name, url)) }
    }
    namedPeers = peers
  }
  return MawProjection(node: node, agents: agents, namedPeers: namedPeers)
}

/// The `new URL()` gauntlet a display peer has to pass: http(s) only, no
/// credentials, no `@` in the authority, no whitespace/control/`\`/`?`/`#`,
/// and no port 0.
private func peerURLAccepted(_ text: String) -> Bool {
  guard text.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil,
    let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
  else { return false }
  if let user = url.user, !user.isEmpty { return false }
  if let password = url.password, !password.isEmpty { return false }
  // `entry.url.split('://')[1]?.split(/[/?#]/)[0].includes('@')`
  let afterScheme = text.range(of: "://").map { String(text[$0.upperBound...]) } ?? ""
  let authority = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
  if authority.contains("@") { return false }
  if containsScalar(text, where: { $0 == "\\" || $0 == "?" || $0 == "#" || $0.value <= 0x20 || $0.value == 0x7F }) {
    return false
  }
  if let port = url.port, port == 0 { return false }
  return true
}
