import Foundation
import os

/// Maps libghostty surface handles back to their Swift controllers, and
/// decodes the action callback.
///
/// The decoding half matters more than the mapping half. `ghostty_action_s`
/// carries `const char*` fields that libghostty frees the instant the
/// callback returns, and the callback can arrive on libghostty's own threads.
/// So every action is copied into a `Sendable` Swift value *synchronously*,
/// and only then handed to the main actor. Reading those pointers after the
/// hop is a use-after-free that shows up as garbled titles long before it
/// shows up as a crash.
final class SurfaceRegistry: @unchecked Sendable {
    static let shared = SurfaceRegistry()

    /// What a surface can be told to do. One case per action tag we act on;
    /// everything else is ignored rather than crashing on an unknown tag,
    /// because libghostty adds tags faster than we adopt them.
    enum DecodedAction: Sendable {
        case render
        case setTitle(String)
        case pwd(String)
        case openURL(String)
        case desktopNotification(title: String, body: String)
        case commandFinished(exitCode: Int32, durationMS: UInt64)
        case searchTotal(Int)
        case searchSelected(Int)
        case rendererHealth(healthy: Bool)
        case showKeyboard(Bool)
        case closeRequested
    }

    /// Keyed on the handle's bit pattern rather than the pointer itself:
    /// a raw pointer is not `Sendable`, and this map is read from
    /// libghostty's threads.
    private let lock = OSAllocatedUnfairLock(initialState: [UInt: Weak]())
    private struct Weak { weak var controller: SurfaceController? }

    private static func key(_ handle: ghostty_surface_t) -> UInt {
        UInt(bitPattern: handle)
    }

    private init() {}

    // MARK: - Registration

    func register(_ controller: SurfaceController, handle: ghostty_surface_t) {
        // The key is computed outside the closure: a raw pointer is not
        // Sendable and so cannot cross into one, but its bit pattern can.
        let k = Self.key(handle)
        lock.withLock { $0[k] = Weak(controller: controller) }
    }

    func unregister(handle: ghostty_surface_t) {
        let k = Self.key(handle)
        _ = lock.withLock { $0.removeValue(forKey: k) }
    }

    private func controller(for handle: ghostty_surface_t) -> SurfaceController? {
        let k = Self.key(handle)
        return lock.withLock { $0[k]?.controller }
    }

    // MARK: - Dispatch

    /// Called on libghostty's thread. Decode first, dispatch second.
    func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let handle = target.target.surface else {
            return false
        }
        guard let decoded = decode(action) else { return false }

        // `.render` is the hot path — it arrives at frame rate. Marking the
        // surface dirty is thread-safe and needs no Swift state at all, so
        // it answers here rather than paying a queue hop and an actor hop
        // per frame.
        if case .render = decoded {
            ghostty_surface_refresh(handle)
            return true
        }

        guard let controller = controller(for: handle) else { return false }

        DispatchQueue.main.async {
            MainActor.assumeIsolated { controller.apply(decoded) }
        }
        return true
    }

    func requestClose(userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let userdata else { return }
        let controller = Unmanaged<SurfaceController>
            .fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { controller.apply(.closeRequested) }
        }
        _ = processAlive
    }

    // MARK: - Decoding

    /// Copy everything we need out of libghostty's memory, synchronously.
    private func decode(_ action: ghostty_action_s) -> DecodedAction? {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            return .render

        case GHOSTTY_ACTION_SET_TITLE:
            guard let t = action.action.set_title.title else { return nil }
            return .setTitle(String(cString: t))

        case GHOSTTY_ACTION_PWD:
            guard let p = action.action.pwd.pwd else { return nil }
            return .pwd(String(cString: p))

        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let ptr = u.url else { return nil }
            return .openURL(String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(u.len)),
                                   as: UTF8.self))

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            return .desktopNotification(
                title: n.title.map { String(cString: $0) } ?? "",
                body: n.body.map { String(cString: $0) } ?? "")

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            return .searchTotal(Int(action.action.search_total.total))

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            return .searchSelected(Int(action.action.search_selected.selected))

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            return .rendererHealth(healthy: action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY)

        case GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD:
            return .showKeyboard(true)

        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            return .closeRequested

        default:
            return nil
        }
    }
}
