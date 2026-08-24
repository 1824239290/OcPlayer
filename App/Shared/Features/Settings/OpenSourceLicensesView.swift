import Foundation
import SwiftUI

/// App 的 SwiftPM 依赖图或随 Erika 二进制分发的开源组件。
///
/// 版本固定的 SwiftPM 项目与 `Package.resolved` 对齐；Erika 及其原生依赖随每次打包
/// 解析到的正式版变化，因此不在源码里写死版本号。
struct OpenSourceComponent: Identifiable, Sendable {
    let id: String
    let name: String
    let version: String?
    let license: String
    let purpose: String
    let homepage: URL
    let licenseURL: URL
    let bundledLicensePaths: [String]
}

struct OpenSourceComponentGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let components: [OpenSourceComponent]
}

enum OpenSourceLicenseCatalog {
    static let groups: [OpenSourceComponentGroup] = [
        OpenSourceComponentGroup(
            id: "direct",
            title: "主要依赖",
            components: [
                component(
                    id: "erika",
                    name: "Erika",
                    license: "MPL-2.0",
                    purpose: "Rust 播放内核，负责音视频解码、字幕与弹幕渲染。打包时使用最新正式版；确切版本见随包 MANIFEST。",
                    homepage: "https://github.com/AimesSoft/Erika",
                    licenseURL: "https://www.mozilla.org/MPL/2.0/",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/erika/MANIFEST.txt",
                        "THIRD_PARTY_LICENSES/erika/LICENSE",
                        "THIRD_PARTY_LICENSES/erika/THIRD_PARTY_NOTICES.md",
                    ]
                ),
                component(
                    id: "jellyfin-sdk-swift",
                    name: "jellyfin-sdk-swift",
                    version: "3.0.0",
                    license: "MPL-2.0",
                    purpose: "Jellyfin 官方 Swift SDK，用于登录、媒体库浏览、PlaybackInfo 与播放进度上报。",
                    homepage: "https://github.com/jellyfin/jellyfin-sdk-swift",
                    licenseURL: "https://www.mozilla.org/MPL/2.0/",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/swiftpm/jellyfin-sdk-swift/LICENSE-MPL-2.0",
                    ]
                ),
                component(
                    id: "get",
                    name: "Get",
                    version: "2.2.1",
                    license: "MIT",
                    purpose: "jellyfin-sdk-swift 使用的 HTTP 客户端。",
                    homepage: "https://github.com/kean/Get",
                    licenseURL: "https://opensource.org/license/mit",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/swiftpm/Get/LICENSE",
                    ]
                ),
                component(
                    id: "grdb",
                    name: "GRDB.swift",
                    version: "7.11.1",
                    license: "MIT",
                    purpose: "BangumiKit 的本地 SQLite 层，缓存 Bangumi 收藏与章节进度。",
                    homepage: "https://github.com/groue/GRDB.swift",
                    licenseURL: "https://opensource.org/license/mit",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/swiftpm/GRDB.swift/LICENSE",
                    ]
                ),
                component(
                    id: "danmaku-renderkit",
                    name: "DanmakuKit（DanmakuRenderKit）",
                    version: "1.6.0",
                    license: "MIT",
                    purpose: "vendored 的弹幕渲染层（qyz777/DanmakuKit）：轨道模型「入轨时追击判定、入轨后不换轨」，取代 Erika 内核 DFM+ 弹幕子系统。",
                    homepage: "https://github.com/qyz777/DanmakuKit",
                    licenseURL: "https://opensource.org/license/mit",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/DanmakuRenderKit/LICENSE",
                        "THIRD_PARTY_LICENSES/DanmakuRenderKit/PROVENANCE.md",
                    ]
                ),
            ]
        ),
        OpenSourceComponentGroup(
            id: "swift-runtime",
            title: "SwiftPM 依赖",
            components: [
                component(
                    id: "swift-nio-transport-services",
                    name: "swift-nio-transport-services",
                    version: "1.28.0",
                    license: "Apache-2.0",
                    purpose: "Jellyfin 服务器发现所需的 Network.framework 传输实现。",
                    homepage: "https://github.com/apple/swift-nio-transport-services",
                    licenseURL: "https://www.apache.org/licenses/LICENSE-2.0",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/swiftpm/swift-nio-transport-services/LICENSE.txt",
                    ]
                ),
                component(
                    id: "swift-nio",
                    name: "swift-nio",
                    version: "2.101.3",
                    license: "Apache-2.0",
                    purpose: "swift-nio-transport-services 的事件循环、通道和网络基础类型。",
                    homepage: "https://github.com/apple/swift-nio",
                    licenseURL: "https://www.apache.org/licenses/LICENSE-2.0",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/swiftpm/swift-nio/LICENSE.txt",
                        "THIRD_PARTY_LICENSES/swiftpm/swift-nio/NOTICE.txt",
                    ]
                ),
                component(
                    id: "swift-atomics",
                    name: "swift-atomics",
                    version: "1.3.1",
                    license: "Apache-2.0",
                    purpose: "SwiftNIO 使用的原子操作类型。",
                    homepage: "https://github.com/apple/swift-atomics",
                    licenseURL: "https://www.apache.org/licenses/LICENSE-2.0",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/swiftpm/swift-atomics/LICENSE.txt",
                    ]
                ),
                component(
                    id: "swift-collections",
                    name: "swift-collections",
                    version: "1.6.0",
                    license: "Apache-2.0",
                    purpose: "SwiftNIO 使用的高效集合类型。",
                    homepage: "https://github.com/apple/swift-collections",
                    licenseURL: "https://www.apache.org/licenses/LICENSE-2.0",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/swiftpm/swift-collections/LICENSE.txt",
                    ]
                ),
                component(
                    id: "swift-system",
                    name: "swift-system",
                    version: "1.8.1",
                    license: "Apache-2.0",
                    purpose: "SwiftNIO 依赖图中的跨平台系统调用接口。",
                    homepage: "https://github.com/apple/swift-system",
                    licenseURL: "https://www.apache.org/licenses/LICENSE-2.0",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/swiftpm/swift-system/LICENSE.txt",
                    ]
                ),
            ]
        ),
        OpenSourceComponentGroup(
            id: "erika-runtime",
            title: "Erika 内置组件",
            components: [
                component(
                    id: "ffmpeg",
                    name: "FFmpeg",
                    license: "LGPL-3.0",
                    purpose: "音视频封装、解封装与编解码；Erika 使用禁用 GPL 组件的 LGPL profile 构建。",
                    homepage: "https://ffmpeg.org",
                    licenseURL: "https://www.gnu.org/licenses/lgpl-3.0.html",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/erika/licenses/LICENSE.FFmpeg.md",
                        "THIRD_PARTY_LICENSES/erika/licenses/LICENSE.LGPL-3.0",
                    ]
                ),
                component(
                    id: "dav1d",
                    name: "dav1d",
                    license: "BSD-2-Clause",
                    purpose: "AV1 视频解码。",
                    homepage: "https://code.videolan.org/videolan/dav1d",
                    licenseURL: "https://opensource.org/license/bsd-2-clause",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/erika/licenses/LICENSE.dav1d",
                    ]
                ),
                component(
                    id: "libass",
                    name: "libass",
                    license: "ISC",
                    purpose: "ASS/SSA 字幕排版与渲染。",
                    homepage: "https://github.com/libass/libass",
                    licenseURL: "https://opensource.org/license/isc-license-txt",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/erika/licenses/LICENSE.libass",
                    ]
                ),
                component(
                    id: "freetype",
                    name: "FreeType",
                    license: "FTL",
                    purpose: "字体栅格化；当前构建采用 FreeType License。",
                    homepage: "https://freetype.org",
                    licenseURL: "https://freetype.org/license.html",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/erika/licenses/LICENSE.FreeType",
                    ]
                ),
                component(
                    id: "harfbuzz",
                    name: "HarfBuzz",
                    license: "MIT (Old Style)",
                    purpose: "复杂文字塑形。",
                    homepage: "https://github.com/harfbuzz/harfbuzz",
                    licenseURL: "https://github.com/harfbuzz/harfbuzz/blob/main/COPYING",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/erika/licenses/LICENSE.HarfBuzz",
                    ]
                ),
                component(
                    id: "fribidi",
                    name: "FriBidi",
                    license: "LGPL-2.1-or-later",
                    purpose: "双向文字排版。",
                    homepage: "https://github.com/fribidi/fribidi",
                    licenseURL: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/erika/licenses/LICENSE.LGPL-2.1",
                    ]
                ),
                component(
                    id: "zlib",
                    name: "zlib",
                    license: "zlib",
                    purpose: "数据压缩与解压。",
                    homepage: "https://zlib.net",
                    licenseURL: "https://www.zlib.net/zlib_license.html",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/erika/licenses/LICENSE.zlib",
                    ]
                ),
                component(
                    id: "soundtouch",
                    name: "SoundTouch",
                    license: "LGPL-2.1",
                    purpose: "变速播放时的音频时间伸缩。",
                    homepage: "https://www.surina.net/soundtouch/",
                    licenseURL: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/erika/licenses/LICENSE.LGPL-2.1",
                    ]
                ),
                component(
                    id: "droid-sans-fallback",
                    name: "Droid Sans Fallback",
                    license: "Apache-2.0",
                    purpose: "Erika 内置的字幕回退字体。",
                    homepage: "https://android.googlesource.com/platform/frameworks/base/+/master/data/fonts/",
                    licenseURL: "https://www.apache.org/licenses/LICENSE-2.0",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/erika/licenses/NOTICE.Droid-Sans-Fallback.md",
                        "THIRD_PARTY_LICENSES/erika/licenses/LICENSE.Apache-2.0",
                    ]
                ),
                component(
                    id: "artcnn",
                    name: "ArtCNN",
                    license: "MIT",
                    purpose: "Erika 内置的图像放大模型权重。",
                    homepage: "https://github.com/Artoriuz/ArtCNN",
                    licenseURL: "https://opensource.org/license/mit",
                    bundledLicensePaths: [
                        "THIRD_PARTY_LICENSES/erika/licenses/LICENSE.ArtCNN",
                    ]
                ),
            ]
        ),
    ]

    static let componentCount = groups.reduce(0) { $0 + $1.components.count }

    private static func component(
        id: String,
        name: String,
        version: String? = nil,
        license: String,
        purpose: String,
        homepage: String,
        licenseURL: String,
        bundledLicensePaths: [String]
    ) -> OpenSourceComponent {
        guard let homepageURL = URL(string: homepage),
              let resolvedLicenseURL = URL(string: licenseURL) else {
            preconditionFailure("Invalid open-source catalog URL for \(name)")
        }
        return OpenSourceComponent(
            id: id,
            name: name,
            version: version,
            license: license,
            purpose: purpose,
            homepage: homepageURL,
            licenseURL: resolvedLicenseURL,
            bundledLicensePaths: bundledLicensePaths
        )
    }
}

struct OpenSourceLicensesView: View {
    var body: some View {
        List {
            Section {
                Text("OcPlayer 使用以下开源项目。发布包同时附带对应许可证文本与 Erika 原生依赖通知。")
                    .foregroundStyle(.secondary)
            }

            ForEach(OpenSourceLicenseCatalog.groups) { group in
                Section(group.title) {
                    ForEach(group.components) { component in
                        NavigationLink {
                            OpenSourceLicenseDetailView(component: component)
                        } label: {
                            OpenSourceComponentRow(component: component)
                        }
                    }
                }
            }
        }
        .navigationTitle("开源许可证")
    }
}

private struct OpenSourceComponentRow: View {
    let component: OpenSourceComponent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                if let version = component.version {
                    Text("版本 \(version)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            Text(component.license)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OpenSourceLicenseDetailView: View {
    let component: OpenSourceComponent
    @State private var bundledText: String?

    var body: some View {
        Form {
            Section("项目") {
                LabeledContent("名称", value: component.name)
                if let version = component.version {
                    LabeledContent("版本", value: version)
                }
                LabeledContent("许可证", value: component.license)
                Link(destination: component.homepage) {
                    Label("项目主页", systemImage: "arrow.up.right.square")
                }
                Link(destination: component.licenseURL) {
                    Label("许可证说明", systemImage: "doc.text")
                }
            }

            Section("用途") {
                Text(component.purpose)
                    .textSelection(.enabled)
            }

            if let bundledText {
                Section("随包许可证文本") {
                    Text(bundledText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(component.name)
        .task(id: component.id) {
            bundledText = BundledLicenseText.load(paths: component.bundledLicensePaths)
        }
    }
}

private enum BundledLicenseText {
    static func load(paths: [String], bundle: Bundle = .main) -> String? {
        guard let resourceURL = bundle.resourceURL else { return nil }

        let texts = paths.compactMap { relativePath -> String? in
            let fileURL = resourceURL.appendingPathComponent(relativePath)
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return nil
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n\n---\n\n")
    }
}
