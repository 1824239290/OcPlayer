import CErika
import Foundation
import Testing

/// `ErikaOpenOptions` 是宿主构造、内核消费的跨 ABI 结构：Swift 侧字段错位
/// （比如 headers 指针/计数与 read-ahead 字节序对不上）会让内核把
/// http_read_ahead_bytes 读成 0（= 默认档），用户调档位就完全无效——
/// 症状隐晦（不报错、只是没效果），所以布局必须锁死。
@Suite("ErikaOpenOptions ABI 布局")
struct ErikaOpenOptionsLayoutTests {

    @Test("字段大小/对齐与 C 头一致，read-ahead 值落在预期偏移")
    func layoutMatchesCHeader() {
        // C: { const ErikaHttpHeader *headers(8); uintptr_t header_count(8);
        //      uint64_t http_read_ahead_bytes(8); uint64_t reserved[3](24); }
        // 总 48 字节、对齐 8。
        #expect(MemoryLayout<ErikaOpenOptions>.size == 48,
                "size=\(MemoryLayout<ErikaOpenOptions>.size)")
        #expect(MemoryLayout<ErikaOpenOptions>.alignment == 8,
                "alignment=\(MemoryLayout<ErikaOpenOptions>.alignment)")
        #expect(MemoryLayout<ErikaOpenOptions>.stride == 48)

        // 成员偏移：headers 0、header_count 8、read-ahead 16。
        var options = ErikaOpenOptions(
            headers: nil, header_count: 0,
            http_read_ahead_bytes: 0, reserved: (0, 0, 0)
        )
        withUnsafeBytes(of: &options) { bytes in
            func u64(at offset: Int) -> UInt64 {
                bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            }
            #expect(u64(at: 16) == 0, "read-ahead 默认应为 0")
        }
        options.http_read_ahead_bytes = 16 * 1024 * 1024
        withUnsafeBytes(of: &options) { bytes in
            let readAhead = bytes.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            #expect(readAhead == 16 * 1024 * 1024,
                    "偏移 16 处必须读到设置值，实际 \(readAhead)")
        }

        // header_count 偏移 8：非零计数可见（内核以它遍历 header 数组）。
        options.header_count = 3
        withUnsafeBytes(of: &options) { bytes in
            let count = bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            #expect(count == 3)
        }
    }
}
