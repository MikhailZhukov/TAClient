import Testing
@testable import TAClient

struct AppErrorTests {

    @Test func network_returnsLocalizedString() {
        let error = AppError.network(underlying: nil)
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
    }

    @Test func unauthorized_returnsLocalizedString() {
        let error = AppError.unauthorized
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
    }

    @Test func serverError_withMessage_returnsMessage() {
        let error = AppError.serverError(statusCode: 500, message: "oops")
        #expect(error.errorDescription == "oops")
    }

    @Test func serverError_nilMessage_returnsGeneric() {
        let error = AppError.serverError(statusCode: 500, message: nil)
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
    }

    @Test func decoding_returnsGeneric() {
        let error = AppError.decoding(underlying: nil)
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
    }

    @Test func invalidURL_returnsGeneric() {
        let error = AppError.invalidURL
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
    }

    @Test func unknown_returnsCustomMessage() {
        let error = AppError.unknown(message: "custom error")
        #expect(error.errorDescription == "custom error")
    }
}
