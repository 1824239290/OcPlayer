import Foundation

/// 墙上的一张海报。
///
/// 两种来源合成同一个值类型：**真实海报**（`imageFile` 非空，字节来自本机图片缓存）
/// 和**程序化封面**（`imageFile` 为空，或那个文件解不出来时兜底）。墙只认这个类型，
/// 不关心图是从哪来的——所以「登录页还没有会话」这件事不需要墙知道。
public struct LoginWallPoster: Identifiable, Hashable, Sendable {
    public let id: String
    /// 真实海报没有标题：缓存文件名是缓存键的哈希，反推不回条目名。
    /// 墙是装饰，不显示标题，只把它留给无障碍标签。
    public let title: String
    public let year: Int?
    /// 本机图片缓存里的那个文件。`nil` = 这张只有程序化封面。
    public let imageFile: URL?
    /// 程序化封面参数，装配时一次算好。
    public let art: LoginWallArt

    public init(
        id: String,
        title: String = "",
        year: Int? = nil,
        imageFile: URL? = nil,
        art: LoginWallArt
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.imageFile = imageFile
        self.art = art
    }

    /// 无障碍标签。整面墙在无障碍树里是**隐藏**的（纯装饰），这个值只用于
    /// 调试与将来可能的「读出墙上是什么」。
    public var accessibilityLabel: String? {
        guard !title.isEmpty else { return nil }
        var parts = [title]
        if let year { parts.append(String(year)) }
        return parts.joined(separator: "，")
    }
}
