import Foundation
import os

/// Process-global libghostty setup.
///
/// `ghostty_init` is a one-time, process-wide call and everything else in the
/// library is undefined before it runs, so it lives here rather than in any
/// one surface's lifecycle.
enum Ghostty {
    private static let initialized = OSAllocatedUnfairLock(initialState: false)

    /// Initialise libghostty. Safe to call more than once; only the first
    /// call does anything.
    @discardableResult
    static func initializeOnce() -> Bool {
        initialized.withLock { done in
            if done { return true }

            // Conterm on macOS points GHOSTTY_RESOURCES_DIR at the bundled
            // shell-integration scripts and terminfo. Neither is meaningful
            // here: there is no local shell to integrate with, and the
            // terminfo that matters lives on the far end of the SSH
            // connection, not on the phone.

            let argv0 = strdup("Conterm")
            defer { free(argv0) }
            var args: [UnsafeMutablePointer<CChar>?] = [argv0, nil]
            let rc = args.withUnsafeMutableBufferPointer { buf in
                ghostty_init(UInt(buf.count - 1), buf.baseAddress)
            }
            guard rc == 0 else {
                log.error("ghostty_init failed rc=\(rc)")
                return false
            }
            done = true
            return true
        }
    }

    static let log = Logger(subsystem: "dev.conterm.ios", category: "ghostty")

    /// Build info, for the diagnostics screen and bug reports.
    static var versionString: String {
        let info = ghostty_info()
        guard let ptr = info.version else { return "unknown" }
        return String(cString: ptr, encoding: .utf8) ?? "unknown"
    }
}
