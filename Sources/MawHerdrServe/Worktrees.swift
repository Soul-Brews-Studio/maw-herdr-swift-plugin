import Foundation

// Port of mod.serveWorktrees.ts: `GET /api/worktrees` lists the worktrees of
// the repository the server was started in, and `POST /api/worktrees/cleanup`
// removes ONE of them — the only route on either server that deletes anything.
//
// The reference wraps the whole handler in one `try { … } catch { throw new
// HTTPError(cleanup ? 400 : 500, …) }`, so every failure — a `readJSON` 415,
// an oversized body, a herdr outage while checking for active panes, a git
// error — collapses to the same two answers: `500 worktrees_unavailable` for
// the listing, `400 worktree_cleanup_rejected` for the removal. Reproduced
// here rather than "improved": a cleanup with the wrong Content-Type is 400,
// not 415, on both servers (measured 2026-09-22 against the reference on
// 3497 with a scratch repository; see utils/conformance.mjs, phase 6).

private struct WorktreeEntry {
  var path: String
  var branch: String
  var prunable: Bool
}

private struct WorktreeFailure: Error {}

/// `safe(value)`: non-empty, no surrounding whitespace, no leading dash, no
/// C0/C1 control or DEL.
private func worktreeSafe(_ value: String) -> Bool {
  !value.isEmpty && jsTrim(value) == value && !value.hasPrefix("-") && !containsScalar(value, where: isControlC0C1)
}

/// `canonical(value)`: `realpathSync`, or the value itself when that throws.
private func worktreeCanonical(_ value: String) -> String { (try? realPath(value)) ?? value }

/// `git worktree list --porcelain -z`, parsed exactly as the reference parses
/// it: groups end in `\0\0`, at most 128 of them, each opening with a
/// `worktree <absolute path>` record no other group repeats.
private func scanWorktrees(root: String, op: HerdrOp) async throws -> [WorktreeEntry] {
  let raw = try await runGit(root, ["worktree", "list", "--porcelain", "-z"], op: op)
  guard raw.hasSuffix("\0\0") else { throw WorktreeFailure() }
  let groups = String(raw.dropLast(2)).components(separatedBy: "\0\0")
  if groups.count > 128 { throw WorktreeFailure() }
  var seen = Set<String>()
  var entries: [WorktreeEntry] = []
  for group in groups {
    let lines = group.components(separatedBy: "\0")
    guard let first = lines.first, first.hasPrefix("worktree ") else { throw WorktreeFailure() }
    let original = String(first.dropFirst("worktree ".count))
    guard NodePath.isAbsolute(original), !seen.contains(original) else { throw WorktreeFailure() }
    seen.insert(original)
    // `lines.find(startsWith('branch '))?.slice(7).replace(/^refs\/heads\//, '') || 'unknown'`
    // — a detached worktree has no branch record and reports "unknown".
    var branch = "unknown"
    if let record = lines.first(where: { $0.hasPrefix("branch ") }) {
      var name = String(record.dropFirst("branch ".count))
      if name.hasPrefix("refs/heads/") { name.removeFirst("refs/heads/".count) }
      if !name.isEmpty { branch = name }
    }
    let prunable = lines.contains { $0 == "prunable" || $0.hasPrefix("prunable ") }
    entries.append(
      WorktreeEntry(
        path: worktreeCanonical(original), branch: worktreeSafe(branch) ? branch : "unknown", prunable: prunable))
  }
  return entries
}

/// `serveWorktrees(request, path, config.worktreeRoot, backend, signal)`.
/// `readBody` is the route's `readJSON(request, 8192, signal)`, deferred so its
/// 415/400 land inside the same catch-all they land in on the reference.
func serveWorktrees(
  cleanup: Bool, startupRoot: String, readBody: () throws -> JSONValue,
  sessions: () async throws -> [Session], op: HerdrOp
) async throws -> JSONValue {
  do {
    guard worktreeSafe(startupRoot) else { throw WorktreeFailure() }
    if !cleanup {
      if !pathExists(NodePath.join(startupRoot, ".git")) { return .array([]) }
      let entries = try await scanWorktrees(root: startupRoot, op: op)
      let rootName = NodePath.basename(startupRoot)
      let rows = entries.map { entry -> (path: String, value: JSONValue) in
        let base = NodePath.basename(entry.path)
        let repo = worktreeSafe(base) ? base : "worktree"
        let mainRepo = worktreeSafe(rootName) ? rootName : repo
        // `repo.indexOf('.wt-')`: a `<main>.wt-<name>` sibling checkout is
        // published under `<name>`; anything else keeps its whole basename.
        let name = repo.range(of: ".wt-").map { String(repo[$0.upperBound...]) } ?? repo
        return (
          entry.path,
          jsonObject([
            ("path", .string(entry.path)), ("branch", .string(entry.branch)), ("repo", .string(repo)),
            ("mainRepo", .string(mainRepo)), ("name", .string(name)),
            ("status", .string(entry.prunable ? "orphan" : "stale")),
          ])
        )
      }
      return .array(rows.sorted { jsLess($0.path, $1.path) }.map(\.value))
    }

    let body = try readBody()
    guard let object = body.object, object.count == 1, let raw = object["path"]?.string else {
      throw WorktreeFailure()
    }
    guard NodePath.isAbsolute(raw), worktreeSafe(raw) else { throw WorktreeFailure() }
    // `raw.split(/[\/\\]/)`: a backslash separates segments too, so `\..` is
    // as much a traversal as `/..`.
    let segments = raw.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "\\" }.map(String.init)
    if segments.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix("-") }) { throw WorktreeFailure() }
    let root = try realPath(startupRoot)
    let target = try realPath(raw)
    let parent = NodePath.dirname(root)
    func validate() async throws {
      let entries = try await scanWorktrees(root: startupRoot, op: op)
      let again = try realPath(raw)
      if target == root || target == entries.first?.path || !NodePath.within(parent, target)
        || !pathExists(NodePath.join(target, ".git")) || !entries.contains(where: { $0.path == target })
        || again != target
      {
        throw WorktreeFailure()
      }
    }
    try await validate()
    // A pane whose cwd sits inside the worktree is using it: refuse. A pane
    // whose cwd is relative cannot be placed at all: refuse that too.
    for session in try await sessions() {
      for window in session.windows {
        guard let cwd = window.cwd, !cwd.isEmpty else { continue }
        if !NodePath.isAbsolute(cwd) { throw WorktreeFailure() }
        if NodePath.within(target, worktreeCanonical(NodePath.resolve(cwd))) { throw WorktreeFailure() }
      }
    }
    try await validate()
    let output = jsTrim(try await runGit(startupRoot, ["worktree", "remove", "--", target], op: op))
    return jsonObject([
      ("ok", .bool(true)), ("path", .string(target)),
      ("log", .array(output.isEmpty ? [] : [.string(output)])),
    ])
  } catch {
    throw HTTPStatusError(
      status: cleanup ? 400 : 500, code: cleanup ? "worktree_cleanup_rejected" : "worktrees_unavailable")
  }
}
