import Foundation

// Process entry point. Port of the tail of mod.runBunServe.ts: parse, announce,
// listen, expire the demo, stop on a signal.
//
// The banner goes to stderr, not stdout, so a caller can pipe the port line
// into a log while `curl` output on stdout stays clean — same as the Bun
// server, which is the thing operators already have muscle memory for.

private let usage = """
  maw herdr-swift serve [--token-file PATH | --insecure-no-token] [--listen 127.0.0.1:3467]

    --token-file PATH        operator token, file mode 0600, 16..4096 bytes
    --insecure-no-token      read-only demo, no token, stops itself
    --listen HOST:PORT       loopback only (127.0.0.1, ::1, localhost); default 127.0.0.1:3457; port 0 = any free port
    --allow-origin ORIGIN    extra browser origin, exact scheme://host[:port]; repeatable
    --herdr PATH             herdr binary to shell out to (default: herdr)
    --data-dir PATH          ui-state directory (accepted for parity; the state routes are not ported)
    --wake-engine KIND       agent kind for `wake` on a bare pane (default codex)
    --demo-minutes N         1..9999, only with --insecure-no-token (default 30)
    --access-log             nginx-style line per request on stderr (default on when insecure)
    --no-access-log          silence it
    --help, -h               this text

  test -e ~/.maw-herdr-token || (umask 077; openssl rand -hex 32 > ~/.maw-herdr-token)
  maw herdr-swift serve --token-file ~/.maw-herdr-token --listen 127.0.0.1:3467
  maw herdr-swift serve --insecure-no-token --listen 127.0.0.1:3467   (read-only demo, self-stopping)
  """

private func serveMain() -> Never {
  var arguments = Array(CommandLine.arguments.dropFirst())
  // `maw herdr-swift serve …` strips the verb before exec, but a human running
  // the binary by hand keeps typing it. Both spellings work.
  if arguments.first == "serve" { arguments.removeFirst() }
  if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
  }
  if let first = arguments.first, !first.hasPrefix("-") {
    warn("serve: unknown verb \(first)")
    warn("  maw herdr-swift serve --token-file ~/.maw-herdr-token --listen 127.0.0.1:3467")
    exit(2)
  }

  var config: ServeConfig
  do {
    config = try parseConfig(arguments)
  } catch {
    warn("\(error)")
    exit(2)
  }

  // `createHerdrBackend(config.binary, config.wakeEngine, config.explicitWakeEngine)`.
  let backend = HerdrProcessBackend(
    binary: config.binary, wakeEngine: config.wakeEngine, explicitWakeEngine: config.explicitWakeEngine)
  let sockets = WebSocketServer(backend: backend)
  let server = HerdrHTTPServer(config: config, backend: backend, sockets: sockets)
  // The server has hashed it; nothing below this line needs the secret itself.
  config.token = ""

  do {
    try server.start()
  } catch {
    warn("serve: cannot start on \(config.hostname):\(config.port) — \(error)")
    warn("  lsof -nP -iTCP:\(config.port) -sTCP:LISTEN")
    exit(1)
  }

  let displayHost = config.hostname.contains(":") ? "[\(config.hostname)]" : config.hostname
  if config.accessLog { warn("maw herdr serve: access log on (--no-access-log to silence).") }
  if !config.allowOrigins.isEmpty {
    warn("maw herdr serve: extra allowed origins — \(config.allowOrigins.joined(separator: ", "))")
  }
  let mode =
    config.insecure
    ? "INSECURE read-only demo; no token required" : "operator token required; core dashboard only"
  // `server.port`, not the configured one: `--listen …:0` reports what it got.
  warn("maw herdr serve: http://\(displayHost):\(server.boundPort) (Swift; \(mode))")
  if config.insecure {
    // Loopback is not a boundary against a browser: any page the operator
    // visits can reach this port. Reads are open here, so say so plainly and
    // stop on a deadline rather than lingering.
    warn(
      "maw herdr serve: WARNING — reads (sessions, panes, captures) are open to any local process or web page.")
    warn("maw herdr serve: writes (send, wake, cleanup) still require --token-file.")
    warn("maw herdr serve: stopping automatically in \(config.demoMinutes) minute(s).")
  }

  scheduleDemoStop(minutes: config.demoMinutes) {
    warn("maw herdr serve: demo window elapsed; stopping.")
    sockets.shutdown()
    server.stop()
    exit(0)
  }
  installShutdownSignals {
    // Bun closes every socket with 1001 before the listener stops.
    sockets.shutdown()
    server.stop()
    exit(0)
  }

  RunLoop.main.run()
  exit(0)
}

serveMain()
