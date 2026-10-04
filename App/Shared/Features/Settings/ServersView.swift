import AppDesignKit
import JellyfinKit
import SwiftUI

/// 「管理服务器」子页：全部已存档案（含正在使用的）的切换与删除。
///
/// 主设置页只保留当前服务器信息与启动默认选择；列表操作收进这里后，
/// 当前服务器也出现在列表里（带「使用中」标），不再需要先「连接其它服务器」
/// 才能看到自己的档案。删除连 token 一起清，不可恢复，走二次确认。
///
/// 每行还能展开管理这台服务器的**多个地址**（局域网 / Tailscale / 反代域名）：
/// 默认并发探活、自动用最快可达的那条，用户也可以固定走某一条。
struct ServersView: View {
    @Environment(AppModel.self) private var app

    /// 待确认删除的已保存服务器档案（删除连 token 一起清，不可恢复）。
    @State private var pendingDeleteProfile: ServerProfile?
    /// 待确认删除的单条地址。
    @State private var pendingAddressRemoval: PendingAddressRemoval?
    /// 「添加地址」弹窗的目标档案。
    ///
    /// **用 `.sheet(item:)` 而不是 `.sheet(isPresented:)` + 另一个状态**：后者在
    /// macOS 上会用「翻转 isPresented 那一次之前」的 body 去求内容闭包，于是
    /// `addAddressTarget` 还是 nil、弹出一个**空** sheet —— 空 sheet 连「取消」
    /// 按钮都没有，而它是模态的，窗口就此点不动（实机现象：白色小方块 + 像卡死）。
    @State private var addAddressTarget: ServerProfile?
    /// 展开中的服务器。首次展开顺手探一次活，用户不必先点「重新检测」。
    @State private var expandedProfileIDs: Set<String> = []
    /// 探活进行中的服务器（按钮转圈 + 防重复点）。
    @State private var probingProfileIDs: Set<String> = []
    /// 各档案最近一次的探活结果（key = profile.id）。**没有 key = 还没探过**，
    /// 这时不显示「不可达」——没结论不等于连不上。
    @State private var probeResults: [String: [ServerProbeResult]] = [:]
    /// `ServerStore` 不是 `@Observable`：地址增删 / 固定改完视图不会自己刷新。
    /// 改完 store 就 +1 让 body 重算（依赖在 body 第一行读出来）。
    @State private var addressRevision = 0
    /// 刚检测完、正在「短暂露出延迟」的档案。见 `revealLatency(for:)`。
    @State private var latencyReveal: Set<String> = []
    /// 上面那个短暂窗口的定时器，按档案记（重复点检测要重置而不是叠加）。
    @State private var latencyRevealTasks: [String: Task<Void, Never>] = [:]

    /// 「使用中 / 已固定」把延迟露出来多久。够看清数字，又不至于长期挤掉状态标记。
    private static let latencyRevealDuration: Duration = .seconds(5)

    var body: some View {
        // 刻意「读了不用」：这一行让 body 依赖 addressRevision。
        let _ = addressRevision

        Form {
            Section {
                ForEach(app.store.profiles) { profile in
                    row(for: profile)
                }
            } footer: {
                Text("正在使用的服务器不能删除；想删它先退出 Jellyfin 登录。默认启动的服务器带星标。展开一行可以管理这台服务器的多个地址。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("管理服务器")
        .confirmationDialog(
            "删除服务器？",
            isPresented: Binding(
                get: { pendingDeleteProfile != nil },
                set: { if !$0 { pendingDeleteProfile = nil } }
            ),
            presenting: pendingDeleteProfile
        ) { profile in
            Button("删除「\(profile.serverName)」", role: .destructive) {
                app.store.remove(id: profile.id)
                pendingDeleteProfile = nil
            }
        } message: { _ in
            Text("服务器地址与登录凭据会一起删除。下次想用这台需要重新输入地址并登录。")
        }
        .confirmationDialog(
            "删除这个地址？",
            isPresented: Binding(
                get: { pendingAddressRemoval != nil },
                set: { if !$0 { pendingAddressRemoval = nil } }
            ),
            presenting: pendingAddressRemoval
        ) { removal in
            Button("删除这条地址", role: .destructive) {
                app.store.removeAddress(removal.url, from: removal.profileID)
                // 地址列表变了，旧探活结论已经对不上号，清掉等下次重探。
                probeResults[removal.profileID] = nil
                addressRevision += 1
                pendingAddressRemoval = nil
            }
        } message: { removal in
            Text(removalMessage(removal))
        }
        .sheet(item: $addAddressTarget) { profile in
            AddAddressSheet(profile: profile) {
                // 地址列表变了：清掉旧结论再重探一遍。`probeAddresses` 按
                // profile.id 现取 store 里的最新档案，所以这里带的是旧快照也安全。
                probeResults[profile.id] = nil
                addressRevision += 1
                Task { await probe(profile) }
            }
        }
    }

    // MARK: - 服务器行

    @ViewBuilder
    private func row(for profile: ServerProfile) -> some View {
        let isCurrent = profile.id == app.server?.profile.id
        let activeURL = effectiveURL(for: profile)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: profile.kind == .emby ? "tv" : "server.rack")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(profile.serverName).font(.callout)
                        Text(profile.kind.displayName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        if app.store.defaultServerID == profile.id {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("启动默认")
                        }
                        if isCurrent {
                            Text("使用中")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                        } else if app.store.token(for: profile) == nil {
                            Text("需重新登录").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    // 这一行显示**当前生效**地址（当前会话走的是决议器选中的那条，
                    // 未必还是档案里的 baseURL）；其它档案没有运行时会话，看 baseURL。
                    Text(activeURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if !isCurrent {
                    Button("切换") {
                        Task { await app.switchToServer(profile) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(role: .destructive) {
                        pendingDeleteProfile = profile
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            addressSection(for: profile, activeURL: activeURL)
        }
    }

    /// 当前会话的档案用 `serverEndpointURL`（决议器选中的那条），其它档案用 baseURL。
    private func effectiveURL(for profile: ServerProfile) -> URL {
        guard profile.id == app.server?.profile.id else { return profile.baseURL }
        return app.serverEndpointURL ?? profile.baseURL
    }

    // MARK: - 地址管理（展开区）

    @ViewBuilder
    private func addressSection(for profile: ServerProfile, activeURL: URL) -> some View {
        let addresses = profile.allAddresses
        DisclosureGroup(isExpanded: expansionBinding(for: profile)) {
            VStack(alignment: .leading, spacing: 10) {
                modeRow(for: profile, activeURL: activeURL)
                ForEach(addresses) { address in
                    addressRow(address, for: profile, activeURL: activeURL)
                }
                if addresses.count == 1 {
                    Text("至少保留一个地址，暂时不能删除。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    Button("添加地址…") {
                        addAddressTarget = profile
                    }
                    Button {
                        Task { await probe(profile) }
                    } label: {
                        if probingProfileIDs.contains(profile.id) {
                            ProgressView().controlSize(.small).padding(.horizontal, 6)
                        } else {
                            Text("重新检测")
                        }
                    }
                    .disabled(probingProfileIDs.contains(profile.id))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 6)
            .padding(.leading, 2)
        } label: {
            Text("地址（\(addresses.count)）")
                .font(.callout)
        }
    }

    /// 展开状态自己拿着（默认折叠）：首次展开顺手探一次活。
    private func expansionBinding(for profile: ServerProfile) -> Binding<Bool> {
        Binding(
            get: { expandedProfileIDs.contains(profile.id) },
            set: { isExpanded in
                if isExpanded {
                    expandedProfileIDs.insert(profile.id)
                    if probeResults[profile.id] == nil {
                        Task { await probe(profile) }
                    }
                } else {
                    expandedProfileIDs.remove(profile.id)
                }
            }
        )
    }

    /// 自动择优 / 已固定的说明与切换。固定是「不再自动换」的代价，得写清楚。
    @ViewBuilder
    private func modeRow(for profile: ServerProfile, activeURL: URL) -> some View {
        let pinned = profile.pinnedURL
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: pinned == nil ? "antenna.radiowaves.left.and.right" : "pin.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if let pinned {
                    Text("已固定到 \(pinned.absoluteString)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("固定后不再自动切换：这条地址不通时会直接报错，换到别的网络也一样。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("自动择优")
                        .font(.caption)
                    Text("并发探测全部地址，用现在最快的那条；请求失败或网络变化时自动换。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if pinned == nil {
                Button("固定当前地址") {
                    app.store.setPinnedAddress(activeURL, for: profile.id)
                    addressRevision += 1
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("恢复自动选择") {
                    app.store.setPinnedAddress(nil, for: profile.id)
                    addressRevision += 1
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func addressRow(
        _ address: ServerAddress,
        for profile: ServerProfile,
        activeURL: URL
    ) -> some View {
        let results = probeResults[profile.id]
        let isPinned = profile.pinnedURL.map { ServerAddress.isSame($0, address.url) } ?? false
        let isActive = !isPinned && ServerAddress.isSame(activeURL, address.url)
        let probeResult = results?.first(where: { ServerAddress.isSame($0.url, address.url) })
        let status = ServerAddressStatus.resolve(
            isPinned: isPinned,
            isActive: isActive,
            latencyMilliseconds: probeResult.map { Int(($0.latency * 1000).rounded()) },
            probed: results != nil,
            revealLatency: latencyReveal.contains(profile.id))
        HStack(spacing: 8) {
            Image(systemName: Self.icon(for: address.kind))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(address.kind.displayName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)
            Text(address.url.absoluteString)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            statusLabel(status)
            if profile.allAddresses.count > 1 {
                Button(role: .destructive) {
                    pendingAddressRemoval = PendingAddressRemoval(
                        profileID: profile.id,
                        serverName: profile.serverName,
                        url: address.url,
                        isActive: isActive,
                        isPinned: isPinned
                    )
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("删除地址 \(address.url.absoluteString)")
            }
        }
    }

    /// 状态标记：固定 > 使用中 > 延迟 > 不可达。没探过就什么都不显示。
    ///
    /// 判定抽到 `ServerAddressStatus`（纯值，可单测）：这里只负责把结论画出来。
    @ViewBuilder
    private func statusLabel(_ status: ServerAddressStatus) -> some View {
        switch status {
        case .pinned, .active:
            // 带延迟时也要等宽数字：读完就退回状态标记，行内不要抖。
            Text(status.text ?? "")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.tint)
        case .reachable:
            Text(status.text ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        case .unreachable:
            Text(status.text ?? "")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .unknown:
            EmptyView()
        }
    }

    // MARK: - 动作

    /// 探活全部地址，只更新管理页的显示，不动当前生效地址（那是决议器的事）。
    private func probe(_ profile: ServerProfile) async {
        guard !probingProfileIDs.contains(profile.id) else { return }
        probingProfileIDs.insert(profile.id)
        let results = await app.probeAddresses(for: profile)
        probeResults[profile.id] = results
        probingProfileIDs.remove(profile.id)
        revealLatency(for: profile.id)
    }

    /// 检测刚跑完：这几秒里连「使用中 / 已固定」那条也把延迟显示出来。
    ///
    /// 这两条平时只显示状态标记（状态比数字重要，常显会稀释重点），但用户点
    /// 「重新检测」就是冲着数字来的 —— 把正在用的那条藏起来最说不通。看完自动退回。
    private func revealLatency(for profileID: String) {
        latencyRevealTasks[profileID]?.cancel()
        latencyReveal.insert(profileID)
        latencyRevealTasks[profileID] = Task {
            try? await Task.sleep(for: Self.latencyRevealDuration)
            guard !Task.isCancelled else { return }
            latencyReveal.remove(profileID)
            latencyRevealTasks[profileID] = nil
        }
    }

    private func removalMessage(_ removal: PendingAddressRemoval) -> String {
        if removal.isPinned {
            return "「\(removal.serverName)」将恢复自动择优，不再固定走这条地址。"
        }
        if removal.isActive {
            return "这是「\(removal.serverName)」当前正在用的地址，删除后会换用列表里的其它地址。"
        }
        return "「\(removal.serverName)」会少一个入口，需要时可以再加回来。服务器上的数据不受影响。"
    }

    private static func icon(for kind: ServerAddress.Kind) -> String {
        switch kind {
        case .lan: "house"
        case .tailscale: "network"
        case .remote: "globe"
        }
    }

    /// 待确认删除的单条地址。标记在点垃圾桶时就算好：确认框要说清「删掉之后会
    /// 怎样」，而对话框弹出时再去比对，看到的就不是当时的状态了。
    private struct PendingAddressRemoval: Identifiable {
        let profileID: String
        let serverName: String
        let url: URL
        let isActive: Bool
        let isPinned: Bool
        var id: String { profileID + "|" + url.absoluteString }
    }
}

// MARK: - 地址行的状态标记

/// 地址行右侧那一格的显示结论。
///
/// 抽成纯值是为了可测：这格的优先级是个「静默出错」的地方 —— 早先「使用中 / 已固定」
/// 永远盖掉延迟，用户点完检测想看的偏偏就是那条数字，界面上却看不到，而且没人会为
/// 这种细节写回归。现在的规则：
///
/// - 平时：状态标记优先（状态比数字重要，两条常显会互相稀释）；
/// - 刚检测完的那几秒（`revealLatency`）：「使用中 / 已固定」后面补上延迟数字；
/// - 没检测过（`unknown`）什么都不显示 —— 没结论不等于连不上。
enum ServerAddressStatus: Equatable {
    case pinned(latencyMilliseconds: Int?)
    case active(latencyMilliseconds: Int?)
    case reachable(latencyMilliseconds: Int)
    case unreachable
    case unknown

    static func resolve(
        isPinned: Bool,
        isActive: Bool,
        latencyMilliseconds: Int?,
        probed: Bool,
        revealLatency: Bool
    ) -> ServerAddressStatus {
        // 只在「刚检测完」这个窗口里把数字带出来；平时非使用中的行照旧常显延迟。
        let revealed = revealLatency ? latencyMilliseconds : nil
        if isPinned { return .pinned(latencyMilliseconds: revealed) }
        if isActive { return .active(latencyMilliseconds: revealed) }
        if let latencyMilliseconds { return .reachable(latencyMilliseconds: latencyMilliseconds) }
        return probed ? .unreachable : .unknown
    }

    /// 展示文字；`unknown` 为 nil（什么都不显示）。
    var text: String? {
        switch self {
        case .pinned(let milliseconds):
            return milliseconds.map { "已固定 · \($0) ms" } ?? "已固定"
        case .active(let milliseconds):
            return milliseconds.map { "使用中 · \($0) ms" } ?? "使用中"
        case .reachable(let milliseconds):
            return "\(milliseconds) ms"
        case .unreachable:
            return "不可达"
        case .unknown:
            return nil
        }
    }
}

// MARK: - 添加地址
/// 「添加地址」弹窗。校验与「能不能并进这台服务器」的判断都在
/// `AppModel.addAddress` 里，这里只收集输入、把结论翻译成人话。
///
/// `.unreachable` 是唯一还能继续的分支：此刻连不上不等于地址没用
/// （典型场景是当下不在 Tailscale 网络里，但家里那条地址要先存好）。
private struct AddAddressSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let profile: ServerProfile
    /// 添加成功：让列表刷新并清掉这台服务器的探活缓存。
    let onAdded: () -> Void

    @State private var text = ""
    @State private var scheme: ServerScheme = .http
    @State private var isSubmitting = false
    @State private var failure: Failure?

    /// 携数据而不是携拼好的字符串：文案要在视图里以字面量渲染
    /// （`Text` 只对字面量做 Markdown 解析，先拼成 String 就没有粗体了）。
    private enum Failure: Equatable {
        case duplicate
        case differentServer(serverID: String?)
        case unreachable
        case invalidAddress
        case missingProfile
    }

    init(profile: ServerProfile, onAdded: @escaping () -> Void) {
        self.profile = profile
        self.onAdded = onAdded
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("服务器地址")
                            .font(.subheadline.weight(.semibold))
                        TextField(
                            "",
                            text: $text,
                            prompt: Text("例如 100.64.1.20:8096 或 nas.example.ts.net:8096")
                        )
                        .textContentType(.URL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .onSubmit { Task { await submit(allowUnreachable: false) } }
                        Text("可以不打 http:// 前缀；Tailscale 请填 100.x 地址或 MagicDNS 名字。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("协议")
                            .font(.subheadline.weight(.semibold))
                        Picker("协议", selection: $scheme) {
                            Text("HTTP").tag(ServerScheme.http)
                            Text("HTTPS").tag(ServerScheme.https)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if let failure {
                        VStack(alignment: .leading, spacing: 8) {
                            failureNotice(failure)
                            if failure == .unreachable {
                                Button("仍然添加") {
                                    Task { await submit(allowUnreachable: true) }
                                }
                                .disabled(isSubmitting)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .navigationTitle("添加地址")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit(allowUnreachable: false) }
                    } label: {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("添加")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isSubmitting)
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 380)
        #endif
    }

    @ViewBuilder
    private func failureNotice(_ failure: Failure) -> some View {
        // 「连不上」是让用户做决定，不是报错，用次要色；其余四种是明确的失败。
        Label {
            failureText(failure).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: failure == .unreachable
                  ? "wifi.exclamationmark" : "exclamationmark.triangle")
        }
        .font(.callout)
        .foregroundStyle(failure == .unreachable ? Color.secondary : Color.red)
    }

    private func failureText(_ failure: Failure) -> Text {
        switch failure {
        case .duplicate:
            Text("这个地址已经在列表里了。")
        case .differentServer(let serverID):
            Text("这个地址能连上，但它是**另一台**服务器（ID \(serverID ?? "未知")），不能并入「\(profile.serverName)」。如果你想添加的是新服务器，请用「连接其它服务器」。")
        case .unreachable:
            Text("现在连不上这个地址。如果只是此刻不在那条网络里（例如 Tailscale 没开、人在外面），可以先存下来，回到那条网络就会自动用上。")
        case .invalidAddress:
            Text("地址格式不对，试试 100.64.1.20:8096 这样的写法。")
        case .missingProfile:
            Text("这台服务器已不在列表里。")
        }
    }

    private var isValid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit(allowUnreachable: Bool) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        let outcome = await app.addAddress(
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            to: profile,
            scheme: scheme,
            allowUnreachable: allowUnreachable
        )
        isSubmitting = false
        switch outcome {
        case .added:
            onAdded()
            dismiss()
        case .duplicate:
            failure = .duplicate
        case .differentServer(let serverID):
            failure = .differentServer(serverID: serverID)
        case .unreachable:
            failure = .unreachable
        case .invalidAddress:
            failure = .invalidAddress
        case .missingProfile:
            failure = .missingProfile
        }
    }
}
