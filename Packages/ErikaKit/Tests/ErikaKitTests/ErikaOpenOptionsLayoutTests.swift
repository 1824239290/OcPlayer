import CErika
import Foundation
import Testing

/// `ErikaOpenOptions` 是宿主构造、内核消费的跨 ABI 结构：Swift 侧字段错位
/// （比如 headers 指针/计数与 read-ahead 字节序对不上）会让内核把
/// http_read_ahead_bytes 读成 0（= 默认档），用户调档位就完全无效——
/// 症状隐晦（不报错、只是没效果），所以布局必须锁死。
@Suite("ErikaOpenOptions ABI 布局")
struct ErikaOpenOptionsLayoutTests {

    @Test("字段大小/对齐与 C 头一致，read-ahead/回退预算值落在预期偏移")
    func layoutMatchesCHeader() {
        // C: { const ErikaHttpHeader *headers(8); uintptr_t header_count(8);
        //      uint64_t http_read_ahead_bytes(8); uint64_t http_back_buffer_bytes(8);
        //      uint64_t reserved[2](16); }
        // 总 48 字节、对齐 8。注意与旧头（reserved[3]）同尺寸：新字段吃的是
        // reserved 槽位，read-ahead 偏移 16 不变，回退预算落在 24。
        #expect(MemoryLayout<ErikaOpenOptions>.size == 48,
                "size=\(MemoryLayout<ErikaOpenOptions>.size)")
        #expect(MemoryLayout<ErikaOpenOptions>.alignment == 8,
                "alignment=\(MemoryLayout<ErikaOpenOptions>.alignment)")
        #expect(MemoryLayout<ErikaOpenOptions>.stride == 48)

        // 成员偏移：headers 0、header_count 8、read-ahead 16、回退预算 24。
        var options = ErikaOpenOptions(
            headers: nil, header_count: 0,
            http_read_ahead_bytes: 0, http_back_buffer_bytes: 0,
            reserved: (0, 0)
        )
        withUnsafeBytes(of: &options) { bytes in
            func u64(at offset: Int) -> UInt64 {
                bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            }
            #expect(u64(at: 16) == 0, "read-ahead 默认应为 0")
            #expect(u64(at: 24) == 0, "回退预算默认应为 0")
        }
        options.http_read_ahead_bytes = 16 * 1024 * 1024
        options.http_back_buffer_bytes = 32 * 1024 * 1024
        withUnsafeBytes(of: &options) { bytes in
            let readAhead = bytes.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            #expect(readAhead == 16 * 1024 * 1024,
                    "偏移 16 处必须读到设置值，实际 \(readAhead)")
            let backBuffer = bytes.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            #expect(backBuffer == 32 * 1024 * 1024,
                    "偏移 24 处必须读到设置值，实际 \(backBuffer)")
        }

        // header_count 偏移 8：非零计数可见（内核以它遍历 header 数组）。
        options.header_count = 3
        withUnsafeBytes(of: &options) { bytes in
            let count = bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            #expect(count == 3)
        }
    }
}
