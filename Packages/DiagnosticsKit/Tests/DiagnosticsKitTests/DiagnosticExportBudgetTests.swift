import Foundation
import XCTest

@testable import DiagnosticsKit

/// 有界导出（性能审查清单 `P2-31`）的回归。
///
/// ## 为什么要钉
///
/// 导出诊断包会同时持有「全部日志的 Data + 解码后的 String + 拼接结果」三份大对象。
/// 实测 48.4 MB 日志对应 **112 MiB 峰值 RSS**（2.44×），在 iOS 上是现实的 jetsam 风险
/// （本 App 真实峰值 RSS 到过 435 MB）。
///
/// `bodyByteBudget` 把尖峰框到「约 2× 预算」。但截断本身有四个容易错的地方，
/// 每一个都不会报错、只会让导出包变得难用或不可解析：
/// 1. 保留的必须是**最新**那段（排障看崩前那一段），不是最旧的；
/// 2. 跨文件截断后顺序仍须**升序**（文件头明写「归档在前、当前文件在后」）；
/// 3. 切在行中间时必须丢掉**残首行**，否则第一行不是合法 JSON、解析工具整份失败；
/// 4. 预算小于一行时给空 body，不能给半行。
final class DiagnosticExportBudgetTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportBudgetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// 每个记录一条的 JSONL 行。
    private func lines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// 正文部分（去掉头部 + 空行）。
    private func body(of exported: String) -> String {
        guard let range = exported.range(of: "\n\n") else { return "" }
        return String(exported[range.upperBound...])
    }

    private func makeLogger(directory: URL, maxFileBytes: Int = 1024 * 1024) -> DiagnosticLogger {
        DiagnosticLogger(
            subsystem: "test", category: "export", directory: directory,
            maxFileBytes: maxFileBytes, maxRetainedFiles: 10,
            maxTotalBytes: 50 * 1024 * 1024, emitToOSLog: false
        )
    }

    // MARK: - 预算生效

    /// 预算生效：输出正文不超过预算（+ 一行余量），且**包含最新一条**。
    ///
    /// 为什么用「+ 一行余量」而不是严格 ≤：实现按整条记录取舍，最后一条可能把总量
    /// 顶过预算一个记录长度（这与 trace 尾部预算同口径）。
    func testBudgetKeepsNewestRecordsOnly() throws {
        let directory = try makeDirectory()
        let log = makeLogger(directory: directory)

        let padding = String(repeating: "x", count: 200)
        for index in 0..<3_000 {
            log.info("record \(index)", fields: ["pad": .string(padding)])
        }
        log.flush()

        let full = try log.exportText(headerLines: ["# h"])
        let fullBody = body(of: full)
        XCTAssertGreaterThan(fullBody.utf8.count, 200_000, "语料要足够大，否则测不出预算")

        let budget = 100_000
        let bounded = try log.exportText(headerLines: ["# h"], bodyByteBudget: budget)
        let boundedBody = body(of: bounded)

        XCTAssertLessThanOrEqual(
            boundedBody.utf8.count, budget + 1_024,
            "正文超预算（预算 \(budget)，实际 \(boundedBody.utf8.count)）")

        // 必须保留最新的那条。
        XCTAssertTrue(boundedBody.contains("\"message\":\"record 2999\""),
                      "预算截断保留了旧记录、丢了最新的（排障要看崩前那一段）")
        // 最旧的那条必须已经不在。
        XCTAssertFalse(boundedBody.contains("\"message\":\"record 0\""),
                       "预算没生效：最旧的记录仍在")
    }

    /// 跨文件截断后，保留下来的记录仍须按**时间升序**。
    ///
    /// 实现是倒序（新→旧）累加再翻回来；翻错方向时导出包会变成「新的在前」，
    /// 与文件头写的「归档在前、当前文件在后」相反。
    func testOrderRemainsAscendingAcrossFiles() throws {
        let directory = try makeDirectory()
        // 小单文件上限 → 必然滚出多个归档文件。
        let log = makeLogger(directory: directory, maxFileBytes: 8 * 1024)

        for index in 0..<400 {
            log.info("ordered \(index)", fields: ["pad": .string(String(repeating: "y", count: 120))])
        }
        log.flush()

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("diagnostics") }
        XCTAssertGreaterThan(files.count, 1, "语料没有滚出多个文件，测不到跨文件截断")

        let bounded = try log.exportText(headerLines: ["# h"], bodyByteBudget: 20_000)
        let records = lines(of: body(of: bounded))
            .filter { $0.contains("\"message\":\"ordered ") }

        XCTAssertGreaterThan(records.count, 1, "保留下来的记录太少，测不出顺序")
        let indexes: [Int] = records.compactMap { line in
            guard let range = line.range(of: "\"message\":\"ordered ") else { return nil }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return Int(rest[..<end])
        }
        XCTAssertEqual(indexes.count, records.count, "有记录解析不出序号")
        XCTAssertEqual(indexes, indexes.sorted(), "保留的记录不是升序：\(indexes)")
    }

    /// 切在行中间时，**首行必须是完整 JSON**（不是残行）。
    func testPartialLeadingLineIsDropped() throws {
        let directory = try makeDirectory()
        let log = makeLogger(directory: directory, maxFileBytes: 512 * 1024)

        for index in 0..<2_000 {
            log.info("line \(index)", fields: ["pad": .string(String(repeating: "z", count: 100))])
        }
        log.flush()

        // 试多个预算，确保其中一些必然切在行中间。
        //
        // 判据用 `JSONSerialization` 而不是 `JSONDecoder.decode(DiagnosticEntry.self)`：
        // 后者要用 `.custom` 时间戳策略（写盘是 ISO 字符串），那是本包私有配置；
        // 而这里只关心「是不是一条**完整的** JSON」——残行必然解析失败。
        for budget in [4_097, 8_191, 12_289, 16_381, 20_003] {
            let bounded = try log.exportText(headerLines: ["# h"], bodyByteBudget: budget)
            let records = lines(of: body(of: bounded))
            guard let first = records.first else { continue }
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(first.utf8)),
                "预算 \(budget) 切出了残首行：\(first.prefix(60))")
            // 每条都要完整，不只是首行。
            for record in records {
                XCTAssertNoThrow(
                    try JSONSerialization.jsonObject(with: Data(record.utf8)),
                    "预算 \(budget) 切出了残行：\(record.prefix(60))")
            }
        }
    }

    /// 预算小于一行 → 只有头部，不崩。
    func testTinyBudgetYieldsHeaderOnly() throws {
        let directory = try makeDirectory()
        let log = makeLogger(directory: directory)
        log.info("only record", fields: ["pad": .string(String(repeating: "q", count: 500))])
        log.flush()

        for budget in [0, 1, 10] {
            let bounded = try log.exportText(headerLines: ["# 头部"], bodyByteBudget: budget)
            XCTAssertTrue(bounded.hasPrefix("# 头部\n\n"), "预算 \(budget) 时头部必须完整")
            XCTAssertTrue(body(of: bounded).isEmpty, "预算 \(budget) 不该产出半行")
        }
    }

    // MARK: - 残尾文件不该吃掉预算（审查 S3 的复现）

    /// **残行比可用预算还长时，那个文件读不出一行，就不该扣预算。**
    ///
    /// `readTail` 在非零偏移时会丢残首行；若丢掉之后**一个换行都没有**
    /// （归档最后一行被撕开、且残行长度 ≥ 可用预算），它整段返回空。
    /// 早先按 `file.size` 记账，那笔预算已经被扣掉 —— 后面的（更旧的）文件
    /// 明明还有额度却被整份跳过，排障价值无声缩水。
    ///
    /// 构造要点：让**中间那个**文件以一条「比预算剩余额度还长的无换行残行」收尾。
    /// 这样读它时拿到的整段没有换行 → 返回空 → 旧记账白扣一笔。
    func testUnterminatedTailDoesNotConsumeBudget() throws {
        let directory = try makeDirectory()
        let names = ["diagnostics.jsonl", "diagnostics-2.jsonl", "diagnostics-3.jsonl"]

        func record(_ index: Int, pad: Int = 200, newline: Bool = true) -> String {
            let payload = String(repeating: "r", count: pad)
            let line = "{\"timestamp\":\"2026-10-19T00:00:00.000Z\",\"level\":\"info\","
                + "\"subsystem\":\"t\",\"category\":\"c\",\"message\":\"m\(index)\","
                + "\"fields\":{\"pad\":\"\(payload)\"},\"session\":\"s\",\"sequence\":\(index)}"
            return newline ? line + "\n" : line
        }

        func write(_ name: String, body: String) throws {
            let url = directory.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000
                    + Double(names.firstIndex(of: name) ?? 0))],
                ofItemAtPath: url.path)
        }

        // 最旧：大量完整记录 —— 只有预算记账正确时才会被取到。
        var oldest = ""
        for i in 0..<30 { oldest += record(i) }
        try write(names[0], body: oldest)

        // 中间：一条**超长无换行残行**（比预算大得多）+ 前面若干完整记录。
        var middle = ""
        for i in 100..<103 { middle += record(i) }
        middle += String(repeating: "X", count: 50_000)   // 无换行的残行
        try write(names[1], body: middle)

        // 最新：几条完整记录。
        var newest = ""
        for i in 200..<204 { newest += record(i) }
        try write(names[2], body: newest)

        let log = makeLogger(directory: directory)
        let fullBytes = try log.exportData().count

        // 预算足以覆盖「最新 + 最旧」，但**不足以**同时装下中间那 50 KB 残行。
        let budget = fullBytes - 40_000
        XCTAssertGreaterThan(budget, 0)

        let text = try log.exportText(headerLines: ["# h"], bodyByteBudget: budget)
        let bytes = body(of: text).utf8.count

        // 若残尾白扣了预算，最旧那批记录会整批消失。
        XCTAssertTrue(
            body(of: text).contains("\"message\":\"m0\""),
            "最旧的记录被丢掉了 —— 残尾文件白扣了预算（S3）。实测正文 \(bytes) 字节 / 预算 \(budget)")
        XCTAssertTrue(body(of: text).contains("\"message\":\"m203\""), "最新记录必须保留")
        XCTAssertLessThanOrEqual(bytes, budget + 1_024, "超出预算上限")
    }

    // MARK: - 不加预算时行为不变

    /// `bodyByteBudget: nil` 必须与「不带该参数」**逐字节相同**，
    /// 且与我按旧实现形状重建的参考值相同。
    ///
    /// 这条守住「默认路径零变化」：`exportText` 内部改成了「一次构造」
    /// （头部字节先写进同一个 Data，去掉 `+` 拼接），输出必须完全一致。
    func testUnboundedExportIsByteIdenticalToLegacyShape() throws {
        let directory = try makeDirectory()
        let log = makeLogger(directory: directory)
        for index in 0..<50 {
            log.info("plain \(index)")
        }
        log.flush()

        let headerLines = ["# 头部", "版本: 1.0"]
        let explicitNil = try log.exportText(headerLines: headerLines, bodyByteBudget: nil)
        let implicitNil = try log.exportText(headerLines: headerLines)

        XCTAssertEqual(explicitNil, implicitNil, "显式 nil 与默认参数必须一致")

        // 参考值：旧实现形状（String(decoding:) + 字符串拼接）。
        let legacyBody = String(decoding: try log.exportData(), as: UTF8.self)
        let legacy = headerLines.joined(separator: "\n") + "\n\n" + legacyBody
        XCTAssertEqual(explicitNil, legacy, "默认路径的输出必须与旧实现逐字节相同")
    }

    /// 全量导出仍包含**全部**记录（预算是可选的，不是默认收窄）。
    func testUnboundedExportStillContainsEverything() throws {
        let directory = try makeDirectory()
        let log = makeLogger(directory: directory)
        for index in 0..<200 {
            log.info("keep \(index)")
        }
        log.flush()

        let text = try log.exportText(headerLines: ["# h"])
        let records = lines(of: body(of: text)).filter { $0.contains("\"message\":\"keep ") }
        XCTAssertEqual(records.count, 200, "不加预算时必须导出全部记录")
    }
}
