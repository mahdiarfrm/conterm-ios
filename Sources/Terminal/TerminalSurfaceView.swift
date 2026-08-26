import IOSurface
import UIKit
import os

/// The `UIView` libghostty renders into.
///
/// libghostty's Metal renderer draws into an `IOSurface` and hands it to a
/// layer. On macOS it makes the host `NSView` layer-hosting and assigns that
/// layer directly; on iOS `UIView.layer` is read-only, so it adds its own
/// layer as a *sublayer* of ours. Either way nothing here touches Metal.
///
/// Two invariants, both inherited from the Mac app and both worth stating
/// because violating either produces a black terminal rather than a crash:
///
/// 1. **The view must have a non-zero frame before the surface is created.**
///    A `.zero` frame leaves the renderer permanently degenerate — it never
///    recovers, even after a later layout.
/// 2. **The view is welded to its surface for life.** libghostty holds the
///    pointer we hand it. Never reparent this view into a different surface;
///    make a new one.
final class TerminalSurfaceView: UIView {

    /// libghostty adds its own `CAMetalLayer` as a sublayer, so this view's
    /// own layer stays a plain one.
    private(set) var controller: SurfaceController?

    /// What libghostty actually attached to us, for diagnosis.
    ///
    /// The renderer adds its own layer as a sublayer on iOS. If this is
    /// empty, the renderer never initialised — a completely different
    /// problem from a renderer that is drawing nothing.
    var renderLayerReport: String {
        let subs = layer.sublayers ?? []
        guard let first = subs.first else { return "no render layer" }
        let f = first.frame
        var parts = [
            "view \(Int(bounds.width))x\(Int(bounds.height))@\(Int(contentScaleFactor))",
            "\(subs.count) sublayer(\(type(of: first)))",
            "frame \(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))",
            "scale \(String(format: "%.1f", first.contentsScale))",
            "opacity \(String(format: "%.2f", first.opacity))",
            first.isHidden ? "HIDDEN" : "visible",
        ]
        if let contents = first.contents {
            // The renderer hands the layer an IOSurface. Its pixel size has
            // to equal bounds x contentsScale or IOSurfaceLayer discards it.
            let surface = unsafeDowncast(contents as AnyObject, to: IOSurfaceRef.self)
            parts.append("contents \(IOSurfaceGetWidth(surface))x\(IOSurfaceGetHeight(surface))")
            parts.append("want \(Int(f.width * first.contentsScale))x\(Int(f.height * first.contentsScale))")
        } else {
            parts.append("NO CONTENTS")
        }
        return parts.joined(separator: "  ")
    }

    /// A pixel sample of the frame the renderer last produced. Expensive:
    /// locks the IOSurface and walks it. Diagnostics only, never in a view
    /// body.
    var renderPixelReport: String {
        guard let contents = layer.sublayers?.first?.contents else { return "no contents" }
        return Self.pixelReport(unsafeDowncast(contents as AnyObject, to: IOSurfaceRef.self))
    }

    /// Sample the pixels the renderer actually produced.
    ///
    /// A terminal that draws its background and no glyphs is indistinguishable
    /// on screen from a layer that never composites — but not in the buffer.
    /// One distinct colour means the renderer cleared and drew nothing.
    private static func pixelReport(_ surface: IOSurfaceRef) -> String {
        guard IOSurfaceLock(surface, .readOnly, nil) == 0 else {
            return "pixels locked"
        }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        guard let base = IOSurfaceGetBaseAddress(surface) as UnsafeMutableRawPointer? else {
            return "pixels no base"
        }
        let stride = IOSurfaceGetBytesPerRow(surface)
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        var seen = Set<UInt32>()
        var first: UInt32 = 0
        var sampled = 0
        for y in Swift.stride(from: 0, to: height, by: 3) {
            let row = base.advanced(by: y * stride)
            for x in Swift.stride(from: 0, to: width, by: 3) {
                let px = row.load(fromByteOffset: x * 4, as: UInt32.self)
                if sampled == 0 { first = px }
                sampled += 1
                if seen.count < 12 { seen.insert(px) }
            }
        }
        return "px first=\(String(format: "%08x", first)) distinct>=\(seen.count) of \(sampled)"
    }

    /// Modifier keys latched by the accessory bar. A phone keyboard has no
    /// Ctrl, so the accessory row provides one and it applies to exactly the
    /// next keystroke — the behaviour people expect from a sticky modifier.
    var stickyModifiers: ghostty_input_mods_e = GHOSTTY_MODS_NONE

    private var keyboardHeight: CGFloat = 0
    // nonisolated(unsafe): deinit runs outside the actor and must invalidate
    // this, and CADisplayLink is not Sendable. Only ever touched on the main
    // thread, which is where both UIKit and deinit for a view actually run.
    private nonisolated(unsafe) var displayLink: CADisplayLink?

    /// Points of cell width per point of font size, for the bundled
    /// JetBrains Mono at the scale libghostty uses on iOS. Measured, not
    /// derived: at font size 14 a 402pt-wide surface came out 34 columns.
    private static let cellWidthRatio: CGFloat = 402.0 / 34.0 / 14.0

    /// Font size that gives a phone a usable number of columns.
    ///
    /// A terminal is unusable below about 50 columns — `ls -l`, a git log
    /// line and every prompt wrap mid-word — and a fixed point size can't
    /// promise that across a 5.4" phone and a 13" iPad. So the size is
    /// derived from the width instead, and clamped to what stays legible.
    static func defaultFontSize(forWidth width: CGFloat) -> Float {
        guard width > 0 else { return 11 }
        let target = CGFloat(Preferences.shared.terminalColumns)
        let size = width / (target * cellWidthRatio)
        return Float(min(max(size, 6), 20))
    }

    init(app: Ghostty.App, fontSize: Float? = nil) {
        // Non-zero on purpose — see invariant 1. The real size arrives at the
        // first layout pass, a moment later.
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        backgroundColor = UIColor(Theme.paneTile)
        isOpaque = true
        clipsToBounds = true
        contentScaleFactor = UIScreen.main.scale

        // Tapping a terminal means "I want to type here". Without this the
        // view never becomes first responder, so the software keyboard never
        // appears and the surface is read-only — which looks exactly like a
        // broken keyboard rather than a missing gesture.
        isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        // Scrollback by drag. libghostty has no idea a touch screen exists;
        // it wants scroll deltas, so this is the thing that turns a finger
        // into them.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)

        // The real width isn't known until layout, but the surface's font is
        // fixed at creation — so size against the screen, which is the width
        // the view will have.
        let width = UIScreen.main.bounds.width
        controller = SurfaceController(view: self, app: app,
                                       fontSize: fontSize ?? Self.defaultFontSize(forWidth: width))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        displayLink?.invalidate()
        // `close()` is main-actor isolated and deinit is not; the controller
        // is owned solely by this view, so hand it over rather than reaching
        // into it from here.
        let controller = self.controller
        self.controller = nil
        Task { @MainActor in controller?.close() }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // libghostty adds its own layer as a sublayer (UIView.layer is
        // read-only, unlike NSView's), and that sublayer does not
        // participate in Auto Layout — without this it keeps whatever
        // size it had when the renderer attached it, which is nothing.
        for sublayer in layer.sublayers ?? [] {
            sublayer.frame = layer.bounds
            sublayer.contentsScale = contentScaleFactor
        }
        MainActor.assumeIsolated {
            controller?.updateSize()
            controller?.markNeedsDisplay()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        MainActor.assumeIsolated {
            if window != nil {
                contentScaleFactor = window?.screen.scale ?? UIScreen.main.scale
                controller?.updateSize()
                controller?.setVisible(true)
                controller?.markNeedsDisplay()
                startDisplayLink()
            } else {
                controller?.setVisible(false)
                stopDisplayLink()
            }
        }
    }

    // MARK: - Presentation
    //
    // libghostty renders into an IOSurface but the embedded apprt expects
    // the host to ask for frames — `ghostty_surface_draw` is that ask. Without
    // it the surface is created, sized, and fed, and never presents anything:
    // a black rectangle that looks exactly like a broken renderer.

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        // A terminal has nothing to say most of the time, and the draw is
        // skipped unless something changed — but capping the rate keeps a
        // burst of output from pinning the GPU at 120Hz on a ProMotion phone.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step() {
        MainActor.assumeIsolated {
            stepFlick()
            controller?.drawIfNeeded()
        }
    }

    // MARK: - First responder

    override var canBecomeFirstResponder: Bool { true }

    @objc private func handleTap() {
        focusKeyboard()
    }

    /// Where the last pan update left off, so each frame sends only its own
    /// delta — libghostty accumulates, and re-sending the whole translation
    /// every frame would scroll quadratically.
    private var lastPanY: CGFloat = 0

    /// Leftover momentum after the finger lifts, decayed on the display link.
    private var flickVelocity: CGFloat = 0

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        MainActor.assumeIsolated {
            switch pan.state {
            case .began:
                lastPanY = 0
                flickVelocity = 0
            case .changed:
                let y = pan.translation(in: self).y
                let delta = y - lastPanY
                lastPanY = y
                // Content follows the finger: dragging down reveals older
                // output, which is the direction every touch UI has taught.
                controller?.scroll(byPixels: delta)
            case .ended, .cancelled, .failed:
                // A terminal without flick-scroll feels dead next to every
                // other list on the phone, so the throw carries on and decays
                // on the display link.
                flickVelocity = pan.velocity(in: self).y / 60
                lastPanY = 0
            default:
                break
            }
        }
    }

    /// Bleed off flick momentum, one display-link tick at a time.
    private func stepFlick() {
        guard abs(flickVelocity) > 0.5 else {
            flickVelocity = 0
            return
        }
        controller?.scroll(byPixels: flickVelocity)
        flickVelocity *= 0.94
    }

    /// Raise the software keyboard and give the surface focus.
    ///
    /// Called on the tap and once when the screen appears, because a terminal
    /// you have just opened is one you are about to type into.
    func focusKeyboard() {
        guard !isFirstResponder else { return }
        _ = becomeFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { MainActor.assumeIsolated { controller?.setFocus(true) } }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { MainActor.assumeIsolated { controller?.setFocus(false) } }
        return ok
    }
}

// MARK: - Software keyboard

extension TerminalSurfaceView: UIKeyInput {
    var hasText: Bool { true }

    func insertText(_ text: String) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            // A latched modifier has to go through the *key* path. Sending
            // the control byte as text would hand it to ghostty's paste
            // encoder, which replaces Ctrl-C, Ctrl-Z, ESC and friends with
            // spaces — so a latched Ctrl-C would type a space.
            let latched = stickyModifiers.rawValue
            if latched != GHOSTTY_MODS_NONE.rawValue,
               let scalar = text.unicodeScalars.first,
               let usage = TerminalKeyMap.usage(for: scalar),
               let key = TerminalKeyMap.press(usage, mods: stickyModifiers, text: text) {
                controller.send(key: key)
                var release = key
                release.action = GHOSTTY_ACTION_RELEASE
                controller.send(key: release)
                stickyModifiers = GHOSTTY_MODS_NONE
                return
            }
            controller.send(TerminalKeyMap.forTerminal(text))
        }
    }

    func deleteBackward() {
        // Not `send("\u{7f}")`: DEL is one of the bytes ghostty's paste
        // encoder replaces with a space, so the software keyboard's delete
        // key would type a space instead of erasing one.
        MainActor.assumeIsolated {
            guard let controller,
                  let key = TerminalKeyMap.press(.keyboardDeleteOrBackspace) else { return }
            controller.send(key: key)
            var release = key
            release.action = GHOSTTY_ACTION_RELEASE
            controller.send(key: release)
        }
    }

    /// Autocorrect, capitalisation and smart quotes are all actively harmful
    /// in a terminal — a smart quote is not the quote the shell wants.
    var autocorrectionType: UITextAutocorrectionType {
        get { .no } set { _ = newValue }
    }
    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none } set { _ = newValue }
    }
    var smartQuotesType: UITextSmartQuotesType {
        get { .no } set { _ = newValue }
    }
    var smartDashesType: UITextSmartDashesType {
        get { .no } set { _ = newValue }
    }
    var spellCheckingType: UITextSpellCheckingType {
        get { .no } set { _ = newValue }
    }
    var keyboardType: UIKeyboardType {
        get { .asciiCapable } set { _ = newValue }
    }
}

// MARK: - Hardware keyboard

extension TerminalSurfaceView {
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if send(key: key, action: GHOSTTY_ACTION_PRESS) { handled = true }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            _ = send(key: key, action: GHOSTTY_ACTION_RELEASE)
        }
        super.pressesEnded(presses, with: event)
    }

    private func send(key: UIKey, action: ghostty_input_action_e) -> Bool {
        MainActor.assumeIsolated {
            guard let controller else { return false }
            guard let keycode = TerminalKeyMap.virtualKeyCode(for: key.keyCode) else {
                return false
            }
            let mods = TerminalKeyMap.mods(from: key.modifierFlags, plus: stickyModifiers)
            let text = key.characters

            var input = ghostty_input_key_s()
            input.action = action
            input.mods = mods
            input.consumed_mods = GHOSTTY_MODS_NONE
            input.keycode = UInt32(keycode)
            input.composing = false
            input.unshifted_codepoint =
                key.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0

            if text.isEmpty {
                input.text = nil
                controller.send(key: input)
            } else {
                text.withCString { ptr in
                    input.text = ptr
                    controller.send(key: input)
                }
            }
            if action == GHOSTTY_ACTION_PRESS { stickyModifiers = GHOSTTY_MODS_NONE }
            return true
        }
    }
}
