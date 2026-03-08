import Foundation

struct LoginRequestDTO: Encodable {
    let username: String
    let password: String
}

struct TokenResponseDTO: Decodable {
    let token: String
}
