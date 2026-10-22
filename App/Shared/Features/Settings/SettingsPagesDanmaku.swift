import AppDesignKit
import DanmakuKit
import SwiftUI

/// 设置 → 弹幕：自动加载、弹弹play 网关与 anime-skip 跳过片头源。
struct DanmakuSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(DanmakuModel.self) private var danmakuModel

    @State private var isEditingGateway = false

    var body: some View {
        // 2026-10-22（B 方案）：设置页整体脱离 `Form`，改成 `ScrollView` + 玻璃卡片流
        // ——与 MoviePilot 下载页同一套承载；一段 = 一张 `SettingsGlassSection`。
        SettingsGlassPage {
            SettingsGlassSection {
                Toggle("自动加载弹幕", isOn: Binding(
                    get: { danmakuModel.danmaku.isAutoLoadingEnabled },
                    set: { app.setDanmakuAutoLoadingEnabled($0) }
                ))
                .neutralSwitch()
                SettingsGlassDivider()
                // **例外（保留原样）**：网关行是「标题 + 值 + 配置按钮」的组合行，
                // 不是单个 Picker/TextField/Button，原样作为一行放进卡内。
                HStack {
                    Text("网关")
                    Spacer()
                    Text(danmakuModel.dandanplayIsConfigured
                         ? danmakuModel.dandanplayGatewayURLString : "未配置")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("配置") {
                        isEditingGateway = true
                    }
                }
                if !danmakuModel.dandanplayIsConfigured {
                    SettingsNote("未配置网关时不请求网络弹幕，播放不受影响。")
                }
                SettingsGlassDivider()
                SettingsTextRow("anime-skip Client ID（可选）", text: Binding(
                    get: { danmakuModel.animeSkipClientID },
                    set: { danmakuModel.animeSkipClientID = $0 }
                ))
                SettingsNote("填入后启用 anime-skip 跳过片头源（在 anime-skip.com 注册获取）。TheIntroDB 免密钥自动启用。")
            }
        }
        .sheet(isPresented: $isEditingGateway) {
            DanmakuGatewayEntrySheet(
                initialURL: danmakuModel.dandanplayGatewayURLString,
                initialKey: danmakuModel.dandanplayAPIKey
            ) { url, key in
                Task { await app.updateDanmakuGateway(urlString: url, apiKey: key) }
            }
        }
    }
}

/// 弹幕网关地址与 API Key 编辑弹窗。Key 留空表示停用网络弹幕。
struct DanmakuGatewayEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var gatewayURL: String
    @State private var key: String
    let onSubmit: (String, String) -> Void

    init(initialURL: String, initialKey: String, onSubmit: @escaping (String, String) -> Void) {
        _gatewayURL = State(initialValue: initialURL)
        _key = State(initialValue: initialKey)
        self.onSubmit = onSubmit
    }

    var body: some View {
        FormSheetShell(
            title: "弹幕网关",
            confirmEnabled: gatewayURLIsValid,
            onConfirm: {
                onSubmit(
                    gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    key.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                dismiss()
            },
            confirmLabel: { Text("保存") }
        ) {
            LabeledCredentialField(
                label: "网关地址",
                text: $gatewayURL,
                prompt: "https://gateway.example.com",
                caption: "仅支持 HTTPS 根地址；留空恢复默认网关。",
                kind: .url
            )

            Divider()

            LabeledCredentialField(
                label: "API Key",
                text: $key,
                prompt: "由网关管理员签发",
                caption: "Key 只通过 X-API-Key 请求头发送，不写入播放地址或诊断日志。",
                kind: .secure
            )
        }
        #if os(macOS)
        .frame(height: 340)
        #endif
    }

    private var gatewayURLIsValid: Bool {
        let value = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || DandanplaySettingsStore.normalizedURL(from: value) != nil
    }
}
