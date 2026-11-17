import Foundation
import Network

/// 网络路径监听：Wi-Fi ↔ 蜂窝、插拔网线、Tailscale 起停都会改变「服务器的哪条
/// 地址现在通」。路径一变就**作废地址决议**（下一个请求重新探活），而不是等某个
/// 在途请求先超时 30 秒才发现。
///
/// 刻意不在路径变化时立刻探活：系统在切换网络时会连发几次路径更新（先
/// unsatisfied 再 satisfied），当场探活容易拿到中间态的结论。这里只作废 + 去抖，
/// 真正探活留给下一个请求 —— 用户此刻多半正在等首屏，那一步本来就顺路。
@MainActor
final class ServerEndpointMonitor {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.jumusu.ocplayer.network-path")
    private var debounce: Task<Void, Never>?
    private var onChange: (@MainActor () -> Void)?
    private var isRunning = false
    /// `NWPathMonitor.start` 会**立刻**投递一次「当前路径」，那不是变化而是初始
    /// 状态。不把它跳掉的话，启动 500ms 后就会作废一次刚预热好的地址结论
    /// （`attachEndpoints` 的预热探活正好落在这个窗口里），首屏第一波请求要白等
    /// 一轮探活（黑洞候选每个最长 2s）。
    private var hasSeenInitialPath = false

    /// 路径变化后的去抖窗口：等系统把这一串更新发完再落地。
    private let debounceInterval: Duration = .milliseconds(500)

    func start(onChange: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        isRunning = true
        hasSeenInitialPath = false
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleChange()
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        debounce?.cancel()
        debounce = nil
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        onChange = nil
    }

    private func scheduleChange() {
        // 启动时那一次投递是「现在是什么路径」，不是「路径变了」。
        // 跳过它不妨碍真正的恢复：网络起初就不通时，等它恢复会再发一次更新。
        guard hasSeenInitialPath else {
            hasSeenInitialPath = true
            return
        }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: self?.debounceInterval ?? .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}
