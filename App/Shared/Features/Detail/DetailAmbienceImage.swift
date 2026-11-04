/// 氛围池小图与详情整组图片的缓存参数。详情清晰层/模糊层共用 art 档像素。
enum DetailAmbienceImage {
    /// 氛围池与进页快照的小图 URL 档。
    static let urlWidth = 800
    /// 氛围池预热、轮播与进页快照共用的解码档。
    static let decodePixels = 512

    static let artURLWidth = 1600
    static let artDecodePixels = 1920
}
