import Foundation

struct PaginationDTO: Decodable {
    let pageSize: Int?
    let pageFrom: Int?
    let currentPage: Int?
    let lastPage: Int?
    let totalHits: Int?
    let maxHits: Bool?

    enum CodingKeys: String, CodingKey {
        case pageSize = "page_size"
        case pageFrom = "page_from"
        case currentPage = "current_page"
        case lastPage = "last_page"
        case totalHits = "total_hits"
        case maxHits = "max_hits"
    }
}

struct PingDTO: Decodable {
    let response: String?
    let user: Int?
    let version: String?
}

struct ErrorResponseDTO: Decodable {
    let detail: String?
}
