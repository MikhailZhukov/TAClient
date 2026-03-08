import Foundation
@testable import TAClient

// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // URLProtocol strips httpBody; read from httpBodyStream instead
        if let stream = request.httpBodyStream {
            Self.lastRequestBody = Self.readStream(stream)
        } else {
            Self.lastRequestBody = request.httpBody
        }

        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func readBodyStream(_ stream: InputStream) -> Data {
        readStream(stream)
    }

    private static func readStream(_ stream: InputStream) -> Data {
        stream.open()
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: 4096)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            }
        }
        stream.close()
        return data
    }
}

// MARK: - Test Helpers

enum MockResponse {
    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    static func makeAuthState(token: String? = "test-token", serverURL: String? = "https://ta.example.com") -> AuthState {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        if let token, let serverURL {
            authState.setCredentials(token: token, serverURL: serverURL)
        }
        return authState
    }

    static func makeAPIClient(authState: AuthState? = nil) -> (APIClient, AuthState) {
        let state = authState ?? makeAuthState()
        let config = makeConfiguration()
        let loginConfig = makeConfiguration()
        let client = APIClient(authState: state, configuration: config, loginConfiguration: loginConfig)
        return (client, state)
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func httpResponse(url: String = "https://ta.example.com", statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    static func setUp(statusCode: Int = 200, json object: Any) {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: statusCode), self.json(object))
        }
    }

    static func setUp(statusCode: Int = 200, data: Data = Data()) {
        MockURLProtocol.requestHandler = { _ in
            (httpResponse(statusCode: statusCode), data)
        }
    }

    static func setUpError(_ error: Error) {
        MockURLProtocol.requestHandler = { _ in
            throw error
        }
    }

    static func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastRequestBody = nil
    }
}
