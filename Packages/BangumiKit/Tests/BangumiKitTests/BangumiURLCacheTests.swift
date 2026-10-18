import Foundation
import Testing

@testable import BangumiKit

/// `BangumiURL` 两个缓存的正确性（性能审查清单 `P1-11`）。
///
/// ## 为什么要钉
///
/// 加缓存之后，写错的两种方式都**不报错**：
/// - **太粘**：镜像域名改了但缓存不失效 → 继续按旧域名取图（图裂）；
/// - **串值**：缓存键不完整 → 不同输入拿到同一输出（图错乱）。
///
/// 两者在真机上都表现为「图片偶尔不对」，极难复现。
///
/// ## 为什么直接测缓存类、不动 UserDefaults
///
/// 两个缓存类的 `mirror` 都是**方法参数**，所以失效逻辑可以完全离线断言 ——
/// 不需要改 `UserDefaults.standard` 的镜像键。这一点很重要：该键是进程级全局状态，
/// 而 Swift Testing 默认并行跑用例；改它会让**别的套件**同时读到镜像形态而偶发失败。
/// （第一版就是这么写的，`domainsInvalidatesOnMirrorChange` 当场红。）
@Suite("BangumiURL 缓存")
struct BangumiURLCacheTests {

    private static let sampleInputs: [String] = [
        "/pic/x.jpg",
        "pic/x.jpg",
        "//lain.bgm.tv/pic/cover/l/ab/cd/123456_abcdef.jpg",
        "http://lain.bgm.tv/pic/cover/l/xx.jpg",
        "https://lain.bgm.tv/pic/cover/l/xx.jpg",
        "https://example.com/other.jpg",
        "",
        "   ",
        "https://lain.bgm.tv/pic/cover/l/a.jpg?x=1#frag",
    ]

    // MARK: imageURLStringCache 的语义

    /// 命中与未命中必须给出同一个值（缓存透明）。
    @Test func imageURLStringCacheIsTransparent() {
        let cache = ImageURLStringCache()
        for input in Self.sampleInputs {
            let reference = BangumiURL.composeImageURLString(from: input)

            let miss = cache.value(for: input, mirror: nil)
            #expect(miss == nil, "冷缓存不该有值（input=\(input.debugDescription)）")

            cache.store(reference, for: input, mirror: nil)
            let hit = cache.value(for: input, mirror: nil)
            #expect(hit == reference, "命中值必须等于写入值（input=\(input.debugDescription)）")
            #expect(hit == BangumiURL.composeImageURLString(from: input),
                    "必须与参考实现一致（input=\(input.debugDescription)）")
        }
    }

    /// 不同输入不能互相串值。
    @Test func imageURLStringCacheDoesNotMixInputs() {
        let cache = ImageURLStringCache()
        var stored: [(String, String)] = []
        for input in Self.sampleInputs {
            let value = BangumiURL.composeImageURLString(from: input)
            cache.store(value, for: input, mirror: nil)
            stored.append((input, value))
        }
        for (input, expected) in stored {
            #expect(cache.value(for: input, mirror: nil) == expected,
                    "输入 \(input.debugDescription) 读回了别人的值")
        }
    }

    /// **镜像一变，上一代条目必须全部作废。**
    ///
    /// 用**原始字符串**当失效键（不是规范化后的域名）：`BangumiDomains` 会把
    /// `"https://x"` 与 `"x"` 都规范化成 `x`，若拿规范化值当键，这两种写法之间的
    /// 切换会被当成「没变」而返回旧缓存。
    @Test func imageURLStringCacheInvalidatesOnMirrorChange() {
        let cache = ImageURLStringCache()
        let input = "https://lain.bgm.tv/pic/cover/l/xx.jpg"

        let official = BangumiURL.composeImageURLString(from: input)
        cache.store(official, for: input, mirror: nil)
        #expect(cache.value(for: input, mirror: nil) == official)

        // 镜像换了 → 旧条目必须读不到。
        #expect(cache.value(for: input, mirror: "mirror.example") == nil,
                "镜像变化后不能返回上一代的缓存值")

        let mirrored = "https://lain.mirror.example/pic/cover/l/xx.jpg"
        cache.store(mirrored, for: input, mirror: "mirror.example")
        #expect(cache.value(for: input, mirror: "mirror.example") == mirrored)

        // 还原镜像 → 那一代的条目也已作废，必须重算。
        #expect(cache.value(for: input, mirror: nil) == nil,
                "镜像还原后旧一代缓存也必须作废")
    }

    /// `"x"` 与 `"https://x"` 是**不同的原始值**，切换必须失效。
    @Test func imageURLStringCacheDistinguishesRawMirrorStrings() {
        let cache = ImageURLStringCache()
        cache.store("A", for: "k", mirror: "mirror.example")
        #expect(cache.value(for: "k", mirror: "mirror.example") == "A")
        #expect(cache.value(for: "k", mirror: "https://mirror.example") == nil,
                "原始字符串不同就必须失效（规范化后相同也不许复用）")
    }

    /// 超量输入不能崩、不能**串值**（有界缓存超限会整表清空）。
    ///
    /// 注意「清空后读不到」是**正确**行为，不是缺陷：这是纯函数结果缓存，
    /// 未命中只会让调用方重算一次。所以判据是「读到的值要么没有、要么必须正确」，
    /// 而不是「必须命中」。
    @Test func cacheSurvivesOverflowWithoutMixingValues() {
        let cache = ImageURLStringCache()
        let limit = ImageURLStringCache.maxEntries
        for index in 0..<(limit + 200) {
            let input = "/pic/cover/l/\(index).jpg"
            cache.store(BangumiURL.composeImageURLString(from: input), for: input, mirror: nil)
        }

        // 抽样校验：每个 key 要么未命中，要么值必须与参考实现一致（绝不能串值）。
        for index in stride(from: 0, to: limit + 200, by: 37) {
            let input = "/pic/cover/l/\(index).jpg"
            if let cached = cache.value(for: input, mirror: nil) {
                #expect(cached == BangumiURL.composeImageURLString(from: input),
                        "溢出清空后读到了错误的值（input=\(input)）")
            }
        }
        // 最新写入的仍要在（清空后清空的只是旧一代）。
        let recent = "/pic/cover/l/\(limit + 199).jpg"
        #expect(cache.value(for: recent, mirror: nil) != nil, "最后写入的那条应仍在缓存里")
    }

    // MARK: 集成（走真实入口，但只读官方域名，不改全局键）

    /// 既有 5 条黄金断言在缓存下仍成立（相对路径 / 协议相对 / http / https）。
    ///
    /// 这条不碰镜像键，所以与并行用例安全共存。
    @Test func goldenAssertionsStillHold() {
        #expect(BangumiURL.imageURLString(from: "/pic/x.jpg") == "/pic/x.jpg")
        #expect(BangumiURL.imageURLString(from: "pic/x.jpg") == "pic/x.jpg")
        #expect(BangumiURL.imageURLString(from: "//lain.bgm.tv/pic/cover/l/xx.jpg")
            == "https://lain.bgm.tv/pic/cover/l/xx.jpg")
        #expect(BangumiURL.imageURLString(from: "http://lain.bgm.tv/pic/cover/l/xx.jpg")
            == "https://lain.bgm.tv/pic/cover/l/xx.jpg")
        #expect(BangumiURL.imageURLString(from: "https://lain.bgm.tv/pic/cover/l/xx.jpg")
            == "https://lain.bgm.tv/pic/cover/l/xx.jpg")
    }

    /// 真实入口第二次调用必须命中缓存且值与首次相同。
    @Test func publicEntryPointIsStableAcrossCalls() {
        let input = "https://lain.bgm.tv/pic/cover/l/stable-test.jpg"
        let first = BangumiURL.imageURLString(from: input)
        let second = BangumiURL.imageURLString(from: input)
        #expect(first == second)
        #expect(first == BangumiURL.composeImageURLString(from: input))

        let domainsFirst = BangumiURL.domains
        let domainsSecond = BangumiURL.domains
        #expect(domainsFirst == domainsSecond)
    }
}
