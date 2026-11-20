using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using OcPlayer.Windows.Services;
using OcPlayer.Windows.Controls;
using Windows.System;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows;

public sealed partial class MainWindow
{
    private CancellationTokenSource? _switchServer;
    internal void HandleExternalActivation(Microsoft.Windows.AppLifecycle.AppActivationArguments activation)
    {
        if (activation.Data is global::Windows.ApplicationModel.Activation.IFileActivatedEventArgs files
            && files.Files.FirstOrDefault() is global::Windows.Storage.StorageFile file) OpenSource(file.Path);
        else if (activation.Data is global::Windows.ApplicationModel.Activation.IProtocolActivatedEventArgs protocol
            && protocol.Uri.Scheme is "http" or "https" or "file") OpenSource(protocol.Uri.AbsoluteUri);
    }
    private readonly DispatcherTimer _coreEvents = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private void InitializeBrowserParity()
    {
        Root.RequestedTheme = _model.ThemeMode switch { "dark" => ElementTheme.Dark, "light" => ElementTheme.Light, _ => ElementTheme.Default };
        WindowRoot.RequestedTheme = Root.RequestedTheme;
        _model.DarkTheme = Root.ActualTheme == ElementTheme.Dark;
        Controls.DemoUi.IsDark = _model.DarkTheme;
        var open = new KeyboardAccelerator { Key = VirtualKey.O, Modifiers = VirtualKeyModifiers.Control };
        open.Invoked += async (_, args) => { args.Handled = true; await OpenLocalFile(); };
        var link = new KeyboardAccelerator { Key = VirtualKey.O, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift };
        link.Invoked += (_, args) => { args.Handled = true; OpenLink_Click(this, new RoutedEventArgs()); };
        WindowRoot.KeyboardAccelerators.Add(open); WindowRoot.KeyboardAccelerators.Add(link);
        _coreEvents.Tick += (_, _) => { if (!_closing) App.Core?.DrainEvents(); }; _coreEvents.Start();
        System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged += NetworkAddressChanged;
        Root.Loaded += (_, _) =>
        {
            if (App.Core is { } core) core.SessionExpired += SessionExpired;
        };
        Root.Loaded += async (_, _) => { if (!App.DemoMode && !Environment.GetCommandLineArgs().Any(x => x.StartsWith("--verify"))) await Features.RuntimeSettingsPages.CheckAutomaticUpdate(Root); };
        Closed += (_, _) => { _switchServer?.Cancel(); _avatarLoad?.Cancel(); _coreEvents.Stop(); System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged -= NetworkAddressChanged; if (App.Core is { } core) core.SessionExpired -= SessionExpired; };
    }
    private static async Task<Preview.DemoMedia> EnrichDetail(Preview.DemoMedia media, MediaServer server, CancellationToken token)
    {
        try { return await App.Core!.Tmdb.Enrich(media, server.Profile.Id, token); }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { return media with { DetailWarning = "TMDB 补全失败，已保留服务器资料：" + ex.Message }; }
    }
    private void NetworkAddressChanged(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(async () =>
    {
        if (App.Core?.Server is not { } server || _closing) return;
        try { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12)); await server.SelectEndpoint(timeout.Token); UpdateServerLabel(); }
        catch (OperationCanceledException) { } catch (Exception ex) { Notify("网络已变更，地址重选失败：" + ex.Message); }
    });
    private void SessionExpired() => DispatcherQueue.TryEnqueue(() =>
    {
        _load?.Cancel(); ++_loadGeneration; DismissPlayer(false); _cachedPages.Clear(); ClearDetailPages();
        _model.ServerItems = null; _model.LibraryId = null; _model.Watched.Clear(); UpdateServerLabel(); Navigate("home");
        Notify("媒体服务器登录已失效，已停止播放。请重新登录。"); ConnectServer();
    });
    private async Task ActivateServer(MediaServer server)
    {
        var core = App.EnsureCore();
        core.SessionExpired -= SessionExpired; core.SessionExpired += SessionExpired;
        _load?.Cancel(); ++_loadGeneration; DismissPlayer(false); MergeServerProfile(server); core.SetServer(server);
        App.LeaveDemo(); Title = "OcPlayer"; _model.LibraryId = null; _model.LibraryName = "全部媒体库";
        _model.ServerItems = server.Latest; _model.Query = ""; GlobalSearch.Text = ""; _model.Watched.Clear();
        _cachedPages.Clear(); ClearDetailPages(); _libraryQueryKey = null;
        UpdateServerLabel(); Navigate("home"); await LoadNavigationAvatar(); LoadHome();
    }
    private static void MergeServerProfile(MediaServer server)
    {
        if (App.Core is not { } core || string.IsNullOrEmpty(server.Profile.ResolvedServerId)) return;
        var existing = core.Servers.Items.Select(x => core.Servers.Get(x.Id)).FirstOrDefault(x => x is not null && x.ResolvedServerId == server.Profile.ResolvedServerId && x.UserId == server.Profile.UserId);
        if (existing is not null) server.UpdateProfile(server.Profile with { Id = existing.Id, Addresses = existing.AllAddresses.Concat(server.Profile.AllAddresses).Distinct(StringComparer.OrdinalIgnoreCase).ToArray(), PinnedAddress = existing.PinnedAddress });
    }
    private UIElement ServerManagementPage()
    {
        var panel = Stack(18); panel.Children.Add(Text("媒体服务器", 24, true));
        panel.Children.Add(Button("添加服务器", ConnectServer));
        if (App.Core is not { } core) { panel.Children.Add(Muted("连接 Jellyfin / Emby 后可在此管理已保存的服务器。")); return _pageLayout.Scroll(panel); }
        foreach (var saved in core.Servers.Items)
        {
            var profile = core.Servers.Get(saved.Id); if (profile is null) continue;
            var card = Stack(12);
            card.Children.Add(Text(saved.Name + (core.Server?.Profile.Id == saved.Id ? " · 使用中" : "") + (core.Servers.DefaultId == saved.Id ? " ★ 启动默认" : "") + (saved.NeedsLogin ? " · 需重新登录" : ""), 17, true));
            card.Children.Add(Muted(saved.UserName + " · " + profile.DisplayKind));
            var actions = Row(8);
            var switchButton = Button(saved.NeedsLogin ? "重新登录" : "切换", async () =>
            {
                if (saved.NeedsLogin) { _loginProfile = profile; ConnectServer(); return; }
                _switchServer?.Cancel(); _switchServer?.Dispose(); _switchServer = new CancellationTokenSource(TimeSpan.FromSeconds(15)); var token = _switchServer.Token;
                try { var server = new MediaServer(core.Client, profile); await server.SelectEndpoint(token); token.ThrowIfCancellationRequested(); if (_closing) return; await ActivateServer(server); }
                catch (OperationCanceledException) { }
                catch (Exception ex) { Notify("切换失败：" + ex.Message); }
            });
            actions.Children.Add(switchButton);
            actions.Children.Add(Button(core.Servers.DefaultId == saved.Id ? "取消启动默认" : "设为启动默认", () => { core.Servers.SetDefault(core.Servers.DefaultId == saved.Id ? null : saved.Id); Navigate("settings:服务器管理"); }));
            actions.Children.Add(Button("删除服务器", async () =>
            {
                if (!await Confirm("删除服务器", $"删除“{saved.Name}”的本机档案和登录凭证？")) return;
                if (core.Server?.Profile.Id == saved.Id) DisconnectServer();
                core.Servers.Delete(saved.Id); Navigate("settings:服务器管理");
            }));
            card.Children.Add(actions);
            var addresses = Stack(10); var statuses = new Dictionary<string, TextBlock>();
            var serverForChecks = core.Server?.Profile.Id == profile.Id ? core.Server : new MediaServer(core.Client, profile);
            void Save(ServerProfile value)
            {
                if (core.Server?.Profile.Id == value.Id) core.Server.UpdateProfile(value); else core.Servers.Save(value);
                Navigate("settings:服务器管理");
            }
            foreach (var endpoint in profile.AllAddresses)
            {
                var line = Stack(5); line.Children.Add(Text(endpoint + (profile.BaseUrl == endpoint ? " · 当前" : "") + (profile.PinnedAddress == endpoint ? " · 已固定" : ""), 13));
                var status = Muted("尚未检测", 11); statuses[endpoint] = status; line.Children.Add(status);
                var options = Row(8);
                options.Children.Add(Button("固定此地址", () => Save(profile with { Addresses = profile.AllAddresses, PinnedAddress = endpoint, BaseUrl = endpoint })));
                var remove = Button("删除地址", async () =>
                {
                    if (!await Confirm("删除地址", $"删除 {endpoint}？")) return;
                    var remaining = profile.AllAddresses.Where(x => x != endpoint).ToArray();
                    Save(profile with { Addresses = remaining, BaseUrl = profile.BaseUrl == endpoint ? remaining[0] : profile.BaseUrl, PinnedAddress = profile.PinnedAddress == endpoint ? null : profile.PinnedAddress });
                }); remove.IsEnabled = profile.AllAddresses.Length > 1; options.Children.Add(remove); line.Children.Add(options); addresses.Children.Add(line);
            }
            var check = Button("重新检测", async () =>
            {
                try { foreach (var value in statuses.Values) value.Text = "正在检测…";
                    foreach (var result in await serverForChecks.CheckEndpoints(CancellationToken.None)) statuses[result.Address].Text = result.LatencyMs is { } latency ? $"可达 · {latency} ms" : result.Error ?? "不可达"; }
                catch (Exception ex) { Notify(ex.Message); }
            });
            addresses.Children.Add(check);
            addresses.Children.Add(Button("恢复自动选择最快地址", async () =>
            {
                try { serverForChecks.UpdateProfile(profile with { PinnedAddress = null }); await serverForChecks.SelectEndpoint(CancellationToken.None); Save(serverForChecks.Profile); }
                catch (Exception ex) { Notify(ex.Message); }
            }));
            addresses.Children.Add(Button("添加地址", async () =>
            {
                var input = new TextBox { Header = "局域网 / Tailscale / 反向代理地址", MinWidth = 340 };
                var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "添加服务器地址", Content = input, PrimaryButtonText = "检测并添加", CloseButtonText = "取消" };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
                try
                {
                    var normalized = MediaServer.NormalizeAddress(input.Text);
                    if (profile.AllAddresses.Contains(normalized, StringComparer.OrdinalIgnoreCase)) { Notify("该地址已存在。"); return; }
                    ServerProfile? found = null;
                    try { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); found = await MediaServer.Probe(core.Client, normalized, profile.Kind, timeout.Token); }
                    catch (Exception ex) when (ex is ServerConnectionException or OperationCanceledException)
                    { if (!await Confirm("地址暂不可达", "无法验证此地址。仍然添加到当前服务器？", "仍然添加")) return; }
                    if (found is not null && profile.ResolvedServerId is { Length: > 0 } id && found.ResolvedServerId != id) { Notify("此地址属于另一台服务器，不能合并。请添加独立服务器档案。"); return; }
                    Save(profile with { Addresses = profile.AllAddresses.Append(normalized).ToArray() });
                }
                catch (Exception ex) { Notify(ex.Message); }
            }));
            var expander = new Expander { Header = $"地址管理 · {profile.AllAddresses.Length} 个地址", Content = addresses, HorizontalAlignment = HorizontalAlignment.Stretch };
            expander.Expanding += async (_, _) =>
            {
                try { foreach (var result in await serverForChecks.CheckEndpoints(CancellationToken.None)) statuses[result.Address].Text = result.LatencyMs is { } latency ? $"可达 · {latency} ms" : result.Error ?? "不可达"; }
                catch (Exception ex) { Notify(ex.Message); }
            };
            card.Children.Add(expander); panel.Children.Add(Panel(card));
        }
        return _pageLayout.Scroll(panel, new Thickness(52, 20, 52, 36));
    }
    private ServerProfile? _loginProfile;
    private async Task<bool> Confirm(string title, string message, string action = "删除") => await new ContentDialog
    { XamlRoot = Root.XamlRoot, Title = title, Content = message, PrimaryButtonText = action, CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary;
}
