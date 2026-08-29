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
    @discardableResult
    func replaceDanmaku(
        json: String,
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
                        json: json,
                        trackOffsetSeconds: Double(offset.microseconds) / 1_000_000
                    )
                    return
                }
                // 先应用渲染偏好再装载：偏好里的布局字段（displayArea/block 等）和
                // 全局偏移一旦变化会触发内核重排。放在 addDanmakuTrack 之前设置，
                // 让 add 那一次重排同时吸收偏好变更，避免装载后再次改配置触发第二次
                // 全量重排（NipaPlay 的做法：配置先于装载稳定，装载只触发一次）。
                do {
                    try applyDanmakuPreferences(to: engine)
                } catch {
                    playerLog.warning("弹幕偏好应用失败，继续装载 error=\(error)")
                    PlaybackLog.append("danmaku preferences skipped error=\(error)")
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

    func setDanmakuFontSize(_ size: Double) {
        danmakuFontSize = size.clamped(14...36)
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

    func applyDanmakuPreferences(to engine: any PlaybackEngine) throws {
        var config = try engine.danmakuConfig()
        config.enabled = danmakuEnabled
        config.opacity = Float(danmakuOpacity)
        config.displayArea = Float(danmakuDisplayArea)
        config.blockTop = danmakuBlockTop
        config.blockBottom = danmakuBlockBottom
        config.blockScroll = danmakuBlockScroll
        config.mergeDuplicates = danmakuMergeDuplicates
        config.allowStacking = danmakuAllowStacking
        try engine.setDanmakuConfig(config)
        try engine.setDanmakuGlobalOffset(.seconds(danmakuGlobalOffsetSeconds))
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
        try? engine.selectSubtitleTrack(track?.id)
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
            state.refreshTracks(from: engine)
        } catch {
            setupError = "字幕加载失败：\(error)"
        }
    }

    /// 只加轨道不改变当前选择（Jellyfin 侧车字幕批量装载用）。
    func addExternalSubtitle(fileURL: URL) {
        guard let engine else { return }
        do {
            let id = try engine.addExternalSubtitle(fileURL.path)
            externalSubtitleNames[id] = fileURL.deletingPathExtension().lastPathComponent
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

    /// 当前没有任何字幕被选中时自动挑一条：中文优先，否则第一条。
    /// （内核对内封字幕有自己的默认选择；这里只兜「全是外挂字幕」的场。）
    func autoSelectSubtitleIfNone() {
        guard let engine, !state.subtitleTracks.isEmpty else { return }
        guard !state.subtitleTracks.contains(where: { $0.selected }) else { return }
        let tracks = state.subtitleTracks
        let picked = tracks.first {
            let lang = $0.language?.lowercased() ?? ""
            return lang.contains("zh") || lang.contains("chi")
        } ?? tracks[0]
        try? engine.selectSubtitleTrack(picked.id)
        state.refreshTracks(from: engine)
    }

    @discardableResult
    func autoSelectSubtitleIfNone(for source: PlaybackSourceGeneration) -> Bool {
        guard source.value == sourceGeneration,
              source.requestID == activeRequest?.id,
              isSourceReady,
              let engine
        else { return false }
        guard !state.subtitleTracks.isEmpty,
              !state.subtitleTracks.contains(where: { $0.selected })
        else { return true }
        let tracks = state.subtitleTracks
        let picked = tracks.first {
            let lang = $0.language?.lowercased() ?? ""
            return lang.contains("zh") || lang.contains("chi")
        } ?? tracks[0]
        do {
            try engine.selectSubtitleTrack(picked.id)
            state.refreshTracks(from: engine)
            return true
        } catch {
            setupError = "字幕选择失败：\(error)"
            return false
        }
    }


}
