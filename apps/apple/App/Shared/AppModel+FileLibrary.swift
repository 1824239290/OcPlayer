import Foundation
import JellyfinKit
import OcPlayerCore
import MetadataKit

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
            homeInitialLoadDone = true
            phase = .ready
        } catch {
            guard generation == sessionGeneration else { return }
            onboardingError = error.localizedDescription
            phase = .onboarding
        }
    }

    func playFileLibraryItem(_ item: OcpFileLibrary.Item, asset: OcpFileLibrary.Asset, fromStart: Bool) async throws {
        guard activeFileSourceID == item.sourceId else { return }
        let generation = sessionGeneration
        // Finish the previous item before reading this leaf's permanent resume
        // state, including when the user immediately reopens the same movie.
        await finishReporting()?.value
        let prepared = try await fileLibrary.preparePlayback(item: item, asset: asset)
        guard generation == sessionGeneration, activeFileSourceID == item.sourceId else { return }
        guard let url = URL(string: prepared.uri), url.isFileURL else {
            throw OcpCoreError(message: "当前文件库只支持本地文件播放")
        }
        let resume = fromStart || prepared.progress?.completed == true || prepared.progress?.played == true
            ? nil : prepared.progress?.positionSeconds
        let request = PlaybackRequest(
            title: item.title, uri: url.path, headers: prepared.headers,
            fileLibraryIdentity: .init(sourceID: prepared.sourceId, itemID: prepared.itemId, assetID: prepared.assetId),
            resumeSeconds: resume)
        presentRequest(request)
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
                        _ = self.checkpointFileLibraryProgress()
                        self.dismissPlayer()
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
