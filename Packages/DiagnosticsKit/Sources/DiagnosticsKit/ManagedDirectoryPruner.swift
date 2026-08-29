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
        let files = urls.compactMap { url -> ManagedFile? in
            guard normalizedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true
            else { return nil }
            // 永久性文件（如弹幕 mapping.json）不参与限额：被当普通缓存删掉的话
            // 同一集会反复回源网关，且映射丢了没法重建。
            guard !normalizedPreserved.contains(url.lastPathComponent.lowercased()) else { return nil }
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
