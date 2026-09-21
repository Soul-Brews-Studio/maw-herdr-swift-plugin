import Foundation

// Port of mod.accessLog.ts: one nginx-shaped line per request, written to
// stderr the moment the response is decided rather than buffered.
//
// Secrets never reach it. The query string is dropped except for a small
// allowlist of harmless keys, and no header is ever printed — an operator
// token arrives in Authorization and a socket ticket in Sec-WebSocket-Protocol,
// so printing either class would leak the credential into a scrollback that
// outlives the process.

private let safeQueryKeys: Set<String> = ["target", "lines", "since", "limit"]

private let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

func accessStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = timeZone
  let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
  let pad = { (value: Int?) in String(format: "%02d", value ?? 0) }
  let offset = timeZone.secondsFromGMT(for: date)
  let sign = offset >= 0 ? "+" : "-"
  let absolute = abs(offset) / 60
  return "\(pad(parts.day))/\(months[(parts.month ?? 1) - 1])/\(parts.year ?? 0)"
    + ":\(pad(parts.hour)):\(pad(parts.minute)):\(pad(parts.second))"
    + " \(sign)\(pad(absolute / 60))\(pad(absolute % 60))"
}

/// `URLSearchParams.toString()` — the application/x-www-form-urlencoded
/// serializer: `*-._` and alphanumerics pass, space becomes `+`, every other
/// UTF-8 byte is `%XX` in upper-case hex. `URLComponents.percentEncodedQuery`
/// leaves `:` and `/` alone, which is how `target=nope:0` used to reach the log
/// where Bun writes `target=nope%3A0`.
func formURLEncode(_ text: String) -> String {
  var out = ""
  for byte in text.utf8 {
    switch byte {
    case 0x20: out += "+"
    case UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
      UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
      UInt8(ascii: "a")...UInt8(ascii: "z"):
      out.unicodeScalars.append(Unicode.Scalar(byte))
    default:
      out += String(format: "%%%02X", byte)
    }
  }
  return out
}

/// Path plus only the query keys that cannot carry a credential, in arrival
/// order with repeats kept, as `url.searchParams.entries()` yields them.
/// Anything dropped is marked with "…" so the log admits it is incomplete.
func safeTarget(path: String, query: [(name: String, value: String)]) -> String {
  let kept = query.filter { safeQueryKeys.contains($0.name) }
  let dropped = query.contains { !safeQueryKeys.contains($0.name) }
  let encoded = kept.map { formURLEncode($0.name) + "=" + formURLEncode($0.value) }.joined(separator: "&")
  var result = path
  if !encoded.isEmpty { result += "?\(encoded)" }
  if dropped { result += encoded.isEmpty ? "?…" : "&…" }
  return result
}

func formatAccess(_ entry: AccessEntry, at date: Date) -> String {
  let size = entry.bytes.map(String.init) ?? "-"
  let origin = entry.origin.isEmpty ? "" : " \"\(entry.origin)\""
  let note = entry.note.map { " \($0)" } ?? ""
  let ip = entry.ip.isEmpty ? "-" : entry.ip
  return "\(ip) [\(accessStamp(date))] \"\(entry.method) \(safeTarget(path: entry.path, query: entry.query))\" "
    + "\(entry.status) \(size) \(Int(entry.milliseconds.rounded()))ms\(origin)\(note)"
}

final class AccessLog: @unchecked Sendable {
  private let enabled: Bool
  private let lock = NSLock()

  init(enabled: Bool) { self.enabled = enabled }

  func record(_ entry: AccessEntry) {
    guard enabled else { return }
    let line = formatAccess(entry, at: Date()) + "\n"
    // Straight to the descriptor, under a lock so two connections cannot
    // interleave halves of a line. A closed pipe must never kill the server.
    lock.lock(); defer { lock.unlock() }
    if let data = line.data(using: .utf8) {
      FileHandle.standardError.write(data)
    }
  }
}
