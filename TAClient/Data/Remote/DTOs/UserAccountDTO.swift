import Foundation

struct UserAccountDTO: Decodable {
    let id: Int?
    let name: String?
    let isSuperuser: Bool?
    let isStaff: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case isSuperuser = "is_superuser"
        case isStaff = "is_staff"
    }
}
