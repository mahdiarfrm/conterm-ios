import SwiftUI
import CoreText
import UIKit

/// Conterm's display face.
///
/// Ported from the Mac app's `OrbitFont`. Michroma is the bundled fallback
/// (SIL OFL, licence ships beside it); Eurostile Bold Extended is preferred
/// when the system happens to have it. Registration through
/// `CTFontManagerRegisterFontsForURL` works identically on iOS, so the font
/// needs no Info.plist entry.
enum ContermFont {
    private static let candidates = [
        "EurostileBQ-BoldExtended",
        "Eurostile Bold Extended",
        "Eurostile BQ",
        "Michroma-Regular",
    ]

    /// Resolved once, lazily. Both values come out of the same `let` so
    /// there is no mutable global state for the concurrency checker to
    /// object to — and the answer cannot change at runtime anyway.
    private static let resolution: (name: String?, synthesise: Bool) = {
        register()
        for name in candidates where UIFont(name: name, size: 12) != nil {
            return (name, name.hasPrefix("Michroma"))
        }
        return (nil, false)
    }()

    /// Michroma ships one weight, so `ContermText` fakes a bolder cut by
    /// drawing twice with a small diagonal offset. Only needed when we
    /// actually fell back to it.
    static var needsSynthesisedWeight: Bool { resolution.synthesise }

    private static func register() {
        guard let url = Bundle.main.url(forResource: "michroma-regular",
                                        withExtension: "ttf") else { return }
        var error: Unmanaged<CFError>?
        // .process scope: the font belongs to this app, not the system.
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }

    /// The display face at a size, falling back to an expanded heavy system
    /// face if neither the bundled nor an installed candidate resolves.
    static func face(_ size: CGFloat) -> Font {
        if let name = resolution.name { return .custom(name, size: size) }
        return .system(size: size - 1, weight: .black, design: .rounded).width(.expanded)
    }
}

/// Display text in the Conterm face, with synthesised weight.
///
/// The back copy is offset by a third of a point on the diagonal — beyond
/// about half a point the letterforms smear rather than thicken.
struct ContermText: View {
    let text: String
    var size: CGFloat
    var tracking: CGFloat = 0
    var weight: CGFloat = 0.34

    init(_ text: String, size: CGFloat, tracking: CGFloat = 0, weight: CGFloat = 0.34) {
        self.text = text
        self.size = size
        self.tracking = tracking
        self.weight = weight
    }

    var body: some View {
        let base = Text(text).font(ContermFont.face(size)).tracking(tracking)
        ZStack(alignment: .leading) {
            if ContermFont.needsSynthesisedWeight {
                base.offset(x: weight, y: weight)
            }
            base
        }
        .fixedSize()
    }
}

/// The Conterm wordmark, as a template image so it takes the surrounding tint.
struct ContermWordmark: View {
    var height: CGFloat = 26

    var body: some View {
        if let image = UIImage(named: "text-logo")?
            .withRenderingMode(.alwaysTemplate) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
        } else {
            // The mark is decorative; a missing asset should not leave a hole.
            ContermText("CONTERM", size: height * 0.62, tracking: 1.2)
        }
    }
}
