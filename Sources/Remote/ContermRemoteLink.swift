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
        // The home's card for this Mac reads this, so it can say what the
        // Mac was doing without opening a connection to ask.
        MacSummary.store(.init(panes: decoded.paneCount,
                               waiting: decoded.agentsNeedingYou,
                               at: decoded.publishedAt), for: host)

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
        guard let connection, let script = Self.inboxScript(for: command) else { return }
        _ = try? await connection.exec(script, timeout: .seconds(15))
    }

    /// The shell that drops a command in the Mac's inbox. base64 rather
    /// than a heredoc: the command carries arbitrary user text, and the
    /// one thing that must never happen is a quote in a reply turning
    /// into shell syntax on someone's Mac.
    nonisolated static func inboxScript(for command: Command) -> String? {
        guard let payload = try? encoder.encode(command) else { return nil }
        let encoded = payload.base64EncodedString()
        let file = "\(inboxDirectory)/\(command.id).json"
        return """
        mkdir -p "\(inboxDirectory)" && \
        printf %s '\(encoded)' | base64 -d > "\(file).part" && \
        mv "\(file).part" "\(file)"
        """
    }

    /// How a command goes on the wire.
    ///
    /// ISO-8601 rather than the `JSONEncoder` default, which writes seconds
    /// since the reference date, because an inbox file is something someone
    /// ends up reading by hand.
    nonisolated(unsafe) static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// How the Mac reads one back, mirroring `RemoteControl.lenientDates`.
    ///
    /// It accepts either shape, so the two apps can ship in either order: a
    /// date strategy mismatch fails the *whole* decode, which would drop
    /// every command silently rather than just its timestamp. Anything on
    /// this side that needs to check what the Mac will see has to decode the
    /// way the Mac does, or it is testing its own assumptions.
    nonisolated(unsafe) static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                if let date = iso8601Frac.date(from: text) { return date }
                if let date = iso8601Plain.date(from: text) { return date }
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "unparseable date \(text)")
            }
            return Date(timeIntervalSinceReferenceDate:
                            try container.decode(Double.self))
        }
        return decoder
    }()

    nonisolated(unsafe) private static let iso8601Frac: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Plain = ISO8601DateFormatter()

    /// What the phone can ask the Mac for. Mirrors `RemoteControl.Command`
    /// on the other side; a closed set on purpose.
    struct Command: Codable, Sendable {
        var id: String = UUID().uuidString
        var action: Action
        var paneID: String?
        var text: String?
        var submit: Bool?
        var windowIndex: Int?
        /// A key by name, for `.key`.
        var key: String?
        /// For `.attach`: the pixels too.
        var picture: Bool?
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
            /// One pane, mirrored to a file while this is renewed.
            case attach
            case detach
            /// Typed as keys, not pasted; `submit` adds a Return.
            case type
            /// A named key: return, escape, tab, backspace, the arrows,
            /// ctrl-c, ctrl-d, ctrl-z, ctrl-l, ctrl-u, ctrl-a, ctrl-e, ctrl-r.
            case key
        }
    }

    // MARK: - One pane

    func attach(_ paneID: String, picture: Bool = false) async {
        await send(.init(action: .attach, paneID: paneID, picture: picture))
    }

    func detach(_ paneID: String) async {
        await send(.init(action: .detach, paneID: paneID))
    }

    func type(_ text: String, into paneID: String, submit: Bool) async {
        await send(.init(action: .type, paneID: paneID, text: text, submit: submit))
    }

    func key(_ name: String, into paneID: String) async {
        await send(.init(action: .key, paneID: paneID, key: name))
    }

    /// Stream the pane's mirrored screen. `onText` gets every new screen;
    /// nil means the Mac has stopped mirroring it. Returns the channel,
    /// for `closeScreen`.
    func openScreen(of paneID: String,
                    onText: @escaping @MainActor (String?) -> Void) async -> SSHChannelID? {
        await openStream(of: paneID, picture: false) { data in
            onText(data.map { String(decoding: $0, as: UTF8.self) })
        }
    }

    /// Stream the pane's picture: every new JPEG as it lands.
    func openPicture(of paneID: String,
                     onImage: @escaping @MainActor (Data?) -> Void) async -> SSHChannelID? {
        await openStream(of: paneID, picture: true) { data in
            onImage(data.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) })
        }
    }

    private func openStream(of paneID: String, picture: Bool,
                            onRecord: @escaping @MainActor (Data?) -> Void) async -> SSHChannelID? {
        guard let connection else { return nil }
        let stream = RecordStream()
        return try? await connection.execStream(
            Self.paneWatcher(paneID, picture: picture),
            onData: { data in
                let records = stream.absorb(data)
                Task { @MainActor in
                    for record in records {
                        if record.isEmpty { continue }
                        if record.count <= 5, String(decoding: record, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines) == "none" {
                            onRecord(nil)
                        } else {
                            onRecord(record)
                        }
                    }
                }
            },
            onClosed: { _ in
                Task { @MainActor in onRecord(nil) }
            })
    }

    func closeScreen(_ id: SSHChannelID) async {
        guard let connection else { return }
        await connection.closeChannel(id)
    }

    /// The state watcher again, for one pane's file. The picture goes
    /// through base64, since a JPEG can contain the record separator.
    private static func paneWatcher(_ paneID: String, picture: Bool) -> String {
        """
        f="$HOME/.config/conterm/remote-panes/\(paneID).\(picture ? "jpg" : "txt")"
        last=""
        beat=0
        started=$(date +%s)
        while :; do
          if [ $(( $(date +%s) - started )) -gt 43200 ]; then exit 0; fi
          if [ -f "$f" ]; then
            s=$(stat -f '%m-%z' "$f" 2>/dev/null || stat -c '%Y-%s' "$f" 2>/dev/null)
            if [ "$s" != "$last" ]; then
              last="$s"
              \(picture ? "base64 < \"$f\"" : "cat \"$f\"")
              printf '\\036'
              beat=0
            fi
          elif [ "$last" != "-absent-" ]; then
            last="-absent-"
            printf 'none\\036'
            beat=0
          fi
          beat=$((beat + 1))
          if [ "$beat" -ge 20 ]; then beat=0; printf '\\036'; fi
          sleep 0.2 2>/dev/null || sleep 1
        done
        """
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

/// Bytes in, records out: everything up to each record separator.
final class RecordStream: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private static let separator: UInt8 = 0x1E

    func absorb(_ data: Data) -> [Data] {
        lock.withLock {
            pending.append(data)
            var out: [Data] = []
            while let index = pending.firstIndex(of: Self.separator) {
                out.append(Data(pending[pending.startIndex..<index]))
                pending = pending[pending.index(after: index)...]
            }
            if pending.count > 4 * 1024 * 1024 { pending.removeAll() }
            return out
        }
    }
}
