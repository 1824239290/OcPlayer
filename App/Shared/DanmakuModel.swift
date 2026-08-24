import DanmakuKit
import Foundation
import Observation

/// 弹幕网关域模型：弹幕协调器 + 网关设置。
///
/// 从 AppModel 拆出并独立环境注入：播放器 / 设置页里只看弹幕的视图，不再被
/// AppModel 的全量观察拖着重绘（播放中 Playback 状态变化不再波及弹幕视图）。
/// 网关地址 + API Key 存 UserDefaults；AppSecret 永远不进客户端，只留在网关。
@MainActor
@Observable
final class DanmakuModel {
    var danmaku: DanmakuCoordinator
    var dandanplayStore: DandanplaySettingsStore

    init(
        danmaku: DanmakuCoordinator? = nil,
        dandanplayStore: DandanplaySettingsStore = DandanplaySettingsStore()
    ) {
        self.danmaku = danmaku ?? DanmakuCoordinator()
        self.dandanplayStore = dandanplayStore
    }

    var dandanplayGatewayURL: URL { dandanplayStore.gatewayURL }

    var dandanplayGatewayURLString: String {
        dandanplayStore.gatewayURLString ?? DandanplaySettingsStore.defaultGatewayURL.absoluteString
    }

    var dandanplayAPIKey: String { dandanplayStore.apiKey }

    /// 是否已配置就绪（地址有效 + API Key 非空）。播放匹配前据此降级到无弹幕。
    var dandanplayIsConfigured: Bool { dandanplayStore.isConfigured }
    var dandanplayHasAPIKey: Bool { !dandanplayStore.apiKey.isEmpty }

    /// 提交网关地址 + Key：先落盘再重启当前播放的弹幕（避免把新地址配旧 Key）
    /// ——重启动作由播放链路（AppModel）在收到更新后触发。
    func updateGateway(urlString: String, apiKey: String) {
        dandanplayStore.gatewayURLString = urlString
        dandanplayStore.apiKey = apiKey
    }
}
