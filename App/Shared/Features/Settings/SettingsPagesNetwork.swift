import JellyfinKit
import SwiftUI

/// 设置 → 网络：自定义 User-Agent。**全局**，不按服务器档案分——
/// 部分服务器开了播放器白名单，这里填白名单内的播放器 UA 即可通过。
struct NetworkSettingsView: View {
    /// 空 = 系统默认。与 `ClientIdentity`（JellyfinKit）同 key，
    /// 三条请求发送口每条即时读取，改完不需要重连。
    @AppStorage(ClientIdentity.customUserAgentKey) private var customUserAgent = ""

    var body: some View {
        Form {
            Section {
                // iOS 的 grouped 行内原生样式是无框；圆角框只贴合 macOS。
                TextField("自定义 User-Agent（可选）", text: $customUserAgent, prompt: Text("留空使用默认"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                Text("部分服务器开了播放器白名单，会把非白名单客户端的请求拒之门外；填入白名单内的播放器 UA（如 SenPlayer 的）即可通过。对所有服务器生效，浏览与拉流即时生效、无需重连；控制字符会被剔除。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .settingsRowBackground()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }
}
