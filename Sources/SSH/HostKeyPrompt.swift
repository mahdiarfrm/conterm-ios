import SwiftUI

/// The first-connection fingerprint prompt.
///
/// The hard part of this screen is not the mechanics, it is not training
/// people to tap through it. Every SSH client shows this, and almost everyone
/// accepts without reading, because the prompt is usually a wall of text that
/// arrives when you are trying to do something else. So this one is short,
/// says what accepting means in one line, and puts the fingerprint in a shape
/// you can actually compare against `ssh-keyscan` output — grouped, not a
/// 43-character run of base64.
///
/// It appears only for a connection the user just asked for. Background work
/// never gets to raise it; see `HostKeyTrust.Policy`.
struct HostKeyPrompt: View {
    let request: HostKeyTrust.Request
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.radiowaves.forward")
                    .font(.system(size: Theme.ui(18), weight: .medium))
                    .foregroundStyle(Theme.sshAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("First connection")
                        .font(.system(size: Theme.ui(19), weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(request.address.target)
                        .font(.system(size: Theme.ui(12), weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 16)

            Text("This host identifies itself with the key below. Accepting it "
               + "means Conterm will refuse to connect if it ever changes.")
                .font(.system(size: Theme.ui(13), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            fingerprint
                .padding(.bottom, 16)

            Text("If you can, check it on the machine itself:")
                .font(.system(size: Theme.ui(11), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Text("ssh-keygen -lf /etc/ssh/ssh_host_\(shortType)_key.pub")
                .font(.system(size: Theme.ui(11), weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
                .textSelection(.enabled)
                .padding(.top, 3)
                .padding(.bottom, 20)

            HStack(spacing: 10) {
                Button {
                    Haptics.shared.fire(.light)
                    onDecide(false)
                } label: {
                    Text("Cancel")
                        .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .glassPill()

                Button {
                    Haptics.shared.fire(.success)
                    onDecide(true)
                } label: {
                    Text("Trust this host")
                        .font(.system(size: Theme.ui(14), weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.appBackground)
                .background(Capsule().fill(Theme.accentOnDark))
            }
        }
        .padding(22)
        .presentationDetents([.height(430)])
        .presentationBackground(Theme.appBackground)
    }

    /// Grouped four characters at a time. A fingerprint you cannot compare
    /// is a fingerprint nobody compares.
    private var fingerprint: some View {
        let body = request.fingerprint
            .replacingOccurrences(of: "SHA256:", with: "")
        let groups = stride(from: 0, to: body.count, by: 4).map { offset -> String in
            let start = body.index(body.startIndex, offsetBy: offset)
            let end = body.index(start, offsetBy: min(4, body.count - offset))
            return String(body[start..<end])
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text("SHA256 \u{00b7} \(request.keyType)")
                .font(.system(size: Theme.ui(10), weight: .bold))
                .tracking(1.0)
                .foregroundStyle(Theme.textSecondary)
            Text(groups.joined(separator: " "))
                .font(.system(size: Theme.ui(13), weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.paneTile)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1))
        )
    }

    private var shortType: String {
        switch request.keyType {
        case "ssh-ed25519": return "ed25519"
        case "ssh-rsa": return "rsa"
        case "ssh-dss": return "dsa"
        default: return "ecdsa"
        }
    }
}

/// Attaches the trust prompt wherever it is placed. One instance, at the
/// root, because a connection can be started from several screens and the
/// prompt has to outlive any of them being dismissed.
struct HostKeyPromptHost: ViewModifier {
    @State private var trust = HostKeyTrust.shared

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { trust.pending },
            set: { if $0 == nil, let pending = trust.pending {
                // Swiped away is a refusal. Anything else would mean a
                // dismissal gesture could grant trust.
                trust.resolve(pending, trust: false)
            } }
        )) { request in
            HostKeyPrompt(request: request) { accepted in
                trust.resolve(request, trust: accepted)
            }
        }
    }
}

extension View {
    func hostKeyPrompts() -> some View { modifier(HostKeyPromptHost()) }
}
