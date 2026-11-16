using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Services;
using Windows.System;
using Windows.UI;

namespace OcPlayer.Windows.Features;

internal sealed partial class ServerConnectionView : UserControl
{
    private readonly CoreRuntime _core;
    private readonly Func<MediaServer, Task> _connected;
    private readonly Action _localPlayer;
    private readonly CancellationTokenSource _lifetime = new();
    private CancellationTokenSource? _operation, _quick;
    private ServerProfile? _detected;
    private bool _busy, _open = true, _syncProtocol;

    public ServerConnectionView(CoreRuntime core, Func<MediaServer, Task> connected, Action localPlayer, ServerProfile? initial = null)
    {
        _core = core; _connected = connected; _localPlayer = localPlayer;
        InitializeComponent();
        SizeChanged += (_, _) => UpdateLayoutWidth();
        ActualThemeChanged += (_, _) => UpdatePalette();
        Loaded += (_, _) => { UpdatePalette(); UpdateLayoutWidth(); };
        Unloaded += (_, _) => { _open = false; _lifetime.Cancel(); _operation?.Cancel(); _quick?.Cancel(); PasswordInput.Password = ""; };
        RenderSavedServers();
        ServerKind.SelectionChanged += (_, _) => { if (_detected is not null) QuickConnect.Visibility = ServerKind.SelectedIndex == 1 ? Visibility.Collapsed : Visibility.Visible; };
        if (initial is not null) { AddressInput.Text = initial.BaseUrl; UsernameInput.Text = initial.UserName ?? ""; ServerKind.SelectedIndex = initial.Kind == "emby" ? 1 : 0; }
    }
    private void UpdatePalette()
    {
        var dark = ActualTheme == ElementTheme.Dark;
        Surface.Background = new LinearGradientBrush
        {
            StartPoint = new(0, .6), EndPoint = new(1, .1),
            GradientStops = {
                new GradientStop { Offset = 0, Color = dark ? Color.FromArgb(255, 36, 32, 31) : Color.FromArgb(255, 246, 239, 234) },
                new GradientStop { Offset = 1, Color = dark ? Color.FromArgb(255, 29, 29, 40) : Color.FromArgb(255, 236, 234, 248) }
            }
        };
        FormCard.Background = new SolidColorBrush(dark ? Color.FromArgb(245, 43, 43, 46) : Color.FromArgb(245, 255, 255, 255));
    }
    private void UpdateLayoutWidth()
    {
        var compact = ActualWidth < 900;
        Grid.SetColumn(FormCard, compact ? 0 : 1); Grid.SetRow(FormCard, compact ? 1 : 0);
        FormColumn.Width = compact ? new GridLength(0) : new GridLength(440);
        IntroductionColumn.Width = new GridLength(1, GridUnitType.Star);
        Layout.ColumnSpacing = compact ? 0 : 72;
        var shortWindow = ActualHeight < 720;
        Layout.Padding = new Thickness(compact ? 24 : 48, shortWindow ? 56 : 72, compact ? 24 : 48, shortWindow ? 24 : compact ? 28 : 36);
        Layout.Width = Math.Max(0, Math.Min(1080, ActualWidth));
        Introduction.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        FormCard.MaxWidth = 440; FormCard.HorizontalAlignment = compact ? HorizontalAlignment.Center : HorizontalAlignment.Stretch;
    }
    private void RenderSavedServers()
    {
        foreach (var saved in _core.Servers.Items)
        {
            if (_core.Servers.Get(saved.Id) is not { } profile) continue;
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            row.Children.Add(new FontIcon { Glyph = profile.Kind == "emby" ? "\uE7F4" : "\uE8F1", FontSize = 18, VerticalAlignment = VerticalAlignment.Center, Opacity = .65 });
            var details = new StackPanel { Spacing = 3 };
            var caption = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
            caption.Children.Add(new TextBlock { Text = saved.Name, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, MaxWidth = 160, TextTrimming = TextTrimming.CharacterEllipsis });
            caption.Children.Add(new Border { CornerRadius = new(4), Padding = new(5, 1, 5, 1), Background = OcPlayer.Windows.Controls.DemoUi.Resource("ControlFillColorSecondaryBrush"), Child = new TextBlock { Text = profile.DisplayKind, FontSize = 10 } });
            details.Children.Add(caption);
            details.Children.Add(new TextBlock { Text = profile.BaseUrl, FontSize = 11, Opacity = .6, TextTrimming = TextTrimming.CharacterEllipsis });
            if (profile.AllAddresses.Length > 1 || saved.NeedsLogin) details.Children.Add(new TextBlock { Text = saved.NeedsLogin ? "需要重新登录" : $"共 {profile.AllAddresses.Length} 个地址 · 自动选择", FontSize = 10, Opacity = .5 });
            Grid.SetColumn(details, 1); row.Children.Add(details);
            var action = new Button { Content = saved.NeedsLogin ? "登录" : "连接", Padding = new(10, 5, 10, 5), FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(action, (saved.NeedsLogin ? "登录 " : "连接 ") + saved.Name);
            action.Click += async (_, _) => await UseSaved(profile, saved.NeedsLogin);
            Grid.SetColumn(action, 2); row.Children.Add(action);
            SavedServers.Children.Add(new Border { Child = row, Padding = new(12), CornerRadius = new(10), BorderThickness = new(1), BorderBrush = OcPlayer.Windows.Controls.DemoUi.Resource("CardStrokeColorDefaultBrush"), Background = OcPlayer.Windows.Controls.DemoUi.Resource("ControlFillColorSecondaryBrush") });
        }
        SavedSection.Visibility = SavedServers.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    private string Address() => MediaServer.NormalizeAddress(AddressInput.Text.Contains("://") ? AddressInput.Text.Trim() : (HttpsButton.IsChecked == true ? "https://" : "http://") + AddressInput.Text.Trim());
    private void Address_Changed(object sender, TextChangedEventArgs e)
    {
        if (HttpButton is null || HttpsButton is null || PrimaryAction is null) return;
        if (!_syncProtocol && (AddressInput.Text.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || AddressInput.Text.StartsWith("http://", StringComparison.OrdinalIgnoreCase)))
        { HttpsButton.IsChecked = AddressInput.Text.StartsWith("https://", StringComparison.OrdinalIgnoreCase); HttpButton.IsChecked = !HttpsButton.IsChecked; }
        PrimaryAction.IsEnabled = !_busy && !string.IsNullOrWhiteSpace(AddressInput.Text);
    }
    private void SelectProtocol(bool https)
    {
        HttpsButton.IsChecked = https; HttpButton.IsChecked = !https;
        _syncProtocol = true;
        try { if (AddressInput.Text.Contains("://")) AddressInput.Text = (https ? "https://" : "http://") + AddressInput.Text.Split("://", 2)[1]; }
        finally { _syncProtocol = false; }
    }
    private void Http_Click(object sender, RoutedEventArgs e) => SelectProtocol(false);
    private void Https_Click(object sender, RoutedEventArgs e) => SelectProtocol(true);
    private async void Primary_Click(object sender, RoutedEventArgs e) { if (_detected is null) await Detect(); else await Login(); }
    private async void Address_KeyDown(object sender, KeyRoutedEventArgs e) { if (e.Key == VirtualKey.Enter && !_busy && PrimaryAction.IsEnabled) { e.Handled = true; await Detect(); } }
    private async void Account_KeyDown(object sender, KeyRoutedEventArgs e) { if (e.Key == VirtualKey.Enter && !_busy) { e.Handled = true; await Login(); } }
    private void ShowError(string message) { ErrorNotice.Message = message; ErrorNotice.Visibility = Visibility.Visible; ErrorNotice.IsOpen = true; }
    private void Busy(bool value, string message = "")
    {
        _busy = value;
        foreach (var control in new Control[] { AddressInput, HttpButton, HttpsButton, ServerKind, UsernameInput, PasswordInput, ChangeAddress }) control.IsEnabled = !value;
        SavedServers.IsHitTestVisible = !value;
        PrimaryAction.IsEnabled = !value && !string.IsNullOrWhiteSpace(AddressInput.Text);
        QuickStart.IsEnabled = !value; LocalPlayer.IsEnabled = true;
        ProgressSection.Visibility = value ? Visibility.Visible : Visibility.Collapsed; ProgressText.Text = message;
        if (value) { ErrorNotice.IsOpen = false; ErrorNotice.Visibility = Visibility.Collapsed; }
    }
    private async Task Run(Func<CancellationToken, Task> action, string message, int seconds = 45)
    {
        if (_busy || !_open) return;
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token); lifetime.CancelAfter(TimeSpan.FromSeconds(seconds));
        _operation = lifetime; Busy(true, message);
        try { await action(lifetime.Token); }
        catch (OperationCanceledException) { if (_open && !_lifetime.IsCancellationRequested) ShowError("连接超时，请检查服务器地址和网络后重试。"); }
        catch (Exception ex) { if (_open) ShowError(ex.Message); }
        finally { _operation = null; if (_open) Busy(false); }
    }
    internal Task Detect() => Run(async token =>
    {
        var address = Address();
        ServerProfile profile;
        try { profile = await MediaServer.Probe(_core.Client, address, ServerKind.SelectedIndex == 1 ? "emby" : "jellyfin", token); }
        catch (ServerConnectionException)
        {
            // Some reverse proxies deny public discovery while allowing login.
            profile = new ServerProfile("", ServerKind.SelectedIndex == 1 ? "emby" : "jellyfin", address);
            FormDescription.Text = "公共检测不可用，请选择服务器类型后登录。";
        }
        token.ThrowIfCancellationRequested(); if (!_open) return;
        ShowAccount(profile); UsernameInput.Focus(FocusState.Programmatic);
    }, "正在检测服务器…", 12);
    private void ShowAccount(ServerProfile profile)
    {
        _detected = profile; ServerName.Text = profile.DisplayName + " · " + profile.DisplayKind;
        ServerAddress.Text = profile.BaseUrl; ServerKind.SelectedIndex = profile.Kind == "emby" ? 1 : 0;
        AddressFields.Visibility = Visibility.Collapsed; AccountFields.Visibility = ChangeAddress.Visibility = Visibility.Visible;
        QuickConnect.Visibility = profile.Kind == "emby" ? Visibility.Collapsed : Visibility.Visible;
        FormTitle.Text = "登录你的账号";
        ServerKind.Visibility = profile.ResolvedServerId is null ? Visibility.Visible : Visibility.Collapsed;
        FormDescription.Text = profile.ResolvedServerId is not null ? "服务器已连接，使用媒体库账号登录。" : "公共检测不可用，请选择服务器类型后登录。";
        AccountStep.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        AccountStep.Opacity = 1;
        ConnectionStep.Opacity = .55; PrimaryAction.Content = "登录并进入媒体库";
    }
    internal Task Login() => Run(async token =>
    {
        if (_detected is null) return;
        var server = await MediaServer.Connect(_core.Client, _detected.BaseUrl, ServerKind.SelectedIndex == 1 ? "emby" : "jellyfin", UsernameInput.Text, PasswordInput.Password,
            token, status => { if (_open) ProgressText.Text = status; });
        token.ThrowIfCancellationRequested(); if (!_open) return;
        PasswordInput.Password = ""; await _connected(server);
    }, "正在验证账号…");
    private async Task UseSaved(ServerProfile profile, bool needsLogin)
    {
        if (_busy) return;
        AddressInput.Text = profile.BaseUrl; UsernameInput.Text = profile.UserName ?? "";
        if (needsLogin) { ShowAccount(profile); PasswordInput.Focus(FocusState.Programmatic); return; }
        await Run(async token =>
        {
            var server = new MediaServer(_core.Client, profile); await server.SelectEndpoint(token); await server.Refresh(token);
            token.ThrowIfCancellationRequested(); if (!_open) return; await _connected(server);
        }, "正在连接已保存的服务器…");
    }
    private void ChangeAddress_Click(object sender, RoutedEventArgs e)
    {
        _quick?.Cancel(); QuickConnect.IsExpanded = false; _detected = null; PasswordInput.Password = "";
        AddressFields.Visibility = Visibility.Visible; AccountFields.Visibility = ChangeAddress.Visibility = QuickConnect.Visibility = Visibility.Collapsed;
        FormTitle.Text = "连接你的媒体库"; FormDescription.Text = "输入 Jellyfin 或 Emby 服务器地址，开始浏览与播放。";
        PrimaryAction.Content = "连接服务器"; ConnectionStep.Opacity = 1; AccountStep.Opacity = .55;
        AccountStep.FontWeight = Microsoft.UI.Text.FontWeights.Normal;
        ErrorNotice.IsOpen = false; ErrorNotice.Visibility = Visibility.Collapsed; AddressInput.Focus(FocusState.Programmatic);
    }
    private void QuickConnect_Collapsed(Expander sender, ExpanderCollapsedEventArgs args) => _quick?.Cancel();
    private async void QuickStart_Click(object sender, RoutedEventArgs e)
    {
        if (_detected is null || _busy) return;
        _quick?.Cancel(); _quick?.Dispose(); _quick = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token); _quick.CancelAfter(TimeSpan.FromMinutes(5));
        var token = _quick.Token; Busy(true, "正在申请配对码…");
        try
        {
            var candidate = new MediaServer(_core.Client, _detected);
            var code = await candidate.Request("server.quickConnect.initiate", token: token);
            var secret = code.GetProperty("secret").GetString() ?? throw new InvalidOperationException("未返回配对凭据。");
            QuickCode.Text = code.GetProperty("code").GetString(); QuickCode.Visibility = CopyCode.Visibility = Visibility.Visible;
            ProgressText.Text = "请在已登录的设备中授权此配对码，正在等待…";
            while (true) { await Task.Delay(3000, token); var state = await candidate.Request("server.quickConnect.state", new { secret }, token); if (state.TryGetProperty("authenticated", out var authorized) && authorized.ValueKind == System.Text.Json.JsonValueKind.True) break; }
            var login = await candidate.Request("server.loginQuickConnect", new { secret }, token);
            var profile = _detected with { Id = _detected.Id + ":" + login.GetProperty("userId").GetString(), UserId = login.GetProperty("userId").GetString(), Token = login.GetProperty("token").GetString(), UserName = login.TryGetProperty("userName", out var name) ? name.GetString() : null };
            var server = new MediaServer(_core.Client, profile); await server.Refresh(token);
            token.ThrowIfCancellationRequested(); if (_open) await _connected(server);
        }
        catch (OperationCanceledException) { if (_open) QuickStatus.Text = "配对已取消或超时，可重新申请。"; }
        catch (Exception ex) { if (_open) QuickStatus.Text = ex.Message; }
        finally { if (_open) { Busy(false); QuickStart.Content = "重新获取配对码"; } }
    }
    private void CopyCode_Click(object sender, RoutedEventArgs e) { var data = new global::Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(QuickCode.Text); global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); }
    private void LocalPlayer_Click(object sender, RoutedEventArgs e) { _operation?.Cancel(); _quick?.Cancel(); _localPlayer(); }
}
