import Foundation

/// Lock-guarded mutable cell for values that must cross a `@Sendable`
/// boundary before they are formally immutable — the general shape of "install
/// a cancel handler, then hand it the thing to cancel".
///
/// `SendableBox` is deliberately `@unchecked Sendable`: callers are
/// responsible for the same discipline the rest of this codebase uses for
/// lock-guarded `nonisolated(unsafe)` state — every read and write goes through
/// the internal `NSLock`.
final class SendableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var current: Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }

    /// Cancel helper for the `URLSessionTask?` case: a no-op while empty.
    func cancelContents() where Value == URLSessionTask? {
        current?.cancel()
    }
}

/// Streams URL response data as chunks via URLSessionDataDelegate.
/// More efficient than URLSession.AsyncBytes which iterates byte-by-byte.
final class StreamingSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var dataContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>?
    private var session: URLSession?

    /// Start the request and hand back the response headers plus a stream of
    /// body chunks.
    ///
    /// Cancellation contract (see CLAUDE.md, "URLSession lifecycle invariant"):
    /// a delegate-based `URLSession` strong-retains this instance until
    /// invalidated, and invalidation happens ONLY in
    /// `urlSession(_:task:didCompleteWithError:)`. That callback is guaranteed
    /// to fire only once the task is allowed to run (`resume()`) and is later
    /// completed, failed, or cancelled — so every path out of this method must
    /// leave the task reachable by a consumer cancel. Hence:
    ///
    /// 1. `onTermination` is attached inside the stream builder, BEFORE
    ///    `resume()`, and reaches the task through a `SendableBox` so the two can
    ///    be wired up in either order. The old `dataContinuation?.onTermination = …`
    ///    assignment ran after the response arrived, which was both too late for
    ///    a consumer that threw or returned before entering the loop, and a
    ///    silent no-op when a tiny response let the delegate reach `finish()`
    ///    first (leaving `dataContinuation` nil) — in both cases the task was
    ///    never cancelled, `didCompleteWithError` never fired, and the session
    ///    leaked.
    /// 2. If `stream()` itself is cancelled while waiting for the response, the
    ///    task is cancelled explicitly: cancellation of the awaiting task does
    ///    not cancel a bare `URLSessionTask`.
    func stream(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> (response: HTTPURLResponse, chunks: AsyncThrowingStream<Data, Error>) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        // The builder runs synchronously inside the `AsyncThrowingStream`
        // initializer and `box.task` is set immediately after it, both strictly
        // before `task.resume()`, so `onTermination` can never fire against an
        // empty box. The indirection exists because `onTermination` has to be
        // installed before the task is cancellable, while the continuation only
        // exists inside the builder.
        let box = SendableBox<URLSessionTask?>(nil)

        let dataStream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.onTermination = { _ in
                box.cancelContents()
            }
            self.dataContinuation = continuation
        }
        box.set(task)

        do {
            let response: HTTPURLResponse = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.responseContinuation = continuation
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
            // The consumer may be cancelled while the response is in flight, and
            // `AsyncThrowingStream` does not fire `onTermination` on a stream that
            // was never created or already finished — so the task would run to
            // `timeoutIntervalForResource = 0` with nobody reading it, and the
            // delegate-based session would never be invalidated.
            dataStream.onTermination = { [weak task] _ in
                task?.cancel()
            }
            return (response, dataStream)
        } catch {
            // Two distinct exits here:
            // - the response continuation threw: `didCompleteWithError` has
            //   already invalidated the session, so this cancel is a no-op;
            // - the caller's task was cancelled: `withTaskCancellationHandler`
            //   ran `onCancel`, which cancelled the URLSessionTask, which
            //   drives the delegate's terminal callback and the invalidate.
            // The cancel is re-issued for the same reason `stopPlayback`
            // re-runs `tearDown()` — cheap, idempotent, and it closes the
            // window if cancellation landed between the continuation resume
            // and this catch.
            task.cancel()
            throw error
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            responseContinuation?.resume(returning: http)
            responseContinuation = nil
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        dataContinuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            responseContinuation?.resume(throwing: error)
            responseContinuation = nil
            dataContinuation?.finish(throwing: error)
        } else {
            dataContinuation?.finish()
        }
        // Nil before invalidate: invalidate may fire didBecomeInvalidWithError
        // synchronously, which would re-enter cleanup with self.session still set.
        let sessionToInvalidate = self.session
        self.session = nil
        sessionToInvalidate?.finishTasksAndInvalidate()
    }
}
