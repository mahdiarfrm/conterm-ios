import Foundation

/// The remote half of Agent Center.
///
/// Conterm on macOS reads `~/.claude/projects/<encoded-cwd>/*.jsonl` off the
/// local disk and tails it incrementally, keeping a byte offset per file so a
/// streaming 15 MB transcript isn't re-scanned every tick. Neither half of
/// that ports directly: the files are on the far end of an SSH connection,
/// and there are hundreds of megabytes of them.
///
/// So the work is split at the seam that makes both halves cheap. The remote
/// reads only the bytes appended since last time and emits one short line per
/// assistant message; this side keeps the offsets and does the accumulation.
/// A full first scan of a large host costs a few seconds of its CPU and about
/// a line per turn on the wire; every tick after that is nearly free.
///
/// `awk` rather than python or jq because it is the only thing guaranteed to
/// exist on a box that happens to run Claude Code, and every stage is
/// `|| true`-guarded like `HostProbe`'s collector: a host with no `~/.claude`
/// must produce an empty answer, not a failure.
enum AgentCollector {

    /// Marker the reply must contain, or what came back is a login banner
    /// rather than a result.
    static let marker = "===conterm:agents==="

    /// Transcripts untouched for longer than this are not live agents and are
    /// not worth a host's CPU to re-read.
    static let staleDays = 14

    /// Pulling a string or a number out of a JSONL line, in awk.
    ///
    /// Not a JSON parser and not trying to be — these lines are machine
    /// written with predictable keys, and a real parser in awk would cost
    /// more than it is worth. `jstr` does handle escapes, because a task
    /// description routinely contains quotes.
    private static let jsonHelpers = #"""
        function jstr(s, key,   i, out, c, esc) {
          i = index(s, "\"" key "\":\"")
          if (i == 0) return ""
          i += length(key) + 4
          out = ""; esc = 0
          while (i <= length(s)) {
            c = substr(s, i, 1)
            if (esc) {
              if (c == "n" || c == "t" || c == "r") out = out " "
              else if (c == "u") i += 4
              else out = out c
              esc = 0
            } else if (c == "\\") esc = 1
            else if (c == "\"") break
            else out = out c
            i++
          }
          return out
        }
        function jnum(s, key,   i, out, c) {
          i = index(s, "\"" key "\":")
          if (i == 0) return 0
          i += length(key) + 3
          out = ""
          while (i <= length(s)) {
            c = substr(s, i, 1)
            if (c < "0" || c > "9") break
            out = out c; i++
          }
          return out + 0
        }
    """#

    /// Bytes read from the end of each transcript for the roster pass. Enough
    /// to contain the last few turns on any real session.
    static let summaryTailBytes = 262_144

    /// The fast pass: who is running, on what, and are they waiting on you.
    ///
    /// Reads only the tail of each transcript, so it is bounded no matter how
    /// large the session has grown. This is what paints the screen; the usage
    /// pass below fills in the numbers a moment later. Splitting them is the
    /// difference between a roster in under a second and one in twenty.
    /// - Parameter knownTasks: transcripts whose task this side already
    ///   knows. Finding the task is the expensive part of this pass — a long
    ///   run buries the last prompt under thousands of tool results — and it
    ///   only changes when you type something, which the incremental usage
    ///   pass sees anyway. Skipping it takes a steady-state poll from two
    ///   seconds of the host's CPU to under half of one.
    static func summaryScript(knownTasks: Set<String> = []) -> String {
        let skip = knownTasks
            .filter { !$0.contains("\t") && !$0.contains("\n") }
            .joined(separator: "\n")
        return """
        printf '\(marker)\\n'
        root="$HOME/.claude/projects"
        [ -d "$root" ] || exit 0

        # The most recent thing you actually said. Tool results are the
        # harness answering the agent, not you, so they are filtered out; the
        # content of a real prompt is sometimes a bare string and sometimes a
        # text block, and both shapes occur in the same file.
        KNOWN='\(skip)'
        lastprompt() {
          grep -a '"type":"user"' 2>/dev/null | grep -av '"tool_use_id"' | tail -20 | awk '
        \(jsonHelpers)
            {
              t = jstr($0, "text")
              if (t == "") t = jstr($0, "content")
              if (t != "" \\
                  && substr(t, 1, 1) != "<" \\
                  && index(t, "Caveat:") != 1 \\
                  && index(t, "[Image") != 1 \\
                  && index(t, "[Request interrupted") != 1) task = t
            }
            END { if (task != "") { gsub(/\\t/, " ", task); printf "%s", substr(task, 1, 300) } }
          ' || true
        }

        # Which tmux pane, if any, each agent is sitting in.
        #
        # This is what makes replying possible. Reading transcripts tells you
        # an agent is waiting on you; it gives you no way to answer, because
        # over SSH there is no pty to type into — unless the agent runs under
        # a multiplexer, which is how anyone leaves one running anyway.
        #
        # The match is exact rather than fuzzy: Claude Code names its project
        # directory by replacing every `/` and `.` in the absolute cwd with
        # `-`, so encoding each pane's cwd the same way and comparing strings
        # identifies the pane with no guessing.
        if command -v tmux >/dev/null 2>&1; then
          # printf, because tmux does not interpret \\t in a format string —
          # it would emit the two characters and every field would be one.
          tmux list-panes -a -F "$(printf '#{pane_id}\\t#{pane_current_path}\\t#{pane_current_command}')" \\
            2>/dev/null | awk -F'\\t' '
              NF >= 2 {
                enc = $2
                gsub(/[\\/.]/, "-", enc)
                printf "t\\t%s\\t%s\\t%s\\n", $1, enc, $3
              }
            ' || true
        fi

        for d in "$root"/*/; do
          [ -d "$d" ] || continue
          f=""
          for c in "$d"*.jsonl; do
            [ -f "$c" ] || continue
            if [ -z "$f" ] || [ "$c" -nt "$f" ]; then f="$c"; fi
          done
          [ -n "$f" ] || continue
          [ -n "$(find "$f" -mtime -\(staleDays) -print 2>/dev/null)" ] || continue
          sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
          [ -n "$sz" ] || continue
          printf 'f\\t%s\\t%s\\t%s\\n' "$f" "$sz" "$d"
          tail -c \(summaryTailBytes) "$f" 2>/dev/null | awk '
        \(jsonHelpers)
            {
              line = $0
              b = jstr(line, "gitBranch"); if (b != "") branch = b
              ts = jstr(line, "timestamp"); if (ts != "") last_ts = ts
              # The real working directory, which the project directory name
              # cannot give back: that encoding turns every `/` and `.` into
              # `-`, so `conterm-ios` and `conterm/ios` are the same string.
              w = jstr(line, "cwd"); if (w != "") cwd = w
              if (index(line, "\\"type\\":\\"user\\"")) {
                last_kind = index(line, "\\"tool_use_id\\"") ? "tool_result" : "user"
                next
              }
              if (!index(line, "\\"type\\":\\"assistant\\"")) next
              last_kind = index(line, "\\"type\\":\\"tool_use\\"") ? "tool_use" : "assistant"
              m = jstr(line, "model")
              if (m != "" && substr(m, 1, 1) != "<") model = m
            }
            END {
              if (model != "") printf "m\\t%s\\n", model
              if (branch != "") printf "b\\t%s\\n", branch
              if (last_ts != "") printf "s\\t%s\\n", last_ts
              if (last_kind != "") printf "k\\t%s\\n", last_kind
              if (cwd != "") printf "c\\t%s\\n", cwd
            }
          ' || true

          # The task needs a different tool. In a long agentic run the last
          # real prompt sits thousands of tool_result lines back, well outside
          # any tail worth reading — a 4 MB window finds it for only three
          # sessions in ten. So: a cheap window first, and the whole file only
          # when that comes up empty. grep manages 58 MB in under a tenth of a
          # second, but doing it to every transcript on every poll would be
          # rude, and most polls hit the window.
          if ! printf '%s' "$KNOWN" | grep -qxF "$f" 2>/dev/null; then
            tsk=$(tail -c 2097152 "$f" 2>/dev/null | lastprompt)
            [ -n "$tsk" ] || tsk=$(lastprompt < "$f")
            [ -n "$tsk" ] && printf 'p\\t%s\\n' "$tsk"
          fi
        done
        """
    }

    /// Build the collector for a given set of known byte offsets.
    ///
    /// - Parameter offsets: transcript path → bytes already consumed.
    static func script(offsets: [String: Int]) -> String {
        // Paths come from the remote's own output, so they cannot contain a
        // tab or newline in practice; guard anyway rather than build a broken
        // table out of a pathological filename.
        let table = offsets
            .filter { !$0.key.contains("\t") && !$0.key.contains("\n") }
            .map { "\($0.key)\t\($0.value)" }
            .joined(separator: "\n")

        return """
        printf '\(marker)\\n'
        root="$HOME/.claude/projects"
        [ -d "$root" ] || exit 0

        OFFS='\(table)'
        lookup() {
          printf '%s' "$OFFS" | awk -F'\\t' -v p="$1" '$1 == p { print $2; f=1 } END { if (!f) print 0 }'
        }

        for d in "$root"/*/; do
          [ -d "$d" ] || continue
          f=""
          for c in "$d"*.jsonl; do
            [ -f "$c" ] || continue
            if [ -z "$f" ] || [ "$c" -nt "$f" ]; then f="$c"; fi
          done
          [ -n "$f" ] || continue
          # An old transcript is not a live agent; skip it before paying to
          # read it at all.
          [ -n "$(find "$f" -mtime -\(staleDays) -print 2>/dev/null)" ] || continue

          sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
          [ -n "$sz" ] || continue
          off=$(lookup "$f")
          # A shrunk file was rotated or replaced; start over rather than
          # reading from the middle of a line.
          [ "$sz" -lt "$off" ] && off=0

          printf 'f\\t%s\\t%s\\t%s\\n' "$f" "$sz" "$d"
          [ "$sz" -gt "$off" ] || continue

          tail -c "+$((off + 1))" "$f" 2>/dev/null | awk '
        \(jsonHelpers)
            {
              line = $0
              b = jstr(line, "gitBranch"); if (b != "") branch = b
              ts = jstr(line, "timestamp"); if (ts != "") last_ts = ts

              if (index(line, "\\"type\\":\\"user\\"")) {
                if (index(line, "\\"tool_use_id\\"")) last_kind = "tool_result"
                else {
                  last_kind = "user"
                  t = jstr(line, "text")
                  # Skip the wrappers, meta lines and attachment stubs that
                  # are not a prompt — they would replace the standing task
                  # with noise.
                  if (t != "" \\
                      && substr(t, 1, 1) != "<" \\
                      && index(t, "Caveat:") != 1 \\
                      && index(t, "[Image") != 1 \\
                      && index(t, "[Request interrupted") != 1) task = t
                }
                next
              }

              if (!index(line, "\\"type\\":\\"assistant\\"")) next
              last_kind = index(line, "\\"type\\":\\"tool_use\\"") ? "tool_use" : "assistant"
              m = jstr(line, "model")
              if (m != "" && substr(m, 1, 1) != "<") model = m

              if (!index(line, "\\"usage\\":")) next
              id = jstr(line, "id")
              if (id == "") { anon++; id = "anon-" anon }
              # One line per message, not a running total: the same message id
              # is re-logged while it streams, so the far side has to be able
              # to overwrite rather than add.
              printf "u\\t%s\\t%d\\t%d\\t%d\\t%d\\n", id, \\
                jnum(line, "input_tokens"), jnum(line, "output_tokens"), \\
                jnum(line, "cache_creation_input_tokens"), \\
                jnum(line, "cache_read_input_tokens")
            }
            END {
              if (model != "") printf "m\\t%s\\n", model
              if (branch != "") printf "b\\t%s\\n", branch
              if (last_ts != "") printf "s\\t%s\\n", last_ts
              if (last_kind != "") printf "k\\t%s\\n", last_kind
              if (task != "") { gsub(/\\t/, " ", task); printf "p\\t%s\\n", substr(task, 1, 300) }
            }
          ' || true
        done
        """
    }

    /// What one poll learned about one transcript. Deltas, not totals — the
    /// caller merges them into what it already knows.
    struct Delta {
        var path: String
        var size: Int
        var projectDir: String
        /// message id → its usage as of this poll. Overwrites, never adds.
        var messages: [String: Usage] = [:]
        var model: String?
        var branch: String?
        var lastActivity: Date?
        var lastKind: String?
        var task: String?
        /// The agent's real working directory, when the transcript said.
        var cwd: String?
    }

    struct Usage: Hashable, Sendable {
        var input = 0
        var output = 0
        var cacheCreate = 0
        var cacheRead = 0
    }

    /// A tmux pane on the host, keyed the way Claude Code names projects.
    struct Pane: Sendable, Hashable {
        var id: String
        /// The pane's cwd, encoded as Claude Code encodes a project dir.
        var encodedPath: String
        var command: String
    }

    struct Reply {
        var deltas: [Delta] = []
        var panes: [Pane] = []
    }

    static func parse(_ raw: String) -> Reply {
        guard let start = raw.range(of: marker) else { return Reply() }
        var reply = Reply()
        var deltas: [Delta] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in raw[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let tag = f.first else { continue }

            switch tag {
            case "f" where f.count >= 4:
                deltas.append(Delta(path: String(f[1]),
                                    size: Int(f[2]) ?? 0,
                                    projectDir: String(f[3])))
            case "u" where f.count >= 6 && !deltas.isEmpty:
                deltas[deltas.count - 1].messages[String(f[1])] = Usage(
                    input: Int(f[2]) ?? 0,
                    output: Int(f[3]) ?? 0,
                    cacheCreate: Int(f[4]) ?? 0,
                    cacheRead: Int(f[5]) ?? 0)
            case "m" where f.count >= 2 && !deltas.isEmpty:
                deltas[deltas.count - 1].model = String(f[1])
            case "b" where f.count >= 2 && !deltas.isEmpty:
                deltas[deltas.count - 1].branch = String(f[1])
            case "s" where f.count >= 2 && !deltas.isEmpty:
                let stamp = String(f[1])
                deltas[deltas.count - 1].lastActivity =
                    iso.date(from: stamp) ?? isoPlain.date(from: stamp)
            case "k" where f.count >= 2 && !deltas.isEmpty:
                deltas[deltas.count - 1].lastKind = String(f[1])
            case "p" where f.count >= 2 && !deltas.isEmpty:
                deltas[deltas.count - 1].task = String(f[1])
            case "c" where f.count >= 2 && !deltas.isEmpty:
                deltas[deltas.count - 1].cwd = String(f[1])
            case "t" where f.count >= 4:
                reply.panes.append(Pane(id: String(f[1]),
                                        encodedPath: String(f[2]),
                                        command: String(f[3])))
            default:
                break
            }
        }
        reply.deltas = deltas
        return reply
    }
}

/// Where an agent is in its loop.
///
/// Conterm on macOS reads this off the pane — it watches the terminal. Over
/// SSH there is no pane to watch, so it is inferred from the last transcript
/// entry, which is the honest signal available: an assistant turn that ended
/// without a tool call is an agent waiting on you.
enum AgentPhase: String, Sendable, CaseIterable {
    case attention, working, interrupted, ready, idle

    /// The roster order, straight from the Mac: needs-you first, because the
    /// whole reason to open this on a phone is to find out whether anything
    /// is waiting on you.
    var rank: Int {
        switch self {
        case .attention: return 0
        case .working: return 1
        case .interrupted: return 2
        case .ready: return 3
        case .idle: return 4
        }
    }

    var label: String {
        switch self {
        case .attention: return "needs you"
        case .working: return "working"
        case .interrupted: return "interrupted"
        case .ready: return "ready"
        case .idle: return "idle"
        }
    }
}

/// Per-model-family pricing, in dollars per million tokens. Ported verbatim.
enum AgentPricing {
    struct Rate { let input, output, cacheWrite, cacheRead: Double }

    static func rate(for model: String?) -> Rate {
        let m = (model ?? "").lowercased()
        if m.contains("haiku") { return Rate(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.10) }
        if m.contains("sonnet") { return Rate(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30) }
        return Rate(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.50)
    }
}
