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
