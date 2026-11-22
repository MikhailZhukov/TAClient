/// Startup error classification for `AppRouter.attemptStartup()`.
///
/// Only a proven-expired session (``AppError/unauthorized``) may wipe credentials.
/// Every other failure — transport errors, 5xx, HTML-200 from a proxy, decoding —
/// means the server is unreachable or misbehaving, which must keep the token
/// intact and surface the reconnect screen instead.
enum StartupOutcome {
    case unauthorized
    case unavailable

    static func classify(_ error: Error) -> StartupOutcome {
        if case AppError.unauthorized = error {
            return .unauthorized
        }
        return .unavailable
    }
}
