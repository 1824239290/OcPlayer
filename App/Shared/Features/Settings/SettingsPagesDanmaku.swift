import AppDesignKit
import DanmakuKit
import SwiftUI

/// 设置 → 弹幕：自动加载、弹弹play 网关与 anime-skip 跳过片头源。
struct DanmakuSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(DanmakuModel.self) private var danmakuModel

    @State private var isEditingGateway = false

    var body: some View {
        Form {
            Section {
                Toggle("自动加载弹幕", isOn: Binding(
                    get: { danmakuModel.danmaku.isAutoLoadingEnabled },
                    set: { app.setDanmakuAutoLoadingEnabled($0) }
                ))
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
                    Text("未配置网关时不请求网络弹幕，播放不受影响。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                TextField("anime-skip Client ID（可选）", text: Binding(
                    get: { danmakuModel.animeSkipClientID },
                    set: { danmakuModel.animeSkipClientID = $0 }
                ))
                Text("填入后启用 anime-skip 跳过片头源（在 anime-skip.com 注册获取）。TheIntroDB 免密钥自动启用。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .settingsRowBackground()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("网关地址")
                            .font(.subheadline.weight(.semibold))
                        TextField(
                            "",
                            text: $gatewayURL,
                            prompt: Text("https://gateway.example.com")
                        )
                        .textContentType(.URL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        Text("仅支持 HTTPS 根地址；留空恢复默认网关。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.subheadline.weight(.semibold))
                        SecureField(
                            "",
                            text: $key,
                            prompt: Text("由网关管理员签发")
                        )
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        Text("Key 只通过 X-API-Key 请求头发送，不写入播放地址或诊断日志。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .navigationTitle("弹幕网关")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSubmit(
                            gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            key.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!gatewayURLIsValid)
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 340)
        #endif
    }

    private var gatewayURLIsValid: Bool {
        let value = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || DandanplaySettingsStore.normalizedURL(from: value) != nil
    }
}
