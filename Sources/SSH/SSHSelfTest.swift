import Foundation
import os

/// Drives the SSH layer against a real server and reports what happened.
///
/// The transport had never met an SSH daemon: everything about it was
/// verified by reading. This runs the paths that matter — trust refusal,
/// trust-on-first-use, the mismatch wall, a shell, and several commands
/// multiplexed onto the same connection while that shell is open — and says
/// PASS or FAIL for each, so a regression shows up as a line rather than as a
/// mysterious black rectangle.
///
/// Set `CONTERM_SSHTEST=1` plus `_HOST`, `_PORT`, `_USER` and `_KEY`.
enum SSHSelfTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["CONTERM_SSHTEST"] == "1"
    }

    private static func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment["CONTERM_SSHTEST_\(name)"]
    }

    private static func say(_ text: String) {
        NSLog("CONTERM-SSHTEST %@", text)
    }

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        say("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    @MainActor
    static func run(app: Ghostty.App? = nil) async {
        // On the simulator the key can be a path, because the app shares the
        // Mac's filesystem. On a device it cannot, so the text travels in the
        // environment instead.
        let keyFromPath = env("KEY").flatMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }
        guard let hostname = env("HOST"),
              let user = env("USER"),
              let privateKey = env("KEY_TEXT") ?? keyFromPath
        else {
            say("FAIL setup — need _HOST, _USER and either _KEY or _KEY_TEXT")
            return
        }
        let port = Int(env("PORT") ?? "22") ?? 22
        let publicKey = env("PUB_TEXT")
            ?? env("KEY").flatMap { try? String(contentsOfFile: $0 + ".pub", encoding: .utf8) }

        var host = Host(alias: "selftest", hostname: hostname, port: port,
                        username: user, auth: .privateKey)
        // A stable id so the pool keys on the same host across steps.
        host.id = UUID(uuidString: "00000000-0000-0000-0000-00000000c0de")!
        let credentials = SSHCredentials(
            address: host.address,
            method: .privateKey(private: privateKey, public: publicKey, passphrase: nil))

        say("--- against \(user)@\(hostname):\(port) ---")
        KnownHostsStore.shared.forget(host.address)
        await SSHConnectionPool.shared.closeAll()

        // 1. An unknown key must be refused outright when nobody is watching.
        //    This is the hole that was open: the check existed, nothing
        //    installed it, and every key was accepted silently.
        var fingerprint: String?
        do {
            _ = try await SSHConnectionPool.shared.connection(
                for: host, credentials: credentials, policy: .requireKnown)
            check("unknown key refused", false, "it connected anyway")
            SSHConnectionPool.shared.release(host)
        } catch let error as SSHError {
            if case .hostKeyUnknown(let fp) = error {
                fingerprint = fp
                check("unknown key refused", true, fp)
            } else {
                check("unknown key refused", false, "\(error)")
            }
        } catch {
            check("unknown key refused", false, "\(error)")
        }

        guard let fingerprint else {
            say("--- stopping: no fingerprint to trust ---")
            return
        }

        // 2. Trust it, the way accepting the prompt would, and connect.
        KnownHostsStore.shared.remember(
            fingerprint: fingerprint, keyType: "ssh-ed25519", for: host.address)

        let phases = Trail()
        let connection: SSHConnection
        do {
            let started = Date()
            connection = try await SSHConnectionPool.shared.connection(
                for: host, credentials: credentials, policy: .requireKnown,
                onPhase: { phase in phases.add("\(phase)") })
            check("connect with a trusted key", true,
                  String(format: "%.0fms", Date().timeIntervalSince(started) * 1000))
            let steps = phases.steps
            check("phases reported", steps.count >= 4, steps.joined(separator: " → "))
        } catch {
            check("connect with a trusted key", false, "\(error)")
            return
        }

        // 3. A command, on its own channel.
        do {
            let result = try await connection.exec("echo hello-from-exec; echo oops >&2; exit 7")
            check("exec stdout", result.output.contains("hello-from-exec"),
                  result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            check("exec stderr", result.errorOutput.contains("oops"),
                  result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            check("exec exit status", result.exitStatus == 7, "got \(result.exitStatus)")
        } catch {
            check("exec", false, "\(error)")
        }

        // 3b. The host probe's real collector, through the real path.
        //     It is 3KB of shell handed to `exec` as a command argument,
        //     where the Mac app pipes the same script to `ssh host sh` on
        //     stdin — a difference worth a check rather than an assumption.
        do {
            let started = Date()
            let result = try await connection.exec(HostProbeModel.collector,
                                                   timeout: .seconds(30))
            let ok = result.output.contains("===conterm:hostname===")
            check("host probe collector runs", ok,
                  String(format: "%d bytes in %.1fs", result.output.count,
                         Date().timeIntervalSince(started)))
        } catch {
            check("host probe collector runs", false, "\(error)")
        }

        // 3c. Agent Center's collector. It reads Claude Code's transcripts
        //     on the *far* machine, which is the whole point — you check
        //     your phone precisely because you are not at that machine.
        do {
            let started = Date()
            let script = AgentCollector.summaryScript(knownTasks: [])
            let result = try await connection.exec(script, timeout: .seconds(40))
            // Records are tab-separated with a one-letter key; `c` is the
            // working directory, so one per agent found.
            let sessions = result.output.split(separator: "\n")
                .filter { $0.hasPrefix("c\t") }.count
            check("agent collector runs", result.output.contains("==="),
                  String(format: "%d sessions, %d bytes in %.1fs",
                         sessions, result.output.count,
                         Date().timeIntervalSince(started)))
            say("     collector said: "
                + result.output.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(400))
            // A collector that works but complains is a collector that is
            // about to stop working on someone else's shell.
            check("agent collector is quiet", result.errorOutput.isEmpty,
                  result.errorOutput.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(200)
                      .description)
        } catch {
            check("agent collector runs", false, "\(error)")
        }

        // 4. A shell with a pty, and the round trip through it.
        let received = Received()
        do {
            let channel = try await connection.openShell(
                columns: 80, rows: 24,
                onOutput: { data in
                    // Stamped at the callback, not after the hop into the
                    // actor, so the latency figure measures the connection
                    // rather than the test's own scheduling.
                    let at = Date()
                    Task { await received.append(data, at: at) }
                },
                onClosed: { _ in })
            check("open a shell", true)

            await connection.write(Data("echo shell-round-trip\n".utf8), to: channel)
            let sawEcho = await received.wait(for: "shell-round-trip", seconds: 8)
            check("shell round trip", sawEcho)

            // 5. The point of the rewrite: commands must not stall the shell.
            //    The old transport put the session back into blocking mode
            //    and read to completion while holding the lock, so a probe
            //    meant a dead keyboard for its duration.
            let started = Date()
            async let a = connection.exec("sleep 1; echo one")
            async let b = connection.exec("sleep 1; echo two")
            async let c = connection.exec("sleep 1; echo three")
            let outputs = try await [a, b, c].map(\.output)
            let elapsed = Date().timeIntervalSince(started)
            check("three commands multiplexed",
                  outputs.allSatisfy { !$0.isEmpty } && elapsed < 2.5,
                  String(format: "%.2fs for 3×1s", elapsed))

            await received.clear()
            await connection.write(Data("echo still-alive\n".utf8), to: channel)
            let alive = await received.wait(for: "still-alive", seconds: 8)
            check("shell still responsive afterwards", alive)

            // 6. Latency. The old pump held the actor across a 200ms poll, so
            //    a keystroke could wait behind it; this should be single-digit
            //    milliseconds on loopback.
            await connection.closeChannel(channel)
        } catch {
            check("shell", false, "\(error)")
        }

        // 6. Round-trip latency, measured against `cat` rather than a shell.
        //
        //    Measuring through zsh gave a median of 0ms with occasional 400ms
        //    outliers, and the outliers were zsh: under its line editor the
        //    *shell* echoes what you type, not the tty driver, so the figure
        //    tracked whether zsh happened to be between prompts. `cat` has no
        //    line editor and no prompt, so what is left is the wire.
        let echoed = Received()
        do {
            let channel = try await connection.execStream(
                "cat",
                onData: { data in
                    let at = Date()
                    Task { await echoed.append(data, at: at) }
                },
                onClosed: { _ in })

            // One throwaway round trip first. The first write on a freshly
            // opened channel pays for the channel window opening and the far
            // process starting, which is real but is not what this measures —
            // it showed up as a lone 20-150ms outlier in first position and
            // never anywhere else.
            await echoed.expect("warmup", occurrences: 1)
            await connection.write(Data("warmup\n".utf8), to: channel)
            _ = await echoed.arrival(seconds: 5)

            var samples: [Double] = []
            for i in 0..<20 {
                let mark = "ping-\(i)"
                await echoed.expect(mark, occurrences: 1)
                let sent = Date()
                await connection.write(Data("\(mark)\n".utf8), to: channel)
                if let arrived = await echoed.arrival(seconds: 5) {
                    samples.append(arrived.timeIntervalSince(sent) * 1000)
                }
            }
            let worst = samples.max() ?? .infinity
            let median = samples.sorted()[max(samples.count / 2, 0)]
            // The median is what typing feels like. A worst case far above it
            // would mean a lost wakeup — the pump sleeping through a write
            // until its poll timed out — which is the bug this design exists
            // to avoid, so it is checked separately.
            check("keystroke latency", median < 20,
                  String(format: "median %.0fms", median))
            check("no lost wakeups", worst < 120,
                  String(format: "worst %.0fms, all [%@]", worst,
                         samples.map { String(format: "%.0f", $0) }.joined(separator: " ")))

            await connection.closeChannel(channel)
        } catch {
            check("latency probe", false, "\(error)")
        }

        // 7. Connection reuse: a second borrow must not re-handshake.
        do {
            let started = Date()
            let again = try await SSHConnectionPool.shared.connection(
                for: host, credentials: credentials, policy: .requireKnown)
            let elapsed = Date().timeIntervalSince(started) * 1000
            check("pool reuses the connection", again === connection,
                  String(format: "%.0fms", elapsed))
            SSHConnectionPool.shared.release(host)
        } catch {
            check("pool reuses the connection", false, "\(error)")
        }

        SSHConnectionPool.shared.release(host)
        await SSHConnectionPool.shared.closeAll()

        // 8. The wall. Pretend we remembered something else and confirm the
        //    connection is refused before authentication — nothing sent.
        KnownHostsStore.shared.remember(
            fingerprint: "SHA256:AAAAdefinitelyNotTheRealKeyAAAAAAAAAAAAAAAA",
            keyType: "ssh-ed25519", for: host.address)
        do {
            _ = try await SSHConnectionPool.shared.connection(
                for: host, credentials: credentials, policy: .requireKnown)
            check("changed key refused", false, "it connected anyway")
            SSHConnectionPool.shared.release(host)
        } catch let error as SSHError {
            if case .hostKeyMismatch = error {
                check("changed key refused", true)
            } else {
                check("changed key refused", false, "\(error)")
            }
        } catch {
            check("changed key refused", false, "\(error)")
        }

        // The pair, end to end: the Mac's state pushed to the phone and a
        // command sent back.
        KnownHostsStore.shared.remember(
            fingerprint: fingerprint, keyType: "ssh-ed25519", for: host.address)
        if let app {
            await TerminalSelfTest.run(host: host, credentials: credentials, app: app)
        }

        if ProcessInfo.processInfo.environment["CONTERM_SSHTEST_LIVE"] == "1" {
            await ContermRemoteSelfTest.runLive(host: host, credentials: credentials)
        } else {
            await ContermRemoteSelfTest.run(host: host, credentials: credentials)
        }

        KnownHostsStore.shared.forget(host.address)
        await SSHConnectionPool.shared.closeAll()
        say("--- done ---")
    }

    /// Records the connect phases as they are reported. A plain `var`
    /// captured by the callback would be a data race; the callback runs
    /// wherever the connection happens to be.
    private final class Trail: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []

        func add(_ step: String) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(step)
        }

        var steps: [String] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
    }

    /// Collects shell output so a test can wait for a specific string.
    private actor Received {
        private var text = ""
        private var needle: String?
        private var wanted = 2
        private var arrivedAt: Date?

        func append(_ data: Data, at when: Date = Date()) {
            text += String(decoding: data, as: UTF8.self)
            guard let needle, arrivedAt == nil else { return }
            if text.components(separatedBy: needle).count - 1 >= wanted {
                arrivedAt = when
            }
        }

        func clear() { text = ""; needle = nil; arrivedAt = nil; wanted = 2 }

        /// `occurrences: 1` is the pty echoing what was typed; `2` is that
        /// echo plus the command's own output.
        func expect(_ mark: String, occurrences: Int = 2) {
            text = ""
            needle = mark
            wanted = occurrences
            arrivedAt = nil
        }

        /// When the expected output actually landed, timed at the callback.
        func arrival(seconds: Double) async -> Date? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let arrivedAt { return arrivedAt }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return nil
        }

        func wait(for mark: String, seconds: Double) async -> Bool {
            expect(mark)
            return await arrival(seconds: seconds) != nil
        }
    }
}
