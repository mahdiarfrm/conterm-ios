import Foundation
import Observation

/// The live link to Conterm on a Mac: what it is doing, and what to do to it.
///
/// The first version polled — reconnect, `cat` a file, hang up, wait fifteen
/// seconds, repeat. That is a fine way to *read* a file and a terrible way to
/// feel connected to a machine: everything you saw was up to fifteen seconds
/// stale, and every refresh paid a full SSH handshake.
///
/// This holds one channel open on the host's pooled connection and lets the
/// Mac push. A tiny shell loop there watches the state file's mtime and
/// writes it out when it changes, so nothing crosses the network while
/// nothing is happening, and a change is on the phone about a third of a
/// second later. Commands go back the other way as files dropped into an
/// inbox the Mac watches.
@MainActor
@Observable
final class ContermRemoteLink {
    enum Phase: Equatable {
        case loading
        case loaded
        /// Conterm has never published here — either it isn't installed, or
        /// it predates the version that does.
        case notPublishing
        case failed(String)
    }

    private(set) var state: ContermState?
    private(set) var phase: Phase = .loading
    private(set) var refreshing = false
    /// True while the watcher channel is open. The difference between "this
    /// is live" and "this is the last thing I heard" is worth showing.
    private(set) var streaming = false

    let host: Host
    private let credentials: SSHCredentials

    private var connection: SSHConnection?
    private var channel: SSHChannelID?
    private var holdsConnection = false
    private var pending = Data()
    private var restart: Task<Void, Never>?
    private var stopped = false
    private var attempt = 0

    /// The paths the Mac app writes and this reads. Two apps, one contract.
    nonisolated static let stateFile = "$HOME/.config/conterm/remote-state.json"
    nonisolated static let inboxDirectory = "$HOME/.config/conterm/remote-inbox"

    /// ASCII record separator. JSON encoders escape control characters inside
    /// strings, so this cannot occur inside a record.
    private static let separator: UInt8 = 0x1E

    init(host: Host, credentials: SSHCredentials) {
        self.host = host
        self.credentials = credentials
    }

    // MARK: - The stream

    func start() {
        guard channel == nil, restart == nil else { return }
        stopped = false
        open()
    }

    func stop() {
        stopped = true
        restart?.cancel()
        restart = nil
        streaming = false
        if let connection, let channel {
            Task { await connection.closeChannel(channel) }
        }
        channel = nil
        release()
    }

    private func release() {
        guard holdsConnection else { return }
        holdsConnection = false
        connection = nil
        SSHConnectionPool.shared.release(host)
    }

    private func open() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try await SSHConnectionPool.shared.connection(
                    for: host, credentials: credentials, policy: .ask)
                self.connection = connection
                self.holdsConnection = true

                let id = try await connection.execStream(
                    Self.watcher,
                    onData: { data in
                        Task { @MainActor [weak self] in self?.absorb(data) }
                    },
                    onClosed: { reason in
                        Task { @MainActor [weak self] in self?.streamEnded(reason) }
                    })
                self.channel = id
                self.streaming = true
                self.attempt = 0

                // Ask for a fresh publish immediately rather than waiting for
                // whatever the Mac's timer was going to do. Opening the screen
                // should show now, not up to ten seconds ago.
                await self.send(.init(action: .refresh))
            } catch {
                self.release()
                if self.state == nil { self.phase = .failed(error.localizedDescription) }
                self.scheduleRestart()
            }
        }
    }

    private func streamEnded(_ reason: String?) {
        streaming = false
        channel = nil
        release()
        guard !stopped else { return }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopped, restart == nil else { return }
        attempt += 1
        let delay = min(Int(pow(2.0, Double(attempt))), 30)
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.stopped else { return }
                self.restart = nil
                self.open()
            }
        }
    }

    // MARK: - Parsing

    private func absorb(_ data: Data) {
        pending.append(data)
        // Everything before the last separator is a complete record.
        while let index = pending.firstIndex(of: Self.separator) {
            let record = pending[pending.startIndex..<index]
            pending = pending[pending.index(after: index)...]
            handle(Data(record))
        }
        // A Mac that is being hammered shouldn't be able to grow this
        // unbounded if a separator never arrives.
        if pending.count > 4 * 1024 * 1024 { pending.removeAll() }
    }

    private func handle(_ record: Data) {
        let text = String(decoding: record, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The heartbeat: an empty record, which exists so the far end
        // notices a hung-up channel and stops looping.
        guard !text.isEmpty else { return }

        if text == "none" {
            phase = .notPublishing
            state = nil
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = text.data(using: .utf8),
              let decoded = try? decoder.decode(ContermState.self, from: data) else {
            if state == nil {
                phase = .failed("Couldn't read the state Conterm published. "
                              + "It may be newer than this app.")
            }
            return
        }
        guard decoded.version <= ContermState.supportedVersion else {
            phase = .failed("That Mac is running a newer Conterm than this app "
                          + "understands (format \(decoded.version)).")
            return
        }
        state = decoded
        phase = .loaded
        refreshing = false

        // Everything that wants you, out to the widgets and the Island. The
        // Mac is where almost everyone's agents actually run, so this is the
        // source that matters most — and the one nothing was feeding.
        SignalCenter.shared.post(decoded.agentSignals(machine: host.alias),
                                 from: "mac.\(host.id.uuidString)")
    }

    // MARK: - Asking for things

    func refresh() async {
        refreshing = true
        await send(.init(action: .refresh))
        // Clears itself when the answer lands; this is the floor so a Mac
        // that has quit doesn't leave a spinner up forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run { self?.refreshing = false }
        }
    }

    func send(_ command: Command) async {
        guard let connection else { return }
        let encoder = JSONEncoder()
        // The Mac reads either shape, but ISO-8601 keeps an inbox file
        // legible when one has to be read by hand.
        encoder.dateEncodingStrategy = .iso8601
        guard let payload = try? encoder.encode(command) else { return }
        // base64 rather than a heredoc: the command carries arbitrary user
        // text, and the one thing that must never happen is a quote in a
        // reply turning into shell syntax on someone's Mac.
        let encoded = payload.base64EncodedString()
        let file = "\(Self.inboxDirectory)/\(command.id).json"
        let script = """
        mkdir -p "\(Self.inboxDirectory)" && \
        printf %s '\(encoded)' | base64 -d > "\(file).part" && \
        mv "\(file).part" "\(file)"
        """
        _ = try? await connection.exec(script, timeout: .seconds(15))
    }

    /// What the phone can ask the Mac for. Mirrors `RemoteControl.Command`
    /// on the other side; a closed set on purpose.
    struct Command: Codable, Sendable {
        var id: String = UUID().uuidString
        var action: Action
        var paneID: String?
        var text: String?
        var submit: Bool?
        var windowIndex: Int?
        /// Stamped at send. The Mac drops anything older than a minute: a
        /// command written while it was asleep should not be typed into a
        /// terminal whenever the lid next opens.
        var sentAt: Date = Date()

        enum Action: String, Codable, Sendable {
            case refresh
            case focusPane
            case sendText
            case interrupt
            case newTab
        }
    }

    // MARK: - The far end

    /// A watcher, in portable shell, that costs nothing while nothing is
    /// happening.
    ///
    /// It stats a local file three times a second — which is free, and stays
    /// on the Mac — and only writes to the network when the file has actually
    /// changed. The heartbeat is one byte every three seconds, and its real
    /// job is dying: a loop whose reader has gone away takes SIGPIPE on that
    /// write and exits, so leaving the screen cleans up after itself within a
    /// few seconds instead of leaving a shell spinning on someone's laptop.
    /// The half-day cap is the belt to that braces, for a connection lost in
    /// some way that swallows the signal.
    private static let watcher = """
    f="$HOME/.config/conterm/remote-state.json"
    mkdir -p "$HOME/.config/conterm/remote-inbox" 2>/dev/null
    last=""
    beat=0
    started=$(date +%s)
    while :; do
      if [ $(( $(date +%s) - started )) -gt 43200 ]; then exit 0; fi
      if [ -f "$f" ]; then
        s=$(stat -f '%m-%z' "$f" 2>/dev/null || stat -c '%Y-%s' "$f" 2>/dev/null)
        if [ "$s" != "$last" ]; then
          last="$s"
          cat "$f"
          printf '\\036'
          beat=0
        fi
      elif [ "$last" != "-absent-" ]; then
        last="-absent-"
        printf 'none\\036'
        beat=0
      fi
      beat=$((beat + 1))
      if [ "$beat" -ge 10 ]; then beat=0; printf '\\036'; fi
      sleep 0.3 2>/dev/null || sleep 1
    done
    """
}
