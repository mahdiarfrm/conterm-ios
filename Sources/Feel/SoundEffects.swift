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

        var phase = 0.0
        var harmonicPhase = 0.0
        let n = Int(frames)

        for i in 0..<n {
            let t = Double(i) / rate
            let frac = Double(i) / Double(max(n - 1, 1))
            // Linear pitch ramp; a constant tone sets both ends equal.
            let freq = spec.freqStart + (spec.freqEnd - spec.freqStart) * frac

            phase += 2 * .pi * freq / rate
            harmonicPhase += 2 * .pi * freq * spec.harmonic / rate

            // A folded sine rather than a real triangle: smoother harmonic
            // content, none of the buzzy edge.
            let fundamental = sin(phase)
            let overtone = asin(sin(harmonicPhase)) * (2 / .pi)
            var sample = fundamental * (1 - spec.harmonicMix)
                       + overtone * spec.harmonicMix

            // Linear attack into an exponential decay — the struck-object
            // curve that gives a *plink* rather than a rectangular *blip*.
            let env: Double
            if t < spec.attack {
                env = t / spec.attack
            } else {
                env = exp(-(t - spec.attack) / spec.decay)
            }

            // The exponential never reaches zero, so force the tail to meet
            // silence: any discontinuity at the buffer edge clicks.
            let tail = max(0, min(1, (spec.duration - t) / 0.006))

            sample *= env * spec.gain * tail
            // tanh is loudness and clipping safety in one: roughly linear
            // when quiet, smoothly compressing at the rails.
            let v = Float(tanh(sample * 2.2))
            left[i] = v
            right[i] = v
        }
        return buf
    }

    private struct Tone {
        var duration: Double
        var freqStart: Double
        var freqEnd: Double
        var harmonic: Double = 2
        var harmonicMix: Double = 0.25
        var attack: Double = 0.005
        var decay: Double = 0.08
        var gain: Double = 0.5
    }

    /// Two variants per effect, detuned slightly, so repeats don't sound
    /// mechanical.
    private static func specs(for effect: Effect) -> [Tone] {
        func pair(_ base: Tone, detune: Double = 1.03) -> [Tone] {
            var b = base
            b.freqStart *= detune
            b.freqEnd *= detune
            return [base, b]
        }

        switch effect {
        case .connect:
            // Rising fifth — an opening gesture.
            return pair(Tone(duration: 0.34, freqStart: 420, freqEnd: 630,
                             harmonicMix: 0.3, decay: 0.13, gain: 0.42))
        case .disconnect:
            return pair(Tone(duration: 0.30, freqStart: 520, freqEnd: 330,
                             harmonicMix: 0.22, decay: 0.11, gain: 0.34))
        case .paletteOpen:
            return pair(Tone(duration: 0.16, freqStart: 660, freqEnd: 880,
                             decay: 0.05, gain: 0.30))
        case .paletteClose:
            return pair(Tone(duration: 0.14, freqStart: 780, freqEnd: 560,
                             decay: 0.045, gain: 0.26))
        case .paletteMove:
            // Very short and quiet: this fires on every row change.
            return pair(Tone(duration: 0.05, freqStart: 1180, freqEnd: 1180,
                             harmonicMix: 0.1, attack: 0.002, decay: 0.014,
                             gain: 0.16), detune: 1.06)
        case .paletteConfirm:
            return pair(Tone(duration: 0.20, freqStart: 720, freqEnd: 1080,
                             harmonicMix: 0.32, decay: 0.07, gain: 0.36))
        case .toggle:
            return pair(Tone(duration: 0.07, freqStart: 900, freqEnd: 900,
                             attack: 0.002, decay: 0.02, gain: 0.22))
        case .notify:
            return pair(Tone(duration: 0.42, freqStart: 590, freqEnd: 880,
                             harmonicMix: 0.4, decay: 0.16, gain: 0.40))
        case .error:
            // Low and falling. Never harsh — a failure should read as a
            // shrug, not an alarm.
            return pair(Tone(duration: 0.34, freqStart: 300, freqEnd: 190,
                             harmonicMix: 0.18, decay: 0.13, gain: 0.36))
        case .click:
            return pair(Tone(duration: 0.06, freqStart: 1020, freqEnd: 1020,
                             harmonicMix: 0.12, attack: 0.002, decay: 0.018,
                             gain: 0.20))
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

    func fire(_ kind: Kind) {
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
