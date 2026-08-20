import Foundation

/// 上报给 Jellyfin 的客户端身份。`DeviceId` 必须**跨启动稳定**（服务器拿它做设备管理），
/// 所以首用即生成、存 UserDefaults；DeviceName 取一次机器名后同样缓存。
public enum ClientIdentity {
    public static let clientName = "OcPlayer"

    /// Jellyfin client version derived from the host app's version metadata.
    /// Release builds therefore report the same marketing version and build
    /// number that users see in Finder / Settings instead of a duplicated
    /// source constant that can drift during packaging.
    public static var version: String {
        version(in: .main)
    }

    /// Product-token-safe app version for User-Agent strings. Build metadata is
    /// intentionally omitted so callers keep the `OcPlay/<semver> (...)` shape.
    public static var marketingVersion: String {
        marketingVersion(in: .main)
    }

    private static let deviceIDKey = "dev.jumusu.ocplayer.deviceId"
    private static let deviceNameKey = "dev.jumusu.ocplayer.deviceName"

    static func version(in bundle: Bundle) -> String {
        let shortVersion = nonEmptyInfoValue(
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        )
        let build = nonEmptyInfoValue(
            bundle.object(forInfoDictionaryKey: "CFBundleVersion")
        )

        switch (shortVersion, build) {
        case let (.some(shortVersion), .some(build)) where build != shortVersion:
            return "\(shortVersion) (\(build))"
        case let (.some(shortVersion), _):
            return shortVersion
        case let (_, .some(build)):
            return build
        default:
            return "development"
        }
    }

    static func marketingVersion(in bundle: Bundle) -> String {
        nonEmptyInfoValue(
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        ) ?? nonEmptyInfoValue(
            bundle.object(forInfoDictionaryKey: "CFBundleVersion")
        ) ?? "development"
    }

    private static func nonEmptyInfoValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 稳定设备 ID（UUID，首用生成）。
    public static var deviceID: String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: deviceIDKey) {
            return stored
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceIDKey)
        return id
    }

    /// 展示用设备名。不用 AppKit/UIKit 取「漂亮名字」：那些 API 有主线程约束，
    /// 机器名对服务器只是展示，`ProcessInfo.hostName`（如 "macbook.local"）足够。
    public static var deviceName: String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: deviceNameKey) {
            return stored
        }
        let name = ProcessInfo.processInfo.hostName
        defaults.set(name, forKey: deviceNameKey)
        return name
    }

    /// Jellyfin `Authorization: MediaBrowser …` 头。API 客户端、图片管线和
    /// 内核 `open_with_headers`（含设置页直连）共用同一套身份字段，避免出现
    /// 硬编码 DeviceId / 版本漂移的第二套客户端。
    public static func mediaBrowserAuthorizationHeader(token: String? = nil) -> String {
        var fields = [
            "Client": clientName,
            "Device": deviceName,
            "DeviceId": deviceID,
            "Version": version,
        ]
        if let token, !token.isEmpty {
            fields["Token"] = token
        }
        return "MediaBrowser " + fields.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: ", ")
    }
}
