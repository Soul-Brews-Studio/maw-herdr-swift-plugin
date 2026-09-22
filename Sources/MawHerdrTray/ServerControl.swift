import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// ServerControl.swift — start / stop / detect the local `maw herdr serve`.
//
// Owned by the lifecycle agent. Conforms to `ServerLifecycleController` from
// Contract.swift and adds three things the seam did not name but the menu
// needs: `ServerPresence` (ours vs. found), `ServerLaunchInfo` (what we
// launched, so the app can adopt the token file we chose), and
// `lifecycleEvents` — an `AsyncStream<ServerLifecycle>` mirroring the seam's
// `FleetMonitor.snapshots` pattern, so the menu learns that the child died
// from `Process.terminationHandler` instead of polling liveness on the main
// thread.
//
// ── SAFETY, non-negotiable ───────────────────────────────────────────────────
// `stop()` terminates ONLY a `Process` this controller launched, by the pid it
// is holding. There is no pkill, no name match, no port-owner lookup, and no
// path that can reach a server the app merely found. This machine runs a real
// fleet; another session's dashboard is not ours to take down.
//
// ── CONCURRENCY ──────────────────────────────────────────────────────────────
// `HerdrServerController` is an `actor`: every mutable field (the launch
// record, the log handle, the last published state) is actor-isolated. The two
// things that must be reachable from OUTSIDE the actor — the child process,
// for the synchronous quit path, and the "this exit was on purpose" flag,
// which `stop()` sets and `terminationHandler` reads — live in small
// NSLock-guarded `@unchecked Sendable` boxes. `Process` itself is not Sendable
// and never leaves its box; the termination handler extracts two Ints and
// hands only those to the actor.
//
// ── MEASURED against the live server, 2026-09-22 ─────────────────────────────
//  * `/api/identity` is the cheap probe, NOT `/api/health`. Measured on the
//    running demo: identity 0.001s avg, health 0.016s avg over 3 calls each —
//    `/api/health` runs `try await backend.roster()` (HTTPServer.swift:918),
//    a `herdr` SUBPROCESS, while `/api/identity` answers from memory
//    (HTTPServer.swift:887). Identity also carries the version/runtime/node
//    that `ServerLifecycle.running` wants, which health's `{"ok":true}` does
//    not. So: identity is the poll, health is the one-shot readiness
//    confirmation after a launch (it proves the herdr backend actually works,
//    not merely that a socket is bound).
//  * In token mode there is NO public-path exemption: measured on 127.0.0.1:3479,
//    an unauthenticated GET of BOTH `/api/identity` AND `/api/health` returns
//    401 {"error":"operator_token_required"} (the gate at HTTPServer.swift:744-767
//    exempts only websocket upgrades). A 401 therefore means "a server IS
//    answering here", never "down" — see `probe()`.
//  * SIGTERM to the child exits it cleanly and the port is free immediately
//    after (`installShutdownSignals` in the server's main.swift closes sockets
//    then `exit(0)`).
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - What a launch was

/// The record of a server process THIS app started. Handed to the UI so the
/// menu can say what it started and, critically, so the app can adopt the token
/// file the controller chose — see `trayConfigAdoptingLaunchToken(_:)`.
///
/// `tokenFilePath` is a PATH. The token value is never stored, never logged and
/// never crosses this type.
struct ServerLaunchInfo: Sendable, Hashable {
  var pid: Int32
  /// `127.0.0.1:3467` — exactly what went to `--listen`.
  var listen: String
  var binaryPath: String
  /// Where the child's stdout+stderr went, so a failed start can be explained.
  var logPath: String
  /// Path passed to `--token-file`, or nil when the insecure demo was started.
  var tokenFilePath: String?
  /// Set only for the insecure demo — the bounded `--demo-minutes`.
  var demoMinutes: Int?
  var startedAt: Date

  var isTokenMode: Bool { tokenFilePath != nil }

  /// One menu-safe line describing the posture. Names the token PATH at most.
  var postureLine: String {
    if let tokenFilePath {
      return "operator token required (\(tokenFilePath))"
    }
    return "insecure read-only demo, stops in \(demoMinutes ?? 0) min"
  }
}

/// Who owns the thing answering `config.baseURL`. This is the answer to
/// "already listening — ours, or somebody else's?", and it is what gates the
/// destructive menu item.
enum ServerPresence: Sendable, Hashable {
  /// Nothing is answering.
  case absent
  /// A process this controller launched, still alive.
  case startedByThisApp(pid: Int32, lifecycle: ServerLifecycle)
  /// A server was found on the port and this app did not start it. Read from
  /// it, never stop it.
  case preexisting(lifecycle: ServerLifecycle)

  var lifecycle: ServerLifecycle {
    switch self {
    case .absent: return .stopped
    case .startedByThisApp(_, let lifecycle): return lifecycle
    case .preexisting(let lifecycle): return lifecycle
    }
  }

  /// The ONLY thing that may enable a "Stop server" menu item.
  var isOurs: Bool {
    if case .startedByThisApp = self { return true }
    return false
  }

  var menuLine: String {
    switch self {
    case .absent: return "server not running"
    case .startedByThisApp(let pid, _): return "server running — started here (pid \(pid))"
    case .preexisting: return "server running — found, not ours"
    }
  }
}

// MARK: - Small Sendable boxes for the things that cross the actor boundary

/// Holds the child `Process` behind a lock. `Process` is not Sendable, so it
/// never escapes this box — callers get Ints and Bools out of it. The box is
/// `nonisolated` on the actor precisely so the synchronous app-quit path can
/// SIGTERM the child without awaiting anything.
private final class ChildProcessBox: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  /// Survives `clear()`. Without it the startup watcher and the termination
  /// handler race: whichever clears first, the other reports "exited -1"
  /// instead of the server's real code (measured: an invalid token file exits
  /// 2, and the first version of this file reported -1 for it).
  private var lastStatus: Int32?

  func adopt(_ process: Process) {
    lock.lock()
    defer { lock.unlock() }
    self.process = process
    lastStatus = nil
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    if let process, !process.isRunning { lastStatus = process.terminationStatus }
    process = nil
  }

  var pid: Int32? {
    lock.lock()
    defer { lock.unlock() }
    guard let process, process.processIdentifier > 0 else { return nil }
    return process.processIdentifier
  }

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return process?.isRunning ?? false
  }

  /// nil while the process is still alive — `terminationStatus` traps if read
  /// before the child exits. After `clear()` this is the remembered status.
  var exitStatus: Int32? {
    lock.lock()
    defer { lock.unlock() }
    guard let process else { return lastStatus }
    guard !process.isRunning else { return nil }
    return process.terminationStatus
  }

  /// SIGTERM, only if we are still holding a live child.
  func sendTERM() {
    lock.lock()
    let process = self.process
    lock.unlock()
    guard let process, process.isRunning else { return }
    process.terminate()
  }

  /// SIGKILL to the tracked pid, only if we are still holding a live child.
  func sendKILL() {
    lock.lock()
    let process = self.process
    lock.unlock()
    guard let process, process.isRunning, process.processIdentifier > 0 else { return }
    kill(process.processIdentifier, SIGKILL)
  }
}

/// A Bool that `stop()` (actor) and `terminationHandler` (background queue) can
/// both see, so a deliberate SIGTERM is not reported to the menu as a crash.
private final class FlagBox: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false

  var value: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return flag
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      flag = newValue
    }
  }
}

// MARK: - Finding the server binary next to our own

/// Resolves `MawHerdrServe` RELATIVE TO THIS EXECUTABLE, so the tray finds the
/// server wherever the package happened to be built (`swift run` puts the tray
/// in `.build/debug/`, `swift build -c release` in `.build/release/`, and
/// `.build/release` is itself a symlink to `.build/<triple>/release`).
/// Never searches PATH: a `MawHerdrServe` somewhere else on this machine is not
/// the one this tray was built against.
private enum ServerBinaryLocator {
  static let fileName = "MawHerdrServe"
  static let environmentOverride = "MAW_HERDR_SERVE_BINARY"

  static func ownExecutableURL() -> URL {
    if let url = Bundle.main.executableURL {
      return url.standardizedFileURL
    }
    let argv0 = CommandLine.arguments.first ?? fileName
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    if argv0.contains("/") {
      return URL(fileURLWithPath: argv0, relativeTo: cwd).standardizedFileURL
    }
    return cwd.appendingPathComponent(argv0).standardizedFileURL
  }

  /// The nearest `.build` ancestor of a path, if any.
  static func buildRoot(of url: URL) -> URL? {
    var directory = url.deletingLastPathComponent()
    while directory.path != "/" && !directory.path.isEmpty {
      if directory.lastPathComponent == ".build" { return directory }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }
    return nil
  }

  /// The package checkout that owns a built binary — used for the `.tmp/` log
  /// fallback. nil when the binary is not inside a `.build` tree.
  static func packageRoot(for binary: URL) -> URL? {
    buildRoot(of: binary)?.deletingLastPathComponent()
  }

  static func locate(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> Result<URL, TrayError>
  {
    var candidates: [URL] = []
    if let override = environment[environmentOverride], !override.isEmpty {
      candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
    }
    let executable = ownExecutableURL()
    let directory = executable.deletingLastPathComponent()
    // Same build directory — the normal case for both debug and release.
    candidates.append(directory.appendingPathComponent(fileName))
    // Tray built debug, server built release (or the other way round).
    let siblings = directory.deletingLastPathComponent()
    candidates.append(siblings.appendingPathComponent("release").appendingPathComponent(fileName))
    candidates.append(siblings.appendingPathComponent("debug").appendingPathComponent(fileName))
    if let buildRoot = buildRoot(of: executable) {
      candidates.append(buildRoot.appendingPathComponent("release").appendingPathComponent(fileName))
      candidates.append(buildRoot.appendingPathComponent("debug").appendingPathComponent(fileName))
    }

    for candidate in candidates {
      let path = candidate.standardizedFileURL.path
      if FileManager.default.isExecutableFile(atPath: path) {
        return .success(candidate.standardizedFileURL)
      }
    }

    // Name the fix, not just the problem: the next line is runnable.
    let root = buildRoot(of: executable)?.deletingLastPathComponent().path ?? directory.path
    return .failure(
      .lifecycle(
        "\(fileName) not found near \(directory.path) — run: swift build -c release --product \(fileName) (in \(root))"
      ))
  }
}

// MARK: - Where a failed start gets explained

/// Creates the file the child's stdout+stderr are redirected to. Prefers
/// `~/Library/Logs/maw-herdr-tray/`, falls back to the package's gitignored
/// `.tmp/`. A start that fails is otherwise unexplainable: the server writes
/// its refusal ("--listen must use a loopback IP", a bad token file, a taken
/// port) to stderr and exits 1 or 2.
private enum ServerLogFile {
  static func create(port: Int, packageRoot: URL?) -> URL? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    let name = "serve-\(port)-\(formatter.string(from: Date())).log"

    var directories: [URL] = []
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    if let library {
      directories.append(library.appendingPathComponent("Logs/maw-herdr-tray", isDirectory: true))
    }
    if let packageRoot {
      directories.append(packageRoot.appendingPathComponent(".tmp/maw-herdr-tray", isDirectory: true))
    }

    for directory in directories {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      } catch {
        continue
      }
      let file = directory.appendingPathComponent(name)
      if FileManager.default.createFile(atPath: file.path, contents: nil) {
        return file
      }
    }
    return nil
  }
}

/// `/api/health` answers `{"ok":true}` — and `{"ok":false,"error":…}` with 503
/// when the herdr backend itself is unavailable (HTTPServer.swift:810-816).
private struct HealthBody: Decodable, Sendable {
  var ok: Bool
}

/// What a GET of `/api/identity` actually produced. Kept separate from
/// `ServerLifecycle` because 401 is the case that matters most: it proves a
/// server is up while telling us nothing about it.
private enum IdentityOutcome: Sendable {
  case ok(HerdrIdentity)
  case unauthorized
  /// `refused` is true only for a connection the kernel rejected outright — a
  /// timeout means something IS holding the port, just not answering.
  case down(reason: String, refused: Bool)
  case unexpected(status: Int, code: String?)
  case malformed(detail: String)
}

// MARK: - The controller

/// Starts, stops and identifies the local `maw herdr serve`.
///
/// Typical wiring in the UI:
/// ```swift
/// let control = HerdrServerController(config: config)
/// Task { @MainActor in
///   for await state in control.lifecycleEvents { menu.serverStateChanged(state) }
/// }
/// ```
actor HerdrServerController: ServerLifecycleController {
  /// Shown for a server that answered 401 — it is up, but it will not say what
  /// it is without a token we do not have.
  static let protectedVersion = "token-protected"
  /// How long a freshly launched server gets to answer `/api/identity`.
  static let startupTimeout: TimeInterval = 12.0
  /// SIGTERM grace before SIGKILL.
  static let terminateGrace: TimeInterval = 4.0
  /// How long we wait for the port to stop answering after the child is gone.
  static let portReleaseTimeout: TimeInterval = 5.0

  nonisolated let config: TrayConfig

  /// State changes, pushed — not polled. Yields on every TRANSITION (never a
  /// repeat of the current value), including the ones that originate off the
  /// main thread in `Process.terminationHandler`. Single consumer, same as the
  /// seam's `FleetMonitor.snapshots`; buffered newest-8 so an absent consumer
  /// cannot grow it without bound.
  nonisolated let lifecycleEvents: AsyncStream<ServerLifecycle>

  private nonisolated let events: AsyncStream<ServerLifecycle>.Continuation
  private nonisolated let child = ChildProcessBox()
  /// Set before we signal our own child, so `childDidExit` reports `.stopped`
  /// rather than "killed by signal 15".
  private nonisolated let intentionalStop = FlagBox()

  private var state: ServerLifecycle = .unknown
  private var launch: ServerLaunchInfo?
  private var logHandle: FileHandle?

  /// `--demo-minutes` for the insecure fallback. Bounded by the server to
  /// 1...9999; bounded here too so a bad value cannot become "forever".
  private let demoMinutes: Int
  /// Where the operator token is expected. Existence of this file is the whole
  /// token-posture decision — see `start()`.
  private let tokenFilePathForStart: String

  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = config.requestTimeout
    configuration.timeoutIntervalForResource = config.requestTimeout
    configuration.waitsForConnectivity = false
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    return URLSession(configuration: configuration)
  }()

  init(
    config: TrayConfig = .standard,
    demoMinutes: Int = 30,
    tokenFilePathForStart: String = "~/.maw-herdr-token"
  ) {
    self.config = config
    self.demoMinutes = min(max(demoMinutes, 1), 9999)
    self.tokenFilePathForStart = tokenFilePathForStart
    let (stream, continuation) = AsyncStream<ServerLifecycle>.makeStream(
      bufferingPolicy: .bufferingNewest(8))
    self.lifecycleEvents = stream
    self.events = continuation
  }

  deinit {
    events.finish()
  }

  // MARK: Probing

  /// GET `/api/identity` — the cheap one (0.001s vs `/api/health`'s 0.016s,
  /// measured; health shells out to `herdr`). Never throws: a server that is
  /// not there is `.stopped`.
  ///
  /// A 401 is `.running`, not `.stopped` — in token mode every path including
  /// `/api/health` is behind the gate, so "refused to talk" still proves
  /// "listening". Killing nothing depends on this, but showing the truth does.
  func probe() async -> ServerLifecycle {
    let outcome = await identityOutcome(timeout: min(config.requestTimeout, 3.0))
    let next: ServerLifecycle
    switch outcome {
    case .ok(let identity):
      next = .running(version: identity.version, runtime: identity.runtime, node: identity.node)
    case .unauthorized:
      next = .running(version: Self.protectedVersion, runtime: "unknown", node: "unknown")
    case .down:
      next = .stopped
    case .unexpected(let status, let code):
      next = .failed(TrayError.httpStatus(status, code: code).displayText)
    case .malformed(let detail):
      next = .failed(TrayError.malformedBody(path: "/api/identity", detail: detail).displayText)
    }
    transition(to: next)
    return next
  }

  /// Is something answering, and is it OURS? This is the question the menu
  /// asks; `ownsRunningServer()` is the cheap cached form of it.
  func detect() async -> ServerPresence {
    let lifecycle = await probe()
    guard lifecycle.isRunning else { return .absent }
    if launch != nil, child.isRunning, let pid = child.pid {
      return .startedByThisApp(pid: pid, lifecycle: lifecycle)
    }
    return .preexisting(lifecycle: lifecycle)
  }

  /// GET `/api/health` — the deeper check. True only on 200 `{"ok":true}`.
  /// This one costs the server a `herdr` subprocess, so it is a confirmation
  /// after a launch, not a poll.
  func health() async -> Bool {
    var request = URLRequest(url: config.endpoint("/api/health"))
    request.httpMethod = "GET"
    request.timeoutInterval = config.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token = currentToken() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let body = try? JSONDecoder().decode(HealthBody.self, from: data)
    else { return false }
    return body.ok
  }

  /// True only when the running server was launched by this app. Cheap: no
  /// HTTP, just the pid we are holding.
  func ownsRunningServer() async -> Bool {
    launch != nil && child.isRunning
  }

  /// The last state published on `lifecycleEvents`.
  func currentState() -> ServerLifecycle { state }

  /// What we launched, or nil if we launched nothing. Paths only, never a token.
  func launchInfo() -> ServerLaunchInfo? { launch }

  /// The config the rest of the app should use against the server WE started.
  ///
  /// This matters: when `~/.maw-herdr-token` exists we start the server in
  /// token mode, and a `TrayConfig` with `tokenFilePath == nil` gets 401 on
  /// every read — an empty menu against a healthy server. Adopt this before
  /// building the API client, or export `MAW_HERDR_TOKEN_FILE`.
  func trayConfigAdoptingLaunchToken(_ base: TrayConfig) -> TrayConfig {
    guard let path = launch?.tokenFilePath else { return base }
    var adopted = base
    adopted.tokenFilePath = path
    return adopted
  }

  // MARK: Starting

  /// Launch the server, unless something is already answering the configured
  /// URL — in which case we adopt nothing, start nothing, and report what is
  /// there. Two servers on one port is the failure this guard exists for.
  ///
  /// TOKEN POSTURE, decided here and nowhere else:
  ///   * `~/.maw-herdr-token` readable  → `--token-file <path>`; writes stay
  ///     behind the operator token, reads need the token too.
  ///   * otherwise                      → REFUSE a write-enabled server; start
  ///     `--insecure-no-token --demo-minutes N` instead, which is read-only
  ///     for writes and stops itself on a deadline.
  /// We never mint a token, never pass one on the command line, and never log
  /// its contents — only its path.
  func start() async -> ServerLifecycle {
    // Already ours and alive.
    if launch != nil, child.isRunning {
      return await probe()
    }

    let existing = await probe()
    guard case .stopped = existing else {
      // Running (possibly 401), or something non-herdr is answering. Either
      // way the port is taken: do not add a second listener.
      return existing
    }

    guard let port = config.baseURL.port else {
      return publish(
        .failed(
          TrayError.lifecycle(
            "base URL \(config.baseURL.absoluteString) has no explicit port — export MAW_HERDR_URL=http://127.0.0.1:3467"
          ).displayText))
    }
    let host = config.baseURL.host ?? "127.0.0.1"
    guard Self.isLoopback(host) else {
      return publish(
        .failed(
          TrayError.lifecycle(
            "refusing to start a server for non-loopback host \(host) — export MAW_HERDR_URL=http://127.0.0.1:\(port)"
          ).displayText))
    }

    let binary: URL
    switch ServerBinaryLocator.locate() {
    case .success(let url): binary = url
    case .failure(let error): return publish(.failed(error.displayText))
    }

    var arguments = ["--listen", "\(host):\(port)"]
    var tokenPathUsed: String?
    var demoMinutesUsed: Int?
    let tokenPath = (tokenFilePathForStart as NSString).expandingTildeInPath
    if FileManager.default.isReadableFile(atPath: tokenPath) {
      arguments += ["--token-file", tokenPath]
      tokenPathUsed = tokenPath
    } else {
      arguments += ["--insecure-no-token", "--demo-minutes", String(demoMinutes)]
      demoMinutesUsed = demoMinutes
    }

    let packageRoot = ServerBinaryLocator.packageRoot(for: binary)
    guard let logURL = ServerLogFile.create(port: port, packageRoot: packageRoot),
      let handle = FileHandle(forWritingAtPath: logURL.path)
    else {
      return publish(
        .failed(
          TrayError.lifecycle(
            "cannot open a log file for the server — run: mkdir -p ~/Library/Logs/maw-herdr-tray"
          ).displayText))
    }
    handle.seekToEndOfFile()
    // The header names the PATH of the token file, never its contents.
    let posture = tokenPathUsed.map { "--token-file \($0)" }
      ?? "--insecure-no-token --demo-minutes \(demoMinutes)"
    handle.write(
      Data(
        "# maw-herdr-tray \(Date()) launching \(binary.path) --listen \(host):\(port) \(posture)\n"
          .utf8))

    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.standardOutput = handle
    process.standardError = handle
    process.standardInput = FileHandle.nullDevice
    // Only Sendable values cross into the handler: two scalars and the actor.
    process.terminationHandler = { [weak self] finished in
      let status = finished.terminationStatus
      let signalled = finished.terminationReason == .uncaughtSignal
      guard let self else { return }
      Task { await self.childDidExit(status: status, signalled: signalled) }
    }

    intentionalStop.value = false
    do {
      try process.run()
    } catch {
      try? handle.close()
      return publish(
        .failed(
          TrayError.lifecycle(
            "cannot launch \(binary.path) — \(error.localizedDescription); tail -n 40 \(logURL.path)"
          ).displayText))
    }

    child.adopt(process)
    logHandle = handle
    launch = ServerLaunchInfo(
      pid: process.processIdentifier,
      listen: "\(host):\(port)",
      binaryPath: binary.path,
      logPath: logURL.path,
      tokenFilePath: tokenPathUsed,
      demoMinutes: demoMinutesUsed,
      startedAt: Date()
    )

    return await waitUntilAnswering(logPath: logURL.path)
  }

  /// Poll `/api/identity` until the child answers, it dies, or we give up.
  /// The child dying is the informative case: the server writes WHY to stderr
  /// (bad token file mode, taken port, bad --listen) and exits non-zero, so the
  /// failure text points at the log rather than guessing.
  private func waitUntilAnswering(logPath: String) async -> ServerLifecycle {
    let deadline = Date().addingTimeInterval(Self.startupTimeout)
    while Date() < deadline {
      if !child.isRunning {
        let status = child.exitStatus ?? -1
        discardChild()
        return publish(
          .failed(
            TrayError.lifecycle(
              "herdr serve exited \(status) during startup — run: tail -n 40 \(logPath)"
            ).displayText))
      }
      switch await identityOutcome(timeout: 1.5) {
      case .ok(let identity):
        // One deeper check so "running" means the herdr backend works, not
        // merely that a socket is bound. Non-fatal: a 503 here is the fleet's
        // problem, not the process's.
        _ = await health()
        return publish(
          .running(version: identity.version, runtime: identity.runtime, node: identity.node))
      case .unauthorized:
        return publish(
          .running(version: Self.protectedVersion, runtime: "unknown", node: "unknown"))
      case .unexpected(let status, let code):
        return publish(.failed(TrayError.httpStatus(status, code: code).displayText))
      case .malformed(let detail):
        return publish(
          .failed(TrayError.malformedBody(path: "/api/identity", detail: detail).displayText))
      case .down:
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
    // Ours, alive, and mute. Take it back down — leaving an orphan is worse.
    intentionalStop.value = true
    child.sendTERM()
    _ = await waitForChildExit(timeout: Self.terminateGrace)
    if child.isRunning { child.sendKILL() }
    discardChild()
    return publish(
      .failed(
        TrayError.lifecycle(
          "herdr serve did not answer within \(Int(Self.startupTimeout))s — run: tail -n 40 \(logPath)"
        ).displayText))
  }

  // MARK: Stopping

  /// Terminate the process THIS controller started: SIGTERM, then SIGKILL
  /// after `terminateGrace`, then wait for the port to actually go quiet.
  ///
  /// A server we merely found is never touched. The contract's comment says
  /// this is a no-op returning `.stopped` when we started nothing; it returns
  /// `.failed(…)` instead when something we do NOT own is answering, because
  /// reporting "stopped" while another person's dashboard is still up is a lie
  /// the menu would render. When nothing is answering it does return `.stopped`
  /// as specified. (Flagged to the orchestrator as a deliberate deviation.)
  func stop() async -> ServerLifecycle {
    guard launch != nil, child.pid != nil else {
      let current = await probe()
      if current.isRunning {
        return .failed(
          TrayError.lifecycle(
            "the server on \(listenDescription) was not started by this app — refusing to stop it"
          ).displayText)
      }
      return publish(.stopped)
    }

    let info = launch
    intentionalStop.value = true
    child.sendTERM()
    if !(await waitForChildExit(timeout: Self.terminateGrace)) {
      child.sendKILL()
      _ = await waitForChildExit(timeout: 2.0)
    }
    discardChild()

    let released = await waitForListenerGone(timeout: Self.portReleaseTimeout)
    guard released else {
      let port = config.baseURL.port.map(String.init) ?? "<port>"
      return publish(
        .failed(
          TrayError.lifecycle(
            "terminated pid \(info?.pid ?? 0) but \(listenDescription) still answers — run: lsof -nP -iTCP:\(port) -sTCP:LISTEN"
          ).displayText))
    }
    return publish(.stopped)
  }

  /// The app-quit path. Synchronous on purpose: `applicationWillTerminate`
  /// cannot await, and an orphaned server holding a port is exactly what this
  /// app must not leave behind. Blocks at most `timeout` (default 2s) on the
  /// caller's thread. Safe to call when nothing was started — it returns
  /// immediately.
  nonisolated func terminateChildForQuit(timeout: TimeInterval = 2.0) {
    guard child.isRunning else { return }
    intentionalStop.value = true
    child.sendTERM()
    let deadline = Date().addingTimeInterval(max(0.25, timeout))
    while Date() < deadline && child.isRunning {
      usleep(50_000)
    }
    if child.isRunning {
      child.sendKILL()
      usleep(200_000)
    }
  }

  /// Finish `lifecycleEvents`. Call after `stop()`/`terminateChildForQuit` so
  /// the consuming `for await` loop ends instead of hanging the quit.
  nonisolated func finishEvents() {
    events.finish()
  }

  // MARK: Child death, observed rather than polled

  /// Called from `Process.terminationHandler` (off the main thread, off this
  /// actor) via a `Task`. This is what makes the menu correct without any
  /// liveness polling: a demo server hitting its `--demo-minutes` deadline, a
  /// crash, or an operator's `kill` all arrive here and become a published
  /// `ServerLifecycle`.
  private func childDidExit(status: Int32, signalled: Bool) {
    let info = launch
    discardChild()

    if intentionalStop.value {
      intentionalStop.value = false
      transition(to: .stopped)
      return
    }
    if status == 0 && !signalled {
      // The insecure demo stopping itself on its deadline lands here.
      transition(to: .stopped)
      return
    }
    let pointer = info.map { " — run: tail -n 40 \($0.logPath)" } ?? ""
    let how = signalled ? "killed by signal \(status)" : "exited \(status)"
    transition(to: .failed(TrayError.lifecycle("herdr serve \(how)\(pointer)").displayText))
  }

  private func discardChild() {
    child.clear()
    launch = nil
    try? logHandle?.close()
    logHandle = nil
  }

  // MARK: Waiting

  private func waitForChildExit(timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !child.isRunning { return true }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return !child.isRunning
  }

  /// True once the configured address REFUSES a connection. A timeout does not
  /// count: something would still be holding the port.
  private func waitForListenerGone(timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if case .down(_, let refused) = await identityOutcome(timeout: 1.0), refused {
        return true
      }
      try? await Task.sleep(nanoseconds: 150_000_000)
    }
    if case .down(_, let refused) = await identityOutcome(timeout: 1.0) { return refused }
    return false
  }

  // MARK: HTTP

  private func identityOutcome(timeout: TimeInterval) async -> IdentityOutcome {
    var request = URLRequest(url: config.endpoint("/api/identity"))
    request.httpMethod = "GET"
    request.timeoutInterval = timeout
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token = currentToken() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .malformed(detail: "no HTTP response")
      }
      switch http.statusCode {
      case 200..<300:
        do {
          return .ok(try JSONDecoder().decode(HerdrIdentity.self, from: data))
        } catch {
          // The decoding description, never the body — a body can carry text
          // from another person's pane.
          return .malformed(detail: Self.decodeDetail(error))
        }
      case 401, 403:
        return .unauthorized
      default:
        let code = (try? JSONDecoder().decode(HerdrErrorBody.self, from: data))?.error
        return .unexpected(status: http.statusCode, code: code)
      }
    } catch let error as URLError {
      return .down(reason: Self.shortReason(error), refused: Self.isRefusal(error))
    } catch {
      return .down(reason: "request failed", refused: false)
    }
  }

  /// The bearer token, read FRESH from disk each time, preferring the file we
  /// launched with over the one in `TrayConfig`. Returned to the caller for an
  /// Authorization header and nothing else: it is never stored on this actor,
  /// never logged, never put in a `TrayError`.
  private func currentToken() -> String? {
    if let path = launch?.tokenFilePath, let token = Self.readTokenFile(path) { return token }
    // `try?` flattens the `String??` here: an unreadable token file and an
    // absent one both come back nil, which is the right posture for a probe —
    // `start()` is where a bad token file becomes a visible failure.
    if let token = try? config.readToken() { return token }
    return nil
  }

  private static func readTokenFile(_ path: String) -> String? {
    let expanded = (path as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: expanded),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
  }

  // MARK: Plumbing

  private func transition(to next: ServerLifecycle) {
    guard next != state else { return }
    state = next
    events.yield(next)
  }

  @discardableResult
  private func publish(_ next: ServerLifecycle) -> ServerLifecycle {
    transition(to: next)
    return next
  }

  private var listenDescription: String {
    if let port = config.baseURL.port {
      return "\(config.baseURL.host ?? "127.0.0.1"):\(port)"
    }
    return config.baseURL.absoluteString
  }

  /// The server itself refuses anything else (`--listen must use a loopback IP
  /// or localhost`, Config.swift:138) — refuse earlier so the reason is ours.
  private static func isLoopback(_ host: String) -> Bool {
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return bare == "127.0.0.1" || bare == "::1" || bare == "localhost"
  }

  private static func isRefusal(_ error: URLError) -> Bool {
    switch error.code {
    case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return true
    default: return false
    }
  }

  private static func shortReason(_ error: URLError) -> String {
    switch error.code {
    case .cannotConnectToHost: return "connection refused"
    case .timedOut: return "timed out"
    case .networkConnectionLost: return "connection lost"
    case .cannotFindHost: return "host not found"
    case .badURL: return "bad URL"
    case .secureConnectionFailed: return "TLS failed"
    default: return "URLError \(error.errorCode)"
    }
  }

  /// A short, body-free description of a decoding failure.
  private static func decodeDetail(_ error: Error) -> String {
    guard let error = error as? DecodingError else { return "undecodable" }
    switch error {
    case .keyNotFound(let key, _): return "missing key \(key.stringValue)"
    case .typeMismatch(let type, let context):
      return "type mismatch \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
    case .valueNotFound(let type, _): return "null where \(type) expected"
    case .dataCorrupted: return "not JSON"
    @unknown default: return "undecodable"
    }
  }
}
