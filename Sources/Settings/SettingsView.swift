import SwiftUI

/// Settings, as typographic bands rather than a stack of grouped boxes —
/// the same shape Host Overview uses, for the same reason: on a phone,
/// nested cards inside a sheet inside a rounded window is three borders
/// deep before any content.
struct SettingsView: View {
    /// On the home's tab rather than in a sheet: a cream card with its own
    /// title row, and no Done button because there is nothing to dismiss.
    var embedded = false
    /// The library, when the settings can open it: keys and snippets are
    /// specific things, categorised under this general one.
    var onKeys: (() -> Void)?
    var onSnippets: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var prefs = Preferences.shared
    @State private var confirmingCloseAll = false

    private var sessions: SessionStore { SessionStore.shared }

    var body: some View {
        Group {
            if embedded {
                VStack(spacing: 0) {
                    CardHeader(title: "Settings")
                    content
                }
                .creamCard()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .arrive(0, enabled: true)
                .contermReadableColumn(740)
            } else {
                NavigationStack {
                    content
                        .creamSheet()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { dismiss() }
                                    .font(Theme.font(Theme.ui(15), .semibold))
                            }
                        }
                }
            }
        }
        .tint(Theme.Brand.ink)
    }

    private var content: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if onKeys != nil || onSnippets != nil {
                        band("Library") {
                            if let onKeys {
                                linkRow("Keys", detail: "\(KeyLibrary.shared.keys.count)",
                                        symbol: "key.horizontal.fill", action: onKeys)
                            }
                            if let onSnippets {
                                linkRow("Snippets", detail: "\(SnippetStore.shared.snippets.count)",
                                        symbol: "apple.terminal.fill", action: onSnippets)
                            }
                        }
                    }

                    band("Colour") {
                        swatches
                        toggleRow("Smoke on colours",
                                  help: "Wisps in the ground's colour drifting over it. The Smoke ground always drifts.",
                                  isOn: $prefs.smoke)
                        toggleRow("Glass panels",
                                  help: "Every panel as monochrome glass, whatever colour it would wear.",
                                  isOn: $prefs.glassPanels)
                    }

                    band("Terminal") {
                        stepperRow(
                            "Columns",
                            detail: "\(prefs.terminalColumns)",
                            help: "How wide a new terminal aims to be. The font size follows from this and the screen.",
                            value: $prefs.terminalColumns, range: 36...96, step: 4)
                        toggleRow(
                            "Keep screen awake",
                            help: "Only while a terminal is open.",
                            isOn: $prefs.keepScreenAwake)
                        toggleRow(
                            "Debian: direct networking",
                            help: "Experimental. The Linux machine reaches the network on any "
                                + "port, ssh included, instead of the built-in HTTP proxy. Fast "
                                + "to connect, but sustained downloads and apt are not yet "
                                + "reliable. Power the machine off and on after changing this.",
                            isOn: $prefs.linuxNativeNet)
                    }

                    band("Feel") {
                        toggleRow("Sound effects",
                                  help: "Synthesised, no audio files. Mixes with whatever else is playing.",
                                  isOn: $prefs.soundEffects)
                        toggleRow("Haptics", isOn: $prefs.haptics)
                        toggleRow("Typing haptics",
                                  help: "A tap for every key. Off by default — it fires "
                                      + "dozens of times a sentence.",
                                  isOn: $prefs.typingHaptics)
                        toggleRow("Launch animation", isOn: $prefs.launchAnimation)
                        stepperRow(
                            "Interface size",
                            detail: String(format: "%.0f%%", prefs.chromeScale * 100),
                            help: "Scales the chrome around the terminal, never the terminal.",
                            value: Binding(
                                get: { Int((prefs.chromeScale * 100).rounded()) },
                                set: { prefs.chromeScale = Double($0) / 100 }),
                            range: 85...125, step: 5)
                    }

                    if !sessions.live.isEmpty {
                        band("Sessions") {
                            plainRow("Open", detail: "\(sessions.live.count)")
                            Button {
                                confirmingCloseAll = true
                            } label: {
                                rowLabel("Disconnect all", tint: Theme.Status.danger)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    band("About") {
                        plainRow("Conterm", detail: Self.appVersion)
                        plainRow("libghostty", detail: Ghostty.versionString)
                        plainRow("Terminal engine", detail: "Ghostty, MIT")
                        plainRow("SSH", detail: "libssh2 + OpenSSL")
                    }

                    Text("Conterm for iOS is an independent frontend and is "
                       + "not affiliated with the Ghostty project.")
                        .font(Theme.font(Theme.ui(11), .medium))
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 40)
                }
            }
            .scrollContentBackground(.hidden)
            .confirmationDialog("Disconnect every open session?",
                                isPresented: $confirmingCloseAll,
                                titleVisibility: .visible) {
                // Named after the act, never "Continue" — Conterm's rule for
                // anything that ends something you can't get back.
                Button("Disconnect \(sessions.live.count)", role: .destructive) {
                    sessions.closeAll()
                }
            }
    }

    /// A row that opens something: a glyph, a name, a count, a chevron.
    private func linkRow(_ title: String, detail: String, symbol: String,
                         action: @escaping () -> Void) -> some View {
        Button {
            Haptics.shared.fire(.light)
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: Theme.ui(13), weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                Text(title)
                    .font(Theme.font(Theme.ui(15), .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(detail)
                    .font(.system(size: Theme.ui(13), weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.ui(11), weight: .semibold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: Theme.ui(46))
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { hairline }
        }
        .buttonStyle(PressableRow())
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    // MARK: - Colour

    /// The grounds, as a row of round swatches. Each is the gradient it
    /// stands for; the chosen one wears a ring in the ink and a tick.
    private var swatches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(GroundPalette.all) { palette in
                    let selected = prefs.ground == palette.id
                    Button {
                        guard !selected else { return }
                        Haptics.shared.fire(.selection)
                        withAnimation(Theme.Spring.snappy) { prefs.ground = palette.id }
                    } label: {
                        VStack(spacing: 7) {
                            Circle()
                                .fill(LinearGradient(colors: [palette.top, palette.bottom],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(width: Theme.ui(46), height: Theme.ui(46))
                                .overlay {
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: Theme.ui(15), weight: .bold))
                                            .foregroundStyle(Theme.Brand.cream)
                                            .transition(.morph)
                                    }
                                }
                                .padding(3)
                                .overlay {
                                    Circle()
                                        .strokeBorder(Theme.textPrimary, lineWidth: selected ? 2 : 0)
                                }
                            Text(palette.name)
                                .font(Theme.font(Theme.ui(11), .semibold))
                                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        }
                        .animation(Theme.Spring.snappy, value: selected)
                    }
                    .buttonStyle(PressablePill(scale: 0.88))
                    .accessibilityLabel(palette.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .overlay(alignment: .bottom) { hairline }
        .padding(.bottom, 6)
    }

    // MARK: - Bands

    /// Bands arrive one after another down the card.
    private static let bandOrder = ["Library", "Colour", "Terminal", "Feel", "Sessions", "About"]

    @ViewBuilder
    private func band<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(Theme.font(Theme.ui(11), .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 22)
                .padding(.top, 26)
                .padding(.bottom, 10)
            VStack(spacing: 0) { content() }
        }
        .arrive((Self.bandOrder.firstIndex(of: title) ?? 0) + 1, step: 0.05, enabled: true)
    }

    private func rowLabel(_ title: String, tint: Color = Theme.textPrimary) -> some View {
        HStack {
            Text(title)
                .font(Theme.font(Theme.ui(15), .medium))
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(minHeight: Theme.ui(46))
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { hairline }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.stroke).frame(height: 0.5).padding(.leading, 20)
    }

    private func plainRow(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(Theme.font(Theme.ui(15), .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(detail)
                .font(.system(size: Theme.ui(13), weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: Theme.ui(46))
        .overlay(alignment: .bottom) { hairline }
    }

    private func toggleRow(_ title: String,
                           help: String? = nil,
                           isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.font(Theme.ui(15), .medium))
                    .foregroundStyle(Theme.textPrimary)
                if let help {
                    Text(help)
                        .font(Theme.font(Theme.ui(11), .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: Theme.ui(46))
        .overlay(alignment: .bottom) { hairline }
    }

    private func stepperRow(_ title: String,
                            detail: String,
                            help: String? = nil,
                            value: Binding<Int>,
                            range: ClosedRange<Int>,
                            step: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(Theme.font(Theme.ui(15), .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.system(size: Theme.ui(13), weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .monospacedDigit()
                }
                if let help {
                    Text(help)
                        .font(Theme.font(Theme.ui(11), .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Stepper("", value: value, in: range, step: step) { editing in
                if !editing { Haptics.shared.fire(.selection) }
            }
            .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: Theme.ui(46))
        .overlay(alignment: .bottom) { hairline }
    }
}
