import Foundation
import os

/// The in-app TCP/IP stack (gvisor, from Vendor/NetStack.xcframework) that
/// forwards the Linux guest's connections to real sockets on the phone,
/// giving any TCP port including ssh. It listens on a loopback WebSocket the
/// guest's page connects to. Started once on first use; the port is cached.
enum LinuxNetStack {
    private static let log = Logger(subsystem: "dev.conterm.ios", category: "netstack")
    private static let lock = OSAllocatedUnfairLock<UInt16?>(initialState: nil)

    /// The loopback port the stack's WebSocket forwarder listens on, starting
    /// it on first access. Nil if it fails to start.
    static var port: UInt16? {
        lock.withLock { state in
            if let state { return state }
            let result = StartNetStack()
            guard result > 0, result <= 65535 else {
                log.error("network stack failed to start (\(result))")
                return nil
            }
            let port = UInt16(result)
            log.notice("network stack on 127.0.0.1:\(port)")
            state = port
            return port
        }
    }
}
