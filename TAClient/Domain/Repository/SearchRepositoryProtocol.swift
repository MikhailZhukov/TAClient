import Foundation

struct SearchResult {
    let videos: [Video]
    let channels: [Channel]
}

protocol SearchRepositoryProtocol {
    func search(query: String, page: Int) async throws -> SearchResult
}
