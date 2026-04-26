import Foundation
import Testing
@testable import TAClient

/// Tests for `ObserverBag` — the nonisolated container that lets
/// `VideoDetailViewModel` tear observers down from `deinit` without a
/// MainActor hop.
@MainActor
struct ObserverBagTests {

    /// Observable target for KVO. Must inherit from `NSObject` and expose
    /// an `@objc dynamic` property so `.observe(_:)` can hook into KVO.
    final class ObservableTarget: NSObject {
        @objc dynamic var counter: Int = 0
    }

    @Test func tearDown_invalidatesKVOTokens() {
        let bag = ObserverBag()
        let target = ObservableTarget()
        var fireCount = 0

        let token = target.observe(\.counter, options: [.new]) { _, _ in
            fireCount += 1
        }
        bag.addKVO(token)

        // Trigger the observer once to confirm the token is live.
        target.counter = 1
        #expect(fireCount == 1)

        bag.tearDown()

        // After tearDown, changing the value must not fire the callback.
        target.counter = 2
        #expect(fireCount == 1, "Expected KVO callback to not fire after tearDown()")
    }

    @Test func tearDown_removesNotificationTokens() {
        let bag = ObserverBag()
        let name = Notification.Name("ru.mzhukov.TAClient.tests.observerBag.\(UUID().uuidString)")
        var fireCount = 0

        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            fireCount += 1
        }
        bag.addNotification(token)

        NotificationCenter.default.post(name: name, object: nil)
        #expect(fireCount == 1)

        bag.tearDown()

        NotificationCenter.default.post(name: name, object: nil)
        #expect(fireCount == 1, "Expected notification callback to not fire after tearDown()")
    }

    @Test func tearDown_isIdempotent() {
        let bag = ObserverBag()
        let target = ObservableTarget()
        let token = target.observe(\.counter, options: [.new]) { _, _ in }
        bag.addKVO(token)

        bag.tearDown()
        bag.tearDown()  // second call is a no-op — must not crash
        bag.tearDown()  // and a third — same story

        // Adding a new token after tearDown must still work.
        let token2 = target.observe(\.counter, options: [.new]) { _, _ in }
        bag.addKVO(token2)
        bag.tearDown()
    }

    /// End-to-end smoke test — creates a VM-like holder in an autoreleasepool,
    /// registers an observer via the bag, drops the strong reference, and
    /// verifies the post-deinit notification does not fire the callback. This
    /// proves observers are cleaned up under abnormal teardown (no explicit
    /// `stopPlayback()`) via the same path `VideoDetailViewModel.deinit` uses.
    @Test func bagOwner_deinit_tearsDownObserversIndirectly() {
        let name = Notification.Name("ru.mzhukov.TAClient.tests.observerBag.deinit.\(UUID().uuidString)")
        var fireCount = 0

        // Local holder whose deinit calls tearDown(), mirroring
        // VideoDetailViewModel.deinit semantics.
        final class Holder {
            let bag = ObserverBag()
            deinit { bag.tearDown() }
        }

        autoreleasepool {
            let holder = Holder()
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { _ in
                fireCount += 1
            }
            holder.bag.addNotification(token)

            NotificationCenter.default.post(name: name, object: nil)
            #expect(fireCount == 1)
            // holder goes out of scope here — deinit runs, bag.tearDown() fires
        }

        NotificationCenter.default.post(name: name, object: nil)
        #expect(fireCount == 1, "Expected observer to be removed by Holder.deinit → bag.tearDown()")
    }
}
