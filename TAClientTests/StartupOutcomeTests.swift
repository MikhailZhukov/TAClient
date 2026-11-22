import Testing
import Foundation
@testable import TAClient

struct StartupOutcomeTests {

    @Test func classify_unauthorized_returnsUnauthorized() {
        let outcome = StartupOutcome.classify(AppError.unauthorized)
        #expect(outcome == .unauthorized)
    }

    @Test func classify_networkError_returnsUnavailable() {
        let error = AppError.network(underlying: URLError(.notConnectedToInternet))
        #expect(StartupOutcome.classify(error) == .unavailable)
    }

    @Test func classify_serverError500_returnsUnavailable() {
        let error = AppError.serverError(statusCode: 500, message: nil)
        #expect(StartupOutcome.classify(error) == .unavailable)
    }

    @Test func classify_serverError429_returnsUnavailable() {
        let error = AppError.serverError(statusCode: 429, message: nil)
        #expect(StartupOutcome.classify(error) == .unavailable)
    }

    @Test func classify_decoding_returnsUnavailable() {
        let error = AppError.decoding(underlying: nil)
        #expect(StartupOutcome.classify(error) == .unavailable)
    }

    @Test func classify_invalidURL_returnsUnavailable() {
        #expect(StartupOutcome.classify(AppError.invalidURL) == .unavailable)
    }

    @Test func classify_unknown_returnsUnavailable() {
        let error = AppError.unknown(message: "x")
        #expect(StartupOutcome.classify(error) == .unavailable)
    }

    @Test func classify_rawURLError_returnsUnavailable() {
        #expect(StartupOutcome.classify(URLError(.cannotConnectToHost)) == .unavailable)
    }
}
