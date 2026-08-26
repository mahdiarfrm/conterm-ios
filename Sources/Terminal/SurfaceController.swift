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
        needsDraw = true
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

    // MARK: - Geometry

    /// Push the view's size and scale down to libghostty.
    ///
    /// Driven from `layoutSubviews`, and idempotent: layout runs on every
    /// keyboard animation frame, and re-sizing the terminal 60 times a second
    /// reflows the screen 60 times a second.
    func updateSize() {
        guard let handle else { return }
        let scale = view.contentScaleFactor
        let bounds = view.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard bounds != lastPushedSize || scale != lastPushedScale else { return }
        lastPushedSize = bounds
        lastPushedScale = scale

        ghostty_surface_set_content_scale(handle, Double(scale), Double(scale))
        ghostty_surface_set_size(handle,
                                 UInt32(bounds.width * scale),
                                 UInt32(bounds.height * scale))
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

    /// Set by libghostty's RENDER action; consumed by the display link.
    ///
    /// Marking dirty and presenting are separate on purpose: the render
    /// action arrives on libghostty's thread at whatever rate output
    /// demands, and presenting has to happen on a frame boundary.
    private(set) var needsDraw = true

    func markNeedsDisplay() {
        guard let handle else { return }
        needsDraw = true
        ghostty_surface_refresh(handle)
    }

    /// Called once per frame while the surface is on screen. Draws only when
    /// something changed, so an idle terminal costs nothing.
    func drawIfNeeded() {
        guard let handle, needsDraw else { return }
        needsDraw = false
        ghostty_surface_draw(handle)
    }

    func draw() {
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
        case .pwd, .desktopNotification, .commandFinished,
             .searchTotal, .searchSelected, .closeRequested:
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
