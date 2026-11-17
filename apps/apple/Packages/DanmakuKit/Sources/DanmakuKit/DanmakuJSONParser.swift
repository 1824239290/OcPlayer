import Foundation

/// Erika 弹幕 JSON 的**解析**侧（写入侧是 `DanmakuJSONConverter.erikaJSON`）。
///
/// 同一份 `{"comments":[{time,type,color,content}]}` schema 的生产者与消费者都在
/// 本包——此前 App 层的 overlay 渲染器自己写了一份解析（DanmakuOverlay 的
/// `Comment` + `parse`），等于让 App 层认识内核的数据格式。现在收回包内。
public enum DanmakuJSONParser {
    /// 一条解析后的弹幕（overlay 渲染的输入）。
    public struct Entry: Equatable, Sendable {
        public let time: Double
        public let mode: Mode
        public let color: UInt32
        public let text: String

        public enum Mode: Sendable {
            case scroll
            case top
            case bottom
        }

        public init(time: Double, mode: Mode, color: UInt32, text: String) {
            self.time = time
            self.mode = mode
            self.color = color
            self.text = text
        }
    }

    private struct Item: Decodable {
        let time: Double
        let type: Int
        let color: Int64?
        let content: String
    }

    private struct Payload: Decodable {
        let comments: [Item]?
    }

    /// 解析 Erika JSON。**返回 nil = 解码失败**（区别于「合法但没有弹幕」的空数组，
    /// 调用方靠这个区分「真没有」和「解析挂了」打日志）。
    public static func parse(_ json: String) -> [Entry]? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return (payload.comments ?? []).compactMap(entry(from:))
    }

    /// 单条清洗：非有限/负时间、空正文跳过；颜色夹进 [0, 0xFFFFFF]
    /// （服务端按有符号 int 写 0xFFFFFFFF 类颜色，UInt32(负数) 会 trap）。
    private static func entry(from item: Item) -> Entry? {
        guard item.time.isFinite, item.time >= 0, !item.content.isEmpty else { return nil }
        let mode: Entry.Mode
        switch item.type {
        case 5: mode = .top
        case 4: mode = .bottom
        default: mode = .scroll
        }
        let color = max(0, min(item.color ?? 0xFF_FF_FF, 0xFF_FF_FF))
        return Entry(
            time: item.time,
            mode: mode,
            color: UInt32(color) & 0xFF_FF_FF,
            text: item.content
        )
    }
}
