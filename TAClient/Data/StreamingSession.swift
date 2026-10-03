import Foundation

/// Lock-guarded mutable cell for a value that must be readable and writable from
/// arbitrary threads — the general shape of "install a cancel handler first, then
/// hand it the thing to cancel".
///
/// Isolation: `nonisolated final class … : @unchecked Sendable`, with the mutable
/// value as a plain `private var`. That is the repo convention for a lock-guarded,
/// concurrency-neutral class — identical to `CacheStore` (`nonisolated final class`
/// + plain `private var entry`), and the class-level form is what makes the whole
/// type, mutable storage included, reachable from detached tasks, URLSession
/// delegate queues and `@Sendable` closures.
///
/// Two things that do NOT work here, both tried and both rejected by the compiler:
/// - a plain `final class` with `nonisolated` on members only: `nonisolated` on a
///   method does not de-isolate the *properties* it touches, so every access warns
///   "main actor-isolated property … can not be referenced from a nonisolated
///   context" (an error in Swift 6 mode);
/// - `nonisolated` on the mutable stored property itself: "'nonisolated' cannot be
///   applied to mutable stored properties".
///
/// Thread-safety comes entirely from the `NSLock` — no member touches `value`
/// outside it.
nonisolated final class SendableBox<Value>: @unchecked Sendable {
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
}

/// Streams URL response data as chunks via URLSessionDataDelegate.
/// More efficient than URLSession.AsyncBytes which iterates byte-by-byte.
final class StreamingSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    nonisolated(unsafe) private var dataContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    nonisolated(unsafe) private var responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>?
    nonisolated(unsafe) private var session: URLSession?
    /// Guards `upstreamTask` / `cancelledUpstream`: `cancelUpstream()` is called
    /// from a relay's send-failure path (a Network.framework queue), while
    /// `setUpstreamTask` runs on the `stream()` caller's executor.
    private let stateLock = NSLock()
    /// The in-flight request, reachable without a stream reference so
    /// `cancelUpstream()` works from a relay whose downstream vanished mid-body.
    ///
    /// `nonisolated(unsafe)` is required, not a shortcut: this class is a plain
    /// `final class`, so under the target's default MainActor isolation the mutable
    /// properties are MainActor and cannot be touched from the `nonisolated`
    /// URLSession delegate callbacks or from Network.framework queues. That is the
    /// same situation `ObserverBag` and `CacheStore` are in — they solve it with
    /// `nonisolated final class`; `StreamingSession` was declared without it and the
    /// three pre-existing properties above (`dataContinuation`,
    /// `responseContinuation`, `session`) already need the same treatment, which is
    /// applied to all five together. Every access to the two below goes through
    /// `stateLock`.
    nonisolated(unsafe) private var upstreamTask: URLSessionTask?
    nonisolated(unsafe) private var cancelledUpstream = false

    /// Start the request and hand back the response headers plus a stream of
    /// body chunks.
    ///
    /// Cancellation contract (see CLAUDE.md, "URLSession lifecycle invariant"):
    /// a delegate-based `URLSession` strong-retains this instance until
    /// invalidated, and invalidation happens ONLY in
    /// `urlSession(_:task:didCompleteWithError:)`. That callback is guaranteed
    /// to fire only once the task is allowed to run (`resume()`) and is later
    /// completed, failed, or cancelled — so every path out of this method must
    /// leave the task reachable by a consumer cancel.
    ///
    /// Four exits must all reach `task.cancel()`, and none of them implies the
    /// others:
    ///
    /// 1. the consumer drops, throws out of, or returns from the chunk loop —
    ///    covered by `continuation.onTermination`, set inside the stream builder and
    ///    therefore installed BEFORE `resume()`. The old
    ///    `dataContinuation?.onTermination = …` assignment ran after the response
    ///    arrived, which was too late for a consumer that threw before entering the
    ///    loop, and a silent no-op when a tiny response let the delegate reach
    ///    `finish()` first (leaving `dataContinuation` nil);
    /// 2. `stream()` itself is cancelled while awaiting the response headers —
    ///    covered by `withTaskCancellationHandler`, because cancelling a Swift task
    ///    never cancels a bare `URLSessionTask`;
    /// 3. the consumer's *task* is cancelled while suspended inside the loop — the
    ///    stream object stays alive, so (1) does not fire; and
    /// 4. a relay `break`s out of the loop while still holding the stream, which
    ///    neither (1) nor (3) can see either.
    ///
    /// Both (3) and (4) are the same shape — "the consumer stopped caring without
    /// the stream noticing" — and neither can be solved from inside the stream,
    /// because there is no observable event to hook. They are covered by
    /// `cancelUpstream()`, the explicit off-consumer cancel, which each call site
    /// must invoke: `VideoDetailViewModel`'s VLC relay and `AuthProxy`'s
    /// `processHTTPRequest` both do. `CachingResourceLoader` is exempt: its request
    /// tasks are cancelled through `activeTasks`, and the task's own `catch` calls
    /// into the loader path that ends the request.
    func stream(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> (response: HTTPURLResponse, chunks: AsyncThrowingStream<Data, Error>) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        // `onTermination` is settable only on the `Continuation` inside the builder
        // closure — there is no such property on a constructed stream, and no
        // `CancellationHandler` initializer. The builder runs synchronously inside
        // the initializer, so the handler is installed before `resume()`, which is
        // the ordering that matters. The box exists because the handler must be
        // created before the task it cancels can be named: the task is handed over
        // on the next line, still strictly before `resume()`. A handler firing
        // against an empty box is a harmless no-op, since a suspended task cannot be
        // cancelled into a terminal state anyway.
        let box = SendableBox<URLSessionTask?>(nil)

        let dataStream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.onTermination = { @Sendable _ in
                // Lock-guarded read; `URLSessionTask.cancel()` is thread-safe.
                box.current?.cancel()
            }
            self.dataContinuation = continuation
        }
        box.set(task)
        setUpstreamTask(task)

        do {
            let response: HTTPURLResponse = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.responseContinuation = continuation
                    task.resume()
                }
            } onCancel: {
                task.cancel()
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

    /// Cancel the in-flight request from outside the consumer's own task.
    ///
    /// `AsyncThrowingStream.onTermination` fires when the *stream object* is
    /// dropped, which is not how a relay notices a dead downstream: `AuthProxy`'s
    /// forwarding loop sees a failed `NWConnection.send` and stops iterating while
    /// still holding the stream, so the upstream task keeps running with
    /// `timeoutIntervalForResource = 0`. Without this the request streams a whole
    /// video to nobody, and the delegate-based session is never invalidated.
    ///
    /// Safe to call before, during, or after `stream(...)`; idempotent.
    func cancelUpstream() {
        let task: URLSessionTask? = stateLock.withLock {
            cancelledUpstream = true
            return upstreamTask
        }
        task?.cancel()
    }

    private func setUpstreamTask(_ task: URLSessionTask) {
        let cancelNow = stateLock.withLock {
            upstreamTask = task
            return cancelledUpstream
        }
        if cancelNow { task.cancel() }
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
