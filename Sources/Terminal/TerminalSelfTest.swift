import Foundation
import UIKit

/// Drives a real terminal against a real shell and reads back what landed.
///
/// The plan's Phase 0c gate was "`vim` and `htop` are usable over SSH", and
/// until now nothing in this project had ever met an SSH daemon, so the gate
/// had never been run at all. This runs the machine-checkable half of it: a
/// pty of the right size, a flood that must not drop bytes, a full-screen
/// application drawing and leaving cleanly, a resize the far end agrees with,
/// and Ctrl-C actually interrupting.
///
/// It reads the terminal's own viewport rather than the bytes on the wire, so
/// a pass means the whole path worked — libssh2, the external termio backend,
/// the VT parser and the grid — not merely that data arrived.
///
/// **Markers are built on the far side**, with `printf 'TAG%s' n` rather than
/// `echo TAGn`. A terminal echoes what you type, so a marker written literally
/// in the command appears on screen whether or not the command ever ran — the
/// first version of this test passed and failed for that reason rather than
/// for any real one.
@MainActor
enum TerminalSelfTest {

    private static func say(_ text: String) { NSLog("CONTERM-TERMTEST %@", text) }

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        say("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    /// The last few lines actually on screen. Printed whenever something
    /// fails, because "FAIL flood" on its own says nothing about why.
    private static func dump(_ label: String, _ session: TerminalSession) {
        let lines = (session.surfaceView.controller?.viewportText ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(6)
            .map { $0.prefix(90) }
            .joined(separator: " ⏎ ")
        say("     screen[\(label)]: \(lines)")
    }

    /// Type a line through the same door the software keyboard uses.
    ///
    /// `insertText` is what iOS calls when someone taps a key, so driving it
    /// directly is the difference between testing the app and testing a
    /// convenient approximation of it. The first version of this test called
    /// `session.send`, which is paste, and so measured a path no keyboard
    /// takes.
    private static func type(_ text: String, in session: TerminalSession) {
        session.surfaceView.insertText(text + "\n")
    }

    private static var counter = 0

    /// A token this test can search for that the echo of the command cannot
    /// produce, because the far shell assembles it.
    private static func mark(_ tag: String) -> (emit: String, needle: String) {
        counter += 1
        return ("printf '\(tag)%s\\n' \(counter)", "\(tag)\(counter)")
    }

    static func run(host: Host, credentials: SSHCredentials, app: Ghostty.App) async {
        say("--- terminal against \(host.displaySubtitle) ---")

        let session = TerminalSession(host: host, app: app)
        // The view never enters a hierarchy here. It doesn't need to: the
        // surface is created with a real 800×600 frame in `init`, and the
        // grid follows from that.
        session.connect(credentials: credentials)

        guard await settle(seconds: 25, { session.state == .connected }) else {
            check("connect", false, "\(session.state)")
            session.disconnect()
            return
        }
        check("connect", true)

        // A prompt of our own, so every later wait has something unambiguous
        // to look for, and a shell that won't wrap or paginate on us.
        type("PS1='> '; unset PROMPT_COMMAND; stty -echo; clear", in: session)
        let ready = mark("RDY")
        type(ready.emit, in: session)
        let prompted = await waitFor(ready.needle, in: session, seconds: 15)
        check("shell prompt", prompted)
        if !prompted { dump("prompt", session) }

        // 1. The pty is the size the surface is. Getting this wrong is how a
        //    terminal ends up wrapping at 80 columns forever.
        let grid = session.grid
        type("stty size", in: session)
        let sizeSeen = await waitFor("\(grid.rows) \(grid.columns)", in: session, seconds: 10)
        check("pty matches the grid", sizeSeen, "\(grid.columns)×\(grid.rows)")
        if !sizeSeen { dump("stty", session) }

        // 2. Resize, and check the far end was told. This is the path that
        //    runs on every rotation.
        session.surfaceView.frame = CGRect(x: 0, y: 0, width: 500, height: 700)
        session.surfaceView.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        let resized = session.grid
        type("clear; stty size", in: session)
        let resizeSeen = await waitFor("\(resized.rows) \(resized.columns)",
                                       in: session, seconds: 10)
        check("resize reaches the remote pty", resizeSeen && resized != grid,
              "\(grid.columns)×\(grid.rows) → \(resized.columns)×\(resized.rows)")
        if !resizeSeen { dump("resize", session) }

        // 3. A flood. `bytesIn` counts what came off the wire, so comparing it
        //    against what was asked for catches a drop the screen can't show.
        let flood = 200_000
        let floodMark = mark("FLOOD")
        let before = session.bytesIn
        let started = Date()
        type("head -c \(flood) /dev/zero | tr '\\0' 'x' | fold -w 120; "
             + floodMark.emit, in: session)
        let floodDone = await waitFor(floodMark.needle, in: session, seconds: 60)
        let delta = session.bytesIn - before
        check("flood arrives whole", floodDone && delta >= flood,
              String(format: "%d of %d bytes in %.1fs", delta, flood,
                     Date().timeIntervalSince(started)))
        if !floodDone || delta < flood { dump("flood", session) }

        // 4. A full-screen application: alternate screen, cursor addressing,
        //    the lot. `vi` is on every Unix worth connecting to.
        //
        //    `-u NONE` because the point is the terminal, not the far user's
        //    vimrc: one run of this failed on a plugin error from the host's
        //    own config, which the terminal had in fact rendered perfectly.
        //    `-n` for no swap file, because a swap left by a failed run makes
        //    the next one open on a recovery prompt that eats everything
        //    typed after it.
        type("rm -f /tmp/.conterm-selftest.txt.swp; "
             + "clear; vi -u NONE -n /tmp/conterm-selftest.txt", in: session)
        let inEditor = await settle(seconds: 15) {
            let text = session.surfaceView.controller?.viewportText ?? ""
            // vi paints empty lines with `~` down the left margin.
            return text.split(separator: "\n").filter { $0.hasPrefix("~") }.count >= 3
        }
        check("full-screen app draws", inEditor)
        dump("vi", session)

        // Leaving is the test that matters, and the one that caught this.
        // `:q!` typed on a phone keyboard used to be *pasted*, and vim treats
        // bracketed-paste content as text — so it inserted `:q!` into the
        // file instead of running it, and there was no way out of an editor
        // from this app at all.
        session.press(.keyboardEscape)
        try? await Task.sleep(for: .milliseconds(250))
        type(":q!", in: session)
        try? await Task.sleep(for: .milliseconds(400))
        let back = mark("BACK")
        type(back.emit, in: session)
        let leftEditor = await waitFor(back.needle, in: session, seconds: 15)
        check("full-screen app exits", leftEditor)
        if !leftEditor { dump("after vi", session) }

        // 5. Ctrl-C. Sent as a real keypress: `ghostty_surface_text` is the
        //    paste path and strips control bytes, which is the bug that ate
        //    backspace once already.
        let leak = mark("LEAK")
        type("clear; sleep 45; " + leak.emit, in: session)
        try? await Task.sleep(for: .milliseconds(800))
        session.press(.keyboardC, mods: GHOSTTY_MODS_CTRL)
        let after = mark("INTR")
        try? await Task.sleep(for: .milliseconds(400))
        type(after.emit, in: session)
        let interrupted = await waitFor(after.needle, in: session, seconds: 12)
        let leaked = (session.surfaceView.controller?.viewportText ?? "")
            .contains(leak.needle)
        check("ctrl-C interrupts", interrupted && !leaked,
              leaked ? "the interrupted command ran anyway" : "")
        if !interrupted || leaked { dump("ctrl-c", session) }

        // 6. UTF-8 and wide glyphs, which is where a byte-at-a-time parser
        //    shows itself.
        type("clear; printf 'h\\303\\251llo \\346\\227\\245\\346\\234\\254\\350\\252\\236\\n'", in: session)
        let unicode = await waitFor("日本語", in: session, seconds: 10)
        check("utf-8 and wide glyphs", unicode)
        if !unicode { dump("unicode", session) }

        // 7. Every shifted character and every punctuation key, through the
        //    same door. A missing entry in the layout map means a character
        //    that silently falls back to paste.
        let punct = mark("PUNCT")
        type("printf '%s\\n' \"$(echo 'A1!@#$%^&*()-_=+[]{}\\\\|;:,.<>/?~`\"'\"'\"')\"",
             in: session)
        let punctSeen = await waitFor("A1!@#$%^&*()-_=+[]{}", in: session, seconds: 10)
        check("punctuation types correctly", punctSeen)
        if !punctSeen { dump("punctuation", session) }
        _ = punct

        type("rm -f /tmp/conterm-selftest.txt", in: session)
        try? await Task.sleep(for: .milliseconds(300))
        session.disconnect()
        say("--- terminal done ---")
    }

    // MARK: - Waiting

    private static func waitFor(_ needle: String,
                                in session: TerminalSession,
                                seconds: Double) async -> Bool {
        await settle(seconds: seconds) {
            (session.surfaceView.controller?.viewportText ?? "").contains(needle)
        }
    }

    private static func settle(seconds: Double,
                               _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return condition()
    }
}
