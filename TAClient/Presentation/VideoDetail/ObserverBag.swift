import Foundation

/// Thread-safe, nonisolated container for KVO and NotificationCenter observer
/// tokens collected during AVPlayer setup. Exists so `VideoDetailViewModel`
/// (MainActor-isolated under Swift 6) can safely tear observers down from
/// `deinit` without hopping to the MainActor — `.invalidate()` on
/// `NSKeyValueObservation` and `NotificationCenter.removeObserver(_:)` are
/// both thread-safe.
///
/// Usage: register tokens via `addKVO` / `addNotification` at observation
/// setup. Call `tearDown()` to invalidate all tokens and drop references. Safe
/// to call `tearDown()` multiple times — each call clears its own state.
final class ObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var kvoTokens: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []

    func addKVO(_ token: NSKeyValueObservation) {
        lock.lock()
        defer { lock.unlock() }
        kvoTokens.append(token)
    }

    func addNotification(_ token: NSObjectProtocol) {
        lock.lock()
        defer { lock.unlock() }
        notificationTokens.append(token)
    }

    /// Invalidates every tracked observer and empties both arrays. Nonisolated
    /// and idempotent — safe to call from `deinit` under any actor isolation.
    func tearDown() {
        lock.lock()
        let kvo = kvoTokens
        let notifs = notificationTokens
        kvoTokens.removeAll()
        notificationTokens.removeAll()
        lock.unlock()

        for token in kvo { token.invalidate() }
        for token in notifs { NotificationCenter.default.removeObserver(token) }
    }
}
