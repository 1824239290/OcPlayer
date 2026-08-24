import SwiftUI

/// 种子条件筛选弹窗（对齐 MP 网页端 TorrentFilterBar 的七组条件）：
/// 站点 / 促销 / 季集 / 制作组 / 编码 / 版本 / 分辨率。
/// 多选、精确匹配；**不选 = 不过滤**。候选值从当前搜索结果聚合。
struct MoviePilotTorrentFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    let options: TorrentFilterEngine.Options
    @Binding var filters: TorrentFilters

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("清除全部筛选") {
                        filters = TorrentFilters()
                    }
                } footer: {
                    Text("不选任何值的条件即不过滤；多个值命中任意一个即保留。")
                }

                group("站点", values: options.site, selection: $filters.site)
                group("促销", values: options.freeState, selection: $filters.freeState)
                group("季集", values: options.season, selection: $filters.season)
                group("制作组", values: options.releaseGroup, selection: $filters.releaseGroup)
                group("编码", values: options.videoCode, selection: $filters.videoCode)
                group("版本", values: options.edition, selection: $filters.edition)
                group("分辨率", values: options.resolution, selection: $filters.resolution)
            }
            .navigationTitle("筛选")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 560)
        #endif
    }

    @ViewBuilder
    private func group(
        _ title: String, values: [String], selection: Binding<Set<String>>
    ) -> some View {
        // 全空（比如搜索结果里没有制作组信息）的组整组不显示，弹窗不堆空标题。
        if !values.isEmpty {
            Section(title) {
                ForEach(values, id: \.self) { value in
                    Button {
                        if selection.wrappedValue.contains(value) {
                            selection.wrappedValue.remove(value)
                        } else {
                            selection.wrappedValue.insert(value)
                        }
                    } label: {
                        HStack {
                            Text(value)
                            Spacer()
                            if selection.wrappedValue.contains(value) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
