import Foundation

/// 「打开播放源」失败的**类别**。
///
/// ## 为什么要有它
///
/// 在此之前，打开失败只落一个 `setupError: String?`，所有失败被糊成一句话。
/// 后果有三层：
/// 1. 用户看到的文案分不清「网络断了」和「这台设备解不了这个格式」，而这两件的
///    处理方式完全相反（换网 / 换源、换内核）；
/// 2. 自动换源（L1）无法分派——不知道失败原因就不知道该不该换、该换哪一条；
/// 3. 诊断日志里 `open 失败 error=...` 是一句话，聚合不出「今晚失败主要是什么类」。
///
/// 所以分类放在**写入 `setupError` 的那一处**做，UI 与日志都拿到同一份判断。
///
/// ## 判据可以怎么被证伪
///
/// 把一次网络超时（`NSURLErrorTimedOut` / 「连接媒体服务器超时」）硬塞成 `.format`，
/// 那么错误徽章必须显示「格式」类的文案、且 `allowsSourceFailover` 的走向随之改变
/// —— 只要分类函数写错，这两个观察点都会立刻偏。
enum PlaybackOpenErrorKind: String, Hashable, Sendable, CaseIterable {
    /// 连不上：超时、DNS、连接被拒、断网。
    case network
    /// 连上了但解不了：容器 / 编码 / 采样格式不被内核支持。
    case format
    /// 鉴权：401/403、令牌过期、地址需要重新登录。
    case auth
    /// 服务端 5xx、返回体不是可播流。
    case server
    /// 主动放弃：换片、用户取消、代次让位。**不算失败**，不弹错误徽章。
    case aborted
    /// 归不出来的。默认按可重试处理（宁可多试一次，不要卡死在未知）。
    case unknown

    /// 用户可见的短标签。徽章文案由它开头，因此「分类错了」在界面上是可见的。
    var label: String {
        switch self {
        case .network: return "网络"
        case .format: return "格式不支持"
        case .auth: return "鉴权失败"
        case .server: return "服务器错误"
        case .aborted: return "已取消"
        case .unknown: return "播放失败"
        }
    }

    /// 这条请求整体重试（`retryPlayback` / 用户点重试）有没有意义。
    ///
    /// `.aborted` 是一次主动放弃，重试只会把用户刚取消的东西又拉起来；
    /// 其余都值得重试——包括 `.auth`：用户可能刚好在设置里修好了地址。
    var isRetryable: Bool {
        self != .aborted
    }

    /// 还有备用源时，**要不要自动换到下一条源**。
    ///
    /// 这个判断是 L1 的核心分派：
    /// * `.network` / `.server` —— 换源最可能有效：多版本条目常常是不同路径、
    ///   不同协议（直连 / HLS），一条通不了另一条常常通。
    /// * `.format` —— 换源也可能有效：首选源是「能直连的」，换到「需要直流的」
    ///   那条往往能被服务端转成内核吃得下的格式。
    /// * `.auth` —— 换源无效：两条源用的是同一份凭据，失败在令牌不在流。
    /// * `.aborted` —— 换源会违背用户意图。
    var allowsSourceFailover: Bool {
        switch self {
        case .network, .format, .server, .unknown: return true
        case .auth, .aborted: return false
        }
    }

    /// 分类：优先看错误对象本身（domain + code），再退回消息文本。
    ///
    /// ⚠️ 消息文本匹配是**过渡手段**：`finishOpenFailure` 的入参目前是
    /// `String`（内核只给出一句话）。等内核侧把错误码结构化之后，这里应该
    /// 只留 `error:` 那条重载，文本匹配整段删掉——**否则它会变成第二套真相**。
    static func classify(_ error: Error) -> PlaybackOpenErrorKind {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorDNSLookupFailed:
                return .network
            case NSURLErrorUserAuthenticationRequired,
                 NSURLErrorUserCancelledAuthentication:
                return .auth
            case NSURLErrorCancelled:
                return .aborted
            default:
                break
            }
        }
        return classify(message: error.localizedDescription)
    }

    /// 分类：只拿到一句话时用（当前生产路径主要走这条）。
    static func classify(message: String) -> PlaybackOpenErrorKind {
        let text = message.lowercased()
        // 取消类先判：它常与「网络中断」的文案混在一起，但语义是主动放弃。
        if text.contains("取消") || text.contains("cancel") || text.contains("让位") {
            return .aborted
        }
        if text.contains("超时") || text.contains("timeout") || text.contains("timed out")
            || text.contains("连接") || text.contains("网络")
            || text.contains("connection") || text.contains("network")
            || text.contains("unreachable") || text.contains("offline")
            || text.contains("host") || text.contains("socket")
            || text.contains("dns") || text.contains("拒绝") {
            return .network
        }
        if text.contains("401") || text.contains("403")
            || text.contains("鉴权") || text.contains("认证")
            || text.contains("令牌")
            || text.contains("unauthorized") || text.contains("forbidden")
            || text.contains("token") {
            return .auth
        }
        if text.contains("解码") || text.contains("格式") || text.contains("不支持")
            || text.contains("codec") || text.contains("format")
            || text.contains("demux") || text.contains("parse") {
            return .format
        }
        if text.contains("500") || text.contains("502")
            || text.contains("503") || text.contains("504")
            || text.contains("服务器") || text.contains("server") {
            return .server
        }
        return .unknown
    }

    /// 把原始错误文案包装成**带类别标签**的一句，作为 `setupError` 落下去。
    ///
    /// 为什么要改写入的内容而不是只在 UI 拼：`setupError` 同时被诊断日志、
    /// 后台恢复观察、loading 撤销判据读取。分类在写入处完成，三处读者就都拿到
    /// 同一份判断，不会出现「日志说网络、徽章说格式」。
    func decorate(rawMessage: String) -> String {
        // `.unknown` 不加前缀：它没提供任何信息，加了只是噪音。
        guard self != .unknown else { return rawMessage }
        return "\(label)：\(rawMessage)"
    }
}
