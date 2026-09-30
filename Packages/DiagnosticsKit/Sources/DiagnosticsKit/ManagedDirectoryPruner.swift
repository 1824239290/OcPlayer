import Foundation

/// Applies count and byte limits to one app-owned, flat directory.
///
/// The root must be a real directory rather than a symbolic link. Entries are
/// never followed recursively, and only regular files with allowed extensions
/// participate in pruning.
public enum ManagedDirectoryPruner {
    public struct Result: Equatable, Sendable {
        public var removedCount: Int
        public var removedBytes: Int64
        public var failedRemovalCount: Int
        public var skippedUnsafeRoot: Bool

        public init(
            removedCount: Int = 0,
            removedBytes: Int64 = 0,
            failedRemovalCount: Int = 0,
            skippedUnsafeRoot: Bool = false
        ) {
            self.removedCount = removedCount
            self.removedBytes = removedBytes
            self.failedRemovalCount = failedRemovalCount
            self.skippedUnsafeRoot = skippedUnsafeRoot
        }
    }

    public static func prune(
        directory: URL,
        allowedExtensions: Set<String>,
        maxFileCount: Int,
        maxTotalBytes: Int64,
        preservedFileNames: Set<String> = [],
        /// 只清理文件名以这些前缀之一的文件；`nil` / 空数组 = 目录内所有候选都可清理。
        ///
        /// **为什么需要它**：淘汰按修改时间**最旧优先**，而"永久"数据恰恰写得最少、
        /// 于是 mtime 最旧 —— 一旦目录里混着永久文件，它们会被**最先删掉**。
        /// 弹幕目录就是这种情况：`comments-<id>.json` 是可重下的缓存，而
        /// `mapping.json` / `intro-hints.json` / `title-aliases.json` /
        /// `aniskip-ids.json` 都是永久数据。原实现只把 `mapping.json` 加进
        /// `preservedFileNames`，另外三个就一直在被优先删除（表现为别名解析与
        /// AniSkip 反复回源、离线「跳过片头」失效）。
        ///
        /// 用白名单而不是继续补 `preservedFileNames`：白名单**fail-safe** ——
        /// 将来新增的永久文件天然安全；补名单是 fail-open，漏一个就继续被删。
        prunableFileNamePrefixes: [String]? = nil,
        fileManager: FileManager = .default
    ) -> Result {
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path) else {
            return Result()
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            return Result(skippedUnsafeRoot: true)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return Result() }

        let normalizedExtensions = Set(allowedExtensions.map { $0.lowercased() })
        let normalizedPreserved = Set(preservedFileNames.map { $0.lowercased() })
        // 白名单为空 / 未传 = 不做前缀过滤（目录里都是可重下缓存的场景）。
        let prefixes: [String]? = prunableFileNamePrefixes.flatMap { list in
            list.isEmpty ? nil : list.map { $0.lowercased() }
        }
        let files = urls.compactMap { url -> ManagedFile? in
            guard normalizedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true
            else { return nil }
            let name = url.lastPathComponent.lowercased()
            // 白名单：只有明确是缓存的文件才参与淘汰（fail-safe —— 将来新增的永久
            // 文件天然安全）。见 `prunableFileNamePrefixes` 的注释。
            if let prefixes, !prefixes.contains(where: { name.hasPrefix($0) }) { return nil }
            // 永久性文件（如弹幕 mapping.json）不参与限额：被当普通缓存删掉的话
            // 同一集会反复回源网关，且映射丢了没法重建。
            guard !normalizedPreserved.contains(name) else { return nil }
            return ManagedFile(
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                size: Int64(max(0, values.fileSize ?? 0))
            )
        }
        .sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }

        let countLimit = max(0, maxFileCount)
        let byteLimit = max(0, maxTotalBytes)
        var remainingCount = files.count
        var remainingBytes = files.reduce(Int64(0)) { partial, file in
            let (sum, overflow) = partial.addingReportingOverflow(file.size)
            return overflow ? Int64.max : sum
        }
        var result = Result()

        for file in files {
            guard remainingCount > countLimit || remainingBytes > byteLimit else { break }
            do {
                try fileManager.removeItem(at: file.url)
                remainingCount -= 1
                remainingBytes = max(0, remainingBytes - file.size)
                result.removedCount += 1
                result.removedBytes += file.size
            } catch {
                result.failedRemovalCount += 1
            }
        }
        return result
    }

    private struct ManagedFile {
        let url: URL
        let modifiedAt: Date
        let size: Int64
    }
}
