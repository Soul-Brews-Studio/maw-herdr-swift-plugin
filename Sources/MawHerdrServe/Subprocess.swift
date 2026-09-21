import Foundation

// Port of mod.runHerdr.ts, generalised the way the Bun code uses it: the same
// bounded runner serves `herdr`, `git` (wake identity, task worktrees),
// `tmux` (inbox sender) and `sh -c` (wake hooks), each with its own
// environment. No shell, argv array, stdin closed, stdout captured, stderr
// counted and discarded, SIGKILL to the whole process group at the deadline,
// 4 MiB stdout cap.
//
// Bun's caller `AbortSignal` has two halves here: `HerdrOp` carries the
// deadline (and any explicit abort), and Swift task cancellation stands in for
// the client disappearing — `withTaskCancellationHandler` kills the child the
// moment the task is cancelled, exactly where Bun's abort listener fires.

/// Subprocesses run here, never on the caller's thread: `waitpid` blocks, and a
/// hung herdr must not take the event loop with it.
let herdrRunQueue = DispatchQueue(label: "maw.herdr.run", qos: .userInitiated, attributes: .concurrent)
private let herdrTimerQueue = DispatchQueue(label: "maw.herdr.timer")

private let stdoutLimit = 4 * 1024 * 1024
private let stderrLimit = 64 * 1024

func backendError(_ message: String) -> BackendError { .unavailable(message) }

/// One dashboard-level operation. Its 10 second deadline covers the queue wait
/// and every subprocess inside it, so a roster of eight snapshots cannot add up
/// to eighty seconds. A nested op (identity resolution, configured launch) has
/// its own shorter deadline and is aborted whenever its parent is.
final class HerdrOp: @unchecked Sendable {
  private let deadline: Date
  private let parent: HerdrOp?
  private let lock = NSLock()
  private var explicitlyAborted = false

  init(timeout: TimeInterval = 10, parent: HerdrOp? = nil) {
    deadline = Date().addingTimeInterval(timeout)
    self.parent = parent
  }

  var aborted: Bool {
    if Task.isCancelled || Date() >= deadline { return true }
    lock.lock()
    let explicit = explicitlyAborted
    lock.unlock()
    return explicit || parent?.aborted == true
  }

  var remaining: TimeInterval {
    min(deadline.timeIntervalSinceNow, parent?.remaining ?? .infinity)
  }

  func abort() {
    lock.lock()
    explicitlyAborted = true
    lock.unlock()
  }
}

/// Shared between the reader threads, the timeout timer, the cancellation
/// handler and the waiter. The first failure wins and kills the child, exactly
/// as Bun's `fail()` does.
private final class RunState: @unchecked Sendable {
  private let lock = NSLock()
  private var message: String?
  private var stdout = Data()
  private var stdoutBytes = 0
  private var stderrBytes = 0
  private var pid: pid_t = 0

  /// Registered after launch. If a failure already fired in that window the
  /// kill would have been lost, so it is replayed here.
  func attach(pid value: pid_t) {
    lock.lock()
    pid = value
    let pending = message != nil
    lock.unlock()
    if pending && value > 0 { killGroup(value) }
  }

  func fail(_ text: String) {
    lock.lock()
    if message == nil { message = text }
    let target = pid
    lock.unlock()
    if target > 0 { killGroup(target) }
  }

  func appendStdout(_ chunk: Data) {
    lock.lock()
    stdoutBytes += chunk.count
    let exceeded = stdoutBytes > stdoutLimit
    if !exceeded && message == nil { stdout.append(chunk) }
    lock.unlock()
    if exceeded { fail("herdr output exceeds limit") }
  }

  /// stderr is counted and dropped. Its bytes never reach a response — a pane
  /// can echo anything, including a credential someone pasted into it.
  func countStderr(_ chunk: Data) {
    lock.lock()
    stderrBytes += chunk.count
    let exceeded = stderrBytes > stderrLimit
    lock.unlock()
    if exceeded { fail("herdr stderr exceeds limit") }
  }

  var failure: String? {
    lock.lock()
    defer { lock.unlock() }
    return message
  }

  func text() -> String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: stdout, as: UTF8.self)
  }
}

/// The whole process group, as Bun's `process.kill(-pid)` does: a herdr that
/// left a child behind would otherwise hold the pipe open and outlive us. The
/// process may have already exited; ESRCH is the expected outcome then.
func killGroup(_ pid: pid_t) {
  if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
}

/// Foundation's Process has no PATH search and a shell is not an option, so the
/// lookup `spawn("herdr", …)` gets for free is done by hand — against the
/// child's PATH when a custom environment is given, as libuv does.
func resolveExecutable(_ binary: String, environment: [String: String]? = nil) -> String? {
  if binary.isEmpty { return nil }
  if binary.contains("/") {
    return FileManager.default.isExecutableFile(atPath: binary) ? binary : nil
  }
  let search = (environment ?? processEnvironment)["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
  for entry in search.split(separator: ":", omittingEmptySubsequences: false) {
    let directory = entry.isEmpty ? "." : String(entry)
    let candidate = (directory as NSString).appendingPathComponent(binary)
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  return nil
}

/// A launched child and the parent's ends of its pipes.
struct SpawnedChild {
  var pid: pid_t
  var stdin: Int32   // -1 when stdin is /dev/null
  var stdout: Int32  // -1 when stdout is /dev/null
  var stderr: Int32  // -1 when stderr is /dev/null
}

private func makeEnvironment(_ environment: [String: String]?) -> [UnsafeMutablePointer<CChar>?]? {
  guard let environment else { return nil }
  return environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
}

/// `posix_spawn` rather than `Process`, for one reason: `POSIX_SPAWN_SETSID`.
/// Bun spawns `detached` and kills `-pid`, so a herdr that leaves a child
/// behind is killed with it; Foundation's Process cannot put the child in its
/// own session, which would leak the grandchild and leave it holding the pipe.
/// Still no shell, still an argv array.
func spawnChild(
  executable: String, args: [String], environment: [String: String]? = nil,
  pipeStdin: Bool = false, pipeOutput: Bool = true
) -> SpawnedChild? {
  var inFds: [Int32] = [-1, -1]
  var outFds: [Int32] = [-1, -1]
  var errFds: [Int32] = [-1, -1]
  if pipeStdin { guard pipe(&inFds) == 0 else { return nil } }
  if pipeOutput {
    guard pipe(&outFds) == 0, pipe(&errFds) == 0 else {
      for descriptor in inFds + outFds + errFds where descriptor >= 0 { close(descriptor) }
      return nil
    }
  }

  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  if pipeStdin {
    posix_spawn_file_actions_adddup2(&actions, inFds[0], 0)
  } else {
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
  }
  if pipeOutput {
    posix_spawn_file_actions_adddup2(&actions, outFds[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errFds[1], 2)
  } else {
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
  }
  // Only descriptors the child has no use for. Guarded on > 2 so a process
  // started with a closed stdout cannot end up closing the pipe it was
  // just handed.
  for descriptor in inFds + outFds + errFds where descriptor > 2 {
    posix_spawn_file_actions_addclose(&actions, descriptor)
  }

  var attributes: posix_spawnattr_t?
  posix_spawnattr_init(&attributes)
  defer { posix_spawnattr_destroy(&attributes) }
  posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

  let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) } + [nil]
  defer { for pointer in argv { free(pointer) } }
  let envp = makeEnvironment(environment)
  defer { if let envp { for pointer in envp { free(pointer) } } }

  var pid: pid_t = 0
  let status: Int32
  if let envp {
    status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
  } else {
    status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
  }
  // The child's ends are closed in the parent whatever happened.
  if pipeStdin { close(inFds[0]) }
  if pipeOutput {
    close(outFds[1])
    close(errFds[1])
  }
  guard status == 0 else {
    if pipeStdin { close(inFds[1]) }
    if pipeOutput {
      close(outFds[0])
      close(errFds[0])
    }
    return nil
  }
  return SpawnedChild(
    pid: pid, stdin: pipeStdin ? inFds[1] : -1, stdout: pipeOutput ? outFds[0] : -1,
    stderr: pipeOutput ? errFds[0] : -1)
}

/// `waitpid` to completion, returning the shell-style exit status. A child that
/// died from a signal reports non-zero, which is what Bun's `code !== 0` sees
/// when `close` fires with a null code.
func waitForExit(_ pid: pid_t) -> Int32 {
  var status: Int32 = 0
  var result: pid_t = 0
  repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
  if result < 0 { return -1 }
  let exited = (status & 0x7f) == 0
  return exited ? (status >> 8) & 0xff : -1
}

/// One-shot flag telling a drain thread to give up. Bun calls `destroy()` on
/// the streams; a blocking `read` cannot be interrupted that way, so the drain
/// polls and checks this instead — otherwise a descendant holding the pipe
/// would strand a thread for the lifetime of the server.
final class DrainStop: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
  }
}

/// Drains one pipe to EOF on its own thread and closes it. Draining is not
/// optional: an undrained stderr fills its buffer and wedges the child until
/// the timeout, which would turn every noisy command into a 10 second stall.
func startDrain(
  descriptor: Int32, stop: DrainStop, group: DispatchGroup?,
  sink: @escaping @Sendable (Data) -> Void
) {
  group?.enter()
  let thread = Thread {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = withUnsafeMutablePointer(to: &descriptors) { poll($0, 1, 200) }
      if ready < 0 {
        if errno == EINTR { continue }
        break
      }
      if ready == 0 {
        if stop.isStopped { break }
        continue
      }
      let count = buffer.withUnsafeMutableBytes { raw -> Int in
        read(descriptor, raw.baseAddress, raw.count)
      }
      if count > 0 {
        sink(Data(buffer[0..<count]))
        continue
      }
      if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
      break
    }
    close(descriptor)
    group?.leave()
  }
  thread.stackSize = 512 * 1024
  thread.start()
}

/// Blocking — call it on `herdrRunQueue`, never on the caller's thread.
private func runProcess(
  binary: String, args: [String], environment: [String: String]?, timeout: TimeInterval,
  timeoutMessage: String, state: RunState
) -> Result<String, BackendError> {
  guard let executable = resolveExecutable(binary, environment: environment) else {
    return .failure(backendError("herdr command failed"))
  }
  let stop = DrainStop()
  guard let child = spawnChild(executable: executable, args: args, environment: environment) else {
    return .failure(backendError("herdr command failed"))
  }
  state.attach(pid: child.pid)

  let group = DispatchGroup()
  startDrain(descriptor: child.stdout, stop: stop, group: group) { state.appendStdout($0) }
  startDrain(descriptor: child.stderr, stop: stop, group: group) { state.countStderr($0) }

  let timer = DispatchSource.makeTimerSource(queue: herdrTimerQueue)
  timer.schedule(deadline: .now() + max(timeout, 0))
  timer.setEventHandler { state.fail(timeoutMessage) }
  timer.resume()

  let exitCode = waitForExit(child.pid)
  timer.cancel()

  // A descendant that inherited the pipe can hold it open after the child is
  // gone; bound that wait rather than hanging on it, then release the readers.
  if group.wait(timeout: .now() + 1) == .timedOut {
    state.fail("herdr output pipes did not close")
    stop.stop()
  }

  if let failure = state.failure { return .failure(backendError(failure)) }
  if exitCode != 0 { return .failure(backendError("herdr command failed")) }
  return .success(state.text())
}

/// `runHerdr(binary, args, signal, env)`: one bounded subprocess under an
/// operation's deadline, killed on task cancellation.
func runCommand(
  binary: String, args: [String], environment: [String: String]? = nil, op: HerdrOp
) async throws -> String {
  if op.aborted { throw backendError("herdr operation aborted") }
  let remaining = op.remaining
  // The operation deadline was armed first, so it is what actually fires;
  // the flat 10s command timer only matters if the two ever diverge.
  let timeout = min(10, remaining)
  let message = remaining < 10 ? "herdr operation aborted" : "herdr command timed out"
  let state = RunState()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      herdrRunQueue.async {
        continuation.resume(
          with: runProcess(
            binary: binary, args: args, environment: environment, timeout: timeout,
            timeoutMessage: message, state: state))
      }
    }
  } onCancel: {
    state.fail("herdr operation aborted")
  }
}

/// `spawn("sh", ["-c", line], { stdio: "ignore", detached })`, waited to exit
/// or killed (whole group) at `deadline`. Nothing it prints is captured — a
/// hook is a trusted operator command, not a data source. Failures to spawn
/// are silent, as `child.on("error", () => {})` makes them.
func runShellLine(_ line: String, environment: [String: String], deadline: Date) async {
  guard let executable = resolveExecutable("sh", environment: environment),
    let child = spawnChild(
      executable: executable, args: ["-c", line], environment: environment, pipeStdin: false,
      pipeOutput: false)
  else { return }
  let state = RunState()
  state.attach(pid: child.pid)
  let timer = DispatchSource.makeTimerSource(queue: herdrTimerQueue)
  timer.schedule(deadline: .now() + max(deadline.timeIntervalSinceNow, 0))
  timer.setEventHandler { state.fail("hook budget elapsed") }
  timer.resume()
  await withTaskCancellationHandler {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      herdrRunQueue.async {
        _ = waitForExit(child.pid)
        // Bun kills the group again on close, so a hook's own background
        // children never outlive the hook.
        killGroup(child.pid)
        continuation.resume()
      }
    }
  } onCancel: {
    state.fail("hook aborted")
  }
  timer.cancel()
}
