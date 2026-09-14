import Foundation
import UIKit

/// Files on a host, over the connection the app already has.
///
/// Every operation is one shell command on an exec channel: a listing is
/// `ls -l`, a download is `head -c` into the channel's stdout, an upload is
/// `cat > path` with the bytes on the channel's stdin. No SFTP subsystem
/// is asked for, so this works on any box a shell works on, through the
/// same jump host, with the same key.

/// One thing in a directory.
struct RemoteEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case directory, file, link, other
    }

    var name: String
    var path: String
    var kind: Kind
    var size: Int64
    var modified: Date?
    var permissions: String
    var owner: String
    var linkTarget: String?

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }
    var isDirectory: Bool { kind == .directory }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    /// What the name says the file is: the glyph it gets, and how the
    /// preview opens it.
    enum Flavour {
        case folder, link, image, code, script, text, archive, other

        var symbol: String {
            switch self {
            case .folder: return "folder.fill"
            case .link: return "arrow.turn.down.right"
            case .image: return "photo.fill"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .script: return "terminal.fill"
            case .text: return "doc.text.fill"
            case .archive: return "archivebox.fill"
            case .other: return "doc.fill"
            }
        }
    }

    var flavour: Flavour {
        switch kind {
        case .directory: return .folder
        case .link: return .link
        case .other: return .other
        case .file: break
        }
        let lower = name.lowercased()
        if Self.images.contains(fileExtension) { return .image }
        if Self.archives.contains(fileExtension) { return .archive }
        if Self.scripts.contains(fileExtension) || lower.hasSuffix("rc")
            || lower == ".profile" || lower == ".bash_profile" { return .script }
        if Self.code.contains(fileExtension) || lower == "dockerfile"
            || lower == "makefile" || lower == "package.swift" { return .code }
        if Self.texts.contains(fileExtension) || fileExtension.isEmpty { return .text }
        return .other
    }

    private static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif",
                                              "webp", "bmp", "tiff", "tif", "ico"]
    private static let archives: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "zst",
                                                "7z", "rar", "dmg", "deb", "rpm", "pkg"]
    private static let scripts: Set<String> = ["sh", "bash", "zsh", "fish", "command"]
    private static let code: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs",
                                            "c", "h", "cpp", "hpp", "cc", "m", "mm", "java", "kt",
                                            "rb", "php", "html", "css", "scss", "json", "yaml",
                                            "yml", "toml", "xml", "sql", "lua", "zig", "nix",
                                            "tf", "proto", "gradle", "cmake"]
    private static let texts: Set<String> = ["md", "txt", "log", "conf", "cfg", "ini", "env",
                                             "csv", "service", "timer", "plist", "pem", "pub",
                                             "license", "rst", "org"]
}

/// A directory, read.
struct RemoteListing: Sendable {
    /// The path as the host resolved it: symlinks followed, `~` expanded.
    var path: String
    var entries: [RemoteEntry]
}

enum RemoteFileError: LocalizedError {
    case failed(String)
    case noCredentials
    case tooLarge(Int64)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .noCredentials: return "This host has no saved password or key yet."
        case .tooLarge(let bytes):
            return "That file is \(formatBytes(Double(bytes))), more than this can carry in one go."
        }
    }
}

/// What a file browser needs from a host. Real over SSH; fake for the
/// design harness.
protocol RemoteFileTransport: Sendable {
    func home() async throws -> String
    func list(_ path: String) async throws -> RemoteListing
    /// The first `limit` bytes of a file.
    func read(_ path: String, limit: Int) async throws -> Data
    func write(_ path: String, data: Data) async throws
    func remove(_ entry: RemoteEntry) async throws
    func makeDirectory(_ path: String) async throws
    func touch(_ path: String) async throws
    func move(_ from: String, to: String) async throws
}

// MARK: - Over SSH

struct SSHFileTransport: RemoteFileTransport {
    let runner: SSHCommandRunner

    func home() async throws -> String {
        let out = try await run("cd && pwd -P").output
        let line = out.split(whereSeparator: \.isNewline).first.map(String.init) ?? "/"
        return line.isEmpty ? "/" : line
    }

    func list(_ path: String) async throws -> RemoteListing {
        // `pwd -P` first, so the browser shows where it really is; then the
        // listing in the C locale, whose date column has one shape on GNU
        // and BSD alike.
        let script = "cd -- \(Self.quote(path)) && pwd -P && LC_ALL=C ls -lA --"
        let out = try await run(script).output
        var lines = out.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.first else { return RemoteListing(path: path, entries: []) }
        lines.removeFirst()
        let resolved = String(first).isEmpty ? path : String(first)
        return RemoteListing(path: resolved,
                             entries: Self.parse(lines.map(String.init), in: resolved))
    }

    func read(_ path: String, limit: Int) async throws -> Data {
        // Redirected in rather than named, so a file whose name starts
        // with a dash is still a file and not an option.
        try await run("head -c \(limit) < \(Self.quote(path))", timeout: .seconds(300)).data
    }

    func write(_ path: String, data: Data) async throws {
        _ = try await run("cat > \(Self.quote(path))", input: data, timeout: .seconds(300))
    }

    func remove(_ entry: RemoteEntry) async throws {
        let flags = entry.isDirectory ? "-rf" : "-f"
        _ = try await run("rm \(flags) -- \(Self.quote(entry.path))")
    }

    func makeDirectory(_ path: String) async throws {
        _ = try await run("mkdir -p -- \(Self.quote(path))")
    }

    func touch(_ path: String) async throws {
        _ = try await run("touch -- \(Self.quote(path))")
    }

    func move(_ from: String, to: String) async throws {
        _ = try await run("mv -- \(Self.quote(from)) \(Self.quote(to))")
    }

    // MARK: Plumbing

    private func run(_ command: String, input: Data? = nil,
                     timeout: Duration = .seconds(60)) async throws -> SSHExecResult {
        let result = try await runner.run(command, input: input, timeout: timeout)
        guard result.exitStatus == 0 else {
            throw RemoteFileError.failed(Self.message(result.errorOutput, status: result.exitStatus))
        }
        return result
    }

    /// Single-quoted for the shell: the one quoting that needs no thought
    /// about what is inside, except a quote itself.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The last line of stderr, past the `sh: line 1: cd:` preamble:
    /// "Permission denied", "No such file or directory".
    static func message(_ stderr: String, status: Int32) -> String {
        let line = stderr.split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return "The host said no (exit \(status))." }
        let tail = line.components(separatedBy: ": ").last ?? line
        return tail.prefix(1).uppercased() + tail.dropFirst()
    }

    // MARK: Parsing ls

    /// `-rw-r--r--  1 user group  1234 Sep  3 14:22 name`, with the date
    /// as `Mon DD HH:MM` for this half-year and `Mon DD  YYYY` before it.
    /// Everything after the single space that follows the date is the
    /// name, spaces and all.
    nonisolated(unsafe) private static let line = #/^(?<perms>\S+)\s+\d+\s+(?<owner>\S+)\s+\S+\s+(?<size>\d+|\d+,\s*\d+)\s+(?<month>[A-Za-z]{3})\s+(?<day>\d{1,2})\s+(?<clock>\d{1,2}:\d{2}|\d{4})\s(?<name>.*)$/#

    static func parse(_ lines: [String], in directory: String, now: Date = Date()) -> [RemoteEntry] {
        var out: [RemoteEntry] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .newlines)
            guard !line.isEmpty, !line.hasPrefix("total ") else { continue }
            guard let match = line.wholeMatch(of: Self.line) else { continue }
            var name = String(match.name)
            var target: String?
            let kind: RemoteEntry.Kind
            switch match.perms.first {
            case "d": kind = .directory
            case "l": kind = .link
            case "-": kind = .file
            default: kind = .other
            }
            if kind == .link, let arrow = name.range(of: " -> ") {
                target = String(name[arrow.upperBound...])
                name = String(name[..<arrow.lowerBound])
            }
            guard name != "." && name != ".." else { continue }
            out.append(RemoteEntry(
                name: name,
                path: directory == "/" ? "/" + name : directory + "/" + name,
                kind: kind,
                size: Int64(match.size) ?? 0,
                modified: date(month: match.month, day: match.day, clock: match.clock, now: now),
                permissions: String(match.perms),
                owner: String(match.owner),
                linkTarget: target))
        }
        return out
    }

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    private static func date(month: Substring, day: Substring, clock: Substring, now: Date) -> Date? {
        guard let m = months[month.lowercased()], let d = Int(day) else { return nil }
        let calendar = Calendar.current
        var comps = DateComponents()
        comps.month = m
        comps.day = d
        if clock.contains(":") {
            let parts = clock.split(separator: ":")
            comps.hour = Int(parts[0])
            comps.minute = parts.count > 1 ? Int(parts[1]) : 0
            comps.year = calendar.component(.year, from: now)
            guard var date = calendar.date(from: comps) else { return nil }
            // A date in the future without a year is last year's.
            if date.timeIntervalSince(now) > 86_400 {
                comps.year! -= 1
                date = calendar.date(from: comps) ?? date
            }
            return date
        }
        comps.year = Int(clock)
        return calendar.date(from: comps)
    }
}

// MARK: - Transports by host

/// One transport per host, and a way for the harness to hand in a fake.
@MainActor
enum FileTransports {
    private static var injected: [UUID: any RemoteFileTransport] = [:]

    static func inject(_ transport: any RemoteFileTransport, for host: Host) {
        injected[host.id] = transport
    }

    static func transport(for host: Host) -> (any RemoteFileTransport)? {
        if let fake = injected[host.id] { return fake }
        guard let credentials = KeyStore.shared.credentials(for: host) else { return nil }
        return SSHFileTransport(runner: SSHCommandRunner(
            host: host, credentials: credentials, timeout: .seconds(60), policy: .ask))
    }
}

// MARK: - A fake, for looking at the screens

/// A home directory that exists only in memory, for the design harness
/// and the tour. Behaves like the real thing: files made here are here on
/// the next listing.
final class FakeFileTransport: RemoteFileTransport, @unchecked Sendable {
    private var directories: [String: [RemoteEntry]] = [:]
    private var contents: [String: Data] = [:]
    private let lock = NSLock()
    private let root: String

    init(home: String) { root = home }

    func home() async throws -> String { root }

    func list(_ path: String) async throws -> RemoteListing {
        try await Task.sleep(for: .milliseconds(350))
        return lock.withLock {
            guard let entries = directories[path] else {
                return RemoteListing(path: path, entries: [])
            }
            return RemoteListing(path: path, entries: entries)
        }
    }

    func read(_ path: String, limit: Int) async throws -> Data {
        try await Task.sleep(for: .milliseconds(300))
        return lock.withLock { contents[path].map { $0.prefix(limit) } ?? Data() }
    }

    func write(_ path: String, data: Data) async throws {
        try await Task.sleep(for: .milliseconds(400))
        lock.withLock {
            contents[path] = data
            let dir = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            var entries = directories[dir] ?? []
            if let i = entries.firstIndex(where: { $0.path == path }) {
                entries[i].size = Int64(data.count)
                entries[i].modified = Date()
            } else {
                entries.append(RemoteEntry(name: name, path: path, kind: .file, size: Int64(data.count),
                                           modified: Date(), permissions: "-rw-r--r--", owner: "mahdiar"))
            }
            directories[dir] = entries
        }
    }

    func remove(_ entry: RemoteEntry) async throws {
        lock.withLock {
            let dir = (entry.path as NSString).deletingLastPathComponent
            directories[dir]?.removeAll { $0.path == entry.path }
            directories[entry.path] = nil
            contents[entry.path] = nil
        }
    }

    func makeDirectory(_ path: String) async throws {
        add(path, kind: .directory)
        lock.withLock { directories[path] = directories[path] ?? [] }
    }

    func touch(_ path: String) async throws {
        add(path, kind: .file)
        lock.withLock { contents[path] = contents[path] ?? Data() }
    }

    func move(_ from: String, to: String) async throws {
        lock.withLock {
            let dir = (from as NSString).deletingLastPathComponent
            guard var entries = directories[dir],
                  let i = entries.firstIndex(where: { $0.path == from }) else { return }
            entries[i].path = to
            entries[i].name = (to as NSString).lastPathComponent
            directories[dir] = entries
            contents[to] = contents.removeValue(forKey: from)
            if let sub = directories.removeValue(forKey: from) { directories[to] = sub }
        }
    }

    private func add(_ path: String, kind: RemoteEntry.Kind) {
        lock.withLock {
            let dir = (path as NSString).deletingLastPathComponent
            var entries = directories[dir] ?? []
            guard !entries.contains(where: { $0.path == path }) else { return }
            entries.append(RemoteEntry(name: (path as NSString).lastPathComponent, path: path,
                                       kind: kind, size: 0, modified: Date(),
                                       permissions: kind == .directory ? "drwxr-xr-x" : "-rw-r--r--",
                                       owner: "mahdiar"))
            directories[dir] = entries
        }
    }

    /// A believable home directory.
    static func sample() -> FakeFileTransport {
        let home = "/home/mahdiar"
        let fake = FakeFileTransport(home: home)
        let now = Date()
        func entry(_ name: String, in dir: String, _ kind: RemoteEntry.Kind, size: Int64,
                   ago: TimeInterval, perms: String? = nil) -> RemoteEntry {
            RemoteEntry(name: name, path: dir == "/" ? "/" + name : dir + "/" + name, kind: kind,
                        size: size, modified: now.addingTimeInterval(-ago),
                        permissions: perms ?? (kind == .directory ? "drwxr-xr-x" : "-rw-r--r--"),
                        owner: "mahdiar")
        }
        let notes = """
        # Notes

        - rotate the deploy key on build before Friday
        - web-01 is still on the old kernel; reboot after the 2am backup
        - move the dashboards to the new Grafana once the datasource is in

        ## Later

        Try the container runtime on studio again. It fell over on the
        second image last time, which smells like the disk rather than the
        runtime.
        """
        let deploy = """
        #!/bin/sh
        set -eu

        cd /srv/app
        git pull --ff-only
        docker compose build web
        docker compose up -d web
        docker image prune -f
        """
        // One formatter for the whole log: making one per line is the kind
        // of thing that holds the main thread for seconds.
        let stamps = DateFormatter()
        stamps.dateFormat = "MMM dd HH:mm:ss"
        let log = (0..<600).map { i in
            let stamp = now.addingTimeInterval(Double(-i) * 37)
            let kind = ["GET /", "GET /api/hosts", "POST /api/session", "GET /health"][i % 4]
            return "\(stamps.string(from: stamp)) web-01 app[412]: \(kind) 200 \(11 + (i * 7) % 90)ms"
        }.joined(separator: "\n")

        fake.directories[home] = [
            entry(".config", in: home, .directory, size: 4096, ago: 86_400 * 3),
            entry(".ssh", in: home, .directory, size: 4096, ago: 86_400 * 40, perms: "drwx------"),
            entry(".zshrc", in: home, .file, size: 1_284, ago: 86_400 * 12),
            entry("Projects", in: home, .directory, size: 4096, ago: 3_600 * 2),
            entry("Documents", in: home, .directory, size: 4096, ago: 86_400 * 6),
            entry("Downloads", in: home, .directory, size: 4096, ago: 1_800),
            entry("notes.md", in: home, .file, size: Int64(notes.utf8.count), ago: 2_400),
            entry("deploy.sh", in: home, .file, size: Int64(deploy.utf8.count), ago: 86_400,
                  perms: "-rwxr-xr-x"),
            entry("server.log", in: home, .file, size: Int64(log.utf8.count), ago: 120),
            entry("avatar.png", in: home, .file, size: 0, ago: 86_400 * 200),
            entry("backup-2026-09.tar.gz", in: home, .file, size: 126_812_160, ago: 86_400 * 2),
            entry("id_ed25519.pub", in: home, .file, size: 104, ago: 86_400 * 300),
        ]
        fake.directories[home + "/Projects"] = [
            entry("conterm", in: home + "/Projects", .directory, size: 4096, ago: 3_600 * 2),
            entry("conterm-ios", in: home + "/Projects", .directory, size: 4096, ago: 900),
            entry("README.md", in: home + "/Projects", .file, size: 412, ago: 86_400 * 30),
        ]
        fake.directories[home + "/Projects/conterm-ios"] = [
            entry("Sources", in: home + "/Projects/conterm-ios", .directory, size: 4096, ago: 900),
            entry("Shared", in: home + "/Projects/conterm-ios", .directory, size: 4096, ago: 5_000),
            entry("README.md", in: home + "/Projects/conterm-ios", .file, size: 24_118, ago: 1_200),
            entry("Package.swift", in: home + "/Projects/conterm-ios", .file, size: 1_902, ago: 86_400 * 8),
        ]
        fake.directories[home + "/Documents"] = []
        fake.directories[home + "/Downloads"] = [
            entry("ubuntu-24.04.iso", in: home + "/Downloads", .file, size: 2_147_483_648, ago: 86_400 * 5),
        ]
        fake.directories[home + "/.config"] = [
            entry("conterm", in: home + "/.config", .directory, size: 4096, ago: 3_600),
        ]
        fake.directories[home + "/.ssh"] = [
            entry("authorized_keys", in: home + "/.ssh", .file, size: 208, ago: 86_400 * 40,
                  perms: "-rw-------"),
        ]
        fake.contents[home + "/notes.md"] = Data(notes.utf8)
        fake.contents[home + "/deploy.sh"] = Data(deploy.utf8)
        fake.contents[home + "/server.log"] = Data(log.utf8)
        fake.contents[home + "/.zshrc"] = Data("export EDITOR=vim\nalias ll='ls -la'\n".utf8)
        fake.contents[home + "/id_ed25519.pub"] = Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialForTheTourOnly mahdiar@studio\n".utf8)
        fake.contents[home + "/Projects/README.md"] = Data("# Projects\n\nWhat lives here.\n".utf8)
        let png = Self.avatar()
        fake.contents[home + "/avatar.png"] = png
        if let i = fake.directories[home]?.firstIndex(where: { $0.name == "avatar.png" }) {
            fake.directories[home]?[i].size = Int64(png.count)
        }
        return fake
    }

    /// A drawn picture, so the image preview has something to show.
    private static func avatar() -> Data {
        let size = CGSize(width: 320, height: 320)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 0.14, green: 0.47, blue: 0.98, alpha: 1).cgColor,
                          UIColor(red: 0.52, green: 0.33, blue: 0.95, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                      locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                  options: [])
            cg.setFillColor(UIColor(white: 1, alpha: 0.92).cgColor)
            cg.fillEllipse(in: CGRect(x: 96, y: 60, width: 128, height: 128))
            cg.fillEllipse(in: CGRect(x: 52, y: 196, width: 216, height: 200))
        }
        return image.pngData() ?? Data()
    }
}
