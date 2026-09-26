import Foundation

/// 首页可配置的栏目（Rail）。设置页「首页栏目」决定**顺序**与**显隐**：
/// 列表里出现 = 显示，缺省 = 隐藏，位置即渲染顺序。
enum HomeSection: String, CaseIterable, Identifiable {
    case resume
    case nextUp
    case latest
    case libraries

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resume: "继续观看"
        case .nextUp: "接下来看"
        case .latest: "最近添加"
        case .libraries: "媒体库"
        }
    }
}

/// `HomeSection` 配置的持久化：逗号分隔的 rawValue 串存进 UserDefaults
/// （单一 @AppStorage 可观察，设置页改完首页即时生效）。
enum HomeSectionPreference {
    static let defaultRaw = HomeSection.allCases.map(\.rawValue).joined(separator: ",")

    /// 解码：未知值剔除、重复去重（保首次出现）；解出空串视为未配置，回默认全开。
    static func decode(_ raw: String) -> [HomeSection] {
        let parsed = raw
            .split(separator: ",")
            .compactMap { HomeSection(rawValue: String($0)) }
        var seen = Set<HomeSection>()
        let deduped = parsed.filter { seen.insert($0).inserted }
        return deduped.isEmpty ? HomeSection.allCases : deduped
    }

    /// 编码：顺序即存储顺序。
    static func encode(_ sections: [HomeSection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }
}
