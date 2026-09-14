import SwiftUI

/// A segmented control whose selection is a thumb that slides.
///
/// The system segmented picker snaps: one segment stops being selected and
/// another starts, with nothing in between. Here the selected state is a
/// single capsule that travels to whichever option was tapped, so the
/// control reads as one object with a position rather than a row of
/// buttons that light up. Text on the thumb inverts as it arrives.
struct SegmentedPill<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    var tone: ChromeTone?

    @Namespace private var thumb
    @Environment(\.colorScheme) private var scheme

    init(selection: Binding<Option>,
         options: [Option],
         tone: ChromeTone? = nil,
         label: @escaping (Option) -> String) {
        _selection = selection
        self.options = options
        self.tone = tone
        self.label = label
    }

    private var resolved: ChromeTone { tone ?? .resolve(scheme) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    guard !selected else { return }
                    Haptics.shared.fire(.selection)
                    withAnimation(Theme.Spring.snappy) { selection = option }
                } label: {
                    Text(label(option))
                        .font(Theme.font(Theme.ui(13), .semibold))
                        .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.ui(34))
                        .background {
                            if selected {
                                Capsule(style: .continuous)
                                    .fill(Theme.accent)
                                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(PressablePill(scale: 0.96))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .glassPill(tone: resolved)
        .animation(Theme.Spring.snappy, value: selection)
    }
}
