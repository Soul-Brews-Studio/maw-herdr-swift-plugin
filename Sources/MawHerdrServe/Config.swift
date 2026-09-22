import Foundation
import Network

/// Startup options, parsed to the same rules as the Bun server's
/// `readServeConfig`. Where the two disagree, the Bun one is right — it has the
/// test suite, and this exists to be checked against it.
struct ServeConfig {
  var hostname: String = "127.0.0.1"
  /// 0 asks the kernel for a free port, as Bun.serve does; the banner reports
  /// the one it got.
  var port: Int = 3457
  var token: String = ""
  var insecure: Bool = false
  var demoMinutes: Int = 0
  var accessLog: Bool = false
  var allowOrigins: [String] = []
  var binary: String = "herdr"
  /// `process.cwd()` at startup — the receiver-inbox and worktree root.
  var worktreeRoot: String = FileManager.default.currentDirectoryPath
  /// `--data-dir`, the ui-state/asks directory. Accepted for parity with the
  /// Bun flag set; the state routes themselves are not ported.
  var dataDir: String = ""
  /// `--wake-engine KIND`, default codex; `explicitWakeEngine` is only set when
  /// the flag was given, which is what `resolveWakeLaunch` keys on.
  var wakeEngine: String = "codex"
  var explicitWakeEngine: String?
  /// `projectMawConfig(readMawConfig())` — the merged maw config's `node`, else
  /// $HOSTNAME, else the short hostname, else "local".
  var node: String = "local"
  var agents: [(name: String, entry: String)] = []
  var namedPeers: [(name: String, url: String)]?

  var tokenConfigured: Bool { !token.isEmpty }
}

enum ConfigError: Error, CustomStringConvertible {
  case message(String)
  var description: String { if case .message(let text) = self { return text }; return "" }
}

/// An error that names the problem but not the fix makes the reader stop and
/// ask, so every one of these ends in a command they can run.
private func fail(_ text: String) -> ConfigError { .message(text) }

func parseConfig(_ arguments: [String]) throws -> ServeConfig {
  var config = ServeConfig()
  var listen: String?
  var tokenFile: String?
  var demoMinutes: String?
  var accessLogFlag: Bool?
  var noAccessLogFlag = false
  var seen = Set<String>()
  var index = 0

  func value(for flag: String, inline: String?) throws -> String {
    // `inline.length ? inline.join('=') : args[++i]` then `if (!value) throw`:
    // an `=` that is PRESENT but empty (`--listen=`) is an explicit empty
    // value and an immediate error. It does not fall through to the next
    // argv element, which is how `--listen= 127.0.0.1:3467` used to be
    // accepted here and refused there.
    if let inline {
      guard !inline.isEmpty else { throw fail("serve: invalid \(flag)") }
      return inline
    }
    index += 1
    guard index < arguments.count, !arguments[index].isEmpty else {
      throw fail("serve: invalid \(flag)")
    }
    return arguments[index]
  }

  let bare: Set<String> = ["--insecure-no-token", "--access-log", "--no-access-log"]
  while index < arguments.count {
    let argument = arguments[index]
    let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let key = parts.first ?? argument
    let inline = parts.count > 1 ? parts[1] : nil

    // `unknown or duplicate option`: every flag but --allow-origin is single-shot.
    if key != "--allow-origin" && seen.contains(key) {
      throw fail("serve: unknown or duplicate option \(key)")
    }
    seen.insert(key)
    // A bare flag given a value (`--access-log=1`) is refused, not ignored.
    if bare.contains(key) && inline != nil { throw fail("serve: invalid \(key)") }

    switch key {
    case "--listen": listen = try value(for: key, inline: inline)
    case "--token-file": tokenFile = try value(for: key, inline: inline)
    case "--herdr": config.binary = try value(for: key, inline: inline)
    case "--data-dir": config.dataDir = try value(for: key, inline: inline)
    case "--wake-engine":
      let engine = try value(for: key, inline: inline)
      config.wakeEngine = engine
      config.explicitWakeEngine = engine
    case "--demo-minutes": demoMinutes = try value(for: key, inline: inline)
    case "--allow-origin": config.allowOrigins.append(try parseAllowedOrigin(value(for: key, inline: inline)))
    case "--insecure-no-token": config.insecure = true
    case "--access-log": accessLogFlag = true
    case "--no-access-log": noAccessLogFlag = true
    default:
      throw fail("""
        serve: unknown or duplicate option \(key)
          maw herdr-swift serve --token-file ~/.maw-herdr-token --listen 127.0.0.1:3467
        """)
    }
    index += 1
  }

  guard Protocol.wakeEngines.contains(config.wakeEngine) else {
    throw fail("""
      serve: --wake-engine must be a supported Herdr agent kind
        maw herdr-swift serve --token-file ~/.maw-herdr-token --wake-engine codex
      """)
  }

  if config.insecure {
    if tokenFile != nil {
      throw fail("serve: --insecure-no-token cannot be combined with --token-file")
    }
  } else {
    guard let path = tokenFile else {
      throw fail("""
        serve: --token-file is required; never pass operator tokens on the command line
          test -e ~/.maw-herdr-token || (umask 077; openssl rand -hex 32 > ~/.maw-herdr-token)
          maw herdr-swift serve --token-file ~/.maw-herdr-token --listen 127.0.0.1:3467
          maw herdr-swift serve --insecure-no-token --listen 127.0.0.1:3467   (read-only demo, self-stopping)
        """)
    }
    config.token = try readTokenFile(path)
  }

  if let listen {
    // Matches the Bun parser: bracketed IPv6, or host:port. Port 0 is legal
    // and means "any free port".
    let pattern = #"^(?:\[([^\]]+)\]|([^:]+)):([0-9]+)$"#
    guard let match = listen.range(of: pattern, options: .regularExpression) else {
      throw fail("serve: --listen must use a loopback IP or localhost and port")
    }
    let text = String(listen[match])
    let lastColon = text.lastIndex(of: ":")!
    var host = String(text[text.startIndex..<lastColon])
    host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let portText = String(text[text.index(after: lastColon)...])
    guard let port = Int(portText), port >= 0, port <= 65535, loopbackHost(host) else {
      throw fail("serve: --listen must use a loopback IP or localhost and port")
    }
    config.hostname = host
    config.port = port
  }

  if let demoMinutes {
    guard config.insecure else {
      throw fail("serve: --demo-minutes only applies to --insecure-no-token")
    }
    // `/^[1-9][0-9]{0,3}$/`, not a numeric parse: `Int()` also accepts `+5`
    // and `0030`, which the reference refuses.
    guard demoMinutes.range(of: #"^[1-9][0-9]{0,3}$"#, options: .regularExpression) != nil,
      let minutes = Int(demoMinutes)
    else {
      throw fail("serve: --demo-minutes must be 1..9999")
    }
    config.demoMinutes = minutes
  } else if config.insecure {
    config.demoMinutes = 30
  }

  // A tokenless listener that outlives the demo is the actual hazard, so it
  // always expires; the flag only moves the deadline.
  if config.insecure && config.demoMinutes == 0 { config.demoMinutes = 30 }

  if accessLogFlag == true && noAccessLogFlag {
    throw fail("serve: --access-log and --no-access-log cannot both be given")
  }
  // A tokenless server is the one whose traffic you want to watch, so it logs
  // by default; everything else opts in.
  config.accessLog = noAccessLogFlag ? false : (accessLogFlag ?? config.insecure)

  if config.dataDir.isEmpty {
    config.dataDir = NodePath.join(
      homeDirectory(), "Library", "Application Support", "maw-herdr", "serve")
  }

  // The merged maw config is read once, at startup, from the process cwd —
  // `readServeConfig` spreads `projectMawConfig(readMawConfig())` into the
  // config, so a failure here is a failure to start, not a 503 later.
  do {
    let projection = projectMawConfig(try readMawConfig())
    config.node = projection.node
    config.agents = projection.agents
    config.namedPeers = projection.namedPeers
  } catch is MawConfigUnavailable {
    throw fail("""
      serve: config_unavailable — a maw config layer is a symlink, oversized, or too deeply nested
        ls -la ~/.config/maw "$(pwd)/.maw" 2>/dev/null
      """)
  }
  return config
}

private func readTokenFile(_ path: String) throws -> String {
  let expanded = (path as NSString).expandingTildeInPath
  let attributes: [FileAttributeKey: Any]
  do { attributes = try FileManager.default.attributesOfItem(atPath: expanded) }
  catch { throw fail("serve: token file: cannot read \(expanded)\n  ls -l \(expanded)") }

  guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
    throw fail("serve: token file must be a regular file\n  ls -l \(expanded)")
  }
  let size = (attributes[.size] as? Int) ?? 0
  guard size <= 4096 else {
    throw fail("serve: token file must be <=4096 bytes\n  wc -c \(expanded)")
  }
  let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
  guard permissions & 0o077 == 0 else {
    throw fail("serve: token file must be readable only by its owner\n  chmod 600 \(expanded)")
  }
  guard let data = FileManager.default.contents(atPath: expanded),
        let text = String(data: data, encoding: .utf8) else {
    throw fail("serve: token file is not readable text\n  file \(expanded)")
  }
  let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard (16...4096).contains(token.utf8.count) else {
    throw fail("serve: operator token must contain 16..4096 bytes")
  }
  return token
}

/// `net.isIP(host) === 4` — node's strict dotted quad: exactly four groups,
/// each 0..255, no leading zeros, ASCII digits only. The loose
/// `^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$` this replaces admitted `127.0.0.01` and
/// `127.999.1.1`, both of which the reference refuses (measured 2026-09-22
/// against the Bun server on 3497: 403 and 500 respectively).
func isIPv4Literal(_ host: String) -> Bool {
  let parts = host.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count == 4 else { return false }
  for part in parts {
    guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
    if part.count > 1 && part.first == "0" { return false }
    guard let value = Int(part), value <= 255 else { return false }
  }
  return true
}

/// Port of `mod.loopbackHost.ts`, used for BOTH the Host-header guard and the
/// CORS origin allowlist — the reference passes the same raw authority to the
/// same predicate in both places, so a second, looser copy is how the two
/// drift apart.
///
/// Three deliberate sharp edges, all measured against the reference:
///   * `host === 'localhost'` is case-SENSITIVE, so `LOCALHOST` is refused.
///   * the IPv4 branch is `isIP(host) === 4 && host.startsWith('127.')`, so
///     `127.0.0.01` is refused even though WHATWG would parse it as 127.0.0.1.
///   * an IPv6 literal is normalised first, so `[::ffff:127.0.0.1]` — what a
///     dashboard page on a dual-stack socket actually sends — is allowed.
func loopbackHost(_ authority: String) -> Bool {
  guard !authority.isEmpty else { return false }
  var host = authority
  // `/^(?:\[([^\]]+)\]|([^:]+))(?::([0-9]+))?$/`, anchored, so a match covers
  // the whole authority; no match at all means the raw string is the host,
  // which is how a bare `::1` reaches the IPv6 branch below.
  if authority.range(of: #"^(?:\[([^\]]+)\]|([^:]+))(?::([0-9]+))?$"#, options: .regularExpression) != nil {
    if authority.hasPrefix("[") {
      if let close = authority.firstIndex(of: "]") {
        host = String(authority[authority.index(after: authority.startIndex)..<close])
      }
    } else if let colon = authority.lastIndex(of: ":") {
      host = String(authority[authority.startIndex..<colon])
    }
  }
  if host == "localhost" { return true }
  if isIPv4Literal(host) { return host.hasPrefix("127.") }
  // `isIP(host) === 6`: node refuses a zone id, so `fe80::1%en0` is not an IP.
  guard host.contains(":"), !host.contains("%"), let address = IPv6Address(host) else { return false }
  let bytes = [UInt8](address.rawValue)
  guard bytes.count == 16 else { return false }
  if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
  // `/^\[::ffff:7f[0-9a-f]{2}:[0-9a-f]{1,4}\]$/` — 0x7f is 127.
  return bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
    && bytes[12] == 127
}
