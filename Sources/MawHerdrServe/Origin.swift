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
  // Bun re-parses with new URL() to reject a syntactically invalid authority.
  guard origin.range(of: pattern, options: .regularExpression) != nil,
        let url = URL(string: origin), let host = url.host else { return .refused }
  if builtinOrigins.contains(origin) || allowed.contains(origin) || isLoopbackHost(host) {
    return .allowed(origin)
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
