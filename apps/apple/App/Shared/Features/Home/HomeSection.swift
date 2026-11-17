import Foundation

/// 首页可配置的栏目（Rail）。顺序与显隐见 `HomeSectionLayout`：
/// **关掉只影响首页**——栏目留在设置页「首页栏目」里（位置也不变），随时可以再打开。
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

/// 首页栏目的本机布局：**全部栏目**的顺序 + 关掉了哪些。
///
/// 不变量：`order` 是 `HomeSection.allCases` 的一个排列（构造时归一化）。
/// 关掉的栏目**仍留在 `order` 里**（保住位置），只在首页渲染时被 `visible`
/// 过滤掉——「关闭」是「首页不显示」，不是「从配置里删掉」。所以关掉再打开
/// 会回到原来的位置，而不是被追加到末尾。
struct HomeSectionLayout: Equatable {
    /// 全部栏目（含已关闭的），位置即渲染顺序。
    let order: [HomeSection]
    /// 已关闭的栏目：首页不渲染，设置页保留。
    let hidden: Set<HomeSection>

    /// 归一化：去重（保首次出现）+ 缺项追加到末尾。
    ///
    /// 这里**不**把缺项标成「已关闭」——直接构造 `HomeSectionLayout(order:)` 的
    /// 语义是「没提到的照常显示」。旧格式（缺项 = 隐藏）的迁移只在
    /// `HomeSectionPreference.decode` 里做。
    init(order: [HomeSection], hidden: Set<HomeSection> = []) {
        var normalized: [HomeSection] = []
        var seen = Set<HomeSection>()
        for section in order where seen.insert(section).inserted {
            normalized.append(section)
        }
        normalized += HomeSection.allCases.filter { !seen.contains($0) }
        self.order = normalized
        self.hidden = hidden
    }

    /// 四栏全开（缺省基准）。
    static let allVisible = HomeSectionLayout(order: HomeSection.allCases)

    /// 首页要渲染的栏目，顺序即渲染顺序。
    var visible: [HomeSection] { order.filter { !hidden.contains($0) } }

    func isVisible(_ section: HomeSection) -> Bool { !hidden.contains(section) }

    /// 开 / 关一个栏目。**位置不变**：关掉再打开仍在原来的位置。
    /// （形参内部名取 `shown`：`visible` 让给上面的同名属性，避免读错。）
    func setting(_ section: HomeSection, visible shown: Bool) -> HomeSectionLayout {
        var hidden = hidden
        if shown {
            hidden.remove(section)
        } else {
            hidden.insert(section)
        }
        return HomeSectionLayout(order: order, hidden: hidden)
    }

    /// 在**全序**（含已关闭的栏目）里与邻居换位；越界原样返回。
    ///
    /// 换位不改变其余条目的相对顺序，所以移动一个已关闭的栏目**不影响**首页的
    /// 可见顺序——关掉的行照样可以先排好位置再打开。
    func moving(_ section: HomeSection, by offset: Int) -> HomeSectionLayout {
        guard let index = order.firstIndex(of: section) else { return self }
        let target = index + offset
        guard order.indices.contains(target) else { return self }
        var order = order
        order.swapAt(index, target)
        return HomeSectionLayout(order: order, hidden: hidden)
    }
}

/// `HomeSectionLayout` 的持久化：逗号分隔 token 存进 UserDefaults
/// （单一 @AppStorage 可观察，设置页改完首页即时生效）。
///
/// token = `HomeSection.rawValue`（首页显示）或 `-rawValue`（已关闭），位置即
/// 顺序；**全部栏目都列出来**（含已关闭的），所以「关掉」不会丢位置。
enum HomeSectionPreference {
    /// 缺省串：与「四栏全开」同字面（`resume,nextUp,latest,libraries`）。
    static let defaultRaw = encode(.allVisible)

    /// 解码。规则（按顺序判定）：
    ///
    /// 1. 整串为空 → **全关**。旧版本的「全关」正好编码成空串（`encode([])`），
    ///    那是空串唯一的来源，所以按用户的明确选择读。
    /// 2. 逐 token：按 `,` 拆、逐段 trim、`-` 前缀 = 已关闭；未知项丢弃；
    ///    重复项**首次出现定案**（含显隐标志）。
    /// 3. 一个已知项都没解出来（损坏串 / 手改坏）→ 回默认全开。
    /// 4. 有已知项但**缺项**：缺项视为已关闭（旧格式「没列出来 = 隐藏」的语义），
    ///    并按 `allCases` 顺序归位（插在第一个「在 `allCases` 里排在它后面」的
    ///    条目之前，没有则追加到末尾），已列项的相对顺序不动——旧数据升级后
    ///    首页渲染的栏目与顺序与升级前完全一致。
    ///
    /// ⚠️ 由第 4 条推出的一个刻意选择：**将来给 `HomeSection` 新增 case 时，
    /// 老用户那边它是关闭的**（串里没有它），需要在设置页自己打开——不让新栏目
    /// 悄悄冒出来打断用户现有的首页。
    static func decode(_ raw: String) -> HomeSectionLayout {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return HomeSectionLayout(order: HomeSection.allCases, hidden: Set(HomeSection.allCases))
        }

        var order: [HomeSection] = []
        var hidden = Set<HomeSection>()
        var seen = Set<HomeSection>()
        for token in trimmed.split(separator: ",") {
            var name = token.trimmingCharacters(in: .whitespaces)
            let isHidden = name.hasPrefix("-")
            if isHidden { name.removeFirst() }
            guard let section = HomeSection(rawValue: name), seen.insert(section).inserted else { continue }
            order.append(section)
            if isHidden { hidden.insert(section) }
        }
        guard !order.isEmpty else { return .allVisible }

        let missing = HomeSection.allCases.filter { !seen.contains($0) }
        hidden.formUnion(missing)
        return HomeSectionLayout(order: merging(missing, into: order), hidden: hidden)
    }

    /// 编码：顺序即存储顺序，已关闭的加 `-` 前缀。
    static func encode(_ layout: HomeSectionLayout) -> String {
        layout.order
            .map { layout.hidden.contains($0) ? "-\($0.rawValue)" : $0.rawValue }
            .joined(separator: ",")
    }

    /// 旧格式迁移：把缺项按 `allCases` 顺序插回已列项之间（已列项相对顺序不变）。
    private static func merging(_ missing: [HomeSection], into listed: [HomeSection]) -> [HomeSection] {
        var result = listed
        for section in missing {
            let sectionRank = rank(of: section)
            if let index = result.firstIndex(where: { rank(of: $0) > sectionRank }) {
                result.insert(section, at: index)
            } else {
                result.append(section)
            }
        }
        return result
    }

    private static func rank(of section: HomeSection) -> Int {
        HomeSection.allCases.firstIndex(of: section) ?? 0
    }
}
