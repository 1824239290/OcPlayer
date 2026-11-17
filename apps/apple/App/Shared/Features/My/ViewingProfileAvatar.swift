import AppDesignKit
import BangumiKit
import Foundation
import JellyfinKit
import Observation
import SwiftUI

enum ServerAvatarResolution: Equatable {
    case pending
    case resolved(tag: String?)
}

/// The preferred source is chosen from account metadata, before any bitmap is presented.
struct ViewingAvatarRequest: Equatable {
    enum Source: String { case server, bangumi, none }
    var identity: String
    var source: Source
    var sourceName: String
    var url: URL?
    var authHeader: String?
    var cacheScope: String?

    static func resolve(server: (any MediaServer)?, generation: Int,
                        resolution: ServerAvatarResolution,
                        bangumiProfile: BangumiProfile?) -> ViewingAvatarRequest? {
        let account = "\(server?.profile.id ?? "local"):\(generation)"
        if let server {
            guard case .resolved(let tag) = resolution else { return nil }
            if let tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
                return ViewingAvatarRequest(identity: account, source: .server,
                                            sourceName: server.profile.kind.displayName,
                                            url: server.userImageURL(tag: tag),
                                            authHeader: server.authorizationHeader,
                                            cacheScope: server.profile.imageCacheScope)
            }
        }
        if let profile = bangumiProfile, let avatar = profile.avatar {
            let raw = [avatar.large, avatar.medium, avatar.small]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            if let raw, let url = URL(string: BangumiURL.imageURLString(from: raw)),
               ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                return ViewingAvatarRequest(identity: "\(account):bangumi:\(profile.id):\(profile.username)",
                                            source: .bangumi, sourceName: "Bangumi", url: url,
                                            authHeader: nil, cacheScope: nil)
            }
        }
        return ViewingAvatarRequest(identity: account, source: .none, sourceName: "账号",
                                    url: nil, authHeader: nil, cacheScope: nil)
    }
}

@MainActor
@Observable
final class ViewingProfileAvatarModel {
    private(set) var request: ViewingAvatarRequest?
    private(set) var image: PlatformImage?
    private(set) var isReady = false
    private var generation = 0

    func isReady(for current: ViewingAvatarRequest?) -> Bool {
        current != nil && current == request && isReady
    }

    func reset() {
        generation &+= 1
        request = nil
        image = nil
        isReady = false
    }

    func load(_ current: ViewingAvatarRequest?, pipeline: ImagePipeline) async {
        guard let current else { reset(); return }
        if isReady(for: current) { return }
        generation &+= 1
        let token = generation
        request = current
        image = nil
        isReady = false
        let bitmap: PlatformImage?
        if let url = current.url {
            bitmap = try? await pipeline.load(url, authHeader: current.authHeader,
                                             cacheScope: current.cacheScope, maxPixelSize: 132)
        } else { bitmap = nil }
        guard !Task.isCancelled, generation == token, request == current else { return }
        // Publish only the final source and decoded image; a slow preferred image never
        // temporarily displays the fallback account's face.
        image = bitmap
        isReady = true
    }
}

extension AppModel {
    func viewingAvatarRequest(bangumiEnabled: Bool) -> ViewingAvatarRequest? {
        guard phase != .boot else { return nil }
        return ViewingAvatarRequest.resolve(
            server: server, generation: sessionGeneration, resolution: serverAvatarResolution,
            bangumiProfile: bangumiEnabled && bangumi.isAuthenticated ? bangumi.profile : nil)
    }
}

struct ViewingProfileAvatarImage: View {
    let image: PlatformImage?
    let sourceName: String

    var body: some View {
        Group {
            if let image {
                Image(platform: image).resizable().renderingMode(.original).scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44).clipShape(.circle)
        .accessibilityLabel(image == nil ? "未设置头像" : "\(sourceName) 头像")
    }
}
