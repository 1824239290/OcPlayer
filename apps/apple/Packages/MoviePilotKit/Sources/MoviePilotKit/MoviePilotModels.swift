import Foundation

/// MoviePilot 当前用户（`GET /api/v1/user/current`）。
/// 宽容解析：只取 UI 需要的字段，实例加字段不影响客户端。
public struct MPUser: Decodable, Sendable, Equatable {
    public let id: Int?
    public let name: String
    public let email: String?
    public let avatar: String?
    public let isSuperuser: Bool?
    public let isActive: Bool?

    public init(
        id: Int? = nil, name: String, email: String? = nil, avatar: String? = nil,
        isSuperuser: Bool? = nil, isActive: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.avatar = avatar
        self.isSuperuser = isSuperuser
        self.isActive = isActive
    }
}

/// `POST /api/v1/login/access-token` 的响应（OAuth2 密码模式）。
struct MPTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
    }
}
