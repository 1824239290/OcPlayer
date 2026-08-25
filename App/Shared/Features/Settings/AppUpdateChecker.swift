import Foundation
import Observation

/// App 版本信息工具
public enum AppVersion {
    public static var currentShortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    public static var currentBuildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    public static var displayString: String {
        "v\(currentShortVersion) (Build \(currentBuildVersion))"
    }

    /// 比较两个版本号（如 "1.2.0" 和 "1.2.1" 或带 "v" 前缀）
    /// - Returns: `.orderedAscending` 表示 remote > current（有新版）
    public static func compare(current: String, remote: String) -> ComparisonResult {
        let cleanCurrent = sanitize(current)
        let cleanRemote = sanitize(remote)

        let v1Components = cleanCurrent.split(separator: ".").compactMap { Int($0) }
        let v2Components = cleanRemote.split(separator: ".").compactMap { Int($0) }

        let maxCount = max(v1Components.count, v2Components.count)
        if maxCount == 0 { return .orderedSame }

        for i in 0..<maxCount {
            let part1 = i < v1Components.count ? v1Components[i] : 0
            let part2 = i < v2Components.count ? v2Components[i] : 0
            if part1 < part2 {
                return .orderedAscending // remote is newer
            } else if part1 > part2 {
                return .orderedDescending // current is newer
            }
        }
        return .orderedSame
    }

    public static func isNewer(remote: String, than current: String = currentShortVersion) -> Bool {
        compare(current: current, remote: remote) == .orderedAscending
    }

    public static func sanitize(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") {
            v.removeFirst()
        }
        // 截取到第一个非数字且非点号的字符（例如 1.0.0-beta -> 1.0.0）
        if let nonNumericIndex = v.firstIndex(where: { !$0.isNumber && $0 != "." }) {
            v = String(v[..<nonNumericIndex])
        }
        return v
    }
}

/// GitHub Release 数据模型
public struct GitHubRelease: Codable, Sendable, Identifiable {
    public var id: String { tagName }
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let publishedAt: Date?
    public let isPrerelease: Bool?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case isPrerelease = "prerelease"
    }

    public init(
        tagName: String,
        name: String? = nil,
        body: String? = nil,
        htmlURL: URL,
        publishedAt: Date? = nil,
        isPrerelease: Bool? = nil
    ) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
    }
}

/// GitHub Release 检查服务
@Observable
@MainActor
public final class AppUpdateChecker {
    public enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate(version: String)
        case updateAvailable(GitHubRelease)
        case failed(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.checking, .checking):
                return true
            case (.upToDate(let v1), .upToDate(let v2)):
                return v1 == v2
            case (.updateAvailable(let r1), .updateAvailable(let r2)):
                return r1.tagName == r2.tagName
            case (.failed(let m1), .failed(let m2)):
                return m1 == m2
            default:
                return false
            }
        }
    }

    public static let shared = AppUpdateChecker()

    public private(set) var state: State = .idle
    public private(set) var lastCheckedDate: Date?

    public let repoOwner: String
    public let repoName: String
    private let session: URLSession

    public init(
        repoOwner: String = "1824239290",
        repoName: String = "OcPlayer",
        session: URLSession = .shared
    ) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.session = session
    }

    public func checkForUpdates() async {
        state = .checking
        do {
            guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
                state = .failed("无效的请求地址")
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 12
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("OcPlayer/\(AppVersion.currentShortVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                state = .failed("服务器响应无效")
                return
            }

            if httpResponse.statusCode == 404 {
                state = .upToDate(version: AppVersion.currentShortVersion)
                lastCheckedDate = Date()
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 403 {
                    state = .failed("GitHub 访问频繁，请稍后重试")
                } else {
                    state = .failed("请求失败 (\(httpResponse.statusCode))")
                }
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let release = try decoder.decode(GitHubRelease.self, from: data)

            lastCheckedDate = Date()

            if AppVersion.isNewer(remote: release.tagName) {
                state = .updateAvailable(release)
            } else {
                state = .upToDate(version: release.tagName)
            }
        } catch {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet:
                    state = .failed("未连接网络")
                case .timedOut:
                    state = .failed("网络超时")
                case .cannotFindHost, .cannotConnectToHost:
                    state = .failed("无法连接 GitHub")
                default:
                    state = .failed("网络异常: \(urlError.localizedDescription)")
                }
            } else {
                state = .failed("检查失败: \(error.localizedDescription)")
            }
        }
    }
}
