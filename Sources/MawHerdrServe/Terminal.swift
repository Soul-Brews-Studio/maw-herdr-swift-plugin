import Foundation

// Port of mod.openHerdrTerminal.ts: one long-lived
// `herdr --session S terminal session control PANE --cols C --rows R` child per
// attached `/ws/pty` client. Its stdout is newline-delimited JSON frames
// (`terminal.frame` with base64 ANSI bytes, or `terminal.closed`); its stdin
// takes `terminal.input` / `terminal.resize` lines. "This controls an existing
// pane; no takeover, shell, or daemon lifecycle commands."
//
// Every bound is the Bun one: 10s until the first frame, 16 MiB/s of output,
// a 4 MiB partial-line buffer, 64 KiB of stderr, 2 MiB per frame, 256 KiB of
// unflushed input. EOF on stdin is the detach; SIGKILL follows 500ms later.

final class HerdrTerminalProcess: HerdrTerminal, @unchecked Sendable {
  private let lock = NSLock()
  private let pid: pid_t
  private var stdinDescriptor: Int32
  private let output: @Sendable (Data) -> Void
  private var stopped = false
  private var exited = false
  private var buffer = Data()
  private var stderrBytes = 0
  private var first = true
  private var epoch = Date()
  private var outputBytes = 0
  private var inputBytes = 0
  private var startTimer: DispatchSourceTimer?
  private var cleanupTimer: DispatchSourceTimer?
  private var doneWaiters: [CheckedContinuation<Void, Never>] = []
  private let writeQueue = DispatchQueue(label: "maw.herdr.terminal.stdin")
  private static let timers = DispatchQueue(label: "maw.herdr.terminal.timers")

  init?(binary: String, target: Target, cols: Int, rows: Int, output: @escaping @Sendable (Data) -> Void) {
    guard let executable = resolveExecutable(binary),
      let child = spawnChild(
        executable: executable,
        args: [
          "--session", target.session, "terminal", "session", "control", target.pane.id, "--cols", String(cols),
          "--rows", String(rows),
        ], pipeStdin: true, pipeOutput: true)
    else { return nil }
    pid = child.pid
    stdinDescriptor = child.stdin
    self.output = output

    let timer = DispatchSource.makeTimerSource(queue: HerdrTerminalProcess.timers)
    timer.schedule(deadline: .now() + 10)
    timer.setEventHandler { [weak self] in self?.close() }
    timer.resume()
    startTimer = timer

    let stop = DrainStop()
    startDrain(descriptor: child.stderr, stop: stop, group: nil) { [weak self] data in
      guard let self else { return }
      self.lock.lock()
      self.stderrBytes += data.count
      let exceeded = self.stderrBytes > 64 * 1024
      self.lock.unlock()
      if exceeded { self.close() }
    }
    startDrain(descriptor: child.stdout, stop: stop, group: nil) { [weak self] data in
      self?.consume(data)
    }
    // `child.on("exit", close)`: the exit itself detaches, and bounds any
    // descendant that kept the output pipes.
    let pid = child.pid
    herdrRunQueue.async { [weak self] in
      _ = waitForExit(pid)
      stop.stop()
      self?.finish()
    }
  }

  private func consume(_ data: Data) {
    lock.lock()
    if stopped {
      lock.unlock()
      return
    }
    let now = Date()
    if now.timeIntervalSince(epoch) >= 1 {
      epoch = now
      outputBytes = 0
    }
    outputBytes += data.count
    if outputBytes > 16 * 1024 * 1024 || buffer.count + data.count > 4 * 1024 * 1024 {
      lock.unlock()
      close()
      return
    }
    buffer.append(data)
    var frames: [Data] = []
    var failed = false
    var closedByPeer = false
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer.subdata(in: buffer.startIndex..<newline)
      buffer = Data(buffer[buffer.index(after: newline)...])
      guard let frame = try? parseJSON(line) else {
        failed = true
        break
      }
      if frame["type"]?.string == "terminal.closed" {
        closedByPeer = true
        break
      }
      guard frame["type"]?.string == "terminal.frame", frame["encoding"]?.string == "ansi",
        let encoded = frame["bytes"]?.string, encoded.utf16.count % 4 == 0,
        let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded,
        bytes.count <= 2 * 1024 * 1024
      else {
        failed = true
        break
      }
      if first {
        first = false
        startTimer?.cancel()
        startTimer = nil
      }
      frames.append(bytes)
    }
    lock.unlock()
    for frame in frames { output(frame) }
    if failed || closedByPeer { close() }
  }

  /// EOF is Herdr detach; never kill the pane or stop its daemon.
  func close() {
    lock.lock()
    if stopped {
      lock.unlock()
      return
    }
    stopped = true
    buffer = Data()
    startTimer?.cancel()
    startTimer = nil
    let timer = DispatchSource.makeTimerSource(queue: HerdrTerminalProcess.timers)
    timer.schedule(deadline: .now() + .milliseconds(500))
    let pid = self.pid
    timer.setEventHandler { killGroup(pid) }
    timer.resume()
    cleanupTimer = timer
    lock.unlock()
    closeStdin()
  }

  /// The descriptor's whole lifetime belongs to `writeQueue`, which is serial:
  /// it is read there and cleared there, so a `write` block can never observe
  /// a number that a `close` block has already handed back to the kernel.
  ///
  /// The shape this replaces read the descriptor under the lock in `write`,
  /// released the lock, and only then enqueued the `Darwin.write`. `close()`
  /// could run entirely inside that window — clearing the field and
  /// enqueueing `Darwin.close(27)` FIRST — so the write landed on a closed,
  /// possibly already-recycled fd, which on this server is the next accepted
  /// client socket. A keystroke frame written into an unrelated connection.
  private func closeStdin() {
    writeQueue.async { [self] in
      lock.lock()
      let descriptor = stdinDescriptor
      stdinDescriptor = -1
      lock.unlock()
      if descriptor >= 0 { Darwin.close(descriptor) }
    }
  }

  private func finish() {
    lock.lock()
    exited = true
    stopped = true
    buffer = Data()
    startTimer?.cancel()
    startTimer = nil
    cleanupTimer?.cancel()
    cleanupTimer = nil
    let waiters = doneWaiters
    doneWaiters = []
    lock.unlock()
    closeStdin()
    for waiter in waiters { waiter.resume() }
  }

  func waitDone() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if exited {
        lock.unlock()
        continuation.resume()
        return
      }
      doneWaiters.append(continuation)
      lock.unlock()
    }
  }

  private func write(_ value: JSONValue) throws {
    let line = jsonStringify(value) + "\n"
    let bytes = Array(line.utf8)
    lock.lock()
    if stopped {
      lock.unlock()
      throw backendError("terminal closed")
    }
    if inputBytes + bytes.count > 256 * 1024 {
      lock.unlock()
      close()
      throw backendError("terminal input overflow")
    }
    inputBytes += bytes.count
    lock.unlock()
    writeQueue.async { [weak self] in
      guard let self else { return }
      // Read the descriptor HERE, on the serial queue that also owns the
      // close, not on the caller's thread before enqueueing.
      self.lock.lock()
      let descriptor = self.stdinDescriptor
      self.lock.unlock()
      var offset = 0
      var failed = descriptor < 0
      while !failed && offset < bytes.count {
        let count = bytes.withUnsafeBytes { raw in
          Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if count < 0 {
          if errno == EINTR { continue }
          failed = true
          break
        }
        offset += count
      }
      self.lock.lock()
      self.inputBytes -= bytes.count
      self.lock.unlock()
      if failed { self.close() }
    }
  }

  func input(_ bytes: Data) throws {
    try write(jsonObject([("type", .string("terminal.input")), ("bytes", .string(bytes.base64EncodedString()))]))
  }

  func resize(cols: Int, rows: Int) throws {
    try write(jsonObject([("type", .string("terminal.resize")), ("cols", .int(cols)), ("rows", .int(rows))]))
  }
}
