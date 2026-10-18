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

    // MARK: 多键代次一致性（审查给的反例）

    /// **镜像切换后，上一代的*其余* key 也不能漏出来。**
    ///
    /// 这是 `entries.removeAll` 那句的守门人：本缓存只记一个整表 `mirror` 标签，
    /// 所以只在新代次里写一个 key 就会把标签推进到新代次 —— 若不清空，旧代次
    /// 留下的其他 key 会被当成新代次的有效值返回（返回旧域名的 URL → 图裂）。
    ///
    /// 独立审查实测：删掉清空后原 7 条用例全绿，只有这条序列能抓住。
    @Test func mirrorChangeInvalidatesAllKeysNotJustTheNewOne() {
        let cache = ImageURLStringCache()

        // 官方代次里写两个 key。
        cache.store("OFFICIAL-A", for: "k1", mirror: nil)
        cache.store("OFFICIAL-B", for: "k2", mirror: nil)
        #expect(cache.value(for: "k1", mirror: nil) == "OFFICIAL-A")
        #expect(cache.value(for: "k2", mirror: nil) == "OFFICIAL-B")

        // 新代次里只写 k3 —— 标签被推进到 mirror.example。
        cache.store("MIRRORED-C", for: "k3", mirror: "mirror.example")

        // k1 / k2 属于旧代次，绝不能以新代次身份被命中。
        #expect(cache.value(for: "k1", mirror: "mirror.example") == nil,
                "旧代次的 k1 漏进了新代次（清空逻辑被删掉时这里会返回 \"OFFICIAL-A\"）")
        #expect(cache.value(for: "k2", mirror: "mirror.example") == nil,
                "旧代次的 k2 漏进了新代次")
        #expect(cache.value(for: "k3", mirror: "mirror.example") == "MIRRORED-C")
    }

    /// 反向：切回旧代次时，新代次的条目也不能漏出来。
    @Test func switchingBackToPreviousMirrorDoesNotLeakNewerEntries() {
        let cache = ImageURLStringCache()
        cache.store("MIRRORED-C", for: "k3", mirror: "mirror.example")
        cache.store("OFFICIAL-A", for: "k1", mirror: nil)
        #expect(cache.value(for: "k3", mirror: nil) == nil, "新代次的 k3 漏进了旧代次")
        #expect(cache.value(for: "k1", mirror: nil) == "OFFICIAL-A")
    }

    // MARK: 容量（FIFO，不整表清空）

    /// 跨过上限时只丢最旧一条，**不整表清空** —— 否则「滚到底再回顶」的命中率
    /// 会从上界直接掉到 0（审查实测 N=512 命中 50%，N=513 直接 0%）。
    @Test func overflowEvictsOldestOnlyNotEverything() {
        let cache = ImageURLStringCache()
        let limit = ImageURLStringCache.maxEntries

        for index in 0..<limit {
            cache.store("v\(index)", for: "k\(index)", mirror: nil)
        }
        // 写第 limit+1 条 → 只应淘汰最旧的 k0。
        cache.store("v\(limit)", for: "k\(limit)", mirror: nil)

        #expect(cache.value(for: "k0", mirror: nil) == nil, "最旧的应被淘汰")
        #expect(cache.value(for: "k1", mirror: nil) == "v1", "次旧的必须还在（证明不是整表清空）")
        #expect(cache.value(for: "k\(limit)", mirror: nil) == "v\(limit)")
    }

    /// 反复写入同一个 key 只占一个槽（不会把 order 撑大、不会提前触发淘汰）。
    @Test func rewritingSameKeyOccupiesOneSlotOnly() {
        let cache = ImageURLStringCache()
        let limit = ImageURLStringCache.maxEntries

        // 写 100 次同一个 key —— order 里只应有 1 项。
        for index in 0..<100 {
            cache.store("v\(index)", for: "same", mirror: nil)
        }
        #expect(cache.value(for: "same", mirror: nil) == "v99")

        // 再写 limit-1 个不同 key：总数恰好等于上限，不该触发淘汰。
        for index in 0..<(limit - 1) {
            cache.store("x\(index)", for: "other\(index)", mirror: nil)
        }
        #expect(cache.value(for: "same", mirror: nil) == "v99",
                "总条目数还没超上限，same 不该被淘汰（说明它只占了一个槽）")

        // 再写 1 个 → 超上限，此时最旧的 same 才该被淘汰（FIFO 语义）。
        cache.store("y", for: "one-more", mirror: nil)
        #expect(cache.value(for: "same", mirror: nil) == nil, "超上限后最旧的应被淘汰")
        #expect(cache.value(for: "other\((limit - 2))", mirror: nil) != nil, "较新的应保留")
    }

    // MARK: 入口接线（审查指出：只测缓存类会漏掉「入口根本没用缓存」）

    /// **生产入口必须真的走缓存**，且代次标签与计算用的是**同一个** mirror 值。
    ///
    /// 审查实测两个必绿变异：N1「入口完全不缓存」、N12「入口把代次固定成 nil」——
    /// 只测缓存类时两个都绿。这条用「入口输出 == 用当前镜像算出的参考值」+ 直接
    /// 比对缓存单例来钉住接线。
    @Test func entryPointDelegatesToCacheAndComposesWithSameMirror() {
        BangumiURL.resetCachesForTesting()

        let input = "https://lain.bgm.tv/pic/cover/l/entry-wiring.jpg"
        let viaEntry = BangumiURL.imageURLString(from: input)
        let reference = BangumiURL.composeImageURLStringWithCurrentMirror(from: input)
        #expect(viaEntry == reference, "入口输出必须与「按当前镜像现算」一致")

        // 入口第二次调用应命中缓存（值不变且不再重算）。
        #expect(BangumiURL.imageURLString(from: input) == viaEntry)

        // 直接问缓存单例：入口写入的条目必须能被查出来 —— 证明它真的用了缓存，
        // 而不是每次都现算（杀掉「入口不缓存」的变异）。
        BangumiURL.resetCachesForTesting()
        _ = BangumiURL.imageURLString(from: input)
        #expect(BangumiURL.probeImageURLStringCacheValue(for: input, mirror: nil) == viaEntry,
                "入口没有把结果写进缓存（N1 变异）")
    }

    /// 相对路径 / 空串也要走同一条缓存路径（杀掉「相对路径绕过缓存」的变异）。
    @Test func entryPointCachesRelativePathsToo() {
        BangumiURL.resetCachesForTesting()
        let input = "/pic/cover/l/relative-entry.jpg"
        let value = BangumiURL.imageURLString(from: input)
        #expect(value == input)
        #expect(BangumiURL.probeImageURLStringCacheValue(for: input, mirror: nil) == input,
                "相对路径没有进缓存（N14 变异）")
    }

    /// **代次必须真的接进计算**（杀掉审查的 N12 变异：入口把 mirror 固定成 nil）。
    ///
    /// 镜像未设置时 `nil` 与「真值」等价，所以那个变异在测试环境里看不出来 ——
    /// 必须用**显式注入的镜像**驱动入口才测得到。这也是为什么入口拆出了一个
    /// `imageURLString(from:mirror:)` seam。
    @Test func entryPointUsesInjectedMirrorForBothTagAndComposition() {
        let cache = ImageURLStringCache()
        let input = "https://lain.bgm.tv/pic/cover/l/mirror-wiring.jpg"

        // 用显式镜像算：结果必须含自建镜像域名（证明 compose 用的是传进来的值）。
        let mirrored = BangumiURL.composeImageURLString(from: input, mirror: "mirror.example")
        #expect(mirrored.contains("lain.mirror.example"),
                "compose 没有用传入的 mirror，实际 \(mirrored)")

        // 官方镜像与自建镜像必须产出不同结果，且各自按自己的代次存取。
        let official = BangumiURL.composeImageURLString(from: input, mirror: nil)
        #expect(official != mirrored)

        // 注意：本缓存只持有一个代次（切换即整表作废），所以两代不能共存 ——
        // 逐代验证即可。
        cache.store(official, for: input, mirror: nil)
        #expect(cache.value(for: input, mirror: nil) == official)

        cache.store(mirrored, for: input, mirror: "mirror.example")
        #expect(cache.value(for: input, mirror: "mirror.example") == mirrored)
        #expect(cache.value(for: input, mirror: nil) == nil, "切代后上一代必须作废")
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
