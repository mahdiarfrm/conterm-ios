import Foundation
import UIKit

/// Drives a real terminal against a real shell and reads back what landed.
///
/// The bar is "`vim` and `htop` are usable over SSH". This runs the
/// machine-checkable half of it: a pty of the right size, a flood that must
/// not drop bytes, a full-screen application drawing and leaving cleanly, a
/// resize the far end agrees with, Ctrl-C actually interrupting, and text
/// making the round trip through the selection and the pasteboard.
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
        await measureRefreshRate()

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
        //
        //    Reversed on the far side on purpose. The first version searched
        //    for the punctuation itself, which a terminal echoes as you type
        //    it — so it passed whether or not the command ran, and its own
        //    quoting wedged the shell for every step after it. The reversal
        //    cannot appear in the echo, so a pass means the far end really
        //    received these characters.
        let punctuation = "!@#$%^&*()-_=+[]{}|;:,.<>/?~"
        let reversed = String(punctuation.reversed())
        type("clear; printf %s '\(punctuation)' | rev", in: session)
        let punctSeen = await waitFor(reversed, in: session, seconds: 10)
        check("punctuation types correctly", punctSeen)
        if !punctSeen { dump("punctuation", session) }

        // 8. Scroll fidelity: a drag of one screen must move one screen.
        //
        //    "Slow to scroll" is measurable, so measure it. libghostty
        //    compares the offset against a cell height in device pixels while
        //    UIKit hands out points, so on a 3× phone this was moving a third
        //    as far as the finger asked.
        // Plain `seq`, no command substitution or quoting: the point here is
        // the scroll, and a command that fails to run just reads as a scroll
        // that didn't move.
        type("clear; seq 1 400", in: session)
        try? await Task.sleep(for: .seconds(2))

        let rows = session.grid.rows
        let heightPoints = session.surfaceView.bounds.height
        let firstBefore = Self.lineNumber(session.firstViewportLine)
        session.surfaceView.controller?.scroll(byPoints: heightPoints)
        try? await Task.sleep(for: .milliseconds(500))
        let firstAfter = Self.lineNumber(session.firstViewportLine)

        if firstBefore == nil || firstAfter == nil { dump("scroll", session) }
        if let before = firstBefore, let after = firstAfter {
            // Dragging down reveals older output, so the first visible line
            // number goes down by about one screen of rows.
            let moved = before - after
            let ratio = Double(moved) / Double(max(rows, 1))
            check("a screen of drag scrolls a screen", ratio > 0.85 && ratio < 1.15,
                  String(format: "moved %d of %d rows (%.0f%%)", moved, rows, ratio * 100))
        } else {
            check("a screen of drag scrolls a screen", false,
                  "couldn't read line numbers: \(session.firstViewportLine)")
        }

        // 9. Search the scrollback. This drives libghostty's own engine
        //    through a keybind action, which is a path the embedded apprt
        //    could plausibly not have wired at all — so it is asserted rather
        //    than assumed.
        type("clear; seq 1 300; printf 'NEEDLE%s\\n' 7; seq 301 600", in: session)
        try? await Task.sleep(for: .seconds(3))
        session.searchQuery = "NEEDLE7"
        let found = await settle(seconds: 8) { session.searchTotal > 0 }
        check("scrollback search finds a match", found,
              "total \(session.searchTotal)")

        // And a needle that is not there must report nothing rather than
        // holding the last result, which is how a find bar starts lying.
        session.searchQuery = "NOTHINGLIKETHIS"
        let cleared = await settle(seconds: 6) { session.searchTotal == 0 }
        check("search clears for a needle that is absent", cleared,
              "total \(session.searchTotal)")
        session.endSearch()

        // 10. Selection and the clipboard. Selection is libghostty's, driven
        //     through mouse events, and the coordinate space it wants is
        //     pixels while UIKit hands out points — a mismatch that would
        //     select the wrong cell by the scale factor and is invisible in
        //     a screenshot. So the round trip is measured: put a known token
        //     on screen, select everything, read the selection back.
        let token = "SELECTME\(Int.random(in: 1000...9999))"
        type("clear; printf '%s\\n' \(token)", in: session)
        try? await Task.sleep(for: .seconds(2))

        let surface = session.surfaceView
        surface.controller?.selectAll()
        let selected = await settle(seconds: 4) {
            surface.controller?.hasSelection == true
        }
        check("select all makes a selection", selected)

        let selection = surface.controller?.selectedText ?? ""
        check("selection reads back", selection.contains(token),
              "\(selection.count) chars, token \(selection.contains(token) ? "in" : "missing")")

        // Copy goes to the pasteboard and takes the highlight with it.
        let copied = surface.copySelection()
        check("copy reaches the pasteboard",
              copied && (UIPasteboard.general.string?.contains(token) ?? false))
        check("copy clears the selection", surface.controller?.hasSelection == false)

        // And back in. Paste is bracketed, so it must arrive as content
        // rather than as keystrokes — which is the whole reason it does not
        // go through the type path.
        let pasted = "PASTED\(Int.random(in: 1000...9999))"
        UIPasteboard.general.string = pasted
        type("clear", in: session)
        try? await Task.sleep(for: .seconds(1))
        surface.pasteFromPasteboard()
        let arrived = await waitFor(pasted, in: session, seconds: 5)
        check("paste reaches the far end", arrived)
        session.press(.keyboardReturnOrEnter)
        try? await Task.sleep(for: .milliseconds(400))

        type("rm -f /tmp/conterm-selftest.txt", in: session)
        try? await Task.sleep(for: .milliseconds(300))
        session.disconnect()
        say("--- terminal done ---")
    }

    /// The first integer on a line. `read_text` keeps the trailing spaces of
    /// each grid row, so a screen of short lines comes back with more than
    /// one number per line of text.
    private static func lineNumber(_ line: String) -> Int? {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { Int($0) }
            .first
    }

    /// What the display actually gives us, as opposed to what we asked for.
    ///
    /// A CADisplayLink can request 120Hz and be handed 60 without saying so:
    /// iOS clamps every app to 60 on a ProMotion phone unless the Info.plist
    /// opts in with `CADisableMinimumFrameDurationOnPhone`. The only honest
    /// way to know which you got is to count ticks. Simulators report 60
    /// whatever the plist says — this number means something on a device.
    private static func measureRefreshRate() async {
        let counter = TickCounter()
        let link = CADisplayLink(target: counter, selector: #selector(TickCounter.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        try? await Task.sleep(for: .milliseconds(1500))
        link.invalidate()
        let rate = Double(counter.count) / 1.5
        say(String(format: "INFO display link %.0f fps (max %.0f advertised)",
                   rate, Double(UIScreen.main.maximumFramesPerSecond)))
    }

    private final class TickCounter: NSObject {
        var count = 0
        @objc func tick() { count += 1 }
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
