import MoviePilotKit
import SwiftUI

/// MoviePilot 订阅配置弹窗：支持添加新订阅与编辑现有订阅。
/// 严格遵循 MoviePilot 规范（基础信息、季集范围、关键词过滤、分辨率质量、站点限制等）。
struct MoviePilotSubscribeSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case add(media: MPMediaInfo?)
        case edit(subscribe: MPSubscribe)
    }

    let mode: Mode
    var onSaved: (() -> Void)?

    // 基础信息
    @State private var name: String = ""
    @State private var mediaType: String = "电视剧" // "电影" or "电视剧"
    @State private var year: String = ""
    @State private var state: String = "R" // R, P, O
    @State private var tmdbIdText: String = ""
    @State private var doubanId: String = ""
    @State private var bangumiIdText: String = ""
    @State private var posterURLString: String = ""
    @State private var overview: String = ""

    // 剧集设置
    @State private var season: Int = 1
    @State private var startEpisode: Int = 1
    @State private var totalEpisode: Int = 0
    @State private var lackEpisode: Int = 0

    // 过滤与偏好
    @State private var keyword: String = ""
    @State private var include: String = ""
    @State private var exclude: String = ""
    @State private var quality: String = ""
    @State private var savePath: String = ""
    @State private var bestVersion: Bool = false
    @State private var selectedSiteIDs: Set<Int> = []

    // 站点列表与加载
    @State private var availableSites: [MPSite] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    // 预设质量标签
    private static let qualityPresets = ["", "2160p", "1080p", "4K", "WEB-DL", "BluRay", "Dolby Vision", "HDR"]

    init(mode: Mode, onSaved: (() -> Void)? = nil) {
        self.mode = mode
        self.onSaved = onSaved
    }

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isTV: Bool {
        mediaType == "电视剧" || mediaType == "动漫" || mediaType == "动画" || mediaType.uppercased() == "TV"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                // 媒体头部预览
                headerSection

                // 基础信息
                basicInfoSection

                // 剧集与季集设置（仅电视剧）
                if isTV {
                    episodeSection
                }

                // 过滤规则与站点
                filterRulesSection

                // 高级选项
                advancedSection
            }
            .formStyle(.grouped)
            .navigationTitle(isEditMode ? "编辑订阅" : "添加订阅")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditMode ? "保存" : "添加") {
                        Task { await save() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .task {
                setupInitialValues()
                await loadSites()
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 640)
        #endif
    }

    // MARK: - 头部预览

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                if let posterURL = URL(string: posterURLString), !posterURLString.isEmpty {
                    RemoteImage(url: posterURL, authHeader: nil, maxPixelSize: 300)
                        .frame(width: 56, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Metrics.placeholderFill)
                        .frame(width: 56, height: 84)
                        .overlay {
                            Image(systemName: isTV ? "tv" : "film")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(name.isEmpty ? (isEditMode ? "未命名条目" : "新订阅条目") : name)
                        .font(.headline)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(mediaType)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4))

                        if !year.isEmpty {
                            Text(year)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if isTV, season > 0 {
                            Text("第 \(season) 季")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !overview.isEmpty {
                        Text(overview)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 基本信息

    private var basicInfoSection: some View {
        Section("基本信息") {
            TextField("媒体名称（必填）", text: $name)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            Picker("媒体类型", selection: $mediaType) {
                Text("电视剧").tag("电视剧")
                Text("电影").tag("电影")
            }
            .pickerStyle(.segmented)

            HStack {
                Text("年份")
                Spacer()
                TextField("如 2024", text: $year)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }

            Picker("订阅状态", selection: $state) {
                Text("追更中 (运行)").tag("R")
                Text("暂停订阅").tag("P")
                Text("已完成").tag("O")
            }

            HStack {
                Text("TMDB ID")
                Spacer()
                TextField("可选数字 ID", text: $tmdbIdText)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }

            HStack {
                Text("豆瓣 ID")
                Spacer()
                TextField("可选", text: $doubanId)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("Bangumi ID")
                Spacer()
                TextField("可选", text: $bangumiIdText)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
        }
    }

    // MARK: - 剧集设置

    private var episodeSection: some View {
        Section("剧集设置") {
            Stepper("季数：第 \(season) 季", value: $season, in: 1...99)

            Stepper("起始集数：第 \(startEpisode) 集", value: $startEpisode, in: 0...999)

            HStack {
                Text("总集数 (0为自动识别)")
                Spacer()
                TextField("0", value: $totalEpisode, format: .number)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }

            HStack {
                Text("缺失集数")
                Spacer()
                TextField("0", value: $lackEpisode, format: .number)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
        }
    }

    // MARK: - 过滤规则

    private var filterRulesSection: some View {
        Section("过滤与偏好规则") {
            VStack(alignment: .leading, spacing: 4) {
                Text("搜索关键词")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("留空则按名称搜索", text: $keyword)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("包含关键词 (逗号分隔)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("如 1080p, HEVC, 杜比", text: $include)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("排除关键词 (逗号分隔)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("如 CAM, TC, 抢先, 国语", text: $exclude)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            Picker("分辨率 / 质量偏好", selection: $quality) {
                Text("全部 / 默认").tag("")
                ForEach(Self.qualityPresets.filter { !$0.isEmpty }, id: \.self) { q in
                    Text(q).tag(q)
                }
            }

            if !availableSites.isEmpty {
                NavigationLink {
                    siteSelectionView
                } label: {
                    HStack {
                        Text("限定搜索站点")
                        Spacer()
                        Text(selectedSiteIDs.isEmpty ? "全部站点" : "已选 \(selectedSiteIDs.count) 个")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 高级选项

    private var advancedSection: some View {
        Section("高级设置") {
            Toggle("最佳版本洗版 (自动下载更高质量版本)", isOn: $bestVersion)

            VStack(alignment: .leading, spacing: 4) {
                Text("自定义存储路径")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("留空使用 MoviePilot 默认目录", text: $savePath)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("海报链接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("http(s):// 或 /path", text: $posterURLString)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
        }
    }

    // MARK: - 站点多选子页

    private var siteSelectionView: some View {
        List {
            Section {
                Button("选择全部站点") {
                    selectedSiteIDs = []
                }
            } footer: {
                Text("未选择特定站点时，MoviePilot 会在全部已启用的站点中搜寻。")
            }

            Section("选择站点") {
                ForEach(availableSites) { site in
                    Button {
                        if selectedSiteIDs.contains(site.id) {
                            selectedSiteIDs.remove(site.id)
                        } else {
                            selectedSiteIDs.insert(site.id)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.name ?? "站点 \(site.id)")
                                if let domain = site.domain {
                                    Text(domain).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selectedSiteIDs.contains(site.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("限定站点")
    }

    // MARK: - 初始化与保存

    private func setupInitialValues() {
        switch mode {
        case .add(let media):
            guard let media else { return }
            name = media.title ?? ""
            mediaType = media.type ?? "电视剧"
            year = media.year ?? ""
            season = media.season ?? 1
            overview = media.overview ?? ""
            if let tmdb = media.tmdbId { tmdbIdText = String(tmdb) }
            if let douban = media.doubanId { doubanId = douban }
            if let bgm = media.bangumiId { bangumiIdText = String(bgm) }
            posterURLString = media.posterURL?.absoluteString ?? ""
            state = "R"

        case .edit(let subscribe):
            name = subscribe.name ?? ""
            mediaType = subscribe.isMovie ? "电影" : "电视剧"
            year = subscribe.year ?? ""
            season = subscribe.season ?? 1
            startEpisode = subscribe.startEpisode ?? 1
            totalEpisode = subscribe.totalEpisode ?? 0
            lackEpisode = subscribe.lackEpisode ?? 0
            state = subscribe.state ?? "R"
            overview = subscribe.description ?? ""
            keyword = subscribe.keyword ?? ""
            include = subscribe.include ?? ""
            exclude = subscribe.exclude ?? ""
            quality = subscribe.quality ?? ""
            savePath = subscribe.savePath ?? ""
            bestVersion = subscribe.bestVersion
            selectedSiteIDs = Set(subscribe.sites)

            if let tmdb = subscribe.tmdbId { tmdbIdText = String(tmdb) }
            if let douban = subscribe.doubanId { doubanId = douban }
            if let bgm = subscribe.bangumiId { bangumiIdText = String(bgm) }
            posterURLString = subscribe.posterURL?.absoluteString ?? (subscribe.poster ?? "")
        }
    }

    private func loadSites() async {
        do {
            availableSites = try await MoviePilotAPIClient.shared.sites()
        } catch {
            // 忽略站点加载错误
        }
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !isSaving else { return }

        isSaving = true
        errorMessage = nil

        var dict: [String: JSONValue] = [:]

        // 如果是编辑模式，保留原字典
        if case .edit(let sub) = mode {
            dict = sub.raw
            if let subId = sub.subscribeId {
                dict["id"] = .number(Double(subId))
            }
        }

        dict["name"] = .string(trimmedName)
        dict["title"] = .string(trimmedName)
        dict["type"] = .string(mediaType)
        dict["year"] = .string(year)
        dict["state"] = .string(state)

        if let tmdb = Int(tmdbIdText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            dict["tmdbid"] = .number(Double(tmdb))
            dict["tmdb_id"] = .number(Double(tmdb))
        }
        if !doubanId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["doubanid"] = .string(doubanId.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let bgm = Int(bangumiIdText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            dict["bangumiid"] = .number(Double(bgm))
            dict["bangumi_id"] = .number(Double(bgm))
        }

        if !posterURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["poster"] = .string(posterURLString.trimmingCharacters(in: .whitespacesAndNewlines))
            dict["poster_path"] = .string(posterURLString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["overview"] = .string(overview)
            dict["description"] = .string(overview)
        }

        if isTV {
            dict["season"] = .number(Double(season))
            dict["start_episode"] = .number(Double(startEpisode))
            dict["total_episode"] = .number(Double(totalEpisode))
            dict["lack_episode"] = .number(Double(lackEpisode))
        }

        if !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["keyword"] = .string(keyword.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            dict.removeValue(forKey: "keyword")
        }

        if !include.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["include"] = .string(include.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            dict.removeValue(forKey: "include")
        }

        if !exclude.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["exclude"] = .string(exclude.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            dict.removeValue(forKey: "exclude")
        }

        if !quality.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["quality"] = .string(quality.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            dict.removeValue(forKey: "quality")
        }

        if !savePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["save_path"] = .string(savePath.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        dict["best_version"] = .bool(bestVersion)

        if !selectedSiteIDs.isEmpty {
            dict["sites"] = .array(selectedSiteIDs.sorted().map { JSONValue.number(Double($0)) })
        } else {
            dict.removeValue(forKey: "sites")
        }

        do {
            if isEditMode {
                try await MoviePilotAPIClient.shared.updateSubscribe(raw: dict)
            } else {
                let sub = MPSubscribe(raw: dict)
                try await MoviePilotAPIClient.shared.addSubscribe(subscribe: sub)
            }
            onSaved?()
            dismiss()
        } catch {
            errorMessage = (error as? MoviePilotError)?.userMessage ?? "\(error)"
            isSaving = false
        }
    }
}
