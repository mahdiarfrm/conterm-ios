import Foundation
import Testing
@testable import Conterm

/// `ls -l` in the C locale has one shape on GNU and BSD, and the file
/// browser reads it. These pin the corners: a name with spaces, a
/// symlink, a year instead of a time, macOS's extended-attribute flag.
struct RemoteFilesTests {

    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 12))!

    @Test("a GNU listing, with a total line, a folder, a file and a link")
    func gnu() {
        let entries = SSHFileTransport.parse("""
        total 24
        drwxr-xr-x 3 mahdiar mahdiar 4096 Sep  3 14:22 Projects
        -rw-r--r-- 1 mahdiar mahdiar 1284 Jan 15  2024 notes.md
        lrwxrwxrwx 1 mahdiar mahdiar   11 Sep 10 09:01 current -> Projects/v2
        """.split(separator: "\n").map(String.init), in: "/home/mahdiar", now: now)

        #expect(entries.count == 3)
        #expect(entries[0].kind == .directory)
        #expect(entries[0].path == "/home/mahdiar/Projects")
        #expect(entries[1].kind == .file)
        #expect(entries[1].size == 1284)
        #expect(Calendar.current.component(.year, from: entries[1].modified!) == 2024)
        #expect(entries[2].kind == .link)
        #expect(entries[2].name == "current")
        #expect(entries[2].linkTarget == "Projects/v2")
    }

    @Test("names keep their spaces, and the root joins without a double slash")
    func spaces() {
        let entries = SSHFileTransport.parse([
            "-rw-r--r--@ 1 mahdiar staff 20480 Aug 30 21:31 My  Report final.pdf",
        ], in: "/", now: now)
        #expect(entries.count == 1)
        #expect(entries[0].name == "My  Report final.pdf")
        #expect(entries[0].path == "/My  Report final.pdf")
        #expect(entries[0].flavour == .other)
    }

    @Test("a date without a year that would be in the future is last year's")
    func lastYear() {
        let entries = SSHFileTransport.parse([
            "-rw-r--r-- 1 root root 5 Dec 20 08:00 late",
        ], in: "/tmp", now: now)
        let year = Calendar.current.component(.year, from: entries[0].modified!)
        #expect(year == 2025)
    }

    @Test("what the name says the file is")
    func flavours() {
        func entry(_ name: String) -> RemoteEntry {
            RemoteEntry(name: name, path: "/" + name, kind: .file, size: 1,
                        modified: nil, permissions: "-rw-r--r--", owner: "u")
        }
        #expect(entry("photo.HEIC").flavour == .image)
        #expect(entry("deploy.sh").flavour == .script)
        #expect(entry(".zshrc").flavour == .script)
        #expect(entry("main.swift").flavour == .code)
        #expect(entry("Dockerfile").flavour == .code)
        #expect(entry("notes.md").flavour == .text)
        #expect(entry("backup.tar.gz").flavour == .archive)
    }

    @Test("the shell quoting survives a quote in the name")
    func quoting() {
        #expect(SSHFileTransport.quote("it's here") == "'it'\\''s here'")
    }

    @Test("the handoff types the ssh line the host needs")
    func handoffCommand() {
        var host = Host(alias: "web", hostname: "10.0.0.4", username: "deploy")
        #expect(Handoff.command(for: host) == "ssh deploy@10.0.0.4")
        host.port = 2222
        host.proxyJump = "bastion"
        #expect(Handoff.command(for: host) == "ssh -p 2222 -J bastion deploy@10.0.0.4")
    }
}
