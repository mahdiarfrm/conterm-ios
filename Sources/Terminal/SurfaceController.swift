import Foundation
import UIKit
import os

/// Owns one `ghostty_surface_t` and the view it renders into.
///
/// The surface is created with libghostty's **external** termio backend, so
/// it has no child process and no pty. Bytes arrive by `write(_:)` and leave
/// through `onWrite`. Everything about resizing, focus and occlusion is the
/// same as the Mac app; everything about where the bytes come from is not.
@MainActor
final class SurfaceController {

    /// Bytes the terminal wants sent to the far end. Called on libghostty's
    /// IO thread, hopped to the main actor before it reaches you.
    var onWrite: ((Data) -> Void)?

    /// The terminal resized. Forward this to the remote pty.
    var onResize: ((_ columns: Int, _ rows: Int) -> Void)?

    /// The remote reported a title (OSC 0/2).
    var onTitle: ((String) -> Void)?

    private(set) var handle: ghostty_surface_t?
    private unowned let view: TerminalSurfaceView

    /// Guards against pushing an identical size on every layout pass —
    /// `ghostty_surface_set_size` is not free and layout runs constantly.
    private var lastPushedSize: CGSize = .zero
    private var lastPushedScale: CGFloat = 0

    /// The size we last told the far end about, so a layout that doesn't
    /// change the *cell* grid doesn't generate an SSH window-change.
    private var lastReportedGrid: (columns: Int, rows: Int) = (0, 0)

    init(view: TerminalSurfaceView, app: Ghostty.App, fontSize: Float) {
        self.view = view

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(
                uiview: Unmanaged.passUnretained(view).toOpaque()))
        config.scale_factor = Double(view.contentScaleFactor)
        config.font_size = fontSize
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // The external backend. Without this libghostty tries to spawn
        // /bin/sh on a pty, which on iOS is a NullPty and a process that
        // cannot exist — the surface would render an empty grid forever.
        config.termio_external = true
        config.termio_userdata = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        // File-scope functions, not closures: libghostty invokes both from
        // its IO thread, and a closure written here would inherit this
        // type's main-actor isolation and trap on the executor check the
        // first time the far end says anything.
        config.termio_write_cb = ghosttyTermioWrite
        config.termio_resize_cb = ghosttyTermioResize

        guard let handle = ghostty_surface_new(app.handle, &config) else {
            Ghostty.log.error("ghostty_surface_new returned null")
            return
        }
        self.handle = handle
        SurfaceRegistry.shared.register(self, handle: handle)
    }

    func close() {
        guard let handle else { return }
        SurfaceRegistry.shared.unregister(handle: handle)
        ghostty_surface_free(handle)
        self.handle = nil
    }

    // MARK: - Data path

    /// Total bytes handed to libghostty. Distinguishes "nothing was written"
    /// from "it was written and did not render".
    private(set) var bytesWritten = 0

    /// Push bytes from the far end into the terminal.
    func write(_ data: Data) {
        guard let handle, !data.isEmpty else {
            Ghostty.log.error("write dropped: handle=\(self.handle != nil) bytes=\(data.count)")
            return
        }
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_surface_write_output(handle, base, raw.count)
        }
        bytesWritten += data.count
        Ghostty.log.info("wrote \(data.count)B total=\(self.bytesWritten)")
    }

    /// Read the visible viewport back out of the terminal.
    ///
    /// This is the only way to tell "the bytes never reached the emulator"
    /// apart from "the emulator has them and the renderer isn't drawing" —
    /// two failures that both present as a black rectangle.
    var viewportText: String? {
        guard let handle else { return nil }
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        selection.bottom_right = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        selection.rectangle = false

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(handle, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(handle, &text) }
        guard let ptr = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)),
                      as: UTF8.self)
    }

    /// Send text as if typed. Goes out through `onWrite`.
    func send(_ text: String) {
        guard let handle, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(handle, ptr, UInt(strlen(ptr)))
        }
    }

    func send(key: ghostty_input_key_s) {
        guard let handle else { return }
        _ = ghostty_surface_key(handle, key)
    }

    /// Paste, with bracketed-paste markers — which is what makes a paste
    /// distinguishable from typing to the program on the far end.
    func paste(_ text: String) {
        send(text)
    }

    /// Type text, one key event per character.
    ///
    /// The distinction this draws is the whole point. `send` is
    /// `ghostty_surface_text`, which is *paste*, and a program that
    /// understands bracketed paste treats what arrives as content rather than
    /// as keystrokes — vim inserts `:wq` into the buffer instead of running
    /// it, and a shell puts a newline into its line editor instead of
    /// submitting. So anything the user typed goes through here, and `paste`
    /// is left for what it says.
    ///
    /// `key.text` carries the character. libghostty on macOS gets that from
    /// the NSEvent; there is no equivalent on iOS, so supplying it explicitly
    /// is both simpler and layout-independent.
    func type(_ text: String, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) {
        guard handle != nil else { return }
        // Every typed character comes through here, which is why the tap
        // lives here rather than in the keyboard view — the accessory row and
        // a hardware keyboard get it too, for free.
        if !text.isEmpty { Haptics.shared.typed() }
        for scalar in text.unicodeScalars {
            guard let stroke = TerminalKeyMap.keystroke(for: scalar) else {
                // No key on a US layout produces this — an emoji, an accented
                // character, anything an input method composed. Paste is the
                // honest description of what that is.
                send(String(scalar))
                continue
            }
            var raw = mods.rawValue
            if stroke.shift { raw |= GHOSTTY_MODS_SHIFT.rawValue }
            typeOne(scalar, stroke: stroke, mods: ghostty_input_mods_e(raw))
        }
    }

    private func typeOne(_ scalar: UnicodeScalar,
                         stroke: TerminalKeyMap.Keystroke,
                         mods: ghostty_input_mods_e) {
        guard let handle,
              let keycode = TerminalKeyMap.virtualKeyCode(for: stroke.usage) else { return }

        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = mods
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(keycode)
        key.composing = false
        key.unshifted_codepoint = stroke.unshifted.value

        // Return has to reach the far end as CR: a shell's line discipline
        // ignores a bare LF, which is how Return once appeared to do nothing.
        let produced = scalar == "\n" ? "\r" : String(scalar)
        // A Ctrl or Alt chord produces no text of its own; libghostty derives
        // the control byte from the keycode, and passing the letter as well
        // would type it alongside.
        let bare = mods.rawValue & ~GHOSTTY_MODS_SHIFT.rawValue
        if bare != GHOSTTY_MODS_NONE.rawValue {
            key.text = nil
            _ = ghostty_surface_key(handle, key)
            key.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(handle, key)
            return
        }

        produced.withCString { pointer in
            key.text = pointer
            _ = ghostty_surface_key(handle, key)
            key.action = GHOSTTY_ACTION_RELEASE
            key.text = nil
            _ = ghostty_surface_key(handle, key)
        }
    }

    // MARK: - Search

    /// How many matches there are, and which one is selected. Both arrive
    /// asynchronously from libghostty's own search thread, separately, so the
    /// callback takes each independently rather than pretending they are one
    /// update.
    var onSearchCount: ((Int?, Int?) -> Void)?

    /// Trigger a libghostty keybind action by name. The same door the
    /// keyboard shortcuts use, so search behaves identically to the desktop.
    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let handle else { return false }
        return action.withCString {
            ghostty_surface_binding_action(handle, $0, UInt(strlen($0)))
        }
    }

    /// Start or update the scrollback search.
    ///
    /// The engine runs on libghostty's own search thread and highlights
    /// matches in the renderer — this is the real thing, not a scrape of the
    /// viewport, so it finds text that scrolled off hours ago and is
    /// unaffected by where lines happen to wrap. An empty needle cancels it.
    func search(_ needle: String) {
        performBindingAction("search:\(needle)")
    }

    /// Step the selected match. The renderer scrolls it into view.
    func navigateSearch(next: Bool) {
        performBindingAction(next ? "navigate_search:next" : "navigate_search:previous")
    }

    func endSearch() {
        performBindingAction("search:")
    }

    // MARK: - Selection

    /// Whether the terminal is holding a selection right now.
    var hasSelection: Bool {
        guard let handle else { return false }
        return ghostty_surface_has_selection(handle)
    }

    /// The selected text, or nil when nothing is selected.
    var selectedText: String? {
        guard let handle, ghostty_surface_has_selection(handle) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(handle, &text) else { return nil }
        defer { ghostty_surface_free_text(handle, &text) }
        guard let ptr = text.text else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)),
                      as: UTF8.self)
    }

    /// Begin a selection at a point in view coordinates.
    ///
    /// Selection is libghostty's, driven through the mouse events the desktop
    /// uses, so word and line snapping, highlighting and scrollback-aware
    /// extension all come from the engine. A touch is a left button: press
    /// here, move to extend, release to finish.
    func beginSelection(at point: CGPoint) {
        guard let handle else { return }
        movePointer(to: point)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_PRESS,
                                         GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }

    /// Extend an in-progress selection to a point in view coordinates.
    func extendSelection(to point: CGPoint) {
        movePointer(to: point)
    }

    /// Finish the selection. What is highlighted stays highlighted.
    func endSelection() {
        guard let handle else { return }
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_RELEASE,
                                         GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }

    /// Drop the selection. A press and release without movement is how
    /// libghostty clears one.
    func clearSelection() {
        guard let handle, ghostty_surface_has_selection(handle) else { return }
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_PRESS,
                                         GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(handle, GHOSTTY_MOUSE_RELEASE,
                                         GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
    }

    func selectAll() {
        performBindingAction("select_all")
    }

    /// Move libghostty's pointer to a point in view coordinates.
    ///
    /// Points in, pixels out, for the reason `scroll(byPoints:)` documents at
    /// length: libghostty divides the position by `size.cell.width`, which is
    /// in device pixels because that is the unit `ghostty_surface_set_size`
    /// was given. Passing points selects the wrong cell by the scale factor,
    /// which on a 3x phone is a selection that starts two thirds of the way
    /// up the screen from where the finger is.
    private func movePointer(to point: CGPoint) {
        guard let handle else { return }
        let scale = Double(view.contentScaleFactor)
        ghostty_surface_mouse_pos(handle,
                                  Double(point.x) * scale,
                                  Double(point.y) * scale,
                                  GHOSTTY_MODS_NONE)
    }

    /// Scroll the terminal by a pixel delta.
    ///
    /// `precision` tells libghostty the offset is in pixels rather than
    /// wheel ticks, which is what a finger produces — without it a drag is
    /// interpreted as a mouse wheel and jumps a screen at a time.
    ///
    /// This also does the right thing inside a full-screen program: when the
    /// far end has mouse reporting on, ghostty turns the scroll into the
    /// escape sequences `less` and `vim` expect instead of moving scrollback.
    func scroll(byPoints dy: CGFloat, dx: CGFloat = 0) {
        guard let handle, dy != 0 || dx != 0 else { return }

        // Points in, pixels out. libghostty compares the offset against
        // `size.cell.height`, which is in device pixels, and UIKit hands out
        // points — so on a 3× phone a finger asking for one screen of scroll
        // got a third of one, which reads as a heavy, sluggish terminal.
        //
        // Ghostty's own macOS view has the same mismatch and an unresolved
        // `TODO(mitchellh): do we have to scale the x/y here by window scale
        // factor?` above an arbitrary `*= 2`. At 2× that roughly cancels; it
        // is not a rule to copy. A finger should move content one for one,
        // which is what every other scrollable thing on the phone does.
        let scale = Double(view.contentScaleFactor)
        var mods = ghostty_input_scroll_mods_t()
        // Bit 0 of ghostty's ScrollMods is `precision`.
        mods |= 1
        ghostty_surface_mouse_scroll(handle, Double(dx) * scale, Double(dy) * scale, mods)
    }

    // MARK: - Geometry

    /// Push the view's size and scale down to libghostty.
    ///
    /// Driven from `layoutSubviews`, and idempotent: layout runs on every
    /// keyboard animation frame, and re-sizing the terminal 60 times a second
    /// reflows the screen 60 times a second.
    @discardableResult
    func updateSize() -> Bool {
        guard let handle else { return false }
        let scale = view.contentScaleFactor
        let bounds = view.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return false }
        guard bounds != lastPushedSize || scale != lastPushedScale else { return false }
        lastPushedSize = bounds
        lastPushedScale = scale

        ghostty_surface_set_content_scale(handle, Double(scale), Double(scale))
        ghostty_surface_set_size(handle,
                                 UInt32(bounds.width * scale),
                                 UInt32(bounds.height * scale))
        return true
    }

    /// Current grid, for anyone who needs to open a pty at the right size
    /// before the first resize callback fires.
    var gridSize: (columns: Int, rows: Int) {
        guard let handle else { return (80, 24) }
        let size = ghostty_surface_size(handle)
        return (Int(size.columns), Int(size.rows))
    }

    fileprivate func reportResize(_ columns: Int, _ rows: Int) {
        guard columns > 0, rows > 0 else { return }
        guard (columns, rows) != lastReportedGrid else { return }
        lastReportedGrid = (columns, rows)
        onResize?(columns, rows)
    }

    // MARK: - Lifecycle

    func setFocus(_ focused: Bool) {
        guard let handle else { return }
        ghostty_surface_set_focus(handle, focused)
    }

    /// Note the parameter is **visible**, not occluded — passing `false`
    /// parks libghostty's renderer thread. Driving this from `scenePhase` is
    /// the single biggest battery win available here.
    func setVisible(_ visible: Bool) {
        guard let handle else { return }
        ghostty_surface_set_occlusion(handle, visible)
    }

    /// Ask libghostty to schedule a frame.
    ///
    /// This only *queues* — the renderer thread does the drawing. Calling
    /// `ghostty_surface_draw` from here instead would run a full drawFrame
    /// synchronously on the main thread, in addition to the one the renderer
    /// thread is already doing.
    func markNeedsDisplay() {
        guard let handle else { return }
        ghostty_surface_refresh(handle)
    }

    /// Draw synchronously, right now, on this thread.
    ///
    /// Reserved for the one case ghostty documents it for: keeping the
    /// contents correct *during* a resize, where waiting for the renderer
    /// thread would show a stretched frame.
    func drawNow() {
        guard let handle else { return }
        ghostty_surface_draw(handle)
    }

    // MARK: - Actions

    func apply(_ action: SurfaceRegistry.DecodedAction) {
        switch action {
        case .render:
            markNeedsDisplay()
        case .setTitle(let title):
            onTitle?(title)
        case .openURL(let url):
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        case .showKeyboard(let show):
            if show { _ = view.becomeFirstResponder() } else { _ = view.resignFirstResponder() }
        case .rendererHealth(let healthy):
            if !healthy { Ghostty.log.error("renderer reported unhealthy") }
        case .searchTotal(let total):
            onSearchCount?(total, nil)
        case .searchSelected(let selected):
            onSearchCount?(nil, selected)
        case .pwd, .desktopNotification, .commandFinished, .closeRequested:
            // Handled by the session layer, which owns the UI these drive.
            break
        }
    }
}

// MARK: - Termio callbacks
//
// The external backend's two outbound edges. Both arrive on libghostty's IO
// thread with memory that is valid only for the duration of the call, so
// each copies what it needs before hopping to the main actor.

private nonisolated func ghosttyTermioWrite(
    _ userdata: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?,
    _ len: Int
) {
    guard let userdata, let data, len > 0 else { return }
    let bytes = Data(bytes: UnsafeRawPointer(data), count: len)
    let controller = Unmanaged<SurfaceController>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { controller.onWrite?(bytes) }
    }
}

private nonisolated func ghosttyTermioResize(
    _ userdata: UnsafeMutableRawPointer?,
    _ columns: UInt16,
    _ rows: UInt16,
    _ widthPX: UInt32,
    _ heightPX: UInt32
) {
    guard let userdata else { return }
    let controller = Unmanaged<SurfaceController>.fromOpaque(userdata).takeUnretainedValue()
    let cols = Int(columns), rws = Int(rows)
    DispatchQueue.main.async {
        MainActor.assumeIsolated { controller.reportResize(cols, rws) }
    }
}
