import Testing
import Foundation
@testable import TAClient

/// Weak-ref tests proving the URLSession lifecycle invariant in
/// `StreamingSession` (see CLAUDE.md). After the consumer drops its strong
/// reference, ARC must reclaim the instance within the polling window.
/// Nested under `DataLayerSuite(.serialized)` because `MockURLProtocol`
/// shares `nonisolated(unsafe)` static state with other Phase 3 tests.
extension DataLayerSuite {
@Suite(.serialized) struct StreamingSessionTests {

    init() {
        MockResponse.tearDown()
    }

    // MARK: - Helpers

    /// Polls every ~5 ms until `ref()` returns `nil` or timeout expires; silent on timeout.
    private func waitUntilNil<T: AnyObject>(
        _ ref: () -> T?,
        timeout: Duration = .seconds(2)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ref() != nil {
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Builds a fresh `URLSessionConfiguration` wired to `MockURLProtocol`.
    private func makeConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    private static let mockURL = URL(string: "https://ta.example.com/stream")!

    private func makeRequest() -> URLRequest {
        URLRequest(url: Self.mockURL)
    }

    // MARK: - Tests

    /// Natural completion: stream a small response, drain all chunks, drop
    /// the strong reference to `StreamingSession`. After invalidation the
    /// session releases its delegate (the StreamingSession itself), so the
    /// weak ref must reach `nil` within the polling window.
    @Test("session reclaimed after natural completion")
    func sessionInvalidatedAfterNaturalCompletion() async throws {
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: Self.mockURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(repeating: 0xAB, count: 4096))
        }

        weak var weakStreamer: StreamingSession?
        do {
            let streamer = StreamingSession()
            weakStreamer = streamer
            let (_, chunks) = try await streamer.stream(
                request: makeRequest(),
                configuration: makeConfig()
            )
            for try await _ in chunks {
                // drain
            }
        }

        try await waitUntilNil({ weakStreamer })
        #expect(weakStreamer == nil, "StreamingSession leaked: URLSession is still retaining its delegate")
    }

    /// Consumer drops the stream mid-iteration via `break`. The
    /// `dataContinuation.onTermination` block calls `task.cancel()`, which
    /// triggers `didCompleteWithError(URLError.cancelled)` — this is the
    /// fix point that must invalidate the session.
    @Test("session reclaimed after consumer drops stream")
    func sessionInvalidatedAfterConsumerDropsStream() async throws {
        // 16 chunks × 4 KiB = 64 KiB of data, 100 ms between chunks → ~1.6 s
        // total wall-clock if drained, plenty of room for the consumer to
        // break after the first chunk and exercise the cancel path.
        let chunks: [Data] = (0..<16).map { _ in Data(repeating: 0xCD, count: 4096) }
        MockURLProtocol.slowStreamHandler = { _ in
            let response = HTTPURLResponse(
                url: Self.mockURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, chunks, 0.1)
        }

        weak var weakStreamer: StreamingSession?
        do {
            let streamer = StreamingSession()
            weakStreamer = streamer
            let (_, stream) = try await streamer.stream(
                request: makeRequest(),
                configuration: makeConfig()
            )
            for try await _ in stream {
                break // mid-stream cancel
            }
        }

        // 5 s ≥ 1.6 s slow stream + invalidation + CI jitter.
        try await waitUntilNil({ weakStreamer }, timeout: .seconds(5))
        #expect(weakStreamer == nil, "StreamingSession leaked after consumer cancellation: URLSession is still retaining its delegate")
    }

    /// Regression for the pre-fix ordering bug: `onTermination` used to be
    /// attached AFTER the response arrived, via `dataContinuation?`, so a tiny
    /// response whose delegate reached `finish()` first left `dataContinuation`
    /// nil and the assignment was a silent no-op — nothing ever cancelled the
    /// task, `didCompleteWithError` never fired, and the delegate-based session
    /// (which strongly retains this instance) leaked.
    ///
    /// The response body is delivered with a delay so the stream is guaranteed
    /// to still be live at `stream()` return (otherwise the test would pass
    /// vacuously on natural completion); the consumer then drops the stream
    /// WITHOUT ever iterating it.
    @Test("session reclaimed when consumer abandons stream before iterating")
    func sessionInvalidatedWhenStreamAbandonedWithoutIterating() async throws {
        let chunks: [Data] = (0..<8).map { _ in Data(repeating: 0x5A, count: 4096) }
        MockURLProtocol.slowStreamHandler = { _ in
            let response = HTTPURLResponse(
                url: Self.mockURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, chunks, 0.1)
        }

        weak var weakStreamer: StreamingSession?
        do {
            let streamer = StreamingSession()
            weakStreamer = streamer
            let (response, _) = try await streamer.stream(
                request: makeRequest(),
                configuration: makeConfig()
            )
            // Response headers received, body still in flight. Dropping the
            // stream here is what `break`ing out of the loop or an early `return`
            // does: the `AsyncThrowingStream` deinitializes and fires
            // `onTermination`.
            #expect(response.statusCode == 200)
        }

        try await waitUntilNil({ weakStreamer }, timeout: .seconds(5))
        #expect(weakStreamer == nil, "StreamingSession leaked when the stream was abandoned before iteration")
    }

    /// Same contract on the error path: the caller cancels the task that is
    /// awaiting the response headers. Cancelling a Swift task does not cancel a
    /// bare `URLSessionTask`, so `stream()` must do it itself (via
    /// `withTaskCancellationHandler`) for the session to ever be invalidated.
    @Test("session reclaimed when awaiting task is cancelled before response")
    func sessionInvalidatedWhenAwaitCancelledBeforeResponse() async throws {
        // Nothing reaches the client for 5 s, so the response-headers
        // continuation is still suspended when we cancel.
        MockURLProtocol.delayedHandler = { _ in
            let response = HTTPURLResponse(
                url: Self.mockURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data([0x01]), 5)
        }

        weak var weakStreamer: StreamingSession?
        let task = Task { () -> Bool in
            let streamer = StreamingSession()
            weakStreamer = streamer
            do {
                _ = try await streamer.stream(
                    request: makeRequest(),
                    configuration: makeConfig()
                )
                return false  // never reached — we cancel below
            } catch {
                return true
            }
        }

        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        // Bounded so an ignored cancellation fails the test instead of hanging the
        // suite for the URLSession's 60 s request timeout.
        let threw = await withTaskGroup(of: Bool?.self) { group in
            // No `try`: the task's closure is non-throwing (it catches its own
            // errors), so `Failure == Never` and `Task.value` does not throw here.
            // The earlier `try?` was dead weight and the compiler said so. The `nil`
            // in the group's element type is only ever produced by the sibling
            // timeout task, which is what makes the race below decidable.
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(threw == true, "stream() should have thrown after cancellation")

        try await waitUntilNil({ weakStreamer }, timeout: .seconds(5))
        #expect(weakStreamer == nil, "StreamingSession leaked after the awaiting task was cancelled")
    }

    /// Exit 3 of `stream`'s cancellation contract: the consumer's *task* is
    /// cancelled while suspended inside the chunk loop. `AsyncThrowingStream`
    /// cannot observe this — the stream object stays alive, so its
    /// `CancellationHandler` never fires — so the contract is that the call site
    /// must reach for `cancelUpstream()`.
    ///
    /// This test pins the half that `StreamingSession` does owe: a consumer that
    /// pairs task cancellation with `cancelUpstream()` (as `AuthProxy` and
    /// `VideoDetailViewModel` do) is reclaimed. The `defer`-style pairing is the
    /// documented mitigation, so it needs a test that exercises exactly it rather
    /// than a bare `task.cancel()` that the class makes no promise about.
    @Test("consuming task cancelled mid-body + cancelUpstream reclaims the session")
    func consumingTaskCancelledMidBodyWithExplicitCancel() async throws {
        let chunks: [Data] = (0..<16).map { _ in Data(repeating: 0x77, count: 4096) }
        MockURLProtocol.slowStreamHandler = { _ in
            let response = HTTPURLResponse(
                url: Self.mockURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, chunks, 0.1)
        }

        weak var weakStreamer: StreamingSession?
        let iterations = SendableBox<Int>(0)
        let task = Task {
            let streamer = StreamingSession()
            weakStreamer = streamer
            defer { streamer.cancelUpstream() }
            // `try?` here would produce `Optional<(response, chunks)>` — a single
            // optional TUPLE, which cannot be destructured into `(_, stream)`. Every
            // other test in this file calls with `try await` and destructures the
            // non-optional tuple; do the same and absorb a throw in the catch below
            // (a stream-establishment failure is as valid an outcome here as a
            // mid-body throw, and the assertion is about the weak reference).
            let (_, stream) = try await streamer.stream(
                request: makeRequest(),
                configuration: makeConfig()
            )
            do {
                for try await _ in stream {
                    iterations.set(iterations.current + 1)
                }
            } catch {
                // Expected: cancellation.
            }
        }

        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        // The join that proves the consumer finished — and its
        // `defer { cancelUpstream() }` ran — before the weak reference is checked.
        // No `try`: this closure is non-throwing, so `Failure == Never`.
        //
        // The await itself is load-bearing and must not be "cleaned up": it is what
        // orders the leak assertion below after the consumer's teardown.
        _ = try? await task.value

        #expect(iterations.current >= 1, "the consumer should have started reading")
        try await waitUntilNil({ weakStreamer }, timeout: .seconds(5))
        #expect(weakStreamer == nil,
                "StreamingSession leaked after the consuming task was cancelled mid-body")
    }

    /// `cancelUpstream()` is what a relay uses when its *downstream* dies: no
    /// amount of stream plumbing cancels a `URLSessionTask` for a consumer that
    /// is still holding the stream alive, so the session must expose an explicit
    /// off-consumer cancel. Also pins that the call is safe (and effective) when
    /// made before `stream(...)` even exists.
    @Test("cancelUpstream cancels an in-flight request without dropping the stream")
    func cancelUpstreamCancelsInFlightRequest() async throws {
        let chunks: [Data] = (0..<16).map { _ in Data(repeating: 0x31, count: 4096) }
        MockURLProtocol.slowStreamHandler = { _ in
            let response = HTTPURLResponse(
                url: Self.mockURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, chunks, 0.1)
        }

        weak var weakStreamer: StreamingSession?
        let streamer = StreamingSession()
        weakStreamer = streamer
        let (_, stream) = try await streamer.stream(
            request: makeRequest(),
            configuration: makeConfig()
        )
        // Read exactly one chunk so the request is genuinely in flight, then
        // cancel from "outside" while keeping `stream` alive.
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        streamer.cancelUpstream()
        streamer.cancelUpstream()  // idempotent

        // The stream must terminate (with a cancellation error) rather than keep
        // yielding the remaining ~1.5 s of chunks.
        var receivedAfterCancel = 0
        do {
            while try await iterator.next() != nil {
                receivedAfterCancel += 1
            }
        } catch {
            // Expected: URLError.cancelled.
        }
        #expect(receivedAfterCancel == 0,
                "upstream kept delivering after cancelUpstream (\(receivedAfterCancel) extra chunks)")

        // Keep a strong ref until here so "the stream was never dropped" is true.
        withExtendedLifetime(stream) {}
        try await waitUntilNil({ weakStreamer }, timeout: .seconds(5))
        #expect(weakStreamer == nil, "StreamingSession leaked after cancelUpstream")
    }

    /// `cancelUpstream()` before the task exists must not be lost — a relay can
    /// notice a dead peer while the request is still being set up.
    @Test("cancelUpstream before stream takes effect on the next request")
    func cancelUpstreamBeforeStreamIsRemembered() async throws {
        let chunks: [Data] = (0..<16).map { _ in Data(repeating: 0x32, count: 4096) }
        MockURLProtocol.slowStreamHandler = { _ in
            let response = HTTPURLResponse(
                url: Self.mockURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, chunks, 0.1)
        }

        weak var weakStreamer: StreamingSession?
        let streamer = StreamingSession()
        weakStreamer = streamer
        streamer.cancelUpstream()

        do {
            let (_, stream) = try await streamer.stream(
                request: makeRequest(),
                configuration: makeConfig()
            )
            // Already cancelled: at most the bytes already buffered, then an end.
            for try await _ in stream {}
        } catch {
            // Expected: the pre-cancelled task fails immediately.
        }

        try await waitUntilNil({ weakStreamer }, timeout: .seconds(5))
        #expect(weakStreamer == nil, "StreamingSession leaked after a pre-emptive cancelUpstream")
    }

    /// Genuine network-error branch: the mock throws `URLError`, so
    /// `didCompleteWithError(error)` runs the error path through
    /// `responseContinuation?.resume(throwing:)` and then invalidates the
    /// session. Distinct coverage from the natural-completion (nil error)
    /// and consumer-cancel (`URLError.cancelled`) paths.
    @Test("session reclaimed after network error")
    func sessionInvalidatedAfterNetworkError() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.networkConnectionLost)
        }

        weak var weakStreamer: StreamingSession?
        do {
            let streamer = StreamingSession()
            weakStreamer = streamer
            do {
                _ = try await streamer.stream(
                    request: makeRequest(),
                    configuration: makeConfig()
                )
                Issue.record("Expected stream() to throw but it returned")
            } catch {
                // Expected.
            }
        }

        try await waitUntilNil({ weakStreamer })
        #expect(weakStreamer == nil, "StreamingSession leaked after network error: URLSession is still retaining its delegate")
    }
}
}
