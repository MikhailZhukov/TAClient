import Foundation
import Network

// Test-only seams for `AuthProxy`.
//
// These live in the APP target, not the test target, for two hard reasons:
//
// 1. `AuthProxy.acceptedConnections` is not reachable from the test target even with
//    `@testable import` — `@testable` extends `internal` to the tests, and never
//    reaches `private`. The field is therefore declared `internal` (see AuthProxy.swift)
//    and this extension reads it.
// 2. The test target builds with `MemberImportVisibility` enabled, where a member is
//    only visible by unqualified name if its declaring module is imported here.
//    `DispatchQueue.global(qos:)` and `NWConnection.State` failed to infer in the
//    test target for exactly that reason. Both modules are imported below, as the
//    rest of AuthProxy already does.
//
// No blocking wait lives inside these members: `AuthProxy` is an actor, so a sleeping
// actor body blocks its executor and deadlocks against the `newConnectionHandler`
// whose effect it is waiting for. Every wait here is `await Task.sleep`.
extension AuthProxy {
    /// The actor's live port, or 0 before bind / after `stop()`. Same value as the
    /// public `localPort`, exposed under a test-seam name for intent.
    internal var portForTests: UInt16 {
        get async { localPort }
    }

    /// The live accepted-connection tracker's count, or `-1` when there is no
    /// tracker (never started, or after `stop()` dropped it).
    ///
    /// `AcceptedConnections` is app-target internal, so the test side cannot name the
    /// type; only the count is exposed, which is everything the assertions need.
    internal func trackedConnectionCountForTests() async -> Int {
        acceptedConnections?.count ?? -1
    }

    /// Open a real loopback connection through the running listener so the tracker
    /// has something to cancel, and return it once the tracker has registered the
    /// peer. Returns `nil` if the listener is not bound, the peer never became
    /// ready, the tracker never counted it, or loopback is unavailable in this
    /// sandbox.
    ///
    /// The returned connection belongs to the caller, which must `cancel()` it.
    /// Registration happens on a Network.framework queue via `newConnectionHandler`,
    /// hence the bounded waits.
    internal func openLoopbackConnectionForTests(timeoutSeconds: TimeInterval = 2) async -> NWConnection? {
        let port = await portForTests
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }

        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let connected = SendableBox<Bool>(false)
        let queue = DispatchQueue(label: "AuthProxy.loopbackProbe")

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connected.set(true)
            case .failed, .cancelled:
                connected.set(false)
            default:
                break
            }
        }
        connection.start(queue: queue)

        let started = Date()
        while !connected.current {
            if Date().timeIntervalSince(started) > timeoutSeconds {
                connection.cancel()
                return nil
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        // The TCP peer is up; the tracker's count is updated on the Network queue, so
        // give it the same bounded budget.
        let trackStarted = Date()
        while await trackedConnectionCountForTests() <= 0 {
            if Date().timeIntervalSince(trackStarted) > timeoutSeconds {
                connection.cancel()
                return nil
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return connection
    }
}
