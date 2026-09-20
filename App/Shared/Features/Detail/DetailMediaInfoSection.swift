import AppDesignKit
import CoreModel
import JellyfinKit
import SwiftUI

/// 详情页内嵌的「媒体信息」区块：展示**当前条目 / 当前选中集**的文件级媒体信息。
///
/// 数据来自服务端元数据（`MediaSources`），不是播放器解码后的运行时数据——
/// 这里看到的分辨率/码率是文件自身的属性，和 HUD 信息面板（内核实际解出来的）
/// 是两回事，两者对不上通常意味着转码或源标注有误。
///
/// 走 `GET /Items?fields=MediaSources`（`JellyfinServer.mediaFileInfo`），
/// **不建播放会话**：在详情页翻看选集不该在服务端留下会话记录。
///
/// 未取到媒体源（目录条目 / 老服务端不返回流信息）时整块不出现。
struct DetailMediaInfoSection: View {
    @Environment(AppModel.self) private var app

    /// 目标条目：剧集传当前选中集，电影传自身。nil 时整块不渲染。
    let item: MediaItem?
    /// 与上方「剧集」「Bangumi」等区块同一左缘。
    let horizontalInset: CGFloat

    /// 本次停留期间的条目 → 媒体信息缓存：来回点选集不重拉、不闪 loading。
    @State private var cache: [MediaItem.ID: MediaFileInfo] = [:]
    /// 拉过但确认没有媒体源的条目（目录 / 老服务端），同样不重拉。
    @State private var emptyIDs: Set<MediaItem.ID> = []
    /// 正在拉的条目。用 id 而不是 Bool：切集时旧任务被取消，它的收尾不能把
    /// 新任务的 loading 态一起清掉。
    @State private var loadingID: MediaItem.ID?
    /// 拉取失败的条目与原因。同样按 id 绑定：切集后不能把上一集的错误
    /// 挂在新选中的集上（`.task(id:)` 重启前有一帧的空窗）。
    @State private var failedID: MediaItem.ID?
    @State private var errorMessage: String?

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 26)
                    .padding(.bottom, 12)
                sectionBody(for: item)
            }
            .padding(.horizontal, horizontalInset)
            .task(id: item.id) { await load(item) }
        }
    }

    // MARK: - 区块头

    private var header: some View {
        HStack(spacing: 10) {
            Text("媒体信息")
                .font(.title3.weight(.bold))
            if let count = info?.sourceCount, count > 1 {
                Text("共 \(count) 个版本")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
        }
    }

    private var isLoading: Bool {
        guard let item else { return false }
        return loadingID == item.id
    }

    // MARK: - 主体

    @ViewBuilder
    private func sectionBody(for item: MediaItem) -> some View {
        if let info {
            content(info)
                .transition(.section)
        } else if isLoading {
            skeleton
                .transition(.section)
        } else if let message = errorMessage(for: item) {
            ErrorNotice(message) {
                Task { await load(item, force: true) }
            }
            .padding(.bottom, 4)
            .transition(.section)
        }
    }

    private func errorMessage(for item: MediaItem) -> String? {
        failedID == item.id ? errorMessage : nil
    }

    /// 当前展示的媒体信息：只认当前条目的缓存，避免切集瞬间闪上一集的数据。
    private var info: MediaFileInfo? {
        guard let item else { return nil }
        return cache[item.id]
    }

    private func content(_ info: MediaFileInfo) -> some View {
        let groups = mediaGroups(info)
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(groups.indices, id: \.self) { index in
                if index > 0 { Divider() }
                group(groups[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        // 与 MoviePilot 区块同一档半透明填充：详情页的信息卡都透出海报氛围底，
        // 不用 `.background.secondary`（那是不透明灰，在氛围底上会糊成一块）。
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }

    private func mediaGroups(_ info: MediaFileInfo) -> [(title: String, rows: [(label: String, value: String)])] {
        var groups: [(title: String, rows: [(label: String, value: String)])] = []
        if let video = info.video {
            let rows = videoRows(video)
            if !rows.isEmpty { groups.append(("视频", rows)) }
        }
        if !info.audioTracks.isEmpty {
            groups.append(("音频", audioRows(info.audioTracks)))
        }
        if !info.subtitleTracks.isEmpty {
            groups.append(("字幕", subtitleRows(info.subtitleTracks)))
        }
        let fileRows = fileRows(info)
        if !fileRows.isEmpty { groups.append(("文件", fileRows)) }
        return groups
    }

    /// 一组「标签 + 值」行：组名 + 宽屏两列（同行等高）/ 紧凑单列的网格。
    private func group(_ group: (title: String, rows: [(label: String, value: String)])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            EqualRowHeightGrid(minColumnWidth: 280, horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(group.rows.indices, id: \.self) { index in
                    infoRow(group.rows[index].label, group.rows[index].value)
                }
            }
        }
    }

    /// 单行「标签 + 值」：标签定宽、值可选中，与 Bangumi 条目详情页的「作品信息」同款。
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 各行

    private func videoRows(_ video: MediaFileInfo.VideoTrack) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let resolution = MediaInfoLabel.resolution(width: video.width, height: video.height) {
            rows.append(("分辨率", resolution))
        }
        if let codec = MediaInfoLabel.codec(video.codec) {
            let withProfile = video.profile.map { "\(codec) · \($0)" } ?? codec
            rows.append(("编码", withProfile))
        }
        if let bitrate = MediaInfoLabel.bitrate(video.bitrate) {
            rows.append(("码率", bitrate))
        }
        if let frameRate = MediaInfoLabel.frameRate(video.frameRate) {
            rows.append(("帧率", frameRate))
        }
        if let range = MediaInfoLabel.dynamicRange(videoRangeType: video.videoRangeType) {
            rows.append(("动态范围", range))
        }
        let color = [MediaInfoLabel.colorPrimaries(video.colorPrimaries),
                     MediaInfoLabel.colorTransfer(video.colorTransfer)]
            .compactMap { $0 }
            .joined(separator: " · ")
        if !color.isEmpty {
            rows.append(("色彩", color))
        }
        if let depth = video.bitDepth, depth > 0 {
            rows.append(("位深", "\(depth) bit"))
        }
        if video.isInterlaced {
            rows.append(("扫描", "隔行"))
        }
        return rows
    }

    private func audioRows(_ tracks: [MediaFileInfo.AudioTrack]) -> [(label: String, value: String)] {
        tracks.enumerated().map { index, track in
            var parts: [String] = []
            if let language = MediaInfoLabel.language(track.language) { parts.append(language) }
            if let codec = MediaInfoLabel.codec(track.codec) { parts.append(codec) }
            if let channels = MediaInfoLabel.channels(count: track.channels, layout: track.channelLayout) {
                parts.append(channels)
            }
            if let sampleRate = MediaInfoLabel.sampleRate(track.sampleRate) { parts.append(sampleRate) }
            if let bitrate = MediaInfoLabel.bitrate(track.bitrate) { parts.append(bitrate) }
            if track.isDefault { parts.append("默认") }
            return (trackLabel(track.title, kind: "音轨", index: index, total: tracks.count),
                    parts.isEmpty ? "—" : parts.joined(separator: " · "))
        }
    }

    private func subtitleRows(_ tracks: [MediaFileInfo.SubtitleTrack]) -> [(label: String, value: String)] {
        tracks.enumerated().map { index, track in
            var parts: [String] = []
            if let language = MediaInfoLabel.language(track.language) { parts.append(language) }
            if let codec = MediaInfoLabel.codec(track.codec) { parts.append(codec) }
            if track.isExternal { parts.append("外挂") }
            if track.isForced { parts.append("强制") }
            if track.isDefault { parts.append("默认") }
            return (trackLabel(track.title, kind: "字幕", index: index, total: tracks.count),
                    parts.isEmpty ? "—" : parts.joined(separator: " · "))
        }
    }

    /// 轨道行标题：服务端给了标题就用标题，否则「音轨 2」这样按序号排（单轨不带序号）。
    private func trackLabel(_ title: String?, kind: String, index: Int, total: Int) -> String {
        if let title, !title.isEmpty { return title }
        return total > 1 ? "\(kind) \(index + 1)" : kind
    }

    private func fileRows(_ info: MediaFileInfo) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let container = MediaInfoLabel.container(info.container) {
            rows.append(("容器", container))
        }
        if let size = MediaInfoLabel.size(info.sizeBytes) {
            rows.append(("大小", size))
        }
        if let duration = MediaInfoLabel.duration(info.durationSeconds) {
            rows.append(("时长", duration))
        }
        if let fileName = info.fileName {
            rows.append(("文件", fileName))
        }
        return rows
    }

    // MARK: - 骨架

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonBlock(cornerRadius: 6)
                    .frame(height: 44)
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .skeletonShimmer()
    }

    // MARK: - 数据

    /// 拉取并缓存某个条目的媒体信息。
    ///
    /// 竞态守卫：`.task(id:)` 在切集时会取消旧任务，但取消可能发生在 await 之后，
    /// 所以每个写回点都比一次「当前正在拉的是不是我」——快速连点选集时，
    /// 旧请求回来不能把新选中集的 loading 清掉、也不能写入错误。
    private func load(_ target: MediaItem, force: Bool = false) async {
        guard let server = app.server else { return }
        if !force, cache[target.id] != nil || emptyIDs.contains(target.id) { return }

        loadingID = target.id
        failedID = nil
        errorMessage = nil
        defer {
            if loadingID == target.id { loadingID = nil }
        }
        do {
            let info = try await server.mediaFileInfo(itemID: target.id)
            guard !Task.isCancelled, loadingID == target.id else { return }
            if let info {
                cache[target.id] = info
            } else {
                emptyIDs.insert(target.id)
            }
        } catch is CancellationError {
            // 切集 / 离页的取消不是错误。
        } catch let e as JellyfinError {
            guard !Task.isCancelled, loadingID == target.id else { return }
            failedID = target.id
            errorMessage = e.errorDescription
        } catch {
            guard !Task.isCancelled, loadingID == target.id else { return }
            failedID = target.id
            errorMessage = "\(error)"
        }
    }
}
