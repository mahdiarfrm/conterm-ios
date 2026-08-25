import Foundation
import UIKit
import os

extension Ghostty {

    /// The process-wide libghostty app object. One per process; every surface
    /// belongs to it.
    @MainActor
    final class App {
        // `nonisolated(unsafe)`: deinit runs outside the actor and has to
        // free this, and a raw pointer is not Sendable. It is written once
        // in init and never mutated, which is the case the annotation is
        // for.
        nonisolated(unsafe) let handle: ghostty_app_t

        /// Coalesces `wakeup_cb` into at most one pending `ghostty_app_tick`.
        ///
        /// This is not an optimisation, it is load-bearing. `wakeup_cb` fires
        /// far faster than the run loop drains, and a single tick drains
        /// *all* pending work — so without coalescing the queue amplifies
        /// itself into thousands of main-thread wakeups a second on a surface
        /// that is doing nothing. Conterm learned this on a Mac plugged into
        /// the wall; on a phone it is a battery bug.
        private let tickPending = OSAllocatedUnfairLock(initialState: false)

        init?(config: Config) {
            guard Ghostty.initializeOnce() else { return nil }

            var runtime = ghostty_runtime_config_s(
                userdata: nil,
                supports_selection_clipboard: false,
                wakeup_cb: { _ in App.current?.scheduleTick() },
                action_cb: { _, target, action in App.handle(target: target, action: action) },
                read_clipboard_cb: { _, location, state in
                    App.readClipboard(location: location, state: state)
                },
                confirm_read_clipboard_cb: { _, _, _, _ in
                    // Nothing on iOS can paste into a terminal without the
                    // user having tapped Paste, so there is nothing left to
                    // confirm. The system already asked.
                },
                write_clipboard_cb: { _, location, content, count, confirm in
                    App.writeClipboard(location: location, content: content,
                                       count: count, confirm: confirm)
                },
                close_surface_cb: { userdata, processAlive in
                    SurfaceRegistry.shared.requestClose(userdata: userdata,
                                                        processAlive: processAlive)
                }
            )

            guard let handle = ghostty_app_new(&runtime, config.handle) else {
                Ghostty.log.error("ghostty_app_new returned null")
                return nil
            }
            self.handle = handle
            App.current = self
        }

        deinit {
            // `App.current` is a strong reference held for the C callbacks,
            // so reaching deinit means the app is being torn down for real.
            ghostty_app_free(handle)
        }

        /// The single live app, reachable from the C callbacks. libghostty
        /// hands `userdata` back on most callbacks but not `wakeup_cb`, which
        /// is exactly the one that needs to find us.
        nonisolated(unsafe) static var current: App?

        // MARK: - Ticking

        nonisolated func scheduleTick() {
            let alreadyPending = tickPending.withLock { pending -> Bool in
                if pending { return true }
                pending = true
                return false
            }
            guard !alreadyPending else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tickPending.withLock { $0 = false }
                ghostty_app_tick(self.handle)
            }
        }

        func setFocus(_ focused: Bool) {
            ghostty_app_set_focus(handle, focused)
        }

        func setColorScheme(_ scheme: UIUserInterfaceStyle) {
            ghostty_app_set_color_scheme(
                handle,
                scheme == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        }

        // MARK: - Callbacks

        /// Decode and dispatch an action.
        ///
        /// **This must finish reading the action before it returns.**
        /// `ghostty_action_s` carries `const char*` fields that libghostty
        /// frees the moment the callback returns, so anything we want later
        /// has to be copied into Swift memory *here*, not after a hop to the
        /// main queue.
        nonisolated static func handle(target: ghostty_target_s,
                                       action: ghostty_action_s) -> Bool {
            SurfaceRegistry.shared.handle(target: target, action: action)
        }

        nonisolated static func readClipboard(location: ghostty_clipboard_e,
                                              state: UnsafeMutableRawPointer?) -> Bool {
            // Reading the pasteboard from a background thread is not allowed,
            // and libghostty wants an answer synchronously. Surfaces route
            // paste through `SurfaceController.paste()` instead, which runs
            // on the main actor where UIPasteboard is legal.
            _ = location
            _ = state
            return false
        }

        nonisolated static func writeClipboard(location: ghostty_clipboard_e,
                                               content: UnsafePointer<ghostty_clipboard_content_s>?,
                                               count: Int,
                                               confirm: Bool) {
            _ = confirm
            guard location == GHOSTTY_CLIPBOARD_STANDARD,
                  let content, count > 0 else { return }
            // Copy out of libghostty's memory before hopping threads: these
            // pointers are freed as soon as this callback returns.
            var text: String?
            for i in 0..<count {
                let item = content[i]
                let mime = item.mime.map { String(cString: $0) } ?? "text/plain"
                guard mime.hasPrefix("text/"), let data = item.data else { continue }
                text = String(cString: data)
                break
            }
            guard let text else { return }
            DispatchQueue.main.async {
                UIPasteboard.general.string = text
            }
        }
    }

    /// A libghostty configuration.
    ///
    /// The pinned libghostty has no string-key setter — everything goes
    /// through config *files* — so settings are written to a file in the
    /// app's caches directory and loaded from there. That is also what
    /// Conterm does on macOS, for the same reason.
    @MainActor
    final class Config {
        nonisolated(unsafe) let handle: ghostty_config_t

        init?(settings: [String: String] = [:]) {
            guard Ghostty.initializeOnce(), let handle = ghostty_config_new() else {
                return nil
            }
            self.handle = handle

            var lines = Config.defaults
            for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
                lines.append("\(key) = \(value)")
            }

            if let url = Config.write(lines.joined(separator: "\n")) {
                url.path.withCString { ghostty_config_load_file(handle, $0) }
            }
            ghostty_config_finalize(handle)

            let diagnostics = ghostty_config_diagnostics_count(handle)
            if diagnostics > 0 {
                for i in 0..<diagnostics {
                    let d = ghostty_config_get_diagnostic(handle, i)
                    if let msg = d.message {
                        Ghostty.log.warning("config: \(String(cString: msg))")
                    }
                }
            }
        }

        deinit { ghostty_config_free(handle) }

        /// Defaults for a terminal that only ever talks to a remote host.
        private static let defaults: [String] = [
            // A block cursor visually sits ON the previous character, which
            // confuses people. Conterm ships the same default.
            "cursor-style = bar",
            "cursor-style-blink = true",
            // Keep the cursor shape from being rewritten by remote shells
            // (oh-my-zsh themes, vi-mode).
            "shell-integration-features = no-cursor",
            // There is no local shell to integrate with.
            "shell-integration = none",
            // Opaque: the terminal is a solid tile on the app's glass sheet,
            // and a translucent streaming region over a phone wallpaper is
            // unreadable rather than pretty.
            "background-opacity = 1",
            // Room at the rounded corner so text isn't flush with it.
            "window-padding-x = 6",
            "window-padding-y = 4",
        ]

        private static func write(_ contents: String) -> URL? {
            let dir = FileManager.default.urls(for: .cachesDirectory,
                                               in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("ghostty.conf")
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
                return url
            } catch {
                Ghostty.log.error("couldn't write ghostty config: \(error.localizedDescription)")
                return nil
            }
        }
    }
}
