import Foundation

/// Streams URL response data as chunks via URLSessionDataDelegate.
/// More efficient than URLSession.AsyncBytes which iterates byte-by-byte.
final class StreamingSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var dataContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>?
    private var session: URLSession?

    func stream(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> (response: HTTPURLResponse, chunks: AsyncThrowingStream<Data, Error>) {
        let dataStream = AsyncThrowingStream<Data, Error> { self.dataContinuation = $0 }

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)

        let response: HTTPURLResponse = try await withCheckedThrowingContinuation { continuation in
            self.responseContinuation = continuation
            task.resume()
        }

        dataContinuation?.onTermination = { @Sendable _ in
            task.cancel()
        }

        return (response, dataStream)
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
