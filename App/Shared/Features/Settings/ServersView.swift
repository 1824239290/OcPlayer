import AppDesignKit
import JellyfinKit
import SwiftUI

/// 「管理服务器」子页：全部已存档案（含正在使用的）的切换与删除。
///
/// 主设置页只保留当前服务器信息与启动默认选择；列表操作收进这里后，
/// 当前服务器也出现在列表里（带「使用中」标），不再需要先「连接其它服务器」
/// 才能看到自己的档案。删除连 token 一起清，不可恢复，走二次确认。
struct ServersView: View {
    @Environment(AppModel.self) private var app

    /// 待确认删除的已保存服务器档案（删除连 token 一起清，不可恢复）。
    @State private var pendingDeleteProfile: ServerProfile?

    var body: some View {
        Form {
            Section {
                ForEach(app.store.profiles) { profile in
                    row(for: profile)
                }
            } footer: {
                Text("正在使用的服务器不能删除；想删它先退出 Jellyfin 登录。默认启动的服务器带星标。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("管理服务器")
        .confirmationDialog(
            "删除服务器？",
            isPresented: Binding(
                get: { pendingDeleteProfile != nil },
                set: { if !$0 { pendingDeleteProfile = nil } }
            ),
            presenting: pendingDeleteProfile
        ) { profile in
            Button("删除「\(profile.serverName)」", role: .destructive) {
                app.store.remove(id: profile.id)
                pendingDeleteProfile = nil
            }
        } message: { _ in
            Text("服务器地址与登录凭据会一起删除。下次想用这台需要重新输入地址并登录。")
        }
    }

    @ViewBuilder
    private func row(for profile: ServerProfile) -> some View {
        let isCurrent = profile.id == app.server?.profile.id
        HStack(spacing: 10) {
            Image(systemName: profile.kind == .emby ? "tv" : "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(profile.serverName).font(.callout)
                    Text(profile.kind.displayName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    if app.store.defaultServerID == profile.id {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("启动默认")
                    }
                    if isCurrent {
                        Text("使用中")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    } else if app.store.token(for: profile) == nil {
                        Text("需重新登录").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text(profile.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !isCurrent {
                Button("切换") {
                    Task { await app.switchToServer(profile) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(role: .destructive) {
                    pendingDeleteProfile = profile
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }
}
