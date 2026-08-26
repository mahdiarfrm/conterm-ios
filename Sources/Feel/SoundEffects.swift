import AVFoundation
import UIKit

/// Synthesised UI sounds — no audio files, no bundle weight, no I/O on the
/// hot path.
///
/// Ported from Conterm's engine. Each effect is rendered once into an
/// `AVAudioPCMBuffer` at first use and played through a small pool of player
/// nodes, with two or three randomised variants so rapid actions don't feel
/// like a Geiger counter.
///
/// The one thing the Mac app never had to think about: on a phone this shares
/// the device with whatever the user is listening to. The session is
/// `.ambient` with `.mixWithOthers`, so Conterm ducks nothing and stops
/// nothing — and it obeys the ringer switch, which is the behaviour anyone
/// expects from UI chrome.
@MainActor
final class SoundEffects {
    static let shared = SoundEffects()

    enum Effect: String, CaseIterable {
        case connect        // a session came up
        case disconnect     // it went away
        case paletteOpen
        case paletteClose
        case paletteMove    // selection moved through rows
        case paletteConfirm
        case toggle
        case notify
        case error
        case click
    }

    private static let prefKey = "conterm.soundEffects"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: prefKey) as? Bool ?? true
    }

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [String: [AVAudioPCMBuffer]] = [:]
    private var started = false
    private var idleTimer: Task<Void, Never>?

    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    private init() {}

    // MARK: - Playback

    func play(_ effect: Effect) {
        guard Self.isEnabled else { return }
        guard start() else { return }

        let variants = buffers[effect.rawValue] ?? render(effect)
        guard let buffer = variants.randomElement() else { return }

        let player = players[next % players.count]
        next += 1
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        scheduleIdleStop()
    }

    /// Park the engine after a few seconds of quiet.
    ///
    /// A running AVAudioEngine holds a render thread awake. On a Mac that is
    /// invisible; on a phone it is a battery cost for nothing, and on a
    /// loaded machine it shows up as a stream of CoreAudio overload warnings.
    /// The buffers stay rendered, so restarting is cheap.
    private func scheduleIdleStop() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.stopEngine() }
        }
    }

    private func stopEngine() {
        guard started else { return }
        engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        started = false
    }

    /// Sound and haptic together. A tap that only clicks feels hollow on a
    /// phone, and one that only buzzes feels mute — the pair is what reads as
    /// a physical control.
    func tap(_ effect: Effect = .click, haptic: Haptics.Kind = .light) {
        play(effect)
        Haptics.shared.fire(haptic)
    }

    @discardableResult
    private func start() -> Bool {
        if started { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            // Already built, just parked by the idle timer.
            if !players.isEmpty {
                try engine.start()
                started = true
                return true
            }

            for _ in 0..<4 {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                players.append(player)
            }
            try engine.start()
            started = true
            return true
        } catch {
            // Audio is decoration. If the session will not start — another app
            // holds it exclusively, say — everything else must carry on.
            return false
        }
    }

    // MARK: - Synthesis

    private func render(_ effect: Effect) -> [AVAudioPCMBuffer] {
        let specs = Self.specs(for: effect)
        let rendered = specs.compactMap { self.buffer(for: $0) }
        buffers[effect.rawValue] = rendered
        return rendered
    }

    private func buffer(for spec: Tone) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(spec.duration * rate)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buf.frameLength = frames

        guard let left = buf.floatChannelData?[0],
              let right = buf.floatChannelData?[1] else { return nil }

        var phases = [Double](repeating: 0, count: spec.partials.count)
        var noiseState = [Double](repeating: 0, count: spec.partials.count)
        let n = Int(frames)

        for i in 0..<n {
            let t = Double(i) / rate
            var sample = 0.0

            for (idx, p) in spec.partials.enumerated() {
                switch p.shape {
                case .sine:
                    phases[idx] += 2 * .pi * spec.freq * p.harmonic / rate
                    if phases[idx] > 2 * .pi { phases[idx] -= 2 * .pi }
                    sample += sin(phases[idx]) * p.amplitude

                case .noise:
                    // The strike transient. `harmonic` doubles as a 1-pole
                    // lowpass coefficient — small is a muffled "tff", larger
                    // a brighter "tch". Generation stops at 25ms with a 5ms
                    // ramp from 20ms so the cutoff itself cannot click.
                    if t > 0.025 { break }
                    let raw = Double.random(in: -1...1)
                    let alpha = p.harmonic
                    noiseState[idx] = noiseState[idx] * (1 - alpha) + raw * alpha
                    let life = exp(-t / 0.012)
                    let cut = max(0, min(1, (0.025 - t) / 0.005))
                    sample += noiseState[idx] * p.amplitude * life * cut
                }
            }

            // Linear attack into exponential decay — the struck-object curve.
            let env: Double = t < spec.attack
                ? t / spec.attack
                : exp(-(t - spec.attack) / spec.decay)

            // The exponential never reaches zero, so force the tail to meet
            // silence; a discontinuity at the buffer edge clicks.
            let tail = max(0, min(1, (spec.duration - t) / 0.006))

            let v = Float(tanh(sample * env * tail * spec.gain * 2.5))
            left[i] = v
            right[i] = v
        }
        return buf
    }

    /// One rendered sound. Conterm's shape exactly: a tonal fundamental, a
    /// sub-octave that turns a tap into a *thunk*, and an optional noise
    /// strike. Everything lives between 108 and 260 Hz — these are meant to
    /// be felt more than heard, which is what keeps a UI sound from reading
    /// as a cartoon.
    private struct Tone {
        var duration: Double
        var freq: Double
        var partials: [Partial]
        var attack: Double = 0.005
        var decay: Double
        var gain: Double

        struct Partial {
            enum Shape { case sine, noise }
            /// Sine: multiple of the fundamental (0.5 = octave below).
            /// Noise: the lowpass coefficient.
            var harmonic: Double
            var amplitude: Double
            var shape: Shape
        }
    }

    /// Fundamental + sub-octave + strike.
    private static func thunk(_ f: Double, decay: Double, gain: Double,
                              body: Double = 0.35, attack: Double = 0.14,
                              noiseAlpha: Double = 0.08) -> Tone {
        Tone(duration: max(0.05, decay * 3), freq: f,
             partials: [
                .init(harmonic: 1.0, amplitude: 0.45, shape: .sine),
                .init(harmonic: 0.5, amplitude: body, shape: .sine),
                .init(harmonic: noiseAlpha, amplitude: attack, shape: .noise),
             ],
             decay: decay, gain: gain)
    }

    /// `thunk` without the strike. For frequent events, where the noise
    /// partial accumulates into splashiness across rapid repeats.
    private static func cleanThunk(_ f: Double, decay: Double, gain: Double,
                                   body: Double = 0.28) -> Tone {
        Tone(duration: max(0.05, decay * 3), freq: f,
             partials: [
                .init(harmonic: 1.0, amplitude: 0.55, shape: .sine),
                .init(harmonic: 0.5, amplitude: body, shape: .sine),
             ],
             decay: decay, gain: gain)
    }

    /// Conterm's own values. Three close variants per family so consecutive
    /// events don't repeat the same tone.
    private static func specs(for effect: Effect) -> [Tone] {
        switch effect {
        // Connect / disconnect take the pane family's anchor range — the
        // most prominent action gets the lowest, weightiest sound.
        case .connect:
            return [165, 175, 158].map { cleanThunk($0, decay: 0.026, gain: 0.30) }
        case .disconnect:
            return [142, 134, 150].map { cleanThunk($0, decay: 0.026, gain: 0.28) }

        // Overlay open/close: the longest body in the palette, because it
        // accompanies a full-screen bloom. Sub-octave near 60Hz reads as
        // felt rather than pitched.
        case .paletteOpen:
            return [125, 135].map { thunk($0, decay: 0.050, gain: 0.24, body: 0.42, attack: 0.10) }
        case .paletteClose:
            return [108, 118].map { thunk($0, decay: 0.050, gain: 0.22, body: 0.42, attack: 0.10) }

        // Cursor tick. Pitched above the event range and kept extremely
        // short so scrolling a list does not become a continuous tone.
        // Pure sine — no sub, no strike.
        case .paletteMove:
            return [220, 230, 210].map { f in
                Tone(duration: 0.04, freq: f,
                     partials: [.init(harmonic: 1, amplitude: 0.40, shape: .sine)],
                     attack: 0.003, decay: 0.010, gain: 0.10)
            }

        // Confirm keeps the strike, so a committed action reads as more
        // substantial than the navigation before it.
        case .paletteConfirm:
            return [175, 188].map { thunk($0, decay: 0.045, gain: 0.24, body: 0.38) }

        case .toggle:
            return [195, 205, 185].map { thunk($0, decay: 0.018, gain: 0.16, body: 0.28, attack: 0.08) }

        case .notify:
            return [245, 260].map { thunk($0, decay: 0.060, gain: 0.26, body: 0.40, attack: 0.12) }

        // Error: low warm sine and sub-octave, longest decay, no strike.
        // A failure should carry a steady body rather than a percussive
        // attack — it is a shrug, not an alarm.
        case .error:
            return [110.0].map { f in
                Tone(duration: 0.4, freq: f,
                     partials: [
                        .init(harmonic: 1.0, amplitude: 0.50, shape: .sine),
                        .init(harmonic: 0.5, amplitude: 0.30, shape: .sine),
                     ],
                     attack: 0.012, decay: 0.100, gain: 0.22)
            }

        case .click:
            return [210, 222, 200].map { thunk($0, decay: 0.015, gain: 0.14, body: 0.26, attack: 0.08) }
        }
    }
}

/// Haptics, paired with the sounds above.
@MainActor
final class Haptics {
    static let shared = Haptics()

    enum Kind { case light, medium, rigid, success, warning, failure, selection }

    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    private init() {}

    /// Warm the generators so the first tap isn't late. Taptic Engine spin-up
    /// is real and very noticeable on a first interaction.
    func prepare() {
        selection.prepare()
        notification.prepare()
    }

    private static let prefKey = "conterm.haptics"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: prefKey) as? Bool ?? true
    }

    func fire(_ kind: Kind) {
        guard Self.isEnabled else { return }
        switch kind {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .rigid: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .selection: selection.selectionChanged()
        case .success: notification.notificationOccurred(.success)
        case .warning: notification.notificationOccurred(.warning)
        case .failure: notification.notificationOccurred(.error)
        }
    }
}
