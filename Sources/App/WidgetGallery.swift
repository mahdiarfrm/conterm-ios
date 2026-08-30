import SwiftUI

/// Every widget face, at its real size, inside the app.
///
/// Widget design is otherwise a miserable loop: change a number, build,
/// install, remove the widget from the home screen, add it back, squint. The
/// faces live in `Shared/` precisely so this screen can render the same views
/// the extension does, which turns that loop into build-and-run.
///
/// Reachable with `CONTERM_WIDGETS=1`, and from Settings, because it is also
/// the honest answer to "what will this look like on my home screen".
struct WidgetGallery: View {
    /// The real sizes on a 402pt-wide phone. Hardcoded rather than derived:
    /// the point is to see the face at the size the system will give it, not
    /// at the size this screen happens to be.
    private let small = CGSize(width: 170, height: 170)
    private let medium = CGSize(width: 364, height: 170)
    private let large = CGSize(width: 364, height: 382)

    @State private var useLiveData = false

    /// `CONTERM_WIDGETS=2` shows only the tall faces, which is the only way
    /// to see them without a scroll gesture the tooling can't make.
    private var compact: Bool {
        ProcessInfo.processInfo.environment["CONTERM_WIDGETS"] == "2"
    }

    private var snapshot: ContermSnapshot {
        useLiveData ? ContermSnapshotStore.read() : .preview
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                source

                if !compact {
                group("Small") {
                    SmallFace(snapshot: snapshot)
                        .frame(width: small.width, height: small.height)
                }
                group("Medium") {
                    MediumFace(snapshot: snapshot)
                        .frame(width: medium.width, height: medium.height)
                }
                }
                group("Large") {
                    LargeFace(snapshot: snapshot)
                        .frame(width: large.width, height: large.height)
                }
                group("Lock screen") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 16) {
                            CircularFace(snapshot: snapshot)
                                .frame(width: 72, height: 72)
                            RectangularFace(snapshot: snapshot)
                                .frame(width: 160, height: 72, alignment: .leading)
                        }
                        InlineFace(snapshot: snapshot)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    // The lock screen renders accessory widgets as a single
                    // tinted stencil, so previewing them in colour would be a
                    // lie about what you will actually see.
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.08)))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.appBackground.ignoresSafeArea())
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $useLiveData) {
                Text("Sample").tag(false)
                Text("Live").tag(true)
            }
            .pickerStyle(.segmented)

            Text(ContermSnapshotStore.isShared
                 ? "Sharing with the widget extension."
                 : "No App Group — the extension can't read this yet, so widgets "
                 + "on the home screen show sample data.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(ContermSnapshotStore.isShared
                                 ? Theme.textSecondary : Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func group<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}
