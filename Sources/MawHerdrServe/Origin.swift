import Foundation

// Port of mod.requestOrigin.ts. Loopback pages and the original dashboard are
// allowed without asking; any other site must be named with --allow-origin,
// because an allowed origin can read every pane this server can see.

private let builtinOrigins: Set<String> = ["https://god.buildwithoracle.com"]

enum OriginDecision: Equatable {
  case none                 // no Origin header at all — a non-browser client
  case allowed(String)      // echo back in Access-Control-Allow-Origin
  case refused              // 403 origin_not_allowed
}

func decideOrigin(header: String?, allowed: [String]) -> OriginDecision {
  guard let origin = header else { return .none }
  let pattern = #"^https?://([^/?#\s,@]+)$"#
  guard origin.range(of: pattern, options: .regularExpression) != nil else { return .refused }
  // `loopbackHost(match[1])` — the RAW authority the regex captured, not
  // `new URL(origin).host`. Foundation case-folds and normalises a parsed
  // host, and the reference's predicate is deliberately case-sensitive on
  // `localhost` and deliberately strict on the IPv4 literal. Measured
  // 2026-09-22 against the Bun server on 3497: `http://LOCALHOST:5173` 403,
  // `http://127.0.0.01:5173` 403, `http://[::ffff:127.0.0.1]:5173` 200 — the
  // last is what a dashboard page on a dual-stack socket actually sends, and
  // the pre-fix port answered 403 to it, which is a dead UI.
  // The `^https?://` in the reference has no `i` flag, so the scheme is
  // lower-case or the origin never matched at all.
  let authority: String
  if origin.hasPrefix("https://") {
    authority = String(origin.dropFirst("https://".count))
  } else if origin.hasPrefix("http://") {
    authority = String(origin.dropFirst("http://".count))
  } else {
    return .refused
  }
  if builtinOrigins.contains(origin) || allowed.contains(origin) || loopbackHost(authority) {
    // `try { new URL(origin); return origin; } catch { }`: an authority the
    // URL parser refuses (`http://127.999.1.1:5173`) falls through to the 403.
    if authorityParses(authority) { return .allowed(origin) }
  }
  return .refused
}

/// Exact origins only: no wildcards, no paths, no query. A single trailing
/// slash is accepted because it is what a browser's address bar hands you.
func parseAllowedOrigin(_ value: String) throws -> String {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  // A wildcard silently becomes an entry that can never match a real Origin,
  // so refusing it is the difference between "not supported" and an allowlist
  // the operator believes is working.
  if trimmed.contains("*") {
    throw ConfigError.message("""
      --allow-origin does not support wildcards, got "\(value)"
        name each origin: --allow-origin https://bridge.buildwithoracle.com --allow-origin https://village.buildwithoracle.com
      """)
  }
  let pattern = #"^https?://([^/?#\s,@]+)/?$"#
  guard trimmed.range(of: pattern, options: .regularExpression) != nil,
        let url = URL(string: trimmed), let scheme = url.scheme, let host = url.host else {
    throw ConfigError.message("""
      --allow-origin must be a bare scheme://host[:port], got "\(value)"
        maw herdr-swift serve --insecure-no-token --allow-origin https://bridge.buildwithoracle.com
      """)
  }
  var origin = "\(scheme)://\(host)"
  if let port = url.port { origin += ":\(port)" }
  return origin
}
