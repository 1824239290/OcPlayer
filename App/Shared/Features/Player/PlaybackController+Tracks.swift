import DanmakuKit
import DiagnosticsKit
import PlaybackKit
import Foundation

extension PlaybackController {
    // MARK: - 轨道（音轨 / 字幕菜单用）

    /// 按轨道 id 取外挂字幕显示名；没有记录时回退到内核给的名字/语言。
    /// 记录由 `addExternalSubtitle` 系列在拿到轨道 id 时写入
    /// （`externalSubtitleNames`，主类存储属性）。
    func externalSubtitleDisplayName(for track: TrackInfo) -> String {
        if let name = externalSubtitleNames[track.id], !name.isEmpty {
            return name
        }
        return track.displayTitle
    }

    /// 弹幕是否已装载。当前恒走 overlay 渲染（内核轨道恒为空），所以不能只看
    /// `danmakuTracks`——HUD 的时间偏移区块显隐要一并看 overlay 的数据。
    var hasDanmakuLoaded: Bool {
        !danmakuTracks.isEmpty || danmakuOverlay.hasComments
    }

    /// Replace the current source's danmaku only while its generation token is valid.
    ///
    /// `entries` 是 overlay 路线的直接输入（`DanmakuService` 在 actor 上转好的结构体，
    /// 主线程只赋值）；`json` 只给内核轨道路线。见 `DanmakuPlaybackHosting`。
    @discardableResult
    func replaceDanmaku(
        entries: [DanmakuJSONParser.Entry],
        json: String?,
        name: String,
        offset: Duration,
        for source: PlaybackSourceGeneration
    ) throws -> Bool {
        var tracks: [DanmakuTrackInfo] = []
        do {
            let accepted = try withReadyEngine(for: source) { engine in
                // overlay 路线：数据喂 App 层渲染器，内核轨道保持为空，
                // 避免 kernel/overlay 双份弹幕。时间桥语义见 DanmakuOverlay。
                if usesOverlayDanmakuRenderer {
                    try engine.clearDanmaku()
                    danmakuOverlay.update {
                        $0.enabled = danmakuEnabled
                        $0.opacity = danmakuOpacity
                        $0.displayArea = danmakuDisplayArea
                        $0.blockTop = danmakuBlockTop
                        $0.blockBottom = danmakuBlockBottom
                        $0.blockScroll = danmakuBlockScroll
                        $0.allowStacking = danmakuAllowStacking
                        $0.offsetSeconds = danmakuGlobalOffsetSeconds
                        $0.fontSize = danmakuFontSize
                    }
                    danmakuOverlay.replace(
                        entries: entries,
                        trackOffsetSeconds: Double(offset.microseconds) / 1_000_000
                    )
                    return
                }
                // 内核路线（当前停用）：需要 Erika JSON 串。
                guard let json else { return }
                // 先应用渲染偏好再装载：偏好里的布局字段（displayArea/block 等）和
                // 全局偏移一旦变化会触发内核重排。放在 addDanmakuTrack 之前设置，
                // 让 add 那一次重排同时吸收偏好变更，避免装载后再次改配置触发第二次
                // 全量重排（NipaPlay 的做法：配置先于装载稳定，装载只触发一次）。
                do {
                    try applyDanmakuPreferences(to: engine)
                } catch {
                    playerLog.warning("弹幕偏好应用失败，继续装载 error=\(error)")
                }
                try engine.clearDanmaku()
                _ = try engine.addDanmakuTrack(json: json, name: name, offset: offset)
                tracks = try engine.danmakuTracks()
            }
            if accepted { danmakuTracks = tracks }
            return accepted
        } catch {
            refreshDanmakuTracks(for: source)
            throw error
        }
    }

    @discardableResult
    func clearDanmaku(for source: PlaybackSourceGeneration) throws -> Bool {
        danmakuOverlay.clear()
        do {
            let accepted = try withReadyEngine(for: source) { engine in
                try engine.clearDanmaku()
            }
            if accepted { danmakuTracks = [] }
            return accepted
        } catch {
            refreshDanmakuTracks(for: source)
            throw error
        }
    }

    func setDanmakuEnabled(_ enabled: Bool) {
        danmakuEnabled = enabled
        PlaybackPreferences.danmakuEnabled = enabled
        try? engine?.setDanmakuEnabled(enabled)
        if usesOverlayDanmakuRenderer { danmakuOverlay.update { $0.enabled = enabled } }
    }

    func setDanmakuOpacity(_ opacity: Double) {
        danmakuOpacity = opacity.clamped(0.25...1)
        PlaybackPreferences.danmakuOpacity = danmakuOpacity
        if usesOverlayDanmakuRenderer { danmakuOverlay.update { $0.opacity = danmakuOpacity } }
        updateDanmakuConfig { $0.opacity = Float(danmakuOpacity) }
    }

    func setDanmakuDisplayArea(_ area: Double) {
        danmakuDisplayArea = area.clamped(0.25...1)
        PlaybackPreferences.danmakuDisplayArea = danmakuDisplayArea
        if usesOverlayDanmakuRenderer { danmakuOverlay.update { $0.displayArea = danmakuDisplayArea } }
        updateDanmakuConfig { $0.displayArea = Float(danmakuDisplayArea) }
    }

    func setDanmakuBlocked(top: Bool? = nil, bottom: Bool? = nil, scroll: Bool? = nil) {
        if let top {
            danmakuBlockTop = top
            PlaybackPreferences.danmakuBlockTop = top
        }
        if let bottom {
            danmakuBlockBottom = bottom
            PlaybackPreferences.danmakuBlockBottom = bottom
        }
        if let scroll {
            danmakuBlockScroll = scroll
            PlaybackPreferences.danmakuBlockScroll = scroll
        }
        if usesOverlayDanmakuRenderer {
            danmakuOverlay.update {
                $0.blockTop = danmakuBlockTop
                $0.blockBottom = danmakuBlockBottom
                $0.blockScroll = danmakuBlockScroll
            }
        }
        updateDanmakuConfig {
            $0.blockTop = danmakuBlockTop
            $0.blockBottom = danmakuBlockBottom
            $0.blockScroll = danmakuBlockScroll
        }
    }

    func setDanmakuMergeDuplicates(_ enabled: Bool) {
        danmakuMergeDuplicates = enabled
        PlaybackPreferences.danmakuMergeDuplicates = enabled
        updateDanmakuConfig { $0.mergeDuplicates = enabled }
    }

    func setDanmakuAllowStacking(_ enabled: Bool) {
        danmakuAllowStacking = enabled
        PlaybackPreferences.danmakuAllowStacking = enabled
        if usesOverlayDanmakuRenderer { danmakuOverlay.update { $0.allowStacking = enabled } }
        updateDanmakuConfig { $0.allowStacking = enabled }
    }

    /// 弹幕字号 +/-（fraction 为基准字号的比例：+0.1 = 加大 10%，50%…200% 夹紧）。
    func adjustDanmakuFontSize(by fraction: Double) {
        setDanmakuFontSize(danmakuFontSize + fraction * PlaybackPreferences.danmakuBaseFontSize)
    }

    func resetDanmakuFontSize() {
        setDanmakuFontSize(PlaybackPreferences.danmakuBaseFontSize)
    }

    func setDanmakuFontSize(_ size: Double) {
        danmakuFontSize = size.clamped(PlaybackPreferences.danmakuFontSizeRange)
        PlaybackPreferences.danmakuFontSize = danmakuFontSize
        if usesOverlayDanmakuRenderer { danmakuOverlay.update { $0.fontSize = danmakuFontSize } }
    }

    func adjustDanmakuOffset(by seconds: Double) {
        setDanmakuOffset(danmakuGlobalOffsetSeconds + seconds)
    }

    func resetDanmakuOffset() {
        setDanmakuOffset(0)
    }

    func setDanmakuOffset(_ seconds: Double) {
        danmakuGlobalOffsetSeconds = seconds.clamped(-30...30)
        if usesOverlayDanmakuRenderer { danmakuOverlay.update { $0.offsetSeconds = danmakuGlobalOffsetSeconds } }
        try? engine?.setDanmakuGlobalOffset(.seconds(danmakuGlobalOffsetSeconds))
    }

    /// 实例路径：采当前偏好快照，走与 open 队列闭包同一份映射（`applyDanmakuPrefs`）。
    func applyDanmakuPreferences(to engine: any PlaybackEngine) throws {
        try Self.applyDanmakuPrefs(danmakuPrefsSnapshot(), to: engine)
    }

    func updateDanmakuConfig(_ update: (inout DanmakuConfig) -> Void) {
        guard let engine, var config = try? engine.danmakuConfig() else { return }
        update(&config)
        try? engine.setDanmakuConfig(config)
    }

    func refreshDanmakuTracks(for source: PlaybackSourceGeneration) {
        var tracks: [DanmakuTrackInfo] = []
        let accepted = (try? withReadyEngine(for: source) { engine in
            tracks = try engine.danmakuTracks()
        }) ?? false
        if accepted { danmakuTracks = tracks }
    }

    func selectAudio(_ track: TrackInfo) {
        guard let engine else { return }
        try? engine.selectAudioTrack(track.id)
        state.refreshTracks(from: engine)
    }

    /// `nil` = 关闭字幕。
    func setSubtitle(_ track: TrackInfo?) {
        guard let engine else { return }
        do {
            try engine.selectSubtitleTrack(track?.id)
            // 用户自己拨过 → 本片内不再自动改（见 `userChoseSubtitleForCurrentSource`）。
            // 只在**真的生效**之后置位：选轨失败（内核报错）时闸门不该跟着关，
            // 否则用户会卡在「自动校正也不再介入」的状态里。
            userChoseSubtitleForCurrentSource = true
        } catch {
            setupError = "字幕选择失败：\(error)"
            playerLog.warning("手动选字幕失败 id=\(track?.id.description ?? "关闭") error=\(error)")
        }
        state.refreshTracks(from: engine)
    }

    /// 移除一条外挂字幕轨（内嵌轨的 `canRemove` 是 false，走不进来）。
    ///
    /// 三条记账：
    /// - 删的是**当前选中**那条 → 清掉「用户自己拨过」闸门，让既有偏好校正
    ///   （`applySubtitlePreferenceIfNeeded`）在刷新后重新挑一条或关闭。闸门是为
    ///   「别覆盖用户的选择」而设的，而那条轨已经不存在了，继续拦着只会让用户
    ///   停在「字幕没了也不自动选」的状态里。
    /// - 顺手清 `externalSubtitleNames`：显示名按轨道 id 记账，不清就会串到内核
    ///   复用的新轨 id 上（Jellyfin 侧车字幕的「简体 / 繁体」判定读的就是它）。
    /// - **不删磁盘上的导入副本**：同一文件可能被多条轨引用，且目录由
    ///   `ManagedDirectoryPruner` 按 100 文件 / 512 MB 有界修剪，孤儿不是泄漏。
    func removeSubtitle(_ track: TrackInfo) {
        guard let engine, track.canRemove else { return }
        do {
            try engine.removeSubtitleTrack(track.id)
        } catch {
            setupError = "字幕删除失败：\(error)"
            playerLog.warning("删除字幕轨失败 id=\(track.id) error=\(error)")
            return
        }
        externalSubtitleNames.removeValue(forKey: track.id)
        if track.selected { userChoseSubtitleForCurrentSource = false }
        playerLog.info(
            "删除字幕轨 id=\(track.id) wasSelected=\(track.selected) "
                + "title=\(track.displayTitle) source=\(track.source.rawValue)"
        )
        state.refreshTracks(from: engine)
    }

    /// 加外挂字幕轨道（用户手动选文件：加载并立即选中）。
    func loadExternalSubtitle(fileURL: URL) {
        guard let engine else { return }
        guard let localURL = copyImportedSubtitle(fileURL) else { return }
        do {
            let id = try engine.addExternalSubtitle(localURL.path)
            // 手动导入的轨道名用文件主名（去掉扩展名）。
            let baseName = fileURL.deletingPathExtension().lastPathComponent
            externalSubtitleNames[id] = baseName
            try engine.selectSubtitleTrack(id)
            // 用户自己挑的文件就是要看的那条：挡住后续的偏好校正。同样只在
            // 加载 + 选中都成功之后才置位（坏文件不该连带关掉自动校正）。
            userChoseSubtitleForCurrentSource = true
            state.refreshTracks(from: engine)
        } catch {
            setupError = "字幕加载失败：\(error)"
        }
    }

    /// Generation-safe variant for asynchronously downloaded resources.
    /// `name` 非 nil 时写入显示名映射（Jellyfin 侧车字幕用 `ExternalSubtitle.title`）。
    @discardableResult
    func addExternalSubtitle(
        fileURL: URL,
        name: String? = nil,
        for source: PlaybackSourceGeneration
    ) -> Bool {
        do {
            return try withReadyEngine(for: source) { engine in
                let id = try engine.addExternalSubtitle(fileURL.path)
                if let name, !name.isEmpty {
                    externalSubtitleNames[id] = name
                }
                state.refreshTracks(from: engine)
            }
        } catch {
            setupError = "字幕加载失败：\(error)"
            return false
        }
    }

    /// 轨道列表每次刷新后按偏好校正字幕选择（`state.onTracksRefreshed` 的落点）。
    ///
    /// 「默认用第一个」的根源在内核：Erika 打开媒体时按 **probe 顺序取第一条字幕轨**
    /// （不看 disposition、不认语言偏好）；片源里第一条是英字 / 日字时，中文用户每次
    /// 开片都要手动切。内核只提供「选哪条」的能力，判断留给宿主——这里是那个判断：
    ///
    /// - 偏好来自设置页（默认**中文优先·简体优先**），规则是纯函数
    ///   `SubtitleTrackSelector`，本方法只负责取状态、落动作。
    /// - 用户已经在菜单里选过（`userChoseSubtitleForCurrentSource`）→ 一律不动。
    /// - 侧车字幕批量装载期间（`isLoadingExternalSubtitleBatch`）→ 整批结束后再校正：
    ///   侧车是一条条挂上来的，逐条校正会让「繁體先下完、简体后下完」的片源在开播
    ///   头几秒连续切两次，而每次切换都是内核级的轨切换（会停/重启音频输出）。
    /// - 动作 `keep`（绝大多数刷新）时不碰引擎、不刷列表，避免事件自激。
    ///
    /// **重入闸门是必需的，不是防御性编程**：方法末尾那次 `refreshTracks` 会同步再
    /// 触发 `onTracksRefreshed`，而内核的选轨是**异步生效**的（`ErikaTrackTests` 里的
    /// 真内核验证：选轨命令投给内核 worker，同一次调用里立刻回读 `tracks()` 拿到的
    /// 仍是旧 `selected`）——于是「判定 → 选轨 → 刷新 → 判定」会一路同步递归下栈。
    /// 闸门在进门处就抬起、`defer` 落下（判 `keep` 的轮次也不会有嵌套调用，代价为零）；
    /// 内核随后的 `trackSelectionChanged` 事件会再触发一轮刷新，此时读到新选择即
    /// 判定 `keep`，收敛。
    func applySubtitlePreferenceIfNeeded() {
        guard !isApplyingSubtitlePreference else { return }
        isApplyingSubtitlePreference = true
        defer { isApplyingSubtitlePreference = false }
        guard !userChoseSubtitleForCurrentSource,
              !isLoadingExternalSubtitleBatch,
              let engine
        else { return }
        let tracks = state.subtitleTracks
        guard !tracks.isEmpty else { return }
        let current = tracks.first(where: { $0.selected })?.id
        let action = SubtitleTrackSelector.selection(
            in: tracks,
            preference: PlaybackPreferences.subtitleLanguagePreference,
            current: current,
            displayNames: externalSubtitleNames
        )
        switch action {
        case .keep:
            return
        case .disable:
            do {
                try engine.selectSubtitleTrack(nil)
            } catch {
                // 自动动作失败只进日志，不弹错误徽章：用户没要求过这次切换
                // （对照 `applyDanmakuPrefs` 失败只 warning 的口径）。
                playerLog.warning("按偏好关闭字幕失败 error=\(error)")
                return
            }
            #if DEBUG
            appliedSubtitlePreferenceCount += 1
            #endif
            playerLog.info("按偏好关闭字幕 tracks=\(tracks.count)")
        case .select(let id):
            do {
                try engine.selectSubtitleTrack(id)
            } catch {
                playerLog.warning("按偏好选字幕失败 id=\(id) error=\(error)")
                return
            }
            #if DEBUG
            appliedSubtitlePreferenceCount += 1
            #endif
            let picked = tracks.first { $0.id == id }
            playerLog.info(
                "按偏好自动选字幕 id=\(id) lang=\(picked?.language ?? "-") "
                    + "title=\(picked?.title ?? "-") source=\(picked?.source.rawValue ?? "-")"
            )
        }
        state.refreshTracks(from: engine)
    }

    /// 侧车字幕批量装载开始：期间不做偏好校正（见 `applySubtitlePreferenceIfNeeded`）。
    func beginExternalSubtitleBatch() {
        isLoadingExternalSubtitleBatch = true
    }

    /// 侧车字幕批量装载结束：整批只在这里校正一次（代次仍对得上才动）。
    ///
    /// 批次的收尾**必须是这个方法**而不是直接调校正：中途取消 / 换片 / 单条失败
    /// 都会提前 return，只有把「关批次」和「校正」绑在一起才能保证 flag 不残留
    /// ——flag 残留的后果是这一整片再也不按偏好选字幕。
    @discardableResult
    func endExternalSubtitleBatch(for source: PlaybackSourceGeneration) -> Bool {
        isLoadingExternalSubtitleBatch = false
        return applySubtitlePreference(for: source)
    }

    /// 异步资源（Jellyfin 侧车字幕）下载完之后按偏好校正一次：代次仍对得上才动。
    @discardableResult
    func applySubtitlePreference(for source: PlaybackSourceGeneration) -> Bool {
        guard source.value == sourceGeneration,
              source.requestID == activeRequest?.id,
              isSourceReady
        else { return false }
        applySubtitlePreferenceIfNeeded()
        return true
    }
}
