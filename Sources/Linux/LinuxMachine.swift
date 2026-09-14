import Foundation
import UIKit
import WebKit
import os

/// A RISC-V Linux guest emulated in WebAssembly inside a hidden web view,
/// booting the kernel and Debian rootfs bundled in the app.
///
/// Single instance: the guest holds hundreds of megabytes of linear memory,
/// so only one runs. It survives view navigation and ends only on `stop()`
/// or when iOS reclaims the web content process.
@MainActor
@Observable
final class LinuxMachine {
    static let shared = LinuxMachine()

    /// Synthetic host used to give the console a name, a list row and a
    /// distro mark. Nothing connects to it.
    static let host: Host = {
        var host = Host(alias: "Debian", hostname: "this iPhone", username: "root")
        host.id = UUID(uuidString: "5B1C0000-0000-4000-8000-000000000001")!
        host.distro = Distro.debian.rawValue
        return host
    }()

    /// Bundle directory holding the page, workers and image.
    static var root: URL? { Bundle.main.url(forResource: "linux", withExtension: nil) }
    /// The guest image, built by scripts/linux-image.sh and gitignored. Nil
    /// when a build ships without it.
    static var imageURL: URL? {
        Bundle.main.url(forResource: "debian", withExtension: "wasm", subdirectory: "linux")
    }
    /// The bundled fetch-proxy network stack. Nil disables proxy networking.
    static var stackURL: URL? {
        Bundle.main.url(forResource: "c2w-net-proxy", withExtension: "wasm", subdirectory: "linux")
    }
    static var imageSize: Int64? {
        imageURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init)
    }

    enum State: Equatable {
        case off
        case starting(String)
        case running
        case stopped(String)
    }

    private(set) var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            log.notice("state: \(String(describing: self.state), privacy: .public)")
            onState?(state)
            if case .running = state, Self.tour {
                // Harness: type a command once the guest is up.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.write(Data("uname -a; stty size\r".utf8))
                    Logger(subsystem: "dev.conterm.ios", category: "tour").notice("tour: linux typed")
                }
            }
        }
    }
    /// CONTERM_LINUX: boot at launch and type into the guest, for testing.
    static let tour = ProcessInfo.processInfo.environment["CONTERM_LINUX"] != nil
    var isUp: Bool {
        switch state {
        case .starting, .running: return true
        case .off, .stopped: return false
        }
    }

    /// Called with each chunk of guest output; nil while no session listens.
    var onOutput: ((Data) -> Void)?
    var onState: ((State) -> Void)?
    /// Output buffered while `onOutput` is nil, so a boot ahead of its
    /// terminal is not lost. Capped at 1 MB.
    private var backlog = Data()

    private(set) var bytesOut = 0
    private(set) var bytesIn = 0
    private(set) var bootedAt: Date?

    private var server: LoopbackServer?
    private var webView: WKWebView?
    private var bridge: Bridge?
    private var grid = (columns: 80, rows: 24)
    private let log = Logger(subsystem: "dev.conterm.ios", category: "linux")

    private init() {}

    // MARK: - Power

    /// CONTERM_LINUX_ECHO: run the console loop with no guest behind it,
    /// echoing input, to exercise the page and worker plumbing alone.
    private static let echo = ProcessInfo.processInfo.environment["CONTERM_LINUX_ECHO"] != nil

    func start() {
        guard !isUp else { return }
        guard let root = Self.root, Self.imageURL != nil || Self.echo else {
            state = .stopped("This build has no Linux image.")
            return
        }
        backlog.removeAll()
        bytesIn = 0
        bytesOut = 0
        state = .starting("starting the local web server")
        Task { [weak self] in
            guard let self else { return }
            do {
                let server = self.server ?? LoopbackServer(root: root)
                self.server = server
                let port = try await server.start()
                guard case .starting = self.state else { return }
                self.openPage(port: port)
            } catch {
                self.state = .stopped("Couldn't start the local web server: \(error.localizedDescription)")
            }
        }
    }

    /// Tear down the web view and power off. The in-memory disk is lost, so
    /// anything installed since boot is gone.
    func stop() {
        tearDown()
        state = .off
    }

    private func tearDown() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "conterm")
        webView = nil
        bridge = nil
        bootedAt = nil
    }

    private func openPage(port: UInt16) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let bridge = Bridge(self)
        config.userContentController.add(bridge, name: "conterm")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        view.navigationDelegate = bridge
        view.isUserInteractionEnabled = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.alpha = 0.02
        view.accessibilityElementsHidden = true
        // Insert behind everything in the key window: WebKit may throttle a
        // web view that is not in a window.
        if let window = Self.window {
            window.insertSubview(view, at: 0)
        }
        self.bridge = bridge
        self.webView = view
        state = .starting("loading the machine")

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/index.html"
        var items = [
            URLQueryItem(name: "image", value: Self.echo ? "echo" : "debian.wasm"),
            URLQueryItem(name: "cols", value: String(grid.columns)),
            URLQueryItem(name: "rows", value: String(grid.rows)),
        ]
        // Network mode: the bundled fetch proxy (HTTP/HTTPS) by default; the
        // native in-app stack (any TCP port) only when opted in, since it
        // starts a real TCP/IP stack.
        if !Self.echo {
            if Preferences.shared.linuxNativeNet, let netPort = LinuxNetStack.port {
                items.append(URLQueryItem(name: "net", value: "native"))
                items.append(URLQueryItem(name: "wsport", value: String(netPort)))
            } else if Self.stackURL != nil {
                items.append(URLQueryItem(name: "net", value: "proxy"))
            }
        }
        components.queryItems = items
        view.load(URLRequest(url: components.url!))
    }

    private static var window: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    // MARK: - Console

    /// Send typed bytes to the guest's stdin.
    func write(_ data: Data) {
        guard let webView, isUp else { return }
        bytesIn += data.count
        let b64 = data.base64EncodedString()
        webView.evaluateJavaScript("conterm.input(\"\(b64)\")") { _, _ in }
    }

    /// Set the guest console size. Remembered so a machine booted after the
    /// terminal is laid out starts at the right size.
    func resize(columns: Int, rows: Int) {
        guard columns >= 4, rows >= 4 else { return }
        grid = (columns, rows)
        guard let webView, isUp else { return }
        webView.evaluateJavaScript("conterm.resize(\(columns), \(rows))") { _, _ in }
    }

    /// Drain and return output buffered before a session attached.
    func takeBacklog() -> Data {
        defer { backlog.removeAll() }
        return backlog
    }

    private func emit(_ data: Data) {
        bytesOut += data.count
        if let onOutput {
            onOutput(data)
        } else {
            backlog.append(data)
            if backlog.count > 1 << 20 { backlog.removeFirst(backlog.count - (1 << 20)) }
        }
    }

    // MARK: - From the page

    fileprivate func handle(_ body: Any) {
        guard let dict = body as? [String: Any], let kind = dict["t"] as? String else { return }
        switch kind {
        case "page":
            state = .starting("fetching the image")
        case "ready":
            state = .starting("booting")
            // Send the current size before the kernel is up so the first
            // prompt is laid out for it.
            resize(columns: grid.columns, rows: grid.rows)
        case "out":
            guard let b64 = dict["b"] as? String, let data = Data(base64Encoded: b64) else { return }
            if case .starting = state {
                state = .running
                bootedAt = Date()
            }
            emit(data)
        case "exit":
            let code = (dict["code"] as? Int) ?? -1
            let detail = (dict["s"] as? String) ?? ""
            log.error("machine exited \(code): \(detail, privacy: .public)")
            tearDown()
            state = .stopped(detail.isEmpty ? "The machine halted (exit \(code))."
                                            : "The machine stopped: \(detail)")
        case "fatal":
            let detail = (dict["s"] as? String) ?? "unknown"
            log.error("machine fatal: \(detail, privacy: .public)")
            tearDown()
            state = .stopped(detail)
        case "log":
            log.notice("page: \((dict["s"] as? String) ?? "", privacy: .public)")
        default:
            break
        }
    }

    fileprivate func processDied() {
        guard isUp else { return }
        log.error("web content process died")
        tearDown()
        state = .stopped("iOS took the machine's memory back. Boot again to start over.")
    }

    fileprivate func loadFailed(_ error: any Error) {
        guard case .starting = state else { return }
        log.error("page load failed: \(error.localizedDescription, privacy: .public)")
        tearDown()
        state = .stopped("Couldn't load the machine's page: \(error.localizedDescription)")
    }
}

/// Holds WebKit's delegate roles so `LinuxMachine` and the web view can
/// release each other without a retain cycle.
@MainActor
private final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private weak var machine: LinuxMachine?

    init(_ machine: LinuxMachine) {
        self.machine = machine
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        machine?.handle(message.body)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        machine?.processDied()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        machine?.loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        machine?.loadFailed(error)
    }
}
