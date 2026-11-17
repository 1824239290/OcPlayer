import AppDesignKit
import JellyfinKit
import SwiftUI

/// 设置 → 网络：自定义 User-Agent。**全局**，不按服务器档案分——
/// 部分服务器开了播放器白名单，这里填白名单内的播放器 UA 即可通过。
struct NetworkSettingsView: View {
    /// 空 = 系统默认。与 `ClientIdentity`（JellyfinKit）同 key，
    /// 三条请求发送口每条即时读取，改完不需要重连。
    @AppStorage(ClientIdentity.customUserAgentKey) private var customUserAgent = ""

    var body: some View {
        // 2026-10-22（B 方案）：设置页整体脱离 `Form`，改成 `ScrollView` + 玻璃卡片流
        // ——与 MoviePilot 下载页同一套承载；一段 = 一张 `SettingsGlassSection`。
        SettingsGlassPage {
            SettingsGlassSection {
                // UA 需要禁自动更正 / 禁首字母大写，macOS 还要 `.roundedBorder`——
                // 这些链式修饰 `SettingsTextRow` 包不住 → 用 `SettingsFieldRow` 把行形态
                // 交给原语。iOS 的原生行内样式是无框；圆角框只贴合 macOS。
                SettingsFieldRow("User-Agent") {
                    TextField("自定义 User-Agent（可选）", text: $customUserAgent, prompt: Text("留空使用默认"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .labelsHidden()
                }
                SettingsNote("部分服务器开了播放器白名单，会把非白名单客户端的请求拒之门外；填入白名单内的播放器 UA（如 SenPlayer 的）即可通过。对所有服务器生效，浏览与拉流即时生效、无需重连；控制字符会被剔除。")
            }
        }
    }
}
