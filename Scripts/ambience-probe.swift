#!/usr/bin/env swift
//
// ambience-probe.swift —— 氛围背景验收的**判据实现**（无第三方依赖，只用系统框架）。
//
// 为什么需要它：「某页有没有背景图」此前只能靠人眼看截图，既不可复现也没法进 CI。
// 这里把判据写成可执行的东西——**氛围图是彩色照片，纯色页面底是中性灰/白/黑**，
// 所以采样指定区域后看**色度（max(r,g,b) − min(r,g,b) 的中位数）**：
//
//   - 中位色度 ≥ 阈值        → `image`   ：区域里有图（判为「背景在位」）
//   - 中位色度 < 阈值、亮度方差也小 → `flat`    ：区域是纯色底（判为「缺背景」）
//   - 中位色度 < 阈值、亮度方差大   → `content` ：区域被文字/控件占据（**换区域再测**）
//
// 用**中位数**而不是均值：导航栏里的按钮、标题这类小面积元素不会把整块拽成彩色，
// 也不会因为一两个像素把纯色底判成有图（均值两条都会踩）。`content` 这一档是刻意
// 留的：它代表「这个区域测不了」，脚本会按顺序换下一个区域——绝不把「测不了」
// 说成「有图」，那正是这套判据要防的假通过。
//
// 用法：
//   swift Scripts/ambience-probe.swift <图.png> [选项]
//   swift Scripts/ambience-probe.swift --selftest        # 用内存合成图自检判据
//   swift Scripts/ambience-probe.swift --window OcPlayer # 打印窗口 id 与 bounds（macOS 截图用）
//
// 选项：
//   --regions left,right,top,bottom   依次尝试的区域（默认全部；先命中即定论）
//   --threshold 6                     中位色度阈值（0…255，默认 6）
//   --crop-rect x,y,w,h               先裁掉外框（整屏截图裁到窗口用）
//   --json                            输出 JSON（给人看；脚本解析用 key=value）
//   --quiet                           只打最终判定
//
// 退出码：0 = image（有图）；1 = flat（缺图）；2 = content（测不了，需换区域）；
//        3 = 用法/读图错误。

import CoreGraphics
import Foundation
import ImageIO

// MARK: - 区域定义
//
// 全部按**相对比例**给，不写像素：同一份判据要同时用在 2x 的 macOS 窗口截图、
// 3x 的 iPhone 截图和 iPad 截图上。两条经验：
//   * 左右两条取**内容留白**（页面 padding 之内），macOS ~24pt / iOS ~20pt 的边距里
//     不会被卡片盖住，是最干净的采样带；比例取得很窄（0.4%–2%）就是为了不越界。
//   * 顶部取导航栏/工具栏中段：那里是玻璃，氛围图**透过来**。iOS 的中置标题会落进来，
//     于是判成 `content` 换下一个区域——这是设计好的退路，不是缺陷。

struct Region {
    let name: String
    /// 归一化的 x 区间（左闭右开）。
    let x: ClosedRange<Double>
    let y: ClosedRange<Double>

    /// 默认只取**左右两条内容留白**。
    ///
    /// 刻意不含顶部与底部（它们仍可用 `--regions` 手动指定，用于专项排查）：
    ///   * **顶部**是状态栏 / 灵动岛所在，iPhone 上那块是纯黑系统 UI，与「页面有没有
    ///     氛围图」无关；实测它的横向梯度低到 0.01、亮度方差却有 36（黑块 + 白背景），
    ///     混进投票只会制造噪声。
    ///   * **底部**是 Tab 栏：图标与文字让它恒定判 `content`，没有信息量。
    static let all: [Region] = [
        Region(name: "left", x: 0.004...0.020, y: 0.30...0.70),
        Region(name: "right", x: 0.980...0.996, y: 0.30...0.70),
        Region(name: "top", x: 0.400...0.600, y: 0.015...0.045),
        Region(name: "bottom", x: 0.300...0.700, y: 0.930...0.965),
    ]

    /// 默认参与判定的区域（见上面注释）。
    static let defaults: [Region] = [named("left")!, named("right")!]

    static func named(_ name: String) -> Region? { all.first { $0.name == name } }
}

// MARK: - 统计

struct RegionStats {
    let region: Region
    let pixelCount: Int
    let meanR: Double
    let meanG: Double
    let meanB: Double
    /// 中位色度：判「有没有图」的主判据。
    let medianChroma: Double
    let meanChroma: Double
    /// 亮度标准差：**纯色底判据**（系统纯白/纯黑实测 0.00；有一点点图就 ≥ 数）。
    let luminanceStdDev: Double
    /// 相邻像素亮度差的平均值（梯度）。
    ///
    /// 用来区分「模糊的氛围图」与「文字/控件」——两者都让 `luminanceStdDev` 不为零，
    /// 但空间频率差一个量级：
    ///   * 氛围图经过 blur(14–20) + scale 1.12，是**平缓渐变**，梯度很小；
    ///   * 文字、按钮描边是**锐利边缘**，梯度大得多。
    /// 没有这一项时，浅色模式下被白雾压过的淡氛围图（色度 ~5、lum_std ~8）会被
    /// 误判成「区域被内容占据」，于是页面在报告里显示「判不了」——实测踩过。
    let meanGradient: Double

    enum Verdict: String {
        case image
        case flat
        case content
    }

    /// 判定一个区域（阈值取自实测标定，见下）：
    ///   1. **有彩色** → 一定是图（氛围图是彩色照片；纯色系统底是中性色）；
    ///   2. **亮度几乎不变** → 纯色底（系统纯白/纯黑实测 `lum_std` 精确为 0.00）；
    ///   3. **有变化但平缓**（梯度小）→ 模糊的氛围图；
    ///   4. **有变化且锐利**（梯度大）→ 文字/控件占据，本区域测不了。
    ///
    /// 阈值标定（2026-10-12，iPhone 17 Pro 实截图，`--regions left,right,top,bottom`）：
    ///
    /// | 区域内容 | median_chroma | lum_std | mean_gradient |
    /// | --- | --- | --- | --- |
    /// | 模糊氛围图 | 5–32 | 2.8–8.4 | **0.26–0.28** |
    /// | 系统纯色底 | 0 | **0.00** | 0.00 |
    /// | 文字 / 卡片 / Tab 栏 | 0–4 | 45–72 | **7.2–7.9** |
    /// | 灵动岛黑块 | 0 | 36 | （双向梯度修正后）数级 |
    ///
    /// 图与内容的梯度差了一个量级（0.28 vs 7.2），阈值取 1.0 落在空档正中。
    /// **色度不能单独用**：浅色模式下被白雾压过的氛围图色度只有 4–5，与纯色底
    /// 分不开——它正是靠 `lum_std`（8.4 vs 0.00）与梯度（0.26 vs 0.00）才判得出来。
    func verdict(threshold: Double, gradientThreshold: Double = 1.0) -> Verdict {
        if medianChroma >= threshold { return .image }
        if luminanceStdDev < 1.0 { return .flat }
        return meanGradient < gradientThreshold ? .image : .content
    }
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
}

func loadImage(at path: String, cropRect: CGRect?) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ProbeError(description: "无法读取图片：\(path)")
    }
    guard let cropRect else { return image }

    let rect = cropRect.integral
    guard rect.width >= 8, rect.height >= 8,
          rect.minX >= 0, rect.minY >= 0,
          rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height) else {
        throw ProbeError(
            description: "裁剪区域超出图片范围：\(Int(rect.width))x\(Int(rect.height))"
                + " @\(Int(rect.minX)),\(Int(rect.minY))，图片 \(image.width)x\(image.height)")
    }
    // 屏幕坐标左上原点 → CGImage 裁剪也用左上原点（CGImage.cropping 的 rect 以图像
    // 左上角为原点、y 向下），与 CGWindowList 的 bounds 同一套坐标，直接用。
    guard let cropped = image.cropping(to: rect) else {
        throw ProbeError(description: "裁剪失败")
    }
    return cropped
}

/// 把「区域像素」抽成统计量。区域按比例换算成像素、交给 `CGImage.cropping`
/// 裁成小块再整块读出来算：采样点数是 10⁵ 量级，直接算比抽稀准确得多，代价
/// 可以忽略。**刻意不走「整图 draw 进上下文再偏移」**——CGImage 与 CGContext 的
/// y 轴原点相反，那个偏移量要看区域在不在竖直中段才对得上（居中区域碰巧等价、
/// 顶部/底部区域则整块取错），是这类探针最容易静默取错像素的地方；cropping 与
/// 屏幕坐标同为「左上原点、y 向下」，一条路径、一个语义。
func stats(of image: CGImage, region: Region) -> RegionStats? {
    let x0 = Int((Double(image.width) * region.x.lowerBound).rounded(.down))
    let x1 = Int((Double(image.width) * region.x.upperBound).rounded(.up))
    let y0 = Int((Double(image.height) * region.y.lowerBound).rounded(.down))
    let y1 = Int((Double(image.height) * region.y.upperBound).rounded(.up))
    let width = max(0, min(image.width, x1) - max(0, x0))
    let height = max(0, min(image.height, y1) - max(0, y0))
    guard width > 0, height > 0,
          let patch = image.cropping(to: CGRect(x: x0, y: y0, width: width, height: height))
    else { return nil }

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .none
    context.draw(patch, in: CGRect(x: 0, y: 0, width: width, height: height))

    var chromas = [Double]()
    chromas.reserveCapacity(width * height)
    var lumas = [Double]()
    lumas.reserveCapacity(width * height)
    var lumaSum = 0.0
    var lumaSquareSum = 0.0
    var rSum = 0.0, gSum = 0.0, bSum = 0.0

    for index in stride(from: 0, to: pixels.count, by: 4) {
        let r = Double(pixels[index])
        let g = Double(pixels[index + 1])
        let b = Double(pixels[index + 2])
        chromas.append(max(r, max(g, b)) - min(r, min(g, b)))
        // Rec.709 亮度：判「纯色 vs 中性内容」只要求一个稳定的相对值，不需要绝对正确。
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        lumas.append(luma)
        lumaSum += luma
        lumaSquareSum += luma * luma
        rSum += r; gSum += g; bSum += b
    }

    // 梯度：**横纵双向**相邻像素亮度差的平均。
    //
    // 只算横向不够：一个纯色黑块（iPhone 灵动岛、状态栏条带）横向上完全均匀，
    // 横向梯度会低到 0.01，于是被误判成「平缓的图」——而它其实是系统 UI。
    // 它的边缘只在纵向上出现。双向扫描把它接住（实测该区域梯度从 0.01 升到数级）。
    var gradientSum = 0.0
    var gradientCount = 0
    for row in 0..<height {
        let base = row * width
        for column in 1..<width {
            gradientSum += abs(lumas[base + column] - lumas[base + column - 1])
            gradientCount += 1
        }
    }
    for row in 1..<height {
        let base = row * width
        for column in 0..<width {
            gradientSum += abs(lumas[base + column] - lumas[base - width + column])
            gradientCount += 1
        }
    }
    let meanGradient = gradientCount > 0 ? gradientSum / Double(gradientCount) : 0

    let count = Double(chromas.count)
    chromas.sort()
    let median = chromas.isEmpty ? 0 : chromas[chromas.count / 2]
    let meanLuma = lumaSum / count
    let variance = max(0, lumaSquareSum / count - meanLuma * meanLuma)

    return RegionStats(
        region: region,
        pixelCount: chromas.count,
        meanR: rSum / count,
        meanG: gSum / count,
        meanB: bSum / count,
        medianChroma: median,
        meanChroma: chromas.reduce(0, +) / count,
        luminanceStdDev: variance.squareRoot(),
        meanGradient: meanGradient
    )
}

// MARK: - 窗口查询（macOS 截图用）

/// 返回 `window_id=<CGWindowID>` / `bounds=x,y,w,h`，找不到时退出码 1。
/// `screencapture -l <id>` 只截该窗口，省掉「整屏截图再裁」那条更脆的路。
func printWindowInfo(ownerName: String) -> Int32 {
    guard let infoList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else {
        FileHandle.standardError.write(Data("无法枚举窗口列表\n".utf8))
        return 1
    }
    for info in infoList {
        guard let owner = info[kCGWindowOwnerName as String] as? String,
              owner == ownerName,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              let number = info[kCGWindowNumber as String] as? Int,
              bounds.width >= 200, bounds.height >= 200 else { continue }
        print("window_id=\(number)")
        print("bounds=\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))")
        return 0
    }
    FileHandle.standardError.write(Data("没有找到 \(ownerName) 的可见窗口\n".utf8))
    return 1
}

// MARK: - 屏幕状态（macOS 截图可信性）

/// 屏幕是否已锁定 / 屏保。
///
/// **为什么要在截图前查这个**：锁屏后 `screencapture` 不再返回窗口内容——整屏截图
/// 是一张纯黑图，`screencapture -l <window>` 直接失败。脚本若照常判定，会得到
/// 「每一页都缺背景」这种**完全错误但看起来像真结论**的报告（实测踩过：
/// 23:50 那一轮 9 页全判 flat，实际是屏幕锁了，代码一行没改）。
/// 这种"环境坏掉伪装成被测对象坏掉"的情况必须显式分辨。
///
/// iOS 侧不受影响（模拟器自带截图口，与宿主屏幕无关），所以只对 macOS 生效。
func printScreenState() -> Int32 {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        // 取不到会话字典（极少数无窗口服务器场景）：不阻断，交由截图自身去失败。
        print("locked=unknown")
        return 0
    }
    let locked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    print("locked=\(locked ? 1 : 0)")
    return 0
}

/// 整张图是不是**数学意义上的纯黑**。
///
/// 退出码：`0` = 正常（有内容）；`1` = 全黑。
///
/// 用来分辨"环境坏了"与"页面缺背景"：锁屏 / 显示器休眠时 `screencapture` 给的就是
/// 一张纯黑图，而验收脚本若照常判定，会报出"每一页都缺背景"——一个看起来像真结论的
/// 假结论（实测踩过：一轮 9 页全判 flat，代码一行没改）。
///
/// 判据取"亮度均值 < 6 且方差 < 0.5"：真正的深色模式页面仍有渐层、文字与图标，
/// 不可能在整幅图上做到零方差——所以纯黑是系统级空图，不是页面底色。
func isBlankImage(_ image: CGImage) -> Bool {
    let names = ["left", "right", "top", "bottom"]
    var sampled = 0
    for name in names {
        guard let region = Region.named(name),
              let value = stats(of: image, region: region) else { continue }
        sampled += 1
        if value.luminanceStdDev >= 0.5 { return false }
        if max(value.meanR, max(value.meanG, value.meanB)) >= 6 { return false }
    }
    // 一个区域都没采到（图太小）：不判全黑，交由其它检查去失败。
    return sampled > 0
}

// MARK: - 自检（判据本身也要能被验证）

/// 合成两张图跑同一套判据：彩色噪点图必须判 `image`，纯白图必须判 `flat`。
/// 没有这一层，「判据坏了」和「页面真的没背景」在报告里长得一模一样。
func runSelfTest(threshold: Double) -> Int32 {
    func makeImage(fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
        let width = 640, height = 960
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = fill(x, y)
                let index = (y * width + x) * 4
                pixels[index] = r; pixels[index + 1] = g; pixels[index + 2] = b; pixels[index + 3] = 255
            }
        }
        let data = Data(pixels)
        return data.withUnsafeBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: UnsafeMutableRawPointer(mutating: base),
                      width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            return context.makeImage()
        }
    }

    // 「氛围图」样本：低饱和彩色（模拟被白色遮罩压过的照片），保证 chroma 明显 > 0。
    let photo = makeImage { x, y in
        let t = Double((x * 7 + y * 13) % 64) / 64.0
        return (UInt8(150 + 60 * t), UInt8(160 + 30 * t), UInt8(180 + 20 * t))
    }
    let flatWhite = makeImage { _, _ in (255, 255, 255) }
    let flatDark = makeImage { _, _ in (28, 28, 30) }
    // 「中性内容」样本：白底上**密集的深灰细横纹**（模拟文字笔画）。
    //
    // 刻意不做成一条宽横带：宽带的边缘只有 2 条，梯度只被摊薄到极小，会判成
    // 「平缓的图」——而真实文字区域的笔画密布、梯度大。样本必须反映被测现象的
    // 空间频率，否则自检会给出虚假的通过（第一版就是这么错的，梯度判据上线时
    // 被它抓了出来）。
    let textLike = makeImage { _, y in
        (y % 6 < 3) ? (60, 60, 60) : (255, 255, 255)
    }

    let region = Region.named("left")!
    var failures = 0

    func check(_ name: String, _ image: CGImage?, expected: RegionStats.Verdict) {
        guard let image, let value = stats(of: image, region: region) else {
            print("selftest \(name): 合成图失败"); failures += 1; return
        }
        let actual = value.verdict(threshold: threshold, gradientThreshold: gradientThreshold)
        let mark = actual == expected ? "ok" : "FAIL"
        if actual != expected { failures += 1 }
        print("selftest \(name): \(mark) 期望=\(expected.rawValue) 实际=\(actual.rawValue) " +
              "median_chroma=\(String(format: "%.1f", value.medianChroma)) " +
              "lum_std=\(String(format: "%.2f", value.luminanceStdDev))")
    }

    check("彩色噪点（氛围图）", photo, expected: .image)
    check("纯白（缺背景·浅色）", flatWhite, expected: .flat)
    check("深灰（缺背景·深色）", flatDark, expected: .flat)
    check("白底灰条（区域被内容占据）", textLike, expected: .content)

    print(failures == 0 ? "selftest: 全部通过" : "selftest: \(failures) 项失败")
    return failures == 0 ? 0 : 1
}

// MARK: - 入口

func fail(_ message: String, code: Int32 = 3) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var imagePath: String?
var regionNames = Region.defaults.map(\.name)
var threshold = 6.0
var gradientThreshold = 1.0
var cropRect: CGRect?
var useJSON = false
var quiet = false
var windowOwner: String?
var selfTest = false
var screenState = false
var blankCheck = false

func nextValue(_ flag: String) -> String {
    guard !arguments.isEmpty else { fail("\(flag) 缺少取值") }
    return arguments.removeFirst()
}

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--selftest": selfTest = true
    case "--regions": regionNames = nextValue(argument).split(separator: ",").map(String.init)
    case "--threshold": threshold = Double(nextValue(argument)) ?? threshold
    case "--gradient-threshold": gradientThreshold = Double(nextValue(argument)) ?? gradientThreshold
    case "--crop-rect": cropRect = parseRect(nextValue(argument))
    case "--json": useJSON = true
    case "--quiet": quiet = true
    case "--window": windowOwner = nextValue(argument)
    case "--screen-state": screenState = true
    case "--blank-check": blankCheck = true
    case "-h", "--help":
        print("用法见文件头注释（Scripts/ambience-probe.swift）"); exit(0)
    default:
        if argument.hasPrefix("--") { fail("未知选项：\(argument)") }
        imagePath = argument
    }
}

func parseRect(_ text: String) -> CGRect? {
    let parts = text.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else { return nil }
    return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}

if screenState { exit(printScreenState()) }
if blankCheck {
    guard let path = imagePath else { fail("--blank-check 需要图片路径") }
    let image: CGImage
    do { image = try loadImage(at: path, cropRect: cropRect) } catch { fail("\(error)") }
    exit(isBlankImage(image) ? 1 : 0)
}
if selfTest { exit(runSelfTest(threshold: threshold)) }
if let windowOwner { exit(printWindowInfo(ownerName: windowOwner)) }
guard let imagePath else { fail("缺少图片路径（或用 --selftest / --window）") }

let image: CGImage
do {
    image = try loadImage(at: imagePath, cropRect: cropRect)
} catch {
    fail("\(error)")
}

let regions = regionNames.compactMap(Region.named)
guard !regions.isEmpty else { fail("没有可用的区域：\(regionNames.joined(separator: ","))") }

var allStats: [RegionStats] = []
for region in regions {
    guard let value = stats(of: image, region: region) else { continue }
    allStats.append(value)
}

// **多区域投票**，不是「第一个能判的区域说了算」：
//   * 单区域会骗人——页面右侧可能是内容卡片、底部可能是海报流，各自给出相反的
//     结论（实测旧库页截图：top=flat、bottom=image）。让所有区域都投票，彩色
//     区域多于纯色区域才算「有图」，能挡住单个区域的偶发误判。
//   * **平票判 flat**（保守）：判错成「缺背景」会让人多看一眼，判错成「有背景」
//     则让真正的缺口溜过验收——两种错误的代价不对称。
//   * 一个区域都判不出（全是 content，即都被文字/控件占据）如实报 content：
//     那是「测不了」，不是「有图」。
var imageVotes = 0
var flatVotes = 0
var firstImage: RegionStats?
var firstFlat: RegionStats?
for value in allStats {
    switch value.verdict(threshold: threshold, gradientThreshold: gradientThreshold) {
    case .image:
        imageVotes += 1
        if firstImage == nil { firstImage = value }
    case .flat:
        flatVotes += 1
        if firstFlat == nil { firstFlat = value }
    case .content:
        break
    }
}

let verdict: RegionStats.Verdict
let finalStats: RegionStats?
if imageVotes == 0 && flatVotes == 0 {
    verdict = .content
    finalStats = allStats.first
} else if imageVotes > flatVotes {
    verdict = .image
    finalStats = firstImage
} else {
    verdict = .flat
    finalStats = firstFlat
}

let exitCode: Int32
switch verdict {
case .image: exitCode = 0
case .flat: exitCode = 1
case .content: exitCode = 2
}

if useJSON {
    let entries = allStats.map { value in
        """
        {"region":"\(value.region.name)","verdict":"\(value.verdict(threshold: threshold, gradientThreshold: gradientThreshold).rawValue)",\
        "median_chroma":\(String(format: "%.2f", value.medianChroma)),\
        "mean_chroma":\(String(format: "%.2f", value.meanChroma)),\
        "lum_std":\(String(format: "%.2f", value.luminanceStdDev)),\
        "mean_rgb":[\(Int(value.meanR)),\(Int(value.meanG)),\(Int(value.meanB))]}
        """
    }
    print("""
    {"image":"\(imagePath)","size":[\(image.width),\(image.height)],\
    "threshold":\(threshold),"verdict":"\(verdict.rawValue)",\
    "image_votes":\(imageVotes),"flat_votes":\(flatVotes),\
    "region":"\(finalStats?.region.name ?? "none")","regions":[\(entries.joined(separator: ","))]}
    """)
} else if !quiet {
    for value in allStats {
        print("  \(value.region.name): \(value.verdict(threshold: threshold, gradientThreshold: gradientThreshold).rawValue) " +
              "median_chroma=\(String(format: "%.1f", value.medianChroma)) " +
              "mean_rgb=(\(Int(value.meanR)),\(Int(value.meanG)),\(Int(value.meanB))) " +
              "lum_std=\(String(format: "%.2f", value.luminanceStdDev)) " +
              "grad=\(String(format: "%.2f", value.meanGradient)) " +
              "px=\(value.pixelCount)")
    }
    print("verdict=\(verdict.rawValue)")
    print("votes=image:\(imageVotes) flat:\(flatVotes)")
    print("region=\(finalStats?.region.name ?? "none")")
    print("median_chroma=\(String(format: "%.2f", finalStats?.medianChroma ?? 0))")
    print("image_size=\(image.width)x\(image.height)")
}

exit(exitCode)
