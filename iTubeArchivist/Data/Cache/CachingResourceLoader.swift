import Foundation
import AVFoundation
import OSLog

private nonisolated let logger = Logger(subsystem: "ru.mzhukov.iTubeArchivist", category: "CachingResourceLoader")

private let cachingScheme = "itacache"
private let maxCacheResponseSize = 16 * 1024 * 1024  // 16 MB max per cache read
private let maxNetworkResponseSize = 16 * 1024 * 1024 // 16 MB max per network fetch (data(for:) buffers entire response)

final class CachingResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let videoId: String
    let originalURL: URL
    let token: String
    let loaderQueue = DispatchQueue(label: "ru.mzhukov.iTubeArchivist.resourceLoader", qos: .userInitiated)

    private let networkSession: URLSession

    init(videoId: String, originalURL: URL, token: String) {
        self.videoId = videoId
        self.originalURL = originalURL
        self.token = token

        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        self.networkSession = URLSession(configuration: config)

        super.init()
    }

    // MARK: - URL Conversion

    static func cachingURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = cachingScheme
        return components.url
    }

    static func originalURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == cachingScheme else { return nil }
        components.scheme = "https"
        return components.url
    }

    // MARK: - AVAssetResourceLoaderDelegate

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        Task { await handleLoadingRequest(loadingRequest) }
        return true
    }

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // No-op: requests are short-lived and will check cancellation
    }

    // MARK: - Request Handling

    private func handleLoadingRequest(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        guard !loadingRequest.isCancelled else { return }

        if let contentRequest = loadingRequest.contentInformationRequest {
            let ok = await fillContentInfo(contentRequest)
            if !ok {
                loadingRequest.finishLoading(with: URLError(.cannotOpenFile))
                return
            }
        }

        guard !loadingRequest.isCancelled else { return }

        if let dataRequest = loadingRequest.dataRequest {
            let ok = await fillDataRequest(dataRequest)
            if !ok {
                loadingRequest.finishLoading(with: URLError(.cannotOpenFile))
                return
            }
        }

        if !loadingRequest.isCancelled {
            loadingRequest.finishLoading()
        }
    }

    private func fillContentInfo(_ contentRequest: AVAssetResourceLoadingContentInformationRequest) async -> Bool {
        if let status = await VideoCache.shared.cacheStatus(videoId: videoId) {
            contentRequest.contentLength = status.totalSize
            contentRequest.contentType = contentTypeUTI(from: status.contentType)
            contentRequest.isByteRangeAccessSupported = true
            return true
        }

        var request = URLRequest(url: originalURL)
        request.httpMethod = "HEAD"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await networkSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                contentRequest.contentLength = http.expectedContentLength
                let mimeType = http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"
                contentRequest.contentType = contentTypeUTI(from: mimeType)
                contentRequest.isByteRangeAccessSupported = true
                return true
            }
        } catch {
            logger.error("HEAD request failed: \(error.localizedDescription)")
        }
        return false
    }

    private func fillDataRequest(_ dataRequest: AVAssetResourceLoadingDataRequest) async -> Bool {
        let offset = dataRequest.currentOffset

        // Try reading from cache (larger chunks — RAM is fast)
        let cacheLength = min(dataRequest.requestedLength, maxCacheResponseSize)
        if let cachedData = await VideoCache.shared.readData(
            videoId: videoId,
            offset: offset,
            length: cacheLength
        ) {
            dataRequest.respond(with: cachedData)
            return true
        }

        // Fallback: fetch from network (capped — data(for:) buffers entire response in memory)
        let networkLength = min(dataRequest.requestedLength, maxNetworkResponseSize)
        return await fetchFromNetwork(dataRequest: dataRequest, offset: offset, length: networkLength)
    }

    private func fetchFromNetwork(
        dataRequest: AVAssetResourceLoadingDataRequest,
        offset: Int64,
        length: Int
    ) async -> Bool {
        var request = URLRequest(url: originalURL)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let endByte = offset + Int64(length) - 1
        request.setValue("bytes=\(offset)-\(endByte)", forHTTPHeaderField: "Range")

        do {
            let (data, response) = try await networkSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) || http.statusCode == 206 else {
                logger.error("Network fetch failed: status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return false
            }
            dataRequest.respond(with: data)
            return true
        } catch {
            logger.error("Network fetch error at offset \(offset): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Helpers

    private func contentTypeUTI(from mimeType: String) -> String {
        switch mimeType.lowercased() {
        case let t where t.contains("mp4"): return "public.mpeg-4"
        case let t where t.contains("webm"): return "org.webmproject.webm"
        case let t where t.contains("matroska"): return "org.matroska.mkv"
        case let t where t.contains("mkv"): return "org.matroska.mkv"
        default: return "public.movie"
        }
    }
}
