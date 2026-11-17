import Foundation

/// 直连输入弹窗（`URLEntrySheet`）接受什么。
///
/// 只放行两类：
/// 1. `http` / `https` 直链（Jellyfin/Emby 的 stream 地址、任意直链流）；
/// 2. 本地文件绝对路径（`/…` 或 `~/…`）。
///
/// 其余一律挡住。以前不校验，`file:` 或乱码串会一路揣进内核，错误只能等到播放页
/// 才冒出来（用户看到一句「打开失败」，看不出是自己输错了）；`smb:` / `ftp:` 这类
/// 内核也不支持。本地文件本来就该走 `⌘O`（fileImporter，带 security scope），
/// 这里只兜「手输路径」这一手。
///
/// 相对路径不认：工作目录随启动方式变，同一串在不同启动方式下指向不同文件。
enum DirectLinkInput {
    static func isAcceptable(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let url = URL(string: trimmed), let scheme = url.scheme else {
            return isLocalPath(trimmed)
        }
        switch scheme.lowercased() {
        case "http", "https":
            return url.host()?.isEmpty == false
        default:
            return false
        }
    }

    /// 只认绝对路径与 `~` 展开式；调用方负责 trim。
    private static func isLocalPath(_ raw: String) -> Bool {
        raw.hasPrefix("/") || raw.hasPrefix("~/")
    }
}
