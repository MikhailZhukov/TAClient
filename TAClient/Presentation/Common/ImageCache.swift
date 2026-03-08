import UIKit

actor ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var failedURLs: [URL: Date] = [:]
    private var inFlightTasks: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    private static let failureCooldown: TimeInterval = 60

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB

        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    func image(for url: URL, token: String?) async -> UIImage? {
        let key = url.absoluteString as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        if let failedAt = failedURLs[url], Date().timeIntervalSince(failedAt) < Self.failureCooldown {
            return nil
        }

        if let existing = inFlightTasks[url] {
            return await existing.value
        }

        let session = self.session
        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url)
            if let token {
                request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
            }

            guard let (data, response) = try? await session.data(for: request),
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let image = UIImage(data: data) else {
                return nil
            }

            cache.setObject(image, forKey: key, cost: data.count)
            return image
        }

        inFlightTasks[url] = task
        let result = await task.value
        inFlightTasks[url] = nil

        if result == nil {
            failedURLs[url] = Date()
        }

        return result
    }
}
