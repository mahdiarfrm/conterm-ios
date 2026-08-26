import SwiftUI

/// Settings, as typographic bands rather than a stack of grouped boxes —
/// the same shape Host Overview uses, for the same reason: on a phone,
/// nested cards inside a sheet inside a rounded window is three borders
/// deep before any content.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prefs = Preferences.shared
    @State private var confirmingCloseAll = false

    private var sessions: SessionStore { SessionStore.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
                    }

                    band("Feel") {
                        toggleRow("Sound effects",
                                  help: "Synthesised, no audio files. Mixes with whatever else is playing.",
                                  isOn: $prefs.soundEffects)
                        toggleRow("Haptics", isOn: $prefs.haptics)
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
                        .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 40)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.appBackground.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: Theme.ui(15), weight: .semibold, design: .rounded))
                }
            }
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
        .tint(Theme.accentOnDark)
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    // MARK: - Bands

    @ViewBuilder
    private func band<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: Theme.ui(11), weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 10)
            VStack(spacing: 0) { content() }
        }
    }

    private func rowLabel(_ title: String, tint: Color = Theme.textPrimary) -> some View {
        HStack {
            Text(title)
                .font(.system(size: Theme.ui(15), weight: .medium, design: .rounded))
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
                .font(.system(size: Theme.ui(15), weight: .medium, design: .rounded))
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
                    .font(.system(size: Theme.ui(15), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                if let help {
                    Text(help)
                        .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.accentOnDark)
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
                        .font(.system(size: Theme.ui(15), weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.system(size: Theme.ui(13), weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accentOnDark)
                        .monospacedDigit()
                }
                if let help {
                    Text(help)
                        .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
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
