import AppDesignKit
import PlaybackKit
import SwiftUI

/// 设置 → 播放：网络缓冲、跳过片头/片尾与播放内核（`PlaybackKernelSection`）。
struct PlaybackSettingsView: View {
    /// 预读档位：直接绑 UserDefaults 的原始 key（@AppStorage 可观察，
    /// 别处改了 Picker 也会刷新）。非法值显示为 0（与 PlaybackPreferences 的
    /// 读取校验一致）；Picker 只写合法档位。
    @AppStorage(SettingsKeys.httpReadAheadMiB) private var storedReadAheadMiB = 0
    private var readAheadMiB: Int {
        PlaybackPreferences.readAheadOptionsMiB.contains(storedReadAheadMiB) ? storedReadAheadMiB : 0
    }
    /// 回退缓冲档位：同预读档位的 @AppStorage 套路。
    @AppStorage(SettingsKeys.httpBackBufferMiB) private var storedBackBufferMiB = 0
    private var backBufferMiB: Int {
        PlaybackPreferences.backBufferOptionsMiB.contains(storedBackBufferMiB) ? storedBackBufferMiB : 0
    }
    /// 跳过片头/片尾开关（默认开）与保底片尾保留秒数（默认 10）。与
    /// PlaybackPreferences 同 key，播放中改动即生效（提示按钮每拍进度重读）。
    @AppStorage(SettingsKeys.skipIntro) private var skipIntroEnabled = true
    @AppStorage(SettingsKeys.skipOutro) private var skipOutroEnabled = true
    @AppStorage(SettingsKeys.outroRetentionSeconds) private var storedOutroRetention = 10
    private var outroRetentionSeconds: Int {
        PlaybackPreferences.outroRetentionOptionsSeconds.contains(storedOutroRetention)
            ? storedOutroRetention : 10
    }
    /// 默认字幕语言。存 `SubtitleLanguagePreference.rawValue`；旧版本从没写过这个
    /// key / 值被人手改坏时按默认档（中文优先·简体）显示，与 `PlaybackPreferences`
    /// 的读取语义保持一致。
    @AppStorage(SettingsKeys.subtitleLanguagePreference)
    private var storedSubtitleLanguage = SubtitleLanguagePreference.chineseSimplified.rawValue
    private var subtitleLanguage: SubtitleLanguagePreference {
        SubtitleLanguagePreference(rawValue: storedSubtitleLanguage) ?? .chineseSimplified
    }

    var body: some View {
        Form {
            Section("网络缓冲") {
                Picker("网络预读缓冲", selection: Binding(
                    get: { readAheadMiB },
                    set: { storedReadAheadMiB = $0 }
                )) {
                    ForEach(PlaybackPreferences.readAheadOptionsMiB, id: \.self) { mib in
                        Text(mib == 0 ? "默认（2 MiB）" : "\(mib) MiB").tag(mib)
                    }
                }
                // 内核用持久流预取（开放式 GET 长连接，背压就是 TCP），档位不再
                // 对应带宽门槛：深度只影响内存占用与抗卡顿能力，弱网下无需刻意调小。
                Text("数值越大越能抗带宽抖动，内存占用相应增加。内核用持久流预取，弱网下无需刻意调小。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Picker("回退缓冲", selection: Binding(
                    get: { backBufferMiB },
                    set: { storedBackBufferMiB = $0 }
                )) {
                    ForEach(PlaybackPreferences.backBufferOptionsMiB, id: \.self) { mib in
                        Text(mib == 0 ? "默认（16 MiB）" : "\(mib) MiB").tag(mib)
                    }
                }
                // 回退预算与码率挂钩：16 MiB 在 71 Mbps 下只够 -1.8 秒，
                // 高码率片源想随意回退 10 秒需要 ~89 MB。低码率番剧默认档已够数分钟。
                Text("已播内容保留在缓存里，回退落在这段内不发网络请求。高码率片源建议调大（16 MiB 在 70 Mbps 下只够回退约 2 秒）。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .settingsRowBackground()

            Section("跳过片头与片尾") {
                Toggle("跳过片头", isOn: $skipIntroEnabled)
                Toggle("跳过片尾", isOn: $skipOutroEnabled)
                Picker("片尾保留", selection: Binding(
                    get: { outroRetentionSeconds },
                    set: { storedOutroRetention = $0 }
                )) {
                    ForEach(PlaybackPreferences.outroRetentionOptionsSeconds, id: \.self) { seconds in
                        Text(seconds == 0 ? "不保留" : "\(seconds) 秒").tag(seconds)
                    }
                }
                .disabled(!skipOutroEnabled)
                Text("播放到片头/片尾时出现「跳过」按钮；片尾保留指保底跳过后停在片尾结束前多久，不保留则直接跳到片尾尽头。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .settingsRowBackground()

            Section("字幕") {
                Picker("默认字幕语言", selection: Binding(
                    get: { subtitleLanguage },
                    set: { storedSubtitleLanguage = $0.rawValue }
                )) {
                    ForEach(SubtitleLanguagePreference.allCases, id: \.self) { preference in
                        Text(Self.label(for: preference)).tag(preference)
                    }
                }
                Text("打开新片源时按这里的偏好挑字幕轨：有中文字幕就自动切过去（用不到第一条外语字幕），没有中文则保持片源自带的默认选择。在播放器里自己选过之后，本片不再自动改动。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .settingsRowBackground()

            SubtitleAppearanceSection()

            PlaybackKernelSection()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }

    private static func label(for preference: SubtitleLanguagePreference) -> String {
        switch preference {
        case .chineseSimplified: "中文优先（简体）"
        case .chineseTraditional: "中文优先（繁体）"
        case .followSource: "跟随文件默认"
        case .off: "默认关闭"
        }
    }
}
