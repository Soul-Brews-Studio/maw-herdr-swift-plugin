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

/// Path plus only the query keys that cannot carry a credential. Anything
/// dropped is marked with "…" so the log admits it is incomplete.
func safeTarget(path: String, query: [String: String]) -> String {
  let kept = query.filter { safeQueryKeys.contains($0.key) }.sorted { $0.key < $1.key }
  let dropped = query.keys.contains { !safeQueryKeys.contains($0) }
  var components = URLComponents()
  components.queryItems = kept.isEmpty ? nil : kept.map { URLQueryItem(name: $0.key, value: $0.value) }
  let encoded = components.percentEncodedQuery ?? ""
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
