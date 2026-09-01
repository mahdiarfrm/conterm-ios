import SwiftUI

/// Keeps a column readable when the window is wider than a column should be.
///
/// The phone layouts are the right layouts; an iPad does not need different
/// screens so much as it needs them to stop stretching. A host row spanning
/// 1024 points — a status dot at one end, a chevron a metre away at the other
/// — reads as a phone screen someone pulled at the corners, and the eye has
/// to travel the whole width to connect two things that belong together.
///
/// So content gets a ceiling and centres under it. The terminal is
/// deliberately exempt: there, width is columns, and columns are the point.
struct ReadableColumn: ViewModifier {
    /// Roughly the width at which a line of UI text stops being one glance.
    /// Not derived from anything — measured by eye against the phone layouts
    /// this is protecting, which is the only standard that matters here.
    var maximum: CGFloat = 720

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maximum)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func contermReadableColumn(_ maximum: CGFloat = 720) -> some View {
        modifier(ReadableColumn(maximum: maximum))
    }
}
