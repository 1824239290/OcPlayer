import Foundation

/// 上报给 Jellyfin 的客户端身份。`DeviceId` 必须**跨启动稳定**（服务器拿它做设备管理），
/// 所以首用即生成、存 UserDefaults；DeviceName 取一次机器名后同样缓存。
public enum ClientIdentity {
    public static let clientName = "OcPlayer"
    public static let version = "0.1.1"

    private static let deviceIDKey = "dev.jumusu.ocplayer.deviceId"
    private static let deviceNameKey = "dev.jumusu.ocplayer.deviceName"

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
}
