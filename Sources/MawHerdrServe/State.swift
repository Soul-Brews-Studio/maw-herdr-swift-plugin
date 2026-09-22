import Foundation

// `mod.serveState.ts`: the dashboard's `/api/asks` and `/api/ui-state`
// scratch state, a pure file reader/writer with a hard shape contract. The
// peer list `/api/config` falls back to lives in Federation.swift with the
// rest of the federation surface.

// MARK: - /api/asks and /api/ui-state (mod.serveState.ts)

private let stateLimit = 256 << 10

/// GET. A missing file is not an error: asks answer `[]` and ui-state `{}`,
/// exactly as Bun's ENOENT branch does. Every other failure — a symlink, a
/// directory, an oversized or non-UTF-8 file, malformed JSON, or the wrong
/// top-level shape — is `state_read_failed`, never a partial read.
func readStateFile(directory: String, asks: Bool) throws -> JSONValue {
  guard !directory.isEmpty else { throw HTTPStatusError(status: 503, code: "state_directory_required") }
  let path = NodePath.join(directory, asks ? "asks.json" : "ui-state.json")

  var parsed: JSONValue
  do {
    let (descriptor, stat) = try openNoFollow(path)
    defer { close(descriptor) }
    guard stat.isFile, stat.size <= stateLimit else { throw HTTPStatusError(status: 500, code: "state_read_failed") }
    let bytes = try readDescriptor(descriptor, upTo: stateLimit + 1)
    guard bytes.count <= stateLimit else { throw HTTPStatusError(status: 500, code: "state_read_failed") }
    // `new TextDecoder('utf-8', {fatal: true, ignoreBOM: true})` — a leading
    // BOM is KEPT, so a BOM-prefixed state file fails JSON.parse on both
    // servers rather than silently loading.
    guard let text = strictUTF8(bytes), let value = try? parseJSON(text) else {
      throw HTTPStatusError(status: 500, code: "state_read_failed")
    }
    parsed = value
  } catch let failure as HTTPStatusError {
    throw failure
  } catch let error as FileError where error.code == ENOENT {
    return asks ? .array([]) : jsonObject([])
  } catch {
    throw HTTPStatusError(status: 500, code: "state_read_failed")
  }

  guard stateShapeValid(parsed, asks: asks) else { throw HTTPStatusError(status: 500, code: "state_read_failed") }
  return parsed
}

/// POST. `wx` on a random temporary name, then `rename` — so a reader either
/// sees the old file or the new one, never a half-written one.
func writeStateFile(directory: String, asks: Bool, value: JSONValue) throws -> JSONValue {
  guard !directory.isEmpty else { throw HTTPStatusError(status: 503, code: "state_directory_required") }
  guard stateShapeValid(value, asks: asks) else { throw HTTPStatusError(status: 400, code: "state_shape_invalid") }
  let path = NodePath.join(directory, asks ? "asks.json" : "ui-state.json")
  // `randomBytes(16).toString('hex')` — the temporary name only has to be
  // unguessable enough that two concurrent writers cannot collide on it.
  let random = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
  let temporary = NodePath.join(directory, ".state-" + random)

  defer { unlink(temporary) }
  do {
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw HTTPStatusError(status: 500, code: "state_write_failed") }
    let payload = Array(jsonStringify(value).utf8)
    var written = 0
    while written < payload.count {
      let count = payload.withUnsafeBytes { raw -> Int in
        write(descriptor, raw.baseAddress!.advanced(by: written), payload.count - written)
      }
      if count < 0 {
        if errno == EINTR { continue }
        close(descriptor)
        throw HTTPStatusError(status: 500, code: "state_write_failed")
      }
      written += count
    }
    close(descriptor)
    guard rename(temporary, path) == 0 else { throw HTTPStatusError(status: 500, code: "state_write_failed") }
  } catch let failure as HTTPStatusError {
    throw failure
  } catch {
    throw HTTPStatusError(status: 500, code: "state_write_failed")
  }
  return jsonObject([("ok", .bool(true))])
}

/// `asks` must be an array; `ui-state` must be a non-array object. Anything
/// else is a shape error on the way in AND on the way out.
private func stateShapeValid(_ value: JSONValue, asks: Bool) -> Bool {
  asks ? value.array != nil : value.object != nil
}
