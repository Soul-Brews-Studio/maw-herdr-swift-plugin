import Foundation

// Node's `path` (posix) and the handful of `fs` calls the Bun modules lean on,
// spelled out so their edge cases match rather than Foundation's.
//
// `NSString.standardizingPath` resolves symlinks while collapsing `..`, and
// `URL.resolvingSymlinksInPath` drops `/private` on macOS; neither is
// `path.resolve`, which is purely lexical. Every path comparison on the wake
// and inbox paths is a string comparison against `realpathSync`, so lexical
// and physical resolution have to be the same two operations Node performs.

enum NodePath {
  static func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") }

  /// `path.normalize`: collapse `//`, resolve `.` and `..` lexically, keep a
  /// trailing slash, and keep leading `..` on a relative path.
  static func normalize(_ path: String) -> String {
    if path.isEmpty { return "." }
    let absolute = path.hasPrefix("/")
    let trailing = path.hasSuffix("/")
    var kept: [String] = []
    for segment in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
      if segment == "." { continue }
      if segment == ".." {
        if let last = kept.last, last != ".." {
          kept.removeLast()
        } else if !absolute {
          kept.append("..")
        }
        continue
      }
      kept.append(segment)
    }
    var result = kept.joined(separator: "/")
    if result.isEmpty && !absolute { result = "." }
    if trailing && !result.isEmpty { result += "/" }
    return absolute ? "/" + result : result
  }

  static func join(_ parts: String...) -> String {
    let joined = parts.filter { !$0.isEmpty }.joined(separator: "/")
    return joined.isEmpty ? "." : normalize(joined)
  }

  /// `path.resolve`: right to left until an absolute segment, else cwd first;
  /// normalised, trailing slash removed.
  static func resolve(_ parts: String...) -> String {
    var resolved = ""
    for part in parts.reversed() where !part.isEmpty {
      resolved = resolved.isEmpty ? part : part + "/" + resolved
      if part.hasPrefix("/") { break }
    }
    if !resolved.hasPrefix("/") {
      let cwd = FileManager.default.currentDirectoryPath
      resolved = resolved.isEmpty ? cwd : cwd + "/" + resolved
    }
    var result = normalize(resolved)
    if result.count > 1 && result.hasSuffix("/") { result.removeLast() }
    return result
  }

  static func dirname(_ path: String) -> String {
    if path.isEmpty { return "." }
    var trimmed = path
    while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let slash = trimmed.lastIndex(of: "/") else { return "." }
    if slash == trimmed.startIndex { return "/" }
    var head = String(trimmed[trimmed.startIndex..<slash])
    while head.count > 1 && head.hasSuffix("/") { head.removeLast() }
    return head.isEmpty ? "/" : head
  }

  static func basename(_ path: String) -> String {
    var trimmed = path
    while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
    if trimmed == "/" { return "" }
    guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
    return String(trimmed[trimmed.index(after: slash)...])
  }

  /// `path.relative(from, to)` for two absolute paths.
  static func relative(_ from: String, _ to: String) -> String {
    let source = resolve(from).split(separator: "/", omittingEmptySubsequences: true)
    let destination = resolve(to).split(separator: "/", omittingEmptySubsequences: true)
    var common = 0
    while common < source.count && common < destination.count && source[common] == destination[common] {
      common += 1
    }
    let up = Array(repeating: "..", count: source.count - common)
    let down = destination[common...].map(String.init)
    return (up + down).joined(separator: "/")
  }

  /// `relative(root, value)` does not escape `root`: the `within` helper the
  /// worktree and team readers share.
  static func within(_ root: String, _ value: String) -> Bool {
    let child = relative(root, value)
    return child != ".." && !child.hasPrefix("../") && !isAbsolute(child)
  }
}

// MARK: - fs

struct FileStat {
  let mode: mode_t
  let size: Int
  let ino: ino_t
  let dev: dev_t

  init(_ status: stat) {
    mode = status.st_mode
    size = Int(status.st_size)
    ino = status.st_ino
    dev = status.st_dev
  }

  var isFile: Bool { (mode & S_IFMT) == S_IFREG }
  var isDirectory: Bool { (mode & S_IFMT) == S_IFDIR }
  var isSymbolicLink: Bool { (mode & S_IFMT) == S_IFLNK }
}

struct FileError: Error {
  let code: Int32
  var isMissing: Bool { code == ENOENT || code == ENOTDIR }
}

func lstatPath(_ path: String) throws -> FileStat {
  var status = stat()
  guard lstat(path, &status) == 0 else { throw FileError(code: errno) }
  return FileStat(status)
}

func statPath(_ path: String) throws -> FileStat {
  var status = stat()
  guard stat(path, &status) == 0 else { throw FileError(code: errno) }
  return FileStat(status)
}

func fstatDescriptor(_ descriptor: Int32) throws -> FileStat {
  var status = stat()
  guard fstat(descriptor, &status) == 0 else { throw FileError(code: errno) }
  return FileStat(status)
}

/// `fs.realpathSync`: the physical path, or a throw for anything missing.
func realPath(_ path: String) throws -> String {
  guard let resolved = realpath(path, nil) else { throw FileError(code: errno) }
  defer { free(resolved) }
  return String(cString: resolved)
}

func pathExists(_ path: String) -> Bool {
  (try? statPath(path)) != nil
}

/// `opendirSync` + `readSync` to exhaustion: every entry name except `.`/`..`.
func directoryEntries(_ path: String) throws -> [String] {
  guard let handle = opendir(path) else { throw FileError(code: errno) }
  defer { closedir(handle) }
  var names: [String] = []
  while let entry = readdir(handle) {
    let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    if name == "." || name == ".." { continue }
    names.append(name)
  }
  return names
}

/// `openSync(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)` then `fstatSync`: the
/// descriptor and what it actually points at, so a path can be checked for
/// identity against an earlier `lstat` before a byte is read.
func openNoFollow(_ path: String) throws -> (descriptor: Int32, stat: FileStat) {
  let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
  guard descriptor >= 0 else { throw FileError(code: errno) }
  do {
    return (descriptor, try fstatDescriptor(descriptor))
  } catch {
    close(descriptor)
    throw error
  }
}

/// Reads at most `limit + 1` bytes so the caller can tell "exactly limit"
/// from "more than limit", which is how every bounded reader on the Bun side
/// distinguishes them.
func readDescriptor(_ descriptor: Int32, upTo capacity: Int) throws -> Data {
  var buffer = [UInt8](repeating: 0, count: capacity)
  var length = 0
  while length < capacity {
    let count = buffer.withUnsafeMutableBytes { raw -> Int in
      read(descriptor, raw.baseAddress!.advanced(by: length), capacity - length)
    }
    if count < 0 {
      if errno == EINTR { continue }
      throw FileError(code: errno)
    }
    if count == 0 { break }
    length += count
  }
  return Data(buffer[0..<length])
}

/// `new TextDecoder('utf-8', {fatal: true}).decode(bytes)` — nil on any
/// malformed sequence. `ignoreBOM: true` on the Bun side means a leading BOM
/// is kept, so it is kept here too and fails JSON parsing the same way.
func strictUTF8(_ data: Data) -> String? {
  String(data: data, encoding: .utf8)
}

/// JavaScript `String.prototype.trim`: WhiteSpace + LineTerminator + BOM.
private let jsTrimSet = Set<Unicode.Scalar>([
  "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}", "\u{00A0}", "\u{1680}",
  "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}",
  "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}",
  "\u{FEFF}",
])

/// Unicode `White_Space` — what `\p{White_Space}` matches. Same as the trim set
/// minus the BOM.
let unicodeWhiteSpace = Set<Unicode.Scalar>([
  "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}", "\u{0085}", "\u{00A0}",
  "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}",
  "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}",
  "\u{3000}",
])

func jsTrim(_ text: String) -> String {
  trimScalars(text, in: jsTrimSet)
}

/// `value.replace(/^\p{White_Space}+|\p{White_Space}+$/gu, '')`.
func whiteSpaceTrim(_ text: String) -> String {
  trimScalars(text, in: unicodeWhiteSpace)
}

private func trimScalars(_ text: String, in set: Set<Unicode.Scalar>) -> String {
  let scalars = Array(text.unicodeScalars)
  var start = 0
  var end = scalars.count
  while start < end, set.contains(scalars[start]) { start += 1 }
  while end > start, set.contains(scalars[end - 1]) { end -= 1 }
  var result = String.UnicodeScalarView()
  for scalar in scalars[start..<end] { result.append(scalar) }
  return String(result)
}

/// `Buffer.byteLength(text)`.
func byteLength(_ text: String) -> Int { text.utf8.count }

/// JS string comparison — UTF-16 code unit order — for `a < b ? -1 : …` sorts.
func jsLess(_ left: String, _ right: String) -> Bool {
  Array(left.utf16).lexicographicallyPrecedes(Array(right.utf16))
}

/// `Buffer.compare(Buffer.from(a), Buffer.from(b))` — byte order.
func bytesLess(_ left: String, _ right: String) -> Bool {
  Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
}

/// `/[\x00-\x1f\x7f-\x9f]/` and friends.
func containsScalar(_ text: String, where predicate: (Unicode.Scalar) -> Bool) -> Bool {
  text.unicodeScalars.contains(where: predicate)
}

func isControlC0(_ scalar: Unicode.Scalar) -> Bool { scalar.value < 0x20 || scalar.value == 0x7F }
func isControlC0C1(_ scalar: Unicode.Scalar) -> Bool {
  scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
}

/// `process.env` as Node sees it.
var processEnvironment: [String: String] { ProcessInfo.processInfo.environment }

/// `os.homedir()`: `$HOME` when set, else the account's directory.
func homeDirectory() -> String {
  if let home = processEnvironment["HOME"], !home.isEmpty { return home }
  return NSHomeDirectory()
}

/// The environment `git` is given on the wake and inbox paths: nothing that
/// starts with `GIT_`, plus the three that pin it to a hookless, promptless,
/// config-free run.
func gitEnvironment() -> [String: String] {
  var environment = processEnvironment.filter { !$0.key.hasPrefix("GIT_") }
  environment["GIT_CONFIG_NOSYSTEM"] = "1"
  environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
  environment["GIT_TERMINAL_PROMPT"] = "0"
  return environment
}
