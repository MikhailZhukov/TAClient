import Foundation

extension Notification.Name {
    /// Posted from the Data layer when an HTTP 401/403 response is encountered
    /// on a request that bypasses the main `APIClient` pipeline (preloader,
    /// `CachingResourceLoader`). `AppRouter` subscribes to this and drops the
    /// user back to the login screen via its existing `handleUnauthorized()`
    /// flow — keeping clean-architecture boundaries intact (no router reference
    /// in the Data layer).
    nonisolated static let taAuthUnauthorized = Notification.Name("ru.mzhukov.TAClient.auth.unauthorized")
}
