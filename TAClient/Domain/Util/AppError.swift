import Foundation

enum AppError: Error, LocalizedError {
    case network(underlying: Error?)
    case unauthorized
    case serverError(statusCode: Int, message: String?)
    case decoding(underlying: Error?)
    case invalidURL
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .network:
            return String(localized: "error_network")
        case .unauthorized:
            return String(localized: "error_unauthorized")
        case .serverError(_, let message):
            return message ?? String(localized: "error_generic")
        case .decoding:
            return String(localized: "error_generic")
        case .invalidURL:
            return String(localized: "error_generic")
        case .unknown(let message):
            return message
        }
    }
}
