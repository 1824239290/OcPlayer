import Foundation

/// 一个可用内核的自我介绍。设置页直接渲染这些字段。
public struct PlaybackEngineDescriptor: Identifiable, Hashable, Sendable {
    /// 稳定标识，进 UserDefaults。**别改已发布的值**，否则用户的选择会被当成失效回退。
    public let id: String
    /// 设置页主标题，如「Erika」。
    public let displayName: String
    /// 一行技术构成，如「Rust · FFmpeg · libass · Metal」。
    public let summary: String
    /// 是否自带弹幕渲染器。设置页据此决定要不要显示「内核弹幕渲染」开关。
    public let supportsKernelDanmaku: Bool
    /// 补充说明（许可证、成熟度、已知限制），设置页作为脚注显示。可空。
    public let notes: String?

    public init(
        id: String,
        displayName: String,
        summary: String,
        supportsKernelDanmaku: Bool,
        notes: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.supportsKernelDanmaku = supportsKernelDanmaku
        self.notes = notes
    }
}

/// 可用内核的注册表与选择状态。
///
/// **注册在 App 层做**（`PlaybackEngineAssembly`）——本包不认识任何具体内核，
/// 这是「删掉一个适配器包不影响 App 层」的前提：删包只要改装配点那一行。
///
/// 选择存 UserDefaults，在 `PlaybackController.prepareEngine()`（懒创建）时读取，
/// 所以切换内核在**下一次播放**生效，不用重启。
@MainActor
public enum PlaybackEngineRegistry {
    private static let selectionKey = "dev.jumusu.ocplayer.playback.engineID"

    private struct Entry {
        let descriptor: PlaybackEngineDescriptor
        let make: () throws -> any PlaybackEngine
    }

    private static var entries: [Entry] = []

    /// 注册一个内核。注册顺序 = 设置页显示顺序。
    /// 同 id 重复注册按后者覆盖（方便测试替身）。
    public static func register(
        _ descriptor: PlaybackEngineDescriptor,
        make: @escaping () throws -> any PlaybackEngine
    ) {
        let entry = Entry(descriptor: descriptor, make: make)
        if let index = entries.firstIndex(where: { $0.descriptor.id == descriptor.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        PlaybackLog.append("内核注册 id=\(descriptor.id) name=\(descriptor.displayName)")
    }

    /// 当前构建里可用的内核，按注册顺序。
    public static var available: [PlaybackEngineDescriptor] {
        entries.map(\.descriptor)
    }

    /// UserDefaults 里存的原始选择（可能指向一个已经不存在的内核）。
    public static var storedSelectionID: String? {
        UserDefaults.standard.string(forKey: selectionKey)
    }

    /// 实际会被使用的内核。
    ///
    /// 存的 id 找不到时**回退到第一个可用内核**而不是失败——这正是
    /// 「以后删掉某个适配器不影响后续」的保证：一个失效的偏好不能让播放器打不开。
    public static var selected: PlaybackEngineDescriptor? {
        if let id = storedSelectionID,
           let match = entries.first(where: { $0.descriptor.id == id }) {
            return match.descriptor
        }
        return entries.first?.descriptor
    }

    /// 存的选择已经失效（内核被移除），当前跑的是回退项。设置页据此提示用户。
    public static var selectionIsStale: Bool {
        guard let id = storedSelectionID else { return false }
        return !entries.contains { $0.descriptor.id == id }
    }

    /// 记下用户的选择。下一次 `makeSelected()` 生效。
    public static func select(_ id: String) {
        UserDefaults.standard.set(id, forKey: selectionKey)
        PlaybackLog.append("内核选择 id=\(id)（下次播放生效）")
    }

    /// 清掉显式选择，回到默认（第一个可用）。
    public static func clearSelection() {
        UserDefaults.standard.removeObject(forKey: selectionKey)
    }

    /// 按当前选择造一个引擎。没有任何内核注册时抛 `PlaybackEngineRegistryError.noEngineAvailable`。
    public static func makeSelected() throws -> any PlaybackEngine {
        guard let entry = resolvedEntry() else {
            throw PlaybackEngineRegistryError.noEngineAvailable
        }
        PlaybackLog.append("内核实例化 id=\(entry.descriptor.id)")
        return try entry.make()
    }

    private static func resolvedEntry() -> Entry? {
        if let id = storedSelectionID,
           let match = entries.first(where: { $0.descriptor.id == id }) {
            return match
        }
        return entries.first
    }

    /// 只给测试用：清空注册表。
    public static func resetForTesting() {
        entries = []
    }
}

public enum PlaybackEngineRegistryError: Error, CustomStringConvertible {
    /// 一个内核都没注册。正常构建不该出现——装配点漏了才会。
    case noEngineAvailable

    public var description: String {
        switch self {
        case .noEngineAvailable:
            "没有可用的播放内核（PlaybackEngineAssembly 没有注册任何适配器）"
        }
    }
}
