import Foundation

/// Exercises the link to Conterm on a Mac end to end.
///
/// The two halves of this feature live in two repositories and only meet over
/// a wire, which is exactly the arrangement where a contract drifts silently.
/// This drives the real link against a real SSH host: it writes a state file
/// the way the Mac would, times how long the push takes to arrive, and checks
/// that a command sent from the phone lands in the inbox as the Mac's decoder
/// expects to find it.
///
/// It does not need Conterm to be running on the far side — that is the
/// point. The Mac app's own half is a few lines around `RemoteStatePublisher`
/// and `RemoteControl`; what is worth testing is the contract between them.
enum ContermRemoteSelfTest {

    private static func say(_ text: String) {
        NSLog("CONTERM-SSHTEST %@", text)
    }

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        say("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    @MainActor
    static func run(host: Host, credentials: SSHCredentials) async {
        say("--- Conterm remote link ---")

        let link = ContermRemoteLink(host: host, credentials: credentials)

        // A connection of our own, to play the Mac's part.
        let connection: SSHConnection
        do {
            connection = try await SSHConnectionPool.shared.connection(
                for: host, credentials: credentials, policy: .requireKnown)
        } catch {
            check("remote link setup", false, "\(error)")
            return
        }
        defer { SSHConnectionPool.shared.release(host) }

        _ = try? await connection.exec(
            "rm -f \(ContermRemoteLink.stateFile); "
            + "rm -rf \(ContermRemoteLink.inboxDirectory)")

        link.start()

        // 1. No state file at all: the phone must say so rather than sit on
        //    a spinner. "Conterm isn't running over there" is an answer.
        let sawAbsent = await settle(seconds: 12) { link.phase == .notPublishing }
        check("absent state reported", sawAbsent, "\(link.phase)")

        // 2. The Mac publishes. Time how long until the phone knows.
        let firstWrite = Date()
        await write(state(panes: 2), to: connection)
        let sawState = await settle(seconds: 12) { link.state != nil }
        let pushLatency = Date().timeIntervalSince(firstWrite) * 1000
        check("state pushed", sawState, String(format: "%.0fms", pushLatency))
        check("state decoded", link.state?.paneCount == 2,
              "panes \(link.state?.paneCount ?? -1)")

        // 3. A change, without anything asking for it. This is the whole
        //    difference from polling: nothing crossed the wire until the far
        //    side had something new to say.
        let secondWrite = Date()
        await write(state(panes: 5), to: connection)
        let sawChange = await settle(seconds: 12) { link.state?.paneCount == 5 }
        check("change pushed without polling", sawChange,
              String(format: "%.0fms", Date().timeIntervalSince(secondWrite) * 1000))

        // 4. Nothing changes: the link must be quiet, not spinning.
        let beforeIdle = link.state?.publishedAt
        try? await Task.sleep(for: .seconds(2))
        check("quiet when nothing changes", link.state?.publishedAt == beforeIdle)

        // 5. A command from the phone, in the shape the Mac decodes.
        //    Clear first: opening the link sends its own `refresh`, and with
        //    no Conterm on the far side nothing consumes the inbox, so `cat
        //    *.json` would hand the decoder two documents. The real Mac
        //    deletes each file as it acts on it.
        _ = try? await connection.exec("rm -f \(ContermRemoteLink.inboxDirectory)/*.json")
        await link.send(.init(action: .focusPane, paneID: "pane-1"))
        var landed = false
        var decodedWell = false
        for _ in 0..<20 {
            guard let listing = try? await connection.exec(
                "cat \(ContermRemoteLink.inboxDirectory)/*.json 2>/dev/null"),
                  !listing.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            landed = true
            // Decode it the way the Mac will: same field names, same enum.
            if let data = listing.output.data(using: .utf8),
               let command = try? JSONDecoder().decode(ContermRemoteLink.Command.self,
                                                       from: data) {
                decodedWell = command.action == .focusPane && command.paneID == "pane-1"
            }
            break
        }
        check("command reached the inbox", landed)
        check("command decodes as the Mac expects", decodedWell)

        // 6. Arbitrary text must survive the trip. A reply with a quote in it
        //    turning into shell syntax on someone's Mac is the failure this
        //    has to be immune to, which is why it goes over base64.
        _ = try? await connection.exec("rm -f \(ContermRemoteLink.inboxDirectory)/*.json")
        let nasty = "it's \"quoted\"; rm -rf /; $(whoami) `id` \\ \n newline"
        await link.send(.init(action: .sendText, paneID: "pane-1",
                              text: nasty, submit: true))
        var roundTripped = false
        for _ in 0..<20 {
            if let listing = try? await connection.exec(
                "cat \(ContermRemoteLink.inboxDirectory)/*.json 2>/dev/null"),
               let data = listing.output.data(using: .utf8),
               let command = try? JSONDecoder().decode(ContermRemoteLink.Command.self,
                                                       from: data) {
                roundTripped = command.text == nasty && command.submit == true
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        check("hostile text survives intact", roundTripped)

        // 7. The far end must not be left looping on someone's laptop.
        link.stop()
        // Long enough for the far end's next heartbeat, which is what makes
        // it notice the channel has gone.
        try? await Task.sleep(for: .seconds(8))
        // The pattern is built at runtime so this command's own argv doesn't
        // contain the string it is looking for — otherwise the check counts
        // the shell doing the checking and reports a leak that isn't there.
        let watchers = (try? await connection.exec(
            "p='[r]emote'; ps ax -o command= | grep -c \"${p}-state.json\""))?.output
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        check("watcher stopped with the screen", watchers == "0", "processes: \(watchers)")

        _ = try? await connection.exec(
            "rm -f \(ContermRemoteLink.stateFile); "
            + "rm -rf \(ContermRemoteLink.inboxDirectory)")
        say("--- remote link done ---")
    }

    // MARK: - Playing the Mac's part

    private static func write(_ json: String, to connection: SSHConnection) async {
        let encoded = Data(json.utf8).base64EncodedString()
        let script = """
        mkdir -p "$HOME/.config/conterm" && \
        printf %s '\(encoded)' | base64 -d > "\(ContermRemoteLink.stateFile).part" && \
        mv "\(ContermRemoteLink.stateFile).part" "\(ContermRemoteLink.stateFile)"
        """
        _ = try? await connection.exec(script)
    }

    /// The exact shape `RemoteStatePublisher` writes, built here so a change
    /// on either side shows up as a decode failure in this test rather than
    /// as an empty screen in someone's hand.
    private static func state(panes: Int) -> String {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        let paneJSON = (1...panes).map { i in
            """
            {"id":"pane-\(i)","index":\(i),"title":"shell","cwd":"/tmp",
             "dirLabel":"tmp","isActive":\(i == 1),
             "agentPhase":\(i == 1 ? "\"attention\"" : "null"),
             "agentLabel":\(i == 1 ? "\"waiting on you\"" : "null")}
            """
        }.joined(separator: ",")
        return """
        {"version":1,"publishedAt":"\(now)","hostName":"selftest",
         "appVersion":"0.0.0",
         "windows":[{"index":1,"title":"Conterm","isKey":true,
           "tabs":[{"index":1,"title":"shell","isSelected":true,
                    "panes":[\(paneJSON)]}]}]}
        """
    }

    @MainActor
    private static func settle(seconds: Double,
                               until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
