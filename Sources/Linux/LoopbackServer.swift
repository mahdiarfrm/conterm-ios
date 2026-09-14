import Foundation
import Network
import os

/// Loopback HTTP server for the Linux machine's page, workers and image.
///
/// A WKWebView grants SharedArrayBuffer (which the emulator needs to block on
/// stdin) only to a page served over http from 127.0.0.1 with the two
/// cross-origin isolation headers, not to a file:// or custom-scheme page.
/// This serves the bundle's static files and, at /fetch, relays the guest's
/// proxied HTTP requests through URLSession. Loopback only, one request per
/// connection.
final class LoopbackServer: @unchecked Sendable {
    private let root: URL
    private let queue = DispatchQueue(label: "dev.conterm.ios.loopback")
    private let log = Logger(subsystem: "dev.conterm.ios", category: "loopback")
    private var listener: NWListener?
    private(set) var port: UInt16?
    /// Handles /fetch: the proxy network stack turns the guest's HTTP and
    /// HTTPS into requests the app makes here through URLSession. Same origin
    /// as the page, so the web view's CORS rules never apply to it.
    private lazy var relay = FetchRelay(log: log)
    /// `CONTERM_LINUX` (the harness) turns on per-request logging.
    private static let trace = ProcessInfo.processInfo.environment["CONTERM_LINUX"] != nil

    init(root: URL) {
        self.root = root
    }

    /// Start listening, on whatever port is free. Idempotent.
    func start() async throws -> UInt16 {
        if let port { return port }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            // The handler fires for every state; the continuation takes one.
            let once = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, any Error>
                switch state {
                case .ready:
                    if let port = listener.port {
                        result = .success(port.rawValue)
                    } else {
                        result = .failure(LoopbackError.noPort)
                    }
                case .failed(let error):
                    result = .failure(error)
                case .cancelled:
                    result = .failure(LoopbackError.cancelled)
                default:
                    return
                }
                let first = once.withLock { (done: inout Bool) -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { cont.resume(with: result) }
            }
            listener.start(queue: queue)
        }
        self.port = port
        log.notice("serving \(self.root.lastPathComponent) on 127.0.0.1:\(port)")
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    enum LoopbackError: LocalizedError {
        case noPort, cancelled
        var errorDescription: String? {
            switch self {
            case .noPort: return "The local web server got no port."
            case .cancelled: return "The local web server was cancelled."
            }
        }
    }

    // MARK: - Requests

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, sofar: Data())
    }

    /// Accumulate until the blank line ending the request head.
    private func readHead(_ connection: NWConnection, sofar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var head = sofar
            if let data { head.append(data) }
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                let text = String(decoding: head[..<end.lowerBound], as: UTF8.self)
                self.respond(connection, request: text, body: Data(head[end.upperBound...]))
            } else if done || error != nil || head.count > 64_000 {
                connection.cancel()
            } else {
                self.readHead(connection, sofar: head)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String, body: Data) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else {
            send(connection, status: "400 Bad Request", type: "text/plain", body: Data())
            return
        }
        let method = String(parts[0])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var path = String(parts[1])
        var query = ""
        if let q = path.firstIndex(of: "?") {
            query = String(path[path.index(after: q)...])
            path = String(path[..<q])
        }
        path = path.removingPercentEncoding ?? path

        if path == "/fetch" {
            let expected = Int(headers["content-length"] ?? "") ?? 0
            let query = query, headers = headers
            gatherBody(connection, sofar: body, expected: expected) { [weak self] body in
                guard let self else { connection.cancel(); return }
                self.relay.fetch(query: query, method: method, headers: headers, body: body,
                                 over: connection)
            }
            return
        }
        guard method == "GET" || method == "HEAD" else {
            send(connection, status: "405 Method Not Allowed", type: "text/plain", body: Data())
            return
        }
        if path == "/" { path = "/index.html" }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0 == ".." || $0.hasPrefix(".") }) else {
            send(connection, status: "404 Not Found", type: "text/plain", body: Data())
            return
        }
        let file = root.appending(path: components.joined(separator: "/"))
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let handle = try? FileHandle(forReadingFrom: file)
        guard let size, let handle else {
            if Self.trace {
                log.error("404 \(method, privacy: .public) \(path, privacy: .public) -> \(file.path, privacy: .public) size=\(size ?? -1) handle=\(handle != nil)")
            }
            send(connection, status: "404 Not Found", type: "text/plain", body: Data())
            return
        }
        if Self.trace { log.notice("200 \(method, privacy: .public) \(path, privacy: .public) \(size)B") }
        let type = Self.contentType(for: file.pathExtension)
        let header = Data(Self.header(status: "200 OK", type: type, length: size).utf8)
        if method == "HEAD" {
            try? handle.close()
            connection.send(content: header, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else {
                try? handle.close()
                connection.cancel()
                return
            }
            self.stream(handle, over: connection)
        })
    }

    /// The rest of a request body, when the head came with part of it.
    private func gatherBody(_ connection: NWConnection, sofar: Data, expected: Int,
                            then: @escaping @Sendable (Data) -> Void) {
        guard sofar.count < expected, expected <= 64 << 20 else { then(sofar); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var body = sofar
            if let data { body.append(data) }
            if body.count >= expected || done || error != nil {
                then(body)
            } else {
                self.gatherBody(connection, sofar: body, expected: expected, then: then)
            }
        }
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data) {
        var data = Data(Self.header(status: status, type: type, length: body.count).utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The image is hundreds of MB, so stream it in chunks.
    private func stream(_ handle: FileHandle, over connection: NWConnection) {
        let chunk = (try? handle.read(upToCount: 1 << 18)) ?? Data()
        guard !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else {
                try? handle.close()
                connection.cancel()
                return
            }
            self.stream(handle, over: connection)
        })
    }

    private static func header(status: String, type: String, length: Int) -> String {
        [
            "HTTP/1.1 \(status)",
            "Content-Type: \(type)",
            "Content-Length: \(length)",
            "Cache-Control: no-store",
            "Connection: close",
            // The two headers that make the page cross-origin isolated,
            // which is what unlocks SharedArrayBuffer in the web view.
            "Cross-Origin-Opener-Policy: same-origin",
            "Cross-Origin-Embedder-Policy: require-corp",
            "Cross-Origin-Resource-Policy: same-origin",
            "", "",
        ].joined(separator: "\r\n")
    }

    private static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "wasm": return "application/wasm"
        case "json": return "application/json"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

/// Makes one HTTP request through URLSession and streams the response back
/// to the connection as it arrives. Requests an unencoded body and drops the
/// content-encoding and length headers, so the guest reads exactly the bytes
/// URLSession delivers rather than a decoded body under a compressed header.
private final class FetchRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    private let log: Logger
    private var session: URLSession!
    private var flights: [Int: Flight] = [:]

    /// The response's journey out: bytes wait here between arriving and
    /// being written, and the task pauses when too many are waiting.
    private final class Flight {
        let connection: NWConnection
        let request: URLRequest
        var task: URLSessionDataTask
        var headSent = false
        var pending = Data()
        var writing = false
        var finished = false
        var suspended = false
        /// Retries left for a request that fails before any response, so a
        /// transient reset under apt's parallel load is not a gateway error.
        var retriesLeft = 2
        init(connection: NWConnection, request: URLRequest, task: URLSessionDataTask) {
            self.connection = connection
            self.request = request
            self.task = task
        }
    }

    private static let dropped: Set<String> = [
        "content-encoding", "content-length", "transfer-encoding", "connection",
        "keep-alive", "proxy-connection", "upgrade", "set-cookie", "strict-transport-security",
    ]
    private static let notForwarded: Set<String> = [
        "host", "content-length", "connection", "keep-alive", "transfer-encoding",
        "accept-encoding", "proxy-connection", "origin", "referer", "cookie", "te", "upgrade",
        "sec-fetch-mode", "sec-fetch-site", "sec-fetch-dest", "cache-control", "pragma",
    ]

    init(log: Logger) {
        // A dedicated queue, separate from the file server's, so streaming
        // the large image does not starve the guest's fetches.
        self.queue = DispatchQueue(label: "dev.conterm.ios.fetchrelay")
        self.log = log
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = false
        // apt fetches many indexes at once; let them run in parallel rather
        // than queue behind one another and time out.
        config.httpMaximumConnectionsPerHost = 8
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    func fetch(query: String, method: String, headers: [String: String], body: Data,
               over connection: NWConnection) {
        let target = query.split(separator: "&")
            .first { $0.hasPrefix("url=") }
            .map { String($0.dropFirst(4)) }?
            .removingPercentEncoding
        guard let target, let url = URL(string: target),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else {
            plain(connection, status: "400 Bad Request", text: "fetch needs an http or https url")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers where !Self.notForwarded.contains(name) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !body.isEmpty { request.httpBody = body }
        // Register and start the task on the relay's own queue, where every
        // access to `flights` happens.
        queue.async { [weak self] in
            guard let self else { connection.cancel(); return }
            let task = self.session.dataTask(with: request)
            self.flights[task.taskIdentifier] = Flight(connection: connection, request: request, task: task)
            task.resume()
        }
    }

    private func plain(_ connection: NWConnection, status: String, text: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + text).utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: URLSessionDataDelegate, on `queue`

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let flight = flights[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        var lines = ["HTTP/1.1 200 OK"]
        if let http = response as? HTTPURLResponse {
            let text = HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
            lines = ["HTTP/1.1 \(http.statusCode) \(text)"]
            for (name, value) in http.allHeaderFields {
                let key = String(describing: name)
                guard !Self.dropped.contains(key.lowercased()) else { continue }
                lines.append("\(key): \(value)")
            }
        }
        lines.append("Cache-Control: no-store")
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        flight.headSent = true
        flight.pending.append(Data(lines.joined(separator: "\r\n").utf8))
        pump(flight)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let flight = flights[dataTask.taskIdentifier] else { return }
        flight.pending.append(data)
        // Backpressure: the guest reads slower than the network delivers.
        if flight.pending.count > 4 << 20, !flight.suspended {
            flight.suspended = true
            flight.task.suspend()
        }
        pump(flight)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let flight = flights[task.taskIdentifier] else { return }
        if let error, !flight.headSent {
            flights[task.taskIdentifier] = nil
            if flight.retriesLeft > 0 {
                flight.retriesLeft -= 1
                log.notice("fetch retry \(flight.request.url?.absoluteString ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
                let next = session.dataTask(with: flight.request)
                flight.task = next
                flights[next.taskIdentifier] = flight
                next.resume()
                return
            }
            log.error("fetch \(flight.request.url?.absoluteString ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
            plain(flight.connection, status: "502 Bad Gateway", text: error.localizedDescription)
            return
        }
        flight.finished = true
        pump(flight)
    }

    /// Send pending bytes one write at a time, closing after the last.
    private func pump(_ flight: Flight) {
        guard !flight.writing else { return }
        if flight.pending.isEmpty {
            if flight.finished {
                flights[flight.task.taskIdentifier] = nil
                flight.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                       completion: .contentProcessed { _ in flight.connection.cancel() })
            }
            return
        }
        let chunk = flight.pending.prefix(1 << 18)
        flight.pending.removeFirst(chunk.count)
        flight.writing = true
        flight.connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                flight.writing = false
                if error != nil {
                    self.flights[flight.task.taskIdentifier] = nil
                    flight.task.cancel()
                    flight.connection.cancel()
                    return
                }
                if flight.suspended, flight.pending.count < 1 << 20 {
                    flight.suspended = false
                    flight.task.resume()
                }
                self.pump(flight)
            }
        })
    }
}
