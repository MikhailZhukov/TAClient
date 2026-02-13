import UIKit

actor ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlightTasks: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
    }

    func image(for url: URL, token: String?) async -> UIImage? {
        let key = url.absoluteString as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        if let existing = inFlightTasks[url] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url)
            if let token {
                request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
            }

            guard let (data, response) = try? await URLSession.shared.data(for: request),
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
        return result
    }
}
