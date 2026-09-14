import SwiftUI
import UIKit

extension Theme {
    /// The chosen ground. Cached the way `uiScale` is: read once from
    /// defaults and reloaded when the setting changes, because the tokens
    /// that derive from it are touched on every render.
    nonisolated(unsafe) private static var paletteCache: GroundPalette?
    static var palette: GroundPalette {
        // Read through the preference on the main thread, so a view body
        // that asks for any palette colour is observing the setting and
        // redraws the moment it changes. Off the main thread the cache
        // answers, which is what the setting writes into.
        if Thread.isMainThread {
            let id = MainActor.assumeIsolated { Preferences.shared.ground }
            if let p = paletteCache, p.id == id { return p }
            let p = GroundPalette.named(id)
            paletteCache = p
            return p
        }
        if let p = paletteCache { return p }
        let p = GroundPalette.named(UserDefaults.standard.string(forKey: "conterm.ground"))
        paletteCache = p
        return p
    }
    static func reloadPalette() {
        paletteCache = GroundPalette.named(UserDefaults.standard.string(forKey: "conterm.ground"))
    }
}
