import DiagnosticsKit
import Foundation
import JellyfinKit

/// 服务器地址决议在 App 层的接线。
///
/// 包层（`ServerEndpointDirectory`）负责「哪条地址现在最快」，App 层只做两件事：
///
/// 1. **把结论持久化**：决议器跑在后台线程，而 `ServerStore` 的写入必须留在主线程
///    （`UserDefaults` 变更通知 → SwiftUI 观察者 → UI 锁，后台写会和主线程读构成
///    ABBA 互等，MoviePilotStore 上实测过），所以回调一律 `@MainActor` 落地。
/// 2. **让界面跟着换**：`serverEndpointURL` 是 `@Observable` 状态，换址即触发读它的
///    视图重算；氛围轮播的装载触发键也并入了它（池子里的图片 URL 会一起作废）。
///    其余卡片的取图 URL 是渲染时算的，会在下一次重渲染时自然跟上 —— 换址发生在
///    首屏请求之前（预热探活）或请求失败当场，正常情况下用户看不到中间态。
extension AppModel {

    /// 会话落地（登录 / 启动恢复 / 切换服务器）后挂上地址决议。
    ///
    /// `sessionConfiguration` 是测试注入口（让探活走 URLProtocol mock），
    /// 业务调用不用传。
    ///
    /// **调用前必须已经把 `server` 指到这个会话**（`activate(server:)` 就是这个
    /// 顺序）：下面的对齐要走 `serverEndpointChanged`，它有「回调属不属于当前会话」
    /// 的守卫，`server` 还是 nil 时会被整条丢掉。
    func attachEndpoints(
        to server: any MediaServer,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        let profile = server.profile
        serverEndpointURL = profile.baseURL
        let directory = store.endpointDirectory(for: profile, sessionConfiguration: sessionConfiguration)
        directory.setChangeHandler { [weak self] url in
            // 决议器在后台线程回调；写档案 + 改界面都在主线程做。
            Task { @MainActor [weak self] in
                self?.serverEndpointChanged(to: url, profileID: profile.id)
            }
        }
        // 决议器可能**一开始**就不在 `baseURL` 上：档案被固定到了另一个地址时，
        // 上面创建 / 取用决议器的那一步（`sync`）已经把生效地址换成固定项了，而
        // 那次变更发生在 handler 注册之前、通知丢了。这里补一次对齐，让界面与档案
        // 跟随真正生效的地址（否则会出现「请求走 Tailscale，界面显示局域网」）。
        applyEndpoint(directory.currentURL, profileID: profile.id, announce: false)
        // 立刻探活一次，而不是等第一个请求来触发：登录完成到首屏请求之间本来就
        // 有几十毫秒，探活正好并行跑完，首屏就用上了正确的地址。
        Task { await directory.refresh() }
    }

    /// 决议器选中了另一条地址。
    func serverEndpointChanged(to url: URL, profileID: String) {
        applyEndpoint(url, profileID: profileID, announce: true)
    }

    /// 落地一条生效地址。
    ///
    /// `announce` 区分「真的换址了」与「会话建立时的对齐」：对齐时地址通常没变，
    /// 但**固定模式下也可能变**（档案固定了另一条），那种变化值得记一条日志 ——
    /// 所以判据是地址有没有真的变，而不是调用来源。此前不分青红皂白地记
    /// 「服务器地址切换」，启动日志里每会话必有一条假切换，排查 Tailscale 是否
    /// 生效时会被它误导。
    private func applyEndpoint(_ url: URL, profileID: String, announce: Bool) {
        // 旧会话迟到的回调：换服务器之后不该再动新会话的显示与档案。
        guard server?.profile.id == profileID else { return }
        let previous = serverEndpointURL
        serverEndpointURL = url
        store.markActiveURL(url, for: profileID)
        guard announce else { return }
        guard previous == nil || !ServerAddress.isSame(previous!, url) else { return }
        AppDiagnostics.logInfo(
            "服务器地址切换",
            fields: [
                "server": .string(profileID),
                "from": .string(previous?.absoluteString ?? "—"),
                "url": .string(url.absoluteString),
            ])
    }

    /// 网络路径变化 / 应用回前台：作废所有地址结论，下一次请求重新探活。
    func invalidateServerEndpoints() {
        store.invalidateEndpoints()
    }

    /// 启动网络路径监听（`bootstrap` 里调一次）。
    func startEndpointMonitor() {
        endpointMonitor.start { [weak self] in
            self?.invalidateServerEndpoints()
        }
    }

    // MARK: - 管理页用

    /// 探活一个档案的**全部**候选地址（不改变当前生效地址），按延迟从快到慢。
    /// 管理页用它显示「哪条通、多快、现在在用哪条」。
    ///
    /// 入参只当**身份**用（`profile.id`），候选地址一律现取 store 里的最新档案：
    /// 视图手里那份是渲染时的快照，拿它去同步决议器会把刚添加的地址从候选里抹掉
    /// （`ServerEndpointDirectory.sync` 以传入档案为准）。
    func probeAddresses(for profile: ServerProfile) async -> [ServerProbeResult] {
        guard let latest = store.profiles.first(where: { $0.id == profile.id }) else { return [] }
        return await store.endpointDirectory(for: latest).probeAllCandidates()
    }

    /// 「添加地址」的结果。视图只做展示，判断都在这里 —— 尤其是
    /// `differentServer`：地址通、但那是另一台服务器，绝不能并进当前档案。
    enum AddAddressOutcome: Equatable {
        case added
        /// 地址已在列表里（含与当前生效地址相同）。
        case duplicate
        /// 可达，但报的是另一个服务器 ID。
        case differentServer(serverID: String?)
        /// 连不上（超时 / 拒绝连接 / 不是 Jellyfin·Emby）。
        case unreachable
        /// 地址本身填得不对（解析不出 host）。
        case invalidAddress
        /// 档案已经不在了（边操作边被删）。
        case missingProfile
    }

    /// 校验并添加一个备选地址。
    ///
    /// 探测带**当前会话的认证头**（同一台服务器 token 通用），因此不依赖匿名访问；
    /// `expectedServerID` 用档案里的服务器 ID，地址指向别的机器时直接判
    /// `differentServer` 而不是默默存下来 —— 存下来会在切过去时把会话指向别家。
    ///
    /// `sessionConfiguration` 是测试注入口（让校验走 URLProtocol mock），
    /// 业务调用不用传。
    func addAddress(
        _ raw: String,
        to profile: ServerProfile,
        scheme: ServerScheme?,
        allowUnreachable: Bool = false,
        sessionConfiguration: URLSessionConfiguration = .default
    ) async -> AddAddressOutcome {
        guard let normalized = try? MediaServerLogin.normalizeServerURL(raw, preferredScheme: scheme) else {
            return .invalidAddress
        }
        // Emby 的 API 固定在 `/emby` 前缀下，**档案里的每个地址都必须带它**：
        // 请求地址是在 base 路径之后拼的（`EmbySession.url(path:)`），一条没前缀的
        // 候选被选中后全链路 404，而 404 不是「地址不通」，不会触发换址 —— 会卡死。
        // 登录流程由 `MediaServerLogin.start` 补前缀，这里是唯一的手工入口，
        // 必须用同一个函数补。
        let url = profile.kind == .emby ? MediaServerLogin.embyAPIBaseURL(from: normalized) : normalized
        guard store.profiles.contains(where: { $0.id == profile.id }) else {
            return .missingProfile
        }
        // 用 store 里的最新档案判重（视图手里那份可能是渲染时的快照）。
        let current = store.profiles.first(where: { $0.id == profile.id }) ?? profile
        if current.allAddresses.contains(where: { ServerAddress.isSame($0.url, url) }) {
            return .duplicate
        }
        let authorizationHeader = server?.profile.id == profile.id ? server?.authorizationHeader : nil
        let check = await ServerProbe.check(
            url: url,
            authorizationHeader: authorizationHeader,
            expectedServerID: current.resolvedServerID,
            sessionConfiguration: sessionConfiguration)
        switch check {
        case .differentServer(let serverID):
            return .differentServer(serverID: serverID)
        case .unreachable:
            // 允许「明知现在连不上也先存下来」：典型场景是在没有 Tailscale 的
            // 网络里先把家里那条地址填好，回头出门（或回家）就自动用上了。
            guard allowUnreachable else { return .unreachable }
            return store.addAddress(url, to: profile.id) ? .added : .duplicate
        case .reachable:
            return store.addAddress(url, to: profile.id) ? .added : .duplicate
        }
    }
}
