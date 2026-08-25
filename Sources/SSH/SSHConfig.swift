import Foundation

/// One resolved host from an `ssh_config`.
///
/// "Resolved" means wildcard blocks have already been folded in: a config of
///
///     Host *
///       User deploy
///     Host web-01
///       Hostname 10.0.0.4
///
/// yields `web-01` with `user == "deploy"`, which is what `ssh web-01`
/// actually does. Conterm's Mac parser skipped this because it only ever
/// needed the alias to hand to `/usr/bin/ssh`, which did its own resolution.
/// Here nothing else will do it for us.
struct SSHConfigHost: Identifiable, Hashable, Sendable {
    var id: String { alias }
    let alias: String
    let hostname: String?
    let port: Int?
    let user: String?
    /// `IdentityFile` entries in the order they appear. Paths are left as
    /// written — they name files on the machine that wrote the config, which
    /// is not this one, so they're a hint for matching an imported key rather
    /// than something to open.
    let identityFiles: [String]
    /// `ProxyJump`, verbatim. May be a comma-separated chain and may name
    /// aliases from this same config.
    let proxyJump: String?
}

/// Parser for OpenSSH client config files.
///
/// The Mac app read `~/.ssh/config` directly. iOS apps have no such file and
/// no user shell, so a config arrives as *text* — pasted, imported from
/// Files, or synced from iCloud Drive — and `Include` can only be followed
/// when we were handed a directory to resolve against.
enum SSHConfig {

    // MARK: - Entry points

    /// Parse config text. `baseDirectory`, when given, is what relative
    /// `Include` paths resolve against (the directory the file came from,
    /// standing in for `~/.ssh`). Without it, includes are recorded as
    /// unresolved rather than silently dropped.
    static func parse(_ text: String, baseDirectory: URL? = nil) -> Result {
        var visited = Set<String>()
        var blocks: [Block] = []
        var unresolved: [String] = []
        parse(text: text,
              baseDirectory: baseDirectory,
              visited: &visited,
              blocks: &blocks,
              unresolvedIncludes: &unresolved)
        return .init(hosts: resolve(blocks), unresolvedIncludes: unresolved)
    }

    /// Parse a config file on disk, following `Include` relative to its own
    /// directory. Used for a file the user imported into the app's container.
    static func parse(fileAt url: URL) -> Result {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .init(hosts: [], unresolvedIncludes: [])
        }
        var visited = Set<String>([url.standardizedFileURL.path])
        var blocks: [Block] = []
        var unresolved: [String] = []
        parse(text: text,
              baseDirectory: url.deletingLastPathComponent(),
              visited: &visited,
              blocks: &blocks,
              unresolvedIncludes: &unresolved)
        return .init(hosts: resolve(blocks), unresolvedIncludes: unresolved)
    }

    struct Result: Sendable {
        /// Concrete (non-wildcard) hosts, alphabetical, deduped by alias.
        let hosts: [SSHConfigHost]
        /// `Include` directives we could not follow, so the import screen can
        /// say "3 includes were skipped" instead of quietly losing hosts.
        let unresolvedIncludes: [String]
    }

    // MARK: - Blocks

    /// One `Host` stanza: the patterns it applies to and the settings under
    /// it. Wildcard stanzas are kept — they contribute defaults.
    private struct Block {
        var patterns: [String] = []
        var settings: [String: [String]] = [:]

        mutating func set(_ key: String, _ values: [String]) {
            // First obtained value wins, per ssh_config(5). Within one block
            // that means a repeated keyword keeps its first appearance —
            // except IdentityFile, which accumulates.
            if key == "identityfile" {
                settings[key, default: []].append(contentsOf: values)
            } else if settings[key] == nil {
                settings[key] = values
            }
        }
    }

    private static func parse(text: String,
                              baseDirectory: URL?,
                              visited: inout Set<String>,
                              blocks: inout [Block],
                              unresolvedIncludes: inout [String]) {
        var current = Block(patterns: ["*"])
        var started = false
        // `Match` blocks are conditional on runtime state we don't have
        // (originalhost, exec, final). Swallow their contents rather than
        // attributing them to the previous Host, which would be wrong.
        var inMatch = false

        func flush() {
            if started && !current.settings.isEmpty { blocks.append(current) }
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            guard let (field, values) = splitDirective(line) else { continue }

            switch field {
            case "host":
                flush()
                current = Block(patterns: values)
                started = true
                inMatch = false

            case "match":
                flush()
                started = false
                inMatch = true

            case "include":
                if inMatch { continue }
                for pattern in values {
                    follow(include: pattern,
                           baseDirectory: baseDirectory,
                           visited: &visited,
                           blocks: &blocks,
                           unresolvedIncludes: &unresolvedIncludes,
                           // An include inside a Host block belongs to that
                           // block; at top level it stands alone.
                           inheritedPatterns: started ? current.patterns : nil)
                }

            default:
                if inMatch { continue }
                if !started {
                    // Settings before any Host line are global defaults,
                    // equivalent to `Host *`.
                    current = Block(patterns: ["*"])
                    started = true
                }
                current.set(field, values)
            }
        }
        flush()
    }

    private static func follow(include pattern: String,
                               baseDirectory: URL?,
                               visited: inout Set<String>,
                               blocks: inout [Block],
                               unresolvedIncludes: inout [String],
                               inheritedPatterns: [String]?) {
        // ssh_config resolves a relative Include against ~/.ssh. We have no
        // home directory worth speaking of, so it resolves against whichever
        // directory the config came from — which is the same thing whenever
        // the user imported a real ~/.ssh.
        let expanded = (pattern as NSString).expandingTildeInPath
        let base: URL?
        if expanded.hasPrefix("/") {
            base = nil
        } else {
            base = baseDirectory
        }
        guard base != nil || expanded.hasPrefix("/") else {
            unresolvedIncludes.append(pattern)
            return
        }

        let full = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : base!.appendingPathComponent(expanded)

        // Include takes globs (`Include config.d/*`), which is how most
        // multi-file setups are organised.
        let matches = expand(glob: full)
        if matches.isEmpty {
            unresolvedIncludes.append(pattern)
            return
        }

        for url in matches {
            let key = url.standardizedFileURL.path
            guard visited.insert(key).inserted else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            var nested: [Block] = []
            parse(text: text,
                  baseDirectory: url.deletingLastPathComponent(),
                  visited: &visited,
                  blocks: &nested,
                  unresolvedIncludes: &unresolvedIncludes)

            if let inherited = inheritedPatterns {
                // Settings from a file included inside `Host foo` apply to
                // foo, not to whatever the included file says.
                for var b in nested where b.patterns == ["*"] {
                    b.patterns = inherited
                    blocks.append(b)
                }
                blocks.append(contentsOf: nested.filter { $0.patterns != ["*"] })
            } else {
                blocks.append(contentsOf: nested)
            }
        }
    }

    private static func expand(glob url: URL) -> [URL] {
        let path = url.path
        guard path.contains("*") || path.contains("?") else {
            return FileManager.default.fileExists(atPath: path) ? [url] : []
        }
        let dir = url.deletingLastPathComponent()
        let pattern = url.lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: dir.path) else { return [] }
        return entries
            .filter { matches(pattern: pattern, $0) }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: - Resolution

    /// Fold the wildcard blocks into every concrete alias, first-value-wins
    /// in file order — the same rule `ssh -G` applies.
    private static func resolve(_ blocks: [Block]) -> [SSHConfigHost] {
        // Concrete aliases are the ones a user could actually type. A pattern
        // with a glob or a negation names a class, not a host.
        var aliases: [String] = []
        var seen = Set<String>()
        for block in blocks {
            for p in block.patterns where isConcrete(p) {
                if seen.insert(p).inserted { aliases.append(p) }
            }
        }

        return aliases.map { alias in
            var merged: [String: [String]] = [:]
            for block in blocks where block.patterns.matchAsSSHPatternList(alias) {
                for (k, v) in block.settings {
                    if k == "identityfile" {
                        merged[k, default: []].append(contentsOf: v)
                    } else if merged[k] == nil {
                        merged[k] = v
                    }
                }
            }
            return SSHConfigHost(
                alias: alias,
                hostname: merged["hostname"]?.first,
                port: merged["port"]?.first.flatMap { Int($0) },
                user: merged["user"]?.first,
                identityFiles: merged["identityfile"] ?? [],
                proxyJump: merged["proxyjump"]?.first.flatMap {
                    $0.lowercased() == "none" ? nil : $0
                })
        }
        .sorted { $0.alias.lowercased() < $1.alias.lowercased() }
    }

    private static func isConcrete(_ pattern: String) -> Bool {
        !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!")
    }

    // MARK: - Lexing

    /// Strip a trailing `#` comment, respecting double quotes so a value like
    /// `ProxyCommand "ssh -W %h:%p # gateway"` survives intact.
    private static func stripComment(_ line: String) -> String {
        var out = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" { inQuotes.toggle() }
            if ch == "#" && !inQuotes { break }
            out.append(ch)
        }
        return out
    }

    /// Split `Keyword value value` or `Keyword=value`. The keyword is
    /// case-insensitive per ssh_config(5); values keep their case.
    private static func splitDirective(_ line: String) -> (String, [String])? {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" { inQuotes.toggle(); continue }
            if !inQuotes && (ch == " " || ch == "\t" || ch == "=") {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        guard let head = tokens.first else { return nil }
        return (head.lowercased(), Array(tokens.dropFirst()))
    }

    /// Glob match over `*` and `?`, the only metacharacters ssh patterns use.
    static func matches(pattern: String, _ candidate: String) -> Bool {
        let p = Array(pattern), c = Array(candidate)
        // Iterative backtracking rather than recursion: a pathological
        // pattern of many stars shouldn't be able to blow the stack from a
        // file the user imported.
        var pi = 0, ci = 0, star = -1, mark = 0
        while ci < c.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == c[ci]) {
                pi += 1; ci += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi; pi += 1; mark = ci
            } else if star >= 0 {
                pi = star + 1; mark += 1; ci = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

private extension Array where Element == String {
    /// An ssh pattern-list matches when at least one positive pattern matches
    /// and no negated one does.
    func matchAsSSHPatternList(_ candidate: String) -> Bool {
        var positive = false
        for pattern in self {
            if pattern.hasPrefix("!") {
                if SSHConfig.matches(pattern: String(pattern.dropFirst()), candidate) {
                    return false
                }
            } else if SSHConfig.matches(pattern: pattern, candidate) {
                positive = true
            }
        }
        return positive
    }
}
