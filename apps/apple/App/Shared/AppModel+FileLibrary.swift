import CoreModel
import DiagnosticsKit
import Foundation
import JellyfinKit
import MetadataKit
import OcPlayerCore

extension AppModel {
    static let activeMediaSourceKey = "dev.jumusu.ocplayer.activeMediaSource"

    var fileLibraryAPIBase: String {
        MirrorSettings.tmdbEndpoints(
            enabled: preferences.bool(forKey: SettingsKeys.tmdbMirrorEnabled),
            apiRawValue: preferences.string(forKey: SettingsKeys.tmdbMirrorAPIBaseURL) ?? "",
            imageRawValue: preferences.string(forKey: SettingsKeys.tmdbMirrorImageBaseURL) ?? ""
        ).apiBaseURL.absoluteString
    }

    var fileLibraryCredentialRevision: String {
        let _ = tmdb.credentialGeneration
        return FileLibraryCoordinator.credentialRevision(key: tmdb.rawAPIKey ?? "", apiBase: fileLibraryAPIBase)
    }

    func fileLibraryImageURL(path: String?) -> URL? {
        let endpoints = MirrorSettings.tmdbEndpoints(
            enabled: preferences.bool(forKey: SettingsKeys.tmdbMirrorEnabled),
            apiRawValue: preferences.string(forKey: SettingsKeys.tmdbMirrorAPIBaseURL) ?? "",
            imageRawValue: preferences.string(forKey: SettingsKeys.tmdbMirrorImageBaseURL) ?? "")
        return TMDbImageSize.url(path: path, size: .w500, endpoints: endpoints)
    }

    /// Old installations without a selection retain the server restore policy.
    /// Once a source is selected, failure never substitutes a different profile.
    func restoreSelectedMediaSource() async -> Bool {
        guard let saved = preferences.string(forKey: Self.activeMediaSourceKey) else { return false }
        if saved.hasPrefix("file:") {
            let sourceID = String(saved.dropFirst(5))
            if fileLibrary.sources.contains(where: { $0.sourceId == sourceID }) {
                await activateFileSource(sourceID)
                return true
            }
            onboardingError = fileLibrary.availabilityError ?? "上次选择的文件媒体库不可用，请选择媒体来源"
        } else if saved.hasPrefix("server:") {
            // Preserve the explicit startup preference within server sources;
            // its failure still cannot fall back to another profile.
            let profileID = store.defaultServerID ?? String(saved.dropFirst(7))
            if let profile = store.profiles.first(where: { $0.id == profileID }),
               let server = MediaServerFactory.resume(profile: profile, from: store) {
                await activate(server: server)
                return true
            }
            onboardingError = "上次选择的服务器需要重新登录，请选择媒体来源"
        } else {
            onboardingError = "无法恢复上次选择的媒体来源，请重新选择"
        }
        phase = .onboarding
        isMediaSourcesPresented = true
        return true
    }

    func activateFileSource(_ sourceID: String) async {
        stopPlaybackForSessionChange()
        resetBrowseState()
        resetOnboarding()
        let generation = sessionGeneration
        do {
            try await fileLibrary.setup()
            guard generation == sessionGeneration,
                  fileLibrary.sources.contains(where: { $0.sourceId == sourceID }) else { return }
            activeFileSourceID = sourceID
            preferences.set("file:\(sourceID)", forKey: Self.activeMediaSourceKey)
            phase = .ready
            initialDataTask = Task { [weak self] in
                await self?.loadFileLibraryHome(sourceID: sourceID, generation: generation)
            }
            await initialDataTask?.value
        } catch {
            guard generation == sessionGeneration else { return }
            onboardingError = error.localizedDescription
            phase = .onboarding
        }
    }

    func fileLibrarySessionIsCurrent(_ generation: Int, sourceID: String) -> Bool {
        sessionGeneration == generation && activeFileSourceID == sourceID
    }

    /// 将当前活跃文件媒体库投影到与 Jellyfin/Emby 相同的首页状态（libraries / resume / nextUp / latest）。
    func loadFileLibraryHome(sourceID: String, generation: Int) async {
        guard fileLibrarySessionIsCurrent(generation, sourceID: sourceID) else { return }
        homeLoadGeneration &+= 1
        let loadGeneration = homeLoadGeneration
        home.isLoading = true
        home.error = nil
        defer {
            if fileLibrarySessionIsCurrent(generation, sourceID: sourceID),
               homeLoadGeneration == loadGeneration {
                home.isLoading = false
            }
        }
        do {
            async let loadedLibraries = fileLibrary.libraries(sourceID: sourceID)
            async let loadedResume = fileLibrary.resume(sourceID: sourceID)
            async let loadedNextUp = fileLibrary.nextUp(sourceID: sourceID)
            async let loadedLatest = fileLibrary.page(.init(
                sourceId: sourceID,
                libraryId: nil,
                parentId: nil,
                search: "",
                startIndex: 0,
                limit: 24,
                sortBy: "dateAdded",
                sortAscending: false
            ))
            let (rawLibraries, rawResume, rawNextUp, latestPage) = try await (
                loadedLibraries, loadedResume, loadedNextUp, loadedLatest
            )
            guard !Task.isCancelled,
                  fileLibrarySessionIsCurrent(generation, sourceID: sourceID),
                  homeLoadGeneration == loadGeneration
            else { return }

            let projectedLibraries = rawLibraries.map(FileLibraryProjection.mediaLibrary)
            let projectedResume = rawResume.map { FileLibraryProjection.mediaItem($0) }
            let projectedNextUp = Self.deduplicatedNextUp(
                rawNextUp.map { FileLibraryProjection.mediaItem($0) },
                resume: projectedResume
            )
            let projectedLatest = latestPage.items.map { FileLibraryProjection.mediaItem($0) }

            libraries = projectedLibraries
            librariesError = nil
            home.resume = projectedResume
            home.nextUp = projectedNextUp
            home.latest = projectedLatest
            home.cachedFetchedAt = nil
            home.refreshFailureWasConnectivity = false
            homeInitialLoadDone = true

            // 新元数据或新分类到达时保留已有完整 4 格封面避免闪烁，只对缺失或不足 4 张的分类重新随机选海报。
            let validIDs = Set(projectedLibraries.map(\.id))
            libraryCoverArt = libraryCoverArt.filter { validIDs.contains($0.key) }
            libraryCoverAttempted = libraryCoverAttempted.filter {
                validIDs.contains($0) && (libraryCoverArt[$0]?.count ?? 0) >= 4
            }
            for lib in projectedLibraries where (libraryCoverArt[lib.id]?.count ?? 0) < 4 {
                await resolveLibraryCoverIfNeeded(for: lib)
            }
            await fileLibrary.refreshUnmatchedCount(sourceID: sourceID)

            let presence = HomeRailPresence(
                resume: !home.resume.isEmpty,
                nextUp: !home.nextUp.isEmpty,
                latest: !home.latest.isEmpty
            )
            if home.railPresence != presence {
                home.railPresence = presence
                presence.persist(to: preferences)
            }
        } catch is CancellationError {
            return
        } catch {
            guard fileLibrarySessionIsCurrent(generation, sourceID: sourceID),
                  homeLoadGeneration == loadGeneration else { return }
            if !hasAnyHomeContent {
                home.error = error.localizedDescription
            }
            homeInitialLoadDone = true
            AppDiagnostics.logWarning("文件媒体库首页加载失败", fields: [
                "sourceID": .string(sourceID),
                "error": .string(error.localizedDescription),
            ])
        }
    }

    /// 当后台扫描 / TMDB 刮削或分类增删改产出新变化时，增量刷新首页并使旧分页缓存失效。
    func handleFileLibraryCatalogChanged(sourceID: String) async {
        guard activeFileSourceID == sourceID else { return }
        libraryPages = [:]
        // 仅清理不足 4 张封面的分类记账，避免刮削期间把已有封面瞬间清空成灰块。
        libraryCoverAttempted = libraryCoverAttempted.filter { (libraryCoverArt[$0]?.count ?? 0) >= 4 }
        await loadFileLibraryHome(sourceID: sourceID, generation: sessionGeneration)
    }

    func deleteFileSource(_ sourceID: String) async throws {
        let wasActive = activeFileSourceID == sourceID
        try await fileLibrary.deleteSource(sourceID: sourceID)
        guard wasActive else { return }
        stopPlaybackForSessionChange()
        resetBrowseState()
        preferences.removeObject(forKey: Self.activeMediaSourceKey)
        if let nextFile = fileLibrary.sources.first {
            await activateFileSource(nextFile.sourceId)
        } else if let profile = store.profiles.first {
            await switchToServer(profile)
        } else {
            phase = .onboarding
        }
    }

    /// 为文件媒体库的分类网格页和全库搜索加载分页投影。
    func loadFileLibraryPage(
        sourceID: String,
        libraryID: String?,
        searchTerm: String,
        sort: MediaItemsSort?,
        watchState: MediaItemsWatchState?,
        startIndex: Int,
        limit: Int
    ) async throws -> MediaItemsPage {
        let page = try await fileLibrary.page(.init(
            sourceId: sourceID,
            libraryId: libraryID,
            parentId: nil,
            search: searchTerm,
            startIndex: Int64(startIndex),
            limit: limit,
            sortBy: sort.map { FileLibraryProjection.sortKey(for: $0.field) },
            sortAscending: sort?.ascending,
            watchState: watchState.map(FileLibraryProjection.watchStateKey(for:))
        ))
        return MediaItemsPage(
            items: page.items.map { FileLibraryProjection.mediaItem($0) },
            startIndex: Int(page.startIndex),
            totalRecordCount: Int(page.totalCount)
        )
    }

    // MARK: - 统一播放入口（文件媒体库分支）

    /// 从首页/详情页的 `MediaItem` 发起文件媒体库播放：支持电影、单集、整剧（自动定位续播/下一集/首集）与指定版本资产。
    func openFileLibraryPlayback(
        item: MediaItem,
        resumeSeconds: Double?,
        assetID: String? = nil
    ) async {
        guard let sourceID = activeFileSourceID else { return }
        let generation = playbackOpenGeneration
        let session = sessionGeneration
        do {
            let targetItemID: String
            if item.kind == .series {
                if let hint = preferredEpisodeHint(seriesID: item.id) {
                    targetItemID = hint.id
                } else {
                    let seasonsPage = try await fileLibrary.page(.init(sourceId: sourceID, parentId: item.id, limit: 200))
                    guard !Task.isCancelled, playbackOpenGeneration == generation,
                          fileLibrarySessionIsCurrent(session, sourceID: sourceID) else { return }
                    let projectedSeasons = seasonsPage.items.map { FileLibraryProjection.mediaItem($0) }
                    let seasonID = preferredSeasonID(in: projectedSeasons, seriesID: item.id)
                        ?? projectedSeasons.first?.id
                    guard let seasonID else {
                        playbackPreparation = .failed(title: item.name, error: Self.noPlayableContentMessage(for: item))
                        return
                    }
                    let episodesPage = try await fileLibrary.page(.init(sourceId: sourceID, parentId: seasonID, limit: 500))
                    guard !Task.isCancelled, playbackOpenGeneration == generation,
                          fileLibrarySessionIsCurrent(session, sourceID: sourceID) else { return }
                    let projectedEpisodes = episodesPage.items.map { FileLibraryProjection.mediaItem($0) }
                    guard let chosen = preferredEpisodeID(in: projectedEpisodes, seriesID: item.id)
                        ?? projectedEpisodes.first?.id else {
                        playbackPreparation = .failed(title: item.name, error: Self.noPlayableContentMessage(for: item))
                        return
                    }
                    targetItemID = chosen
                }
            } else {
                targetItemID = item.id
            }

            let detail = try await fileLibrary.detail(sourceID: sourceID, itemID: targetItemID)
            guard !Task.isCancelled, playbackOpenGeneration == generation,
                  fileLibrarySessionIsCurrent(session, sourceID: sourceID) else { return }
            if case .loading = playbackPreparation {
                playbackPreparation = .loading(title: detail.item.title)
            }
            let chosenAsset: OcpFileLibrary.Asset?
            if let assetID {
                chosenAsset = detail.assets.first { $0.assetId == assetID && $0.available }
            } else {
                chosenAsset = detail.assets.first { $0.available }
            }
            guard let asset = chosenAsset else {
                playbackPreparation = .failed(title: detail.item.title, error: "当前没有可用的播放文件")
                return
            }
            let fromStart = resumeSeconds == 0
            try await playFileLibraryItem(
                detail.item,
                asset: asset,
                fromStart: fromStart,
                explicitResumeSeconds: resumeSeconds
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, playbackOpenGeneration == generation else { return }
            playbackPreparation = .failed(title: item.name, error: error.localizedDescription)
        }
    }

    func playFileLibraryItem(
        _ item: OcpFileLibrary.Item,
        asset: OcpFileLibrary.Asset,
        fromStart: Bool,
        explicitResumeSeconds: Double? = nil
    ) async throws {
        guard activeFileSourceID == item.sourceId else { return }
        let generation = sessionGeneration
        // Finish the previous item before reading this leaf's permanent resume
        // state, including when the user immediately reopens the same movie.
        await finishReporting()?.value
        let prepared = try await fileLibrary.preparePlayback(item: item, asset: asset)
        let lifetime = fileLibrary.retainPlayback(prepared)
        guard generation == sessionGeneration, activeFileSourceID == item.sourceId else { return }
        guard let url = URL(string: prepared.uri), (url.isFileURL || (url.scheme == "http" && url.host == "127.0.0.1" && prepared.leaseId != nil)) else {
            throw OcpCoreError(message: "无法解析文件媒体库播放资源")
        }
        let resume: Double?
        if fromStart {
            resume = nil
        } else if let explicitResumeSeconds, explicitResumeSeconds > 0 {
            resume = explicitResumeSeconds
        } else if prepared.progress?.completed == true || prepared.progress?.played == true {
            resume = nil
        } else {
            resume = prepared.progress?.positionSeconds
        }
        let projectedItem = FileLibraryProjection.mediaItem(item, progressOverride: prepared.progress)
        let request = PlaybackRequest(
            title: projectedItem.name, uri: url.isFileURL ? url.path : url.absoluteString, headers: prepared.headers,
            fileLibraryIdentity: .init(sourceID: prepared.sourceId, itemID: prepared.itemId, assetID: prepared.assetId),
            resourceLifetime: lifetime, resumeSeconds: resume)
        presentFileLibraryPlayback(request: request, item: projectedItem)
    }

    private func presentFileLibraryPlayback(request: PlaybackRequest, item: MediaItem) {
        if phase == .onboarding { phase = .ready }
        cancelPlaybackOpen()
        finishReporting()
        playbackPreparation = .loading(title: request.title)
        playback?.prepareForPresentation(request)
        if let sourceID = request.fileLibraryIdentity?.sourceID {
            playback?.startLocalViewingRecord(sourceID: "file-library:\(sourceID)", item: item)
        }
        presentedPlayer = request
        schedulePreparationDismiss(for: request)
        retryPlaybackItem = item
        nowPlayingItem = item
        let identity = ActivePlaybackIdentity(
            sessionGeneration: sessionGeneration,
            itemID: item.id,
            requestID: request.id
        )
        activePlaybackIdentity = identity
        startDanmaku(for: request, item: item)
        resolveFileLibraryNextEpisode(after: item, identity: identity)
        startFileLibraryProgress(for: request)
    }

    private func resolveFileLibraryNextEpisode(after item: MediaItem, identity: ActivePlaybackIdentity) {
        guard item.kind == .episode, let seriesID = item.seriesID,
              let sourceID = activeFileSourceID else { return }
        guard item.seasonNumber != 0 else { return }
        nextEpisodeTask?.cancel()
        nextEpisodeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let seasonsPage = try await self.fileLibrary.page(.init(sourceId: sourceID, parentId: seriesID, limit: 200))
                let seasons = seasonsPage.items
                    .filter { ($0.seasonNumber ?? 0) > 0 }
                    .sorted { ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0) }
                var allEpisodes: [OcpFileLibrary.Item] = []
                for season in seasons {
                    let epPage = try await self.fileLibrary.page(.init(sourceId: sourceID, parentId: season.itemId, limit: 500))
                    allEpisodes.append(contentsOf: epPage.items.filter(\.playable))
                }
                guard !Task.isCancelled, self.activePlaybackIdentity == identity else { return }
                let ordered = allEpisodes.sorted { lhs, rhs in
                    let ls = lhs.seasonNumber ?? 0
                    let rs = rhs.seasonNumber ?? 0
                    if ls != rs { return ls < rs }
                    return (lhs.episodeNumber ?? 0) < (rhs.episodeNumber ?? 0)
                }
                if let index = ordered.firstIndex(where: { $0.itemId == item.id }),
                   index + 1 < ordered.count {
                    self.nextEpisode = FileLibraryProjection.mediaItem(ordered[index + 1])
                }
            } catch {
                return
            }
        }
    }

    func startFileLibraryProgress(for request: PlaybackRequest) {
        guard let identity = request.fileLibraryIdentity else { return }
        fileLibraryProgressTask?.cancel()
        fileLibraryPlaybackIdentity = identity
        fileLibraryPlaybackCompleted = false
        fileLibraryProgressTask = Task { @MainActor [weak self] in
            var ticks = 0
            var sawPlaying = false
            while !Task.isCancelled {
                guard let self, self.presentedPlayer?.id == request.id,
                      self.fileLibraryPlaybackIdentity == identity else { return }
                if let playback = self.playback, playback.reportableRequestID == request.id,
                   playback.hasLoadedSource, playback.failedRequestID != request.id {
                    let position = Double(playback.state.position.microseconds) / 1_000_000
                    let duration = Double(playback.state.duration.microseconds) / 1_000_000
                    if playback.state.state == .playing { sawPlaying = true }
                    let completed = sawPlaying && Self.fileLibraryReachedEnd(
                        stopped: playback.state.state == .stopped, failed: playback.setupError != nil,
                        position: position, duration: duration)
                    if completed {
                        self.fileLibraryPlaybackCompleted = true
                        let finishedItem = self.nowPlayingItem
                        let next = self.nextEpisode
                        _ = self.checkpointFileLibraryProgress()
                        if let finishedItem {
                            self.markWatchedOnBangumi(for: finishedItem)
                        }
                        if let next {
                            self.play(next, resumeSeconds: 0)
                        } else {
                            self.dismissPlayer()
                        }
                        return
                    }
                    if ticks % 5 == 0 { _ = self.checkpointFileLibraryProgress() }
                }
                ticks += 1
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    /// Erika currently reports stopped rather than an explicit EOF event.
    /// A manual stop, failure, or unknown duration never proves completion.
    static func fileLibraryReachedEnd(stopped: Bool, failed: Bool, position: Double, duration: Double) -> Bool {
        stopped && !failed && duration.isFinite && duration > 0 && position.isFinite && position >= duration - 0.5
    }

    @discardableResult
    func checkpointFileLibraryProgress() -> Task<Void, Never>? {
        guard let identity = fileLibraryPlaybackIdentity,
              let request = presentedPlayer, request.fileLibraryIdentity == identity,
              let playback, playback.hasLoadedSource, playback.reportableRequestID == request.id,
              playback.failedRequestID != request.id,
              ![.idle, .opening, .error, .closed].contains(playback.state.state) else { return nil }
        let position = Double(playback.state.position.microseconds) / 1_000_000
        let duration = Double(playback.state.duration.microseconds) / 1_000_000
        guard position.isFinite, position > 0 else { return nil }
        return fileLibrary.record(.init(
            sourceId: identity.sourceID, itemId: identity.itemID, positionSeconds: position,
            durationSeconds: duration > 0 ? duration : nil, played: fileLibraryPlaybackCompleted,
            completed: fileLibraryPlaybackCompleted, recordedAt: Date().timeIntervalSince1970))
    }

    @discardableResult
    func finishFileLibraryProgress() -> Task<Void, Never>? {
        fileLibraryProgressTask?.cancel()
        fileLibraryProgressTask = nil
        let write = checkpointFileLibraryProgress()
        fileLibraryPlaybackIdentity = nil
        fileLibraryPlaybackCompleted = false
        return write
    }
}
