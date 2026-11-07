import AppDesignKit
import SwiftUI

/// 每次首次进入搜索默认检索媒体库；用户主动切换才请求其他服务。
enum UnifiedSearchSource: String, CaseIterable, Identifiable {
    case library, bangumi, moviepilot
    static let defaultSource: Self = .library
    var id: Self { self }
    var title: String {
        switch self {
        case .library: "搜索媒体库"
        case .bangumi: "搜索 Bangumi"
        case .moviepilot: "搜索 MoviePilot"
        }
    }
    var prompt: String { self == .library ? "搜索全部媒体库" : title }
    var symbol: String {
        switch self {
        case .library: "externaldrive"
        case .bangumi: "sparkles.tv"
        case .moviepilot: "arrow.down.circle"
        }
    }
}

/// 原生搜索框下的来源列表，不把来源名称写入用户的关键词。
private struct UnifiedSearchFieldModifier: ViewModifier {
    @Binding var query: String
    @Binding var source: UnifiedSearchSource

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(source.prompt))
            #else
            .searchable(text: $query, prompt: Text(source.prompt))
            #endif
            .searchSuggestions {
                ForEach(UnifiedSearchSource.allCases) { option in
                    Button {
                        source = option
                    } label: {
                        HStack(spacing: 10) {
                            sourceIcon(option)
                                .frame(width: 20, height: 18)
                            Text(option.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Spacer()
                            Image(systemName: "checkmark")
                                .opacity(source == option ? 1 : 0)
                                .frame(width: 16)
                        }
                    }
                    .accessibilityLabel(option.title)
                }
            }
    }

    @ViewBuilder
    private func sourceIcon(_ option: UnifiedSearchSource) -> some View {
        switch option {
        case .library:
            Image(systemName: "externaldrive")
        case .bangumi:
            Image("bangumi-logo-color")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 18, height: 18)
        case .moviepilot:
            Image("moviepilot-logo")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 18, height: 18)
        }
    }
}

extension View {
    func unifiedSearchField(query: Binding<String>, source: Binding<UnifiedSearchSource>) -> some View {
        modifier(UnifiedSearchFieldModifier(query: query, source: source))
    }
}

/// 复用各来源的结果、分页和资源操作，搜索输入由外层唯一持有。
struct UnifiedSearchContent: View {
    @Binding var query: String
    let source: UnifiedSearchSource
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKeys.bangumiEnabled) private var bangumiEnabled = true
    @AppStorage(SettingsKeys.moviepilotEnabled) private var moviepilotEnabled = true

    var body: some View {
        Group {
            switch source {
            case .library:
                if app.server != nil {
                    HomeSearchContent(query: $query)
                } else {
                    PageFillingState {
                        EmptyState(empty: "先连接服务器再搜索媒体库", systemImage: "wifi.exclamationmark")
                    }
                }
            case .bangumi:
                if bangumiEnabled { BangumiHomeView(externalSearchQuery: query) }
                else { disabledSource("Bangumi") }
            case .moviepilot:
                if moviepilotEnabled { MoviePilotHomeView(externalSearchQuery: query) }
                else { disabledSource("MoviePilot") }
            }
        }
    }

    private func disabledSource(_ name: String) -> some View {
        PageFillingState {
            EmptyState(empty: "先启用 \(name)", systemImage: "switch.2",
                       message: "在设置中启用后即可搜索。")
        }
    }
}
