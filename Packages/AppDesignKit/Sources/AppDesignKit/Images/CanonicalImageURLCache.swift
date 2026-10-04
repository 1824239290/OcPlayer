import DiagnosticsKit
import Foundation

/// 图片磁盘缓存的 URL 键规范化。
///
/// ## 为什么需要它
///
/// `URLCache` 拿**完整 URL** 当键，而图片 URL 里含服务器地址：
///
///     http://192.168.5.107:8096/Items/{id}/Images/Thumb?maxWidth=720&tag=...
///     http://100.127.128.96:8096/Items/{id}/Images/Thumb?maxWidth=720&tag=...
///
/// 同一台服务器的两条入口（局域网 / Tailscale / 反代）会让**同一张图**存成两份，
/// 且换地址后**全部海报重新下载一遍** —— 而「多条地址自动择优、换了无缝续用」
/// 正是这个 App 明确支持的能力（见 `ServerEndpointDirectory`）。实测用户库上
/// 110 MB 的图片缓存里就有相当一部分是这种重复。
///
/// 规范化把 scheme + host 换成固定值，只保留**路径与查询**：
///
///     http://ocplayer.invalid/Items/{id}/Images/Thumb?maxWidth=720&tag=...
///
/// ## 键里为什么还要带认证头哈希
///
/// 丢掉 host 之后，「不同服务器上 id 恰好相同的条目」会撞键（Jellyfin 的条目 id 是
/// GUID，撞的概率极低但并非不可能）。认证头哈希把键重新绑回**具体那台服务器 + 那个
/// 账号**，同时不影响本条修复的目的：同一台服务器的不同地址共用同一个 token →
/// 哈希相同 → 缓存仍然共享。
///
/// ⚠️ 哈希**必须跨进程稳定**：这是落在磁盘上的键，用 `String.hashValue`
/// （每进程随机播种）会导致**每次启动所有图片缓存全部失效**。所以用
/// `DiagnosticsKit.FNV1a`（同一个实现就是为「派生 id 必须跨启动稳定」引入的，
/// 见 `ServerItemFields.stableHash`）。
enum ImageCacheKey {

    /// 规范化后的固定 host。`.invalid` 是 RFC 2606 保留的顶级域，永远不会被解析，
    /// 而这里造出来的 URL **只当缓存键用、从不出网**（真正发的请求用原 URL）。
    static let placeholderHost = "ocplayer.invalid"

    /// 只规范化媒体服务器的图片端点（路径含 `/Images/`）。
    ///
    /// 其它图源（`image.tmdb.org`、`lain.bgm.tv` 等）本来就只有一条地址，没有这个问题；
    /// 不去动它们可以避免「不同图床路径相同」这种理论上的撞键，也把改动面收在
    /// 真正出事的那一类 URL 上。
    static func isMediaServerImage(_ url: URL) -> Bool {
        url.path.contains("/Images/")
    }

    /// 缓存键。`authHeader` 为 nil（公开图床）时用固定串，保证确定性。
    static func canonicalURL(for url: URL, authHeader: String?) -> URL? {
        guard isMediaServerImage(url) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = placeholderHost
        components.path = url.path
        components.query = url.query
        // 认证身份拼进查询：不同服务器 / 不同账号的键互不可见。
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "_auth", value: authIdentity(authHeader)))
        components.queryItems = items
        return components.url
    }

    /// 认证身份：**只取与「哪台服务器 + 哪个账号」有关的字段**，绝不含版本。
    ///
    /// 客户端身份头长这样：
    /// ```
    /// MediaBrowser Client="OcPlayer", Device="…", DeviceId="…",
    ///               Version="0.2.0 (506)", Token="…"
    /// ```
    /// 其中 `Version` 的构建号 = git 提交数（`Scripts/build-macos.sh` 取 `GIT_COUNT`），
    /// **每次提交/发版都会变**。若把整条头拿去哈希，就等于「每次更新 App 全部图片缓存
    /// 失效」——实测 Build 505 与 506 的哈希确实不同。Device/Client 同理与资源身份无关。
    ///
    /// 所以这里显式挑出 `DeviceId` + `Token`：前者标识安装，后者标识服务器上的账号。
    /// 换账号 / token 轮换会让缓存失效一次（正确：那是另一份可见范围），
    /// 而换地址、升级版本**不再**影响。
    static func authIdentity(_ authHeader: String?) -> String {
        guard let authHeader, !authHeader.isEmpty else { return "none" }
        var identity = ""
        for field in ["DeviceId", "Token"] {
            if let value = headerValue(field, in: authHeader) {
                identity += "\(field)=\(value);"
            }
        }
        // 一个字段都没解析出来（非 Jellyfin/Emby 头的自定义调用）→ 退回整串哈希，
        // 宁可保守地少共享，也不要让两份不同凭证误共用缓存。
        guard !identity.isEmpty else {
            return String(FNV1a.hex(of: authHeader).prefix(12))
        }
        return String(FNV1a.hex(of: identity).prefix(12))
    }

    /// 从 `Key="value", Key2="value2"` 形态的头里取一个字段。
    private static func headerValue(_ field: String, in header: String) -> String? {
        guard let range = header.range(of: "\(field)=\"") else { return nil }
        let rest = header[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }
}

/// 把 URL 键规范化后再交给 `URLCache` 的图片缓存。
///
/// 只重写「取」与「存」两个动作的键，真正的网络请求仍用调用方给的原始 URL
/// （`URLCache` 不参与建连，它只管响应数据的存取）。
///
/// `@unchecked Sendable`：`URLCache` 自己就是线程安全的（内部有锁），本类只做了
/// 纯函数式的键变换，没有额外可变状态——所以继承它的线程安全保证。Swift 要求
/// 子类**重申**这个 conformance（否则报 warning），并非这里真的放松了什么。
final class CanonicalImageURLCache: URLCache, @unchecked Sendable {

    /// 当前请求携带的认证头。
    ///
    /// `URLCache` 的 `cachedResponse(for:)` 只拿到 `URLRequest`，而规范化需要
    /// auth 参与——认证头本来就在请求里，直接从请求读即可，不必额外传参。
    /// （这也意味着键与「实际发出的请求」永远一致，不会出现两处来源不同步。）
    override func cachedResponse(for request: URLRequest) -> CachedURLResponse? {
        guard let canonicalRequest = canonicalized(request) else {
            return super.cachedResponse(for: request)
        }
        guard let stored = super.cachedResponse(for: canonicalRequest) else { return nil }
        // 还原成调用方请求的那个 URL：上层不该看到「另一个地址」的响应。
        return Self.replacingURL(of: stored, with: request.url)
    }

    override func storeCachedResponse(_ cachedResponse: CachedURLResponse, for request: URLRequest) {
        guard let canonicalRequest = canonicalized(request), let canonicalURL = canonicalRequest.url else {
            super.storeCachedResponse(cachedResponse, for: request)
            return
        }
        super.storeCachedResponse(
            Self.replacingURL(of: cachedResponse, with: canonicalURL),
            for: canonicalRequest)
    }

    override func removeCachedResponse(for request: URLRequest) {
        guard let canonicalRequest = canonicalized(request) else {
            super.removeCachedResponse(for: request)
            return
        }
        super.removeCachedResponse(for: canonicalRequest)
    }

    /// 把请求的 URL 换成规范化键；不适用于规范化的 URL 返回 nil（走原路径）。
    private func canonicalized(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url,
              let canonical = ImageCacheKey.canonicalURL(
                for: url,
                authHeader: request.value(forHTTPHeaderField: "Authorization"))
        else { return nil }
        var copy = request
        copy.url = canonical
        return copy
    }

    /// 换掉响应里的 URL，其余（状态码 / 头 / 数据 / 存储策略）原样保留。
    private static func replacingURL(of cached: CachedURLResponse, with url: URL?) -> CachedURLResponse {
        guard let url, let http = cached.response as? HTTPURLResponse,
              let rebuilt = HTTPURLResponse(
                url: url,
                statusCode: http.statusCode,
                httpVersion: nil,
                headerFields: http.allHeaderFields as? [String: String])
        else { return cached }
        return CachedURLResponse(
            response: rebuilt,
            data: cached.data,
            userInfo: cached.userInfo,
            storagePolicy: cached.storagePolicy)
    }
}
