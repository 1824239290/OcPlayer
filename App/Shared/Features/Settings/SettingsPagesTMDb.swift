import AppDesignKit
import MetadataKit
import SwiftUI

/// 设置 → TMDB 元数据补全。
///
/// 设计上刻意与「维护」页的「媒体元数据缓存」分开两处：
/// - 那一行是**缓存**（服务端数据的副本，清掉只是重新拉）；
/// - 这一块是**补全**（用第三方数据增强展示，清掉会丢掉「哪条对应到哪」的判断）。
///
/// 合成一项的话，用户点「清除 TMDB 数据」时并不知道自己放弃的是后者。
struct TMDbSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var keyInput = ""
    @State private var isClearing = false
    @State private var cleared = false
    @State private var confirmClear = false

    private var tmdb: TMDbCoordinator { app.tmdb }

    var body: some View {
        // 2026-10-22（B 方案）：设置页整体脱离 `Form`，改成 `ScrollView` + 玻璃卡片流
        // ——与 MoviePilot 下载页同一套承载；一段 = 一张 `SettingsGlassSection`。
        SettingsGlassPage {
            SettingsGlassSection("API Key") {
                if tmdb.isConfigured {
                    KeyValueRow(label: "当前 Key", value: tmdb.apiKeyDisplay)
                    // 只在已配置时出现的提示，跟着它解释的那一行（当前 Key）走。
                    SettingsNote("💡 需要同步到 iPad / iPhone？前往「设置 → 维护」导出配置，保存至 iCloud 云盘或通过隔空投送（AirDrop）即可一键恢复。")
                    SettingsGlassDivider()
                }
                // 没有「启用」开关：**留空即禁用**（与 anime-skip Client ID 一致）。
                // 一个「打开」的开关若在 key 为空时什么都不做，用户会以为坏了；
                // 而「清掉 key」本身就等于停用，不需要第二个状态位。
                // 输入框带 `textContentType` / 禁自动更正 / macOS `.roundedBorder` 这些
                // 链式修饰，`SettingsTextRow` 包不住 → 用 `SettingsFieldRow` 把行形态
                // 交给原语、控件自己原样传进来。
                SettingsFieldRow("API Key") {
                    SecureField(
                        "TMDB API Key 或 Read Access Token",
                        text: $keyInput,
                        prompt: Text(tmdb.isConfigured ? "输入新 Key 以替换" : "粘贴 v3 API Key 或 v4 Read Access Token")
                    )
                    .textContentType(.none)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .labelsHidden()
                }
                SettingsGlassDivider()
                SettingsActionRow(tmdb.isConfigured ? "替换" : "保存") {
                    tmdb.setAPIKey(keyInput)
                    keyInput = ""
                    cleared = false
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !tmdb.isConfigured {
                    SettingsNote("填入后启用 TMDB 补全：用第三方元数据补充详情页的简介、评分、演员与海报。"
                         + "留空 = 关闭，不请求、不影响任何现有功能。")
                }
            } footer: {
                // 去哪儿申请 Key、能不能直连，都是整段的说明而不是某个控件的注解 → 段脚，
                // 两句相加成一个 Text。
                Text("在 themoviedb.org 的账户设置里生成（免费）。v3 API Key 与 v4 Read Access Token 都支持，粘贴哪个都行。"
                     + "需要能直连 api.themoviedb.org，图片走 image.tmdb.org（国内网络通常需要代理）。")
            }

            // 刻意**放在 `isConfigured` 闸门之外**：这一项的兜底来源是 Bangumi 章节，
            // 没配 TMDB key 但关联了 Bangumi 的用户同样会看到占位卡，也该找得到这个开关。
            SettingsGlassSection("剧集占位") {
                Toggle("显示未入库剧集占位", isOn: Binding(
                    get: { tmdb.showPlaceholders },
                    set: { tmdb.setShowPlaceholders($0) }))
                .neutralSwitch()
                SettingsNote(tmdb.showPlaceholders
                     ? "剧集详情页的选集条会把库里还没有的集画成占位卡（标「未播出」或「未入库」）。"
                     + "数据优先用 TMDB 的季信息；没有 TMDB 数据时用已关联的 Bangumi 章节。"
                     : "选集条只显示库里已有的集。")
            } footer: {
                // 「不可播放、不进已看记录」是整段功能的边界（与开关状态无关）；
                // 上面那句才是开关自己的注解。
                Text("占位卡不可播放，也不会写进已看记录与缓存；关掉只影响占位，不影响补全本身。")
            }

            if tmdb.isConfigured {
                SettingsGlassSection("补全选项") {
                    SettingsPickerRow("语言", selection: Binding(
                        get: { tmdb.language },
                        set: { tmdb.setLanguage($0) })) {
                        ForEach(TMDbLanguageOption.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    SettingsNote("标题与简介按此语言取；该语言缺翻译的字段自动回退到英文。")

                    SettingsGlassDivider()

                    Toggle("文本以 TMDB 优先", isOn: Binding(
                        get: { tmdb.preferText },
                        set: { tmdb.setPreferText($0) }))
                    .neutralSwitch()
                    SettingsNote(tmdb.preferText
                         ? "标题/简介/类型用 TMDB 的替换服务端的。"
                         : "只补服务端缺的字段，已有的不动。")

                    SettingsGlassDivider()

                    Toggle("用 TMDB 图片替换已有的图", isOn: Binding(
                        get: { tmdb.replaceImages },
                        set: { tmdb.setReplaceImages($0) }))
                    .neutralSwitch()
                    SettingsNote(tmdb.replaceImages
                         ? "海报/背景/分集剧照优先用 TMDB 的（服务端已有的图会被顶掉）。"
                         : "只补服务端没有图的条目；已精修过的海报不会被覆盖。")
                }

                SettingsGlassSection("批量补全") {
                    // 嵌套的独立 View：多根自动平铺成多行（进度 / 取消按钮 / 错误），
                    // 内部结构不动。
                    batchSection

                    // 坏 key / 网络不通原先**完全静默**：用户填了 key 却什么都没发生，
                    // 只会以为功能坏了。这里把最近一次失败摆出来。
                    if let failure = tmdb.lastError {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .settingsCardCompact()
                    }
                } footer: {
                    // 这段说的是整个批量过程（含中途取消后接着做），不只解释那颗按钮 → 段脚；
                    // 放段脚也让它补全进行中同样可见。
                    Text("逐条匹配并拉取简介、评分、演员与图片；剧集连同各季一起补（分集标题与剧照需要季数据）。中途取消或退出后再点一次会接着做——已经补好的不会重复请求。")
                }

                SettingsGlassSection("数据") {
                    // 脱离 `Form` 后 `LabeledContent` 会左贴紧凑排，用 `KeyValueRow` 保住
                    // 「标签左 / 值右」的读法。
                    KeyValueRow(label: "已补全条目", value: "\(tmdb.linkedCount)")

                    SettingsGlassDivider()

                    // **例外（保留原样）**：按钮旁边还挂着「已清除」说明文字，不是单个
                    // `Button` 行，原样放进卡内（两者共享一行）。
                    HStack {
                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            Label(cleared ? "已清除" : "清除 TMDB 补全数据", systemImage: "trash")
                        }
                        .disabled(isClearing)
                        if cleared {
                            Text("对应关系与已下载的 TMDB 数据已删除")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } footer: {
                    // 缓存上限与署名要求都是整段（不是某一行）的说明 → 一起进段脚。
                    // TMDB 的署名要求。完整条款在开源许可证页的「社区数据与服务」分组。
                    Text("缓存上限 \(tmdb.cacheLifetimeDescription)（TMDB 条款要求不超过 \(tmdb.maxCacheDays) 天）。"
                         + "本产品使用 TMDB API，但未获得 TMDB 认可或认证。")
                }
            }
        }
        // 「已补全条目」与错误提示进页面时取一次——原先没有任何地方调它，
        // 于是那一行**恒显示 0**（看着像功能没生效）。
        .onAppear {
            Task {
                await app.refreshTMDbLinkCount()
                await tmdb.refreshLastFailure()
            }
        }
        .confirmationDialog(
            "清除 TMDB 补全数据？",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) { clear() }
        } message: {
            Text("对应关系与已下载的 TMDB 数据会一起删除；想恢复只能重新匹配补全。")
        }
    }

    private func clear() {
        isClearing = true
        Task {
            await tmdb.clear(tenant: app.currentTenant)
            cleared = true
            isClearing = false
        }
    }

    /// 库级批量补全：一次把整库的电影/剧（连同各季）补齐，不用一个个点开详情页。
    ///
    /// 四类计数分开显示（新补 / 跳过 / 匹配不上 / 失败）：混成一个「成功 N 条」的话，
    /// 用户不知道剩下那些该怎么办——「匹配不上」要他去手动匹配，「失败」要去看网络。
    @ViewBuilder
    private var batchSection: some View {
        if tmdb.isBatching {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: tmdb.batchProgress?.fraction ?? 0) {
                    Text(batchStatusText)
                        .font(.caption)
                }
                if let progress = tmdb.batchProgress {
                    Text("新补 \(progress.enriched) · 跳过 \(progress.skipped)"
                         + " · 匹配不上 \(progress.unmatched) · 失败 \(progress.failed)"
                         + (progress.seasons > 0 ? " · 剧集季 \(progress.seasons)" : ""))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button("取消补全", role: .cancel) { tmdb.cancelBatch() }
            }
        } else {
            HStack {
                Button {
                    app.enrichTMDbLibrary()
                } label: {
                    Label("补全整个媒体库", systemImage: "wand.and.stars")
                }
                .disabled(!tmdb.isReady)
                if let result = tmdb.lastBatchResult {
                    Text(batchSummary(result))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        if let error = tmdb.batchError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .settingsCardCompact()
        }
    }

    private var batchStatusText: String {
        guard let progress = tmdb.batchProgress else { return "正在准备…" }
        let head = "正在补全 \(progress.completed)/\(progress.total)"
        guard let title = progress.currentTitle, !title.isEmpty else { return head }
        return "\(head)：\(title)"
    }

    private func batchSummary(_ result: TMDbBatchResult) -> String {
        if result.wasCancelled {
            return "已取消（处理了 \(result.processed)/\(result.total) 条）"
        }
        return "上次：新补 \(result.enriched) · 跳过 \(result.skipped)"
            + " · 匹配不上 \(result.unmatched) · 失败 \(result.failed)"
    }
}
