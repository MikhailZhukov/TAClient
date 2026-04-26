import Foundation
import Network
import OSLog

actor AuthProxy {
    private static let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "AuthProxy")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private let token: String
    private let serverBaseURL: URL

    var localPort: UInt16 { port }

    init(token: String, serverBaseURL: URL) {
        self.token = token
        self.serverBaseURL = serverBaseURL
    }

    func start() async throws {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params, on: .any)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                guard let data, error == nil else {
                    connection.cancel()
                    return
                }
                Task { [weak self] in
                    guard let self else { connection.cancel(); return }
                    await self.processHTTPRequest(data, connection: connection)
                }
            }
        }

        let assignedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        guard assignedPort > 0 else {
            throw AppError.unknown(message: "AuthProxy failed to bind")
        }

        // Monitor listener state after start
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                Self.logger.error("Listener failed: \(error.localizedDescription)")
                Task { await self?.restartListener() }
            case .cancelled:
                Self.logger.info("Listener cancelled")
            default:
                break
            }
        }

        self.listener = listener
        self.port = assignedPort
    }

    private func restartListener() {
        guard listener != nil else { return }
        Self.logger.warning("Attempting restart...")
        listener?.cancel()
        listener = nil
        Task {
            try? await start()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    func proxyURL(for originalURL: URL) -> URL? {
        guard port > 0 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = originalURL.path
        return components.url
    }

    // MARK: - Request processing

    private func processHTTPRequest(_ data: Data, connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Extract Range header
        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Build upstream URL
        let baseStr = serverBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let upstreamURL: URL
        if path.hasPrefix("/") {
            guard let url = URL(string: baseStr + path) else {
                connection.cancel()
                return
            }
            upstreamURL = url
        } else {
            guard let url = URL(string: path) else {
                connection.cancel()
                return
            }
            upstreamURL = url
        }

        var request = URLRequest(url: upstreamURL)
        request.httpMethod = method
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        if let rangeHeader {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }

        // Stream response to avoid loading entire video into memory
        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 0
            config.timeoutIntervalForResource = 0

            let streamer = StreamingSession()
            let (httpResponse, chunks) = try await streamer.stream(request: request, configuration: config)

            // Build response header
            var header = "HTTP/1.1 \(httpResponse.statusCode)"
            if let reason = Self.statusReason(httpResponse.statusCode) {
                header += " \(reason)"
            }
            header += "\r\n"

            let passHeaders = ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"]
            for key in passHeaders {
                if let value = httpResponse.value(forHTTPHeaderField: key) {
                    header += "\(key): \(value)\r\n"
                }
            }
            header += "Connection: close\r\n\r\n"

            // Send header
            let headerSent = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                connection.send(content: header.data(using: .utf8), completion: .contentProcessed { error in
                    cont.resume(returning: error == nil)
                })
            }
            guard headerSent else {
                connection.cancel()
                return
            }

            // Stream body — chunks arrive as Data from delegate, forward directly
            let sendChunkSize = 256 * 1024
            var buffer = Data()
            for try await chunk in chunks {
                buffer.append(chunk)
                while buffer.count >= sendChunkSize {
                    let sendData = Data(buffer.prefix(sendChunkSize))
                    buffer = Data(buffer.dropFirst(sendChunkSize))
                    let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                        connection.send(content: sendData, completion: .contentProcessed { error in
                            cont.resume(returning: error == nil)
                        })
                    }
                    if !ok {
                        connection.cancel()
                        return
                    }
                }
            }

            // Flush remaining
            if !buffer.isEmpty {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    connection.send(content: buffer, completion: .contentProcessed { _ in
                        cont.resume()
                    })
                }
            }

            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            Self.logger.error("Stream error: \(error.localizedDescription)")
            Self.sendError(connection, code: 502)
        }
    }

    private nonisolated static func sendError(_ connection: NWConnection, code: Int) {
        let response = "HTTP/1.1 \(code) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func statusReason(_ code: Int) -> String? {
        switch code {
        case 200: "OK"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        default: nil
        }
    }
}
