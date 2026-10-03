import Foundation
import Network

// Test-only seams for `AuthProxy`.
//
// These live in the APP target, not the test target, for two hard reasons:
//
// 1. `AuthProxy.port` and `AuthProxy.acceptedConnections` are `private`, and even
//    `@testable import` does not reach `private` — only `internal`. An extension in
//    the test target cannot read them.
// 2. The test target is built with `MemberImportVisibility` (and friends) enabled,
//    where a member's declaring module must be imported explicitly for the member to
//    be visible by unqualified name. `DispatchQueue.global(qos:)` and
//    `NWConnection.State` failed to infer there for exactly this reason. Importing
//    both here, in the app target where the rest of `AuthProxy` already does, keeps
//    the seam honest without teaching the test file about module visibility.
//
// The blocking wait used to live as `Thread.sleep` inside these members. That is not
// acceptable: `AuthProxy` is an actor, so a sleeping body blocks its executor and
// deadlocks against the very `newConnectionHandler` it is waiting for. The seam
// therefore only *starts* the peer connection and reports the tracker; the caller
// awaits progress with `Task.sleep`, off the actor.
extension AuthProxy {
	/// The actor's live port, or 0 before bind / after `stop()`. `localPort` already
	/// exposes this publicly; this is the same value under the test-seam name.
	internal var portForTests: UInt16 {
		get async { localPort }
	}

	/// The live accepted-connection tracker, for asserting `stop()` shuts it down.
	///
	/// `AcceptedConnections` is itself internal to the app target, so the test side
	/// cannot name its type; expose only the count, which is all the assertions need.
	internal func trackedConnectionCountForTests() async -> Int {
		acceptedConnections?.count ?? -1
	}

	/// Open a real loopback connection through the running listener so the tracker
	/// has something to cancel, and return once the tracker has registered it (or
	/// `nil` if it never did / the listener is not ready / loopback is unavailable in
	/// this sandbox).
	///
	/// The returned connection is owned by the caller, which must `cancel()` it.
	/// Registration happens on a Network.framework queue via `newConnectionHandler`,
	/// hence the bounded wait — but the wait runs in a detached task on the
	/// cooperative pool, never on the actor's executor.
	internal func openLoopbackConnectionForTests(timeout: Duration = .seconds(2)) async -> NWConnection? {
		let port = await self.portForTests
		guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }

		let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
		let connected = SendableBox<Bool>(false)
		let queue = DispatchQueue(label: "AuthProxy.loopbackProbe")

		connection.stateUpdateHandler = { state in
			switch state {
			case .ready: connected.set(true)
			case .failed, .cancelled: connected.set(false)
			@unknown default: break
			}
		}
		connection.start(queue: queue)

		let started = Date()
		while !connected.current {
			if Date().timeIntervalSince(started) > timeout.seconds {
				connection.cancel()
				return nil
			}
			try? await Task.sleep(for: .milliseconds(10))
		}

		// `connected` means the TCP peer is up; the tracker's count is updated on the
		// Network queue, so give it the same bounded budget.
		let trackStart = Date()
		while await trackedConnectionCountForTests() <= 0 {
			if Date().timeIntervalSince(trackStart) > timeout.seconds {
				connection.cancel()
				return nil
			}
			try? await Task.sleep(for: .milliseconds(10))
		}
		return connection
	}
}

private extension Duration {
	var seconds: TimeInterval {
		Double(components.seconds) + Double(components.attoseconds) * 1e-18
	}
}
