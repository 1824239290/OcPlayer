using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Features;
using OcPlayer.Windows.Services;
using Windows.System;

namespace OcPlayer.Windows;

public sealed partial class PlayerView
{
    private DanmakuCoordinator? _danmaku;
    private DanmakuContext? _danmakuContext;
    private DanmakuPreferences? _danmakuPreferences;
    private MenuFlyoutItem? _danmakuStatusItem;
    private ContentDialog? _danmakuDialog;
    private CancellationTokenSource? _danmakuSearch;
    private long _mediaGeneration;
    private double _danmakuShift, _danmakuOffset;

    private void InitializeDanmaku()
    {
        var service = App.Core!.Danmaku;
        InitializeDanmakuOverlay();
        _useKernelDanmaku = service.Settings.Current.UseKernelRenderer;
        _danmakuPreferences = service.Settings.Current;
        _danmaku = new DanmakuCoordinator(service.Load, () => !_closed && _session?.Ready == true, payload =>
        {
            ApplyDanmakuContent(payload.Json!);
            _danmakuShift = payload.ShiftSeconds;
            _session!.SetDanmakuOffset(_danmakuShift + _danmakuOffset);
        }, ClearDanmakuContent);
        _danmaku.PayloadReceived += payload => ApplyExternalIntroHint(payload.IntroHint);
        _danmaku.Changed += DanmakuChanged;
        service.Settings.Changed += DanmakuPreferencesChanged;
    }

    private void ResetDanmakuSource()
    {
        _mediaGeneration++;
        _danmaku?.Cancel(); _danmakuSearch?.Cancel(); _danmakuDialog?.Hide();
        _danmakuContext = null;
        ClearDanmakuContent();
        _useKernelDanmaku = CurrentDanmakuPreferences.UseKernelRenderer;
        _danmakuShift = _danmakuOffset = 0;
    }

    private void StartDanmaku(bool force = false)
    {
        if (_closed || _session is null || App.Core is not { } core) return;
        try
        {
            _danmakuContext ??= core.Danmaku.Context(_media, _source ?? new PlaybackSource(_media.Id, _media.Title, _media.SourceUri!));
            if (_session.DurationSeconds > 0) _danmakuContext = _danmakuContext with { DurationSeconds = (long)Math.Round(_session.DurationSeconds) };
            _danmaku!.Start(_danmakuContext, core.Danmaku.Settings.Current.AutoLoad, force);
        }
        catch (Exception ex) { ShowDanmakuError(ex.Message); }
    }

    private void DanmakuPreferencesChanged(DanmakuPreferences preferences)
    {
        if (_closed) return;
        var previous = _danmakuPreferences;
        _danmakuPreferences = preferences;
        try { _session?.ConfigureDanmaku((preferences with { Enabled = preferences.Enabled && _useKernelDanmaku }).Renderer); _danmakuEnabled = preferences.Enabled; RebuildDanmakuOverlay(); }
        catch (Exception ex) { ShowDanmakuError(ex.Message); }
        if (previous is not null && (previous.AutoLoad != preferences.AutoLoad || previous.EffectiveUrl != preferences.EffectiveUrl || previous.EffectiveKey != preferences.EffectiveKey))
        {
            _danmakuSearch?.Cancel();
            StartDanmaku();
        }
        UpdateMenuIndicators();
    }

    private void DanmakuChanged()
    {
        if (_closed) return;
        AppDiagnostics.Write("debug", "弹幕状态：" + DanmakuStatus, danmaku: true);
        if (_danmakuStatusItem is not null)
        {
            _danmakuStatusItem.Text = DanmakuStatus;
            ToolTipService.SetToolTip(_danmakuStatusItem, DanmakuStatus);
            ConstrainPlayerMenuItems([_danmakuStatusItem]);
        }
        ToolTipService.SetToolTip(DanmakuButton, (_danmakuEnabled ? "弹幕 · " : "弹幕已关闭 · ") + DanmakuStatus);
    }

    private void ShowDanmakuError(string message)
    {
        if (_closed) return;
        // This error does not change the transport's playing state.
        DanmakuNotice.Message = message; DanmakuNotice.IsOpen = true; ShowHud();
    }

    private void Danmaku_Click(object sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout();
        _danmakuStatusItem = new MenuFlyoutItem { Text = DanmakuStatus, IsEnabled = false };
        ToolTipService.SetToolTip(_danmakuStatusItem, DanmakuStatus);
        menu.Items.Add(_danmakuStatusItem);
        menu.Items.Add(DanmakuToggle("启用弹幕", p => p.Enabled, (p, enabled) => p with { Enabled = enabled }));
        menu.Items.Add(DanmakuAction("选择弹幕…", ShowDanmakuSearch));
        menu.Items.Add(DanmakuAction("重新匹配", () => { if (_demoMode) MatchDemoDanmaku(); else StartDanmaku(true); }));
        if (HasLoadedDanmaku())
        {
            var timing = new MenuFlyoutSubItem { Text = $"时间偏移 · {_danmakuOffset:+0.0;-0.0;0.0} 秒" };
            timing.Items.Add(DanmakuAction("提前 0.5 秒", () => AdjustDanmaku(-.5)));
            timing.Items.Add(DanmakuAction("重置", () => AdjustDanmaku(-_danmakuOffset)));
            timing.Items.Add(DanmakuAction("延后 0.5 秒", () => AdjustDanmaku(.5)));
            menu.Items.Add(timing);
        }
        AddDanmakuAppearanceMenus(menu);
        menu.Items.Add(new MenuFlyoutSeparator());
        var local = DanmakuAction("加载本地弹幕…", () => PickOverlay(true));
        local.IsEnabled = !_demoMode;
        menu.Items.Add(local);
        menu.Items.Add(DanmakuAction("弹幕设置…", ShowDanmakuSettings));
        ShowMenu(sender, menu);
    }

    private MenuFlyoutItem DanmakuAction(string title, Action action)
    {
        var item = new MenuFlyoutItem { Text = title };
        item.Click += (_, _) => { try { action(); } catch (Exception ex) { ShowDanmakuError(ex.Message); } ShowHud(); };
        return item;
    }
    private void AdjustDanmaku(double delta)
    {
        var offset = Math.Clamp(_danmakuOffset + delta, -30, 30);
        _session?.SetDanmakuOffset(_danmakuShift + offset); _danmakuOffset = offset;
    }

    private async void ShowDanmakuSearch()
    {
        if (_demoMode) { ShowDemoDanmakuSearch(); return; }
        if (_closed || _danmakuDialog is not null || App.Core is not { } core || _danmakuContext is not { } context) return;
        var generation = _mediaGeneration;
        var query = new TextBox { Header = "作品名", Text = context.AnimeTitle, PlaceholderText = "输入作品名" };
        var episode = new TextBox { Header = "集数（可选）", Text = context.EpisodeNumber?.ToString(CultureInfo.InvariantCulture) ?? "", PlaceholderText = "如 1、SP1" };
        var search = new Button { Content = "搜索", VerticalAlignment = VerticalAlignment.Bottom };
        var matchStatus = new TextBlock { TextWrapping = TextWrapping.Wrap, Opacity = .75 };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var clearEpisode = new Button { Content = "清空集数重新搜索", Visibility = Visibility.Collapsed };
        var animes = new ListView { Height = 260, SelectionMode = ListViewSelectionMode.Single };
        var episodes = new ListView { Height = 260, SelectionMode = ListViewSelectionMode.Single, Visibility = Visibility.Collapsed };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(animes, "作品列表");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(episodes, "剧集列表");
        var fields = new Grid { ColumnSpacing = 10 };
        fields.ColumnDefinitions.Add(new ColumnDefinition());
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(105) });
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(episode, 1); Grid.SetColumn(search, 2);
        fields.Children.Add(query); fields.Children.Add(episode); fields.Children.Add(search);
        var back = new Button { Content = "返回作品列表", Visibility = Visibility.Collapsed };
        var results = new Grid(); results.Children.Add(animes); results.Children.Add(episodes);
        var panel = new StackPanel { Spacing = 14, Width = Math.Min(480, Math.Max(280, ActualWidth - 96)) };
        foreach (var child in new UIElement[] { fields, back, matchStatus, status, clearEpisode, results }) panel.Children.Add(child);
        var dialog = _danmakuDialog = new ContentDialog { Title = "选择弹幕", XamlRoot = XamlRoot,
            Content = new ScrollViewer { Content = panel, MaxHeight = 480 }, PrimaryButtonText = "加载所选弹幕", CloseButtonText = "取消", IsPrimaryButtonEnabled = false };
        var request = 0;
        var coordinator = _danmaku;
        DanmakuAnime[] searchResults = [];
        var refreshingMatches = false;
        bool Current(int id) => !_closed && generation == _mediaGeneration && ReferenceEquals(_danmakuDialog, dialog) && id == request;
        void RefreshMatch()
        {
            if (_closed || generation != _mediaGeneration || !ReferenceEquals(_danmakuDialog, dialog)) return;
            var currentMatch = coordinator?.CurrentMatch;
            matchStatus.Text = "弹幕状态：" + (coordinator?.Status ?? "等待加载")
                + (currentMatch is null ? "" : $"\n已关联 Episode {currentMatch.EpisodeId}");
            var selectedWork = (animes.SelectedItem as DanmakuAnime)?.AnimeId;
            var selectedEpisode = (episodes.SelectedItem as DanmakuEpisode)?.EpisodeId;
            var marked = searchResults.Select(anime => anime with
            {
                ContainsCurrentMatch = anime.Episodes.Any(part => part.EpisodeId == currentMatch?.EpisodeId),
                Episodes = anime.Episodes.Select(part => part with { IsCurrentMatch = part.EpisodeId == currentMatch?.EpisodeId }).ToArray()
            }).ToArray();
            refreshingMatches = true;
            try
            {
                animes.ItemsSource = marked;
                var work = marked.FirstOrDefault(anime => anime.AnimeId == selectedWork);
                animes.SelectedItem = work;
                episodes.ItemsSource = work?.Episodes;
                episodes.SelectedItem = work?.Episodes.FirstOrDefault(part => part.EpisodeId == selectedEpisode)
                    ?? work?.Episodes.FirstOrDefault(part => part.IsCurrentMatch);
                dialog.IsPrimaryButtonEnabled = episodes.SelectedItem is DanmakuEpisode;
            }
            finally { refreshingMatches = false; }
        }
        void Invalidate()
        {
            request++; _danmakuSearch?.Cancel(); search.IsEnabled = !string.IsNullOrWhiteSpace(query.Text);
            searchResults = [];
            animes.ItemsSource = null; episodes.ItemsSource = null; dialog.IsPrimaryButtonEnabled = false; status.Text = "";
            clearEpisode.Visibility = Visibility.Collapsed;
            fields.Visibility = animes.Visibility = Visibility.Visible;
            back.Visibility = episodes.Visibility = Visibility.Collapsed;
            RefreshMatch();
        }
        async Task Search()
        {
            Invalidate(); var id = request;
            if (string.IsNullOrWhiteSpace(query.Text)) { status.Text = "请输入作品名。"; return; }
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(25));
            _danmakuSearch = cancellation;
            search.IsEnabled = false; status.Text = "正在搜索…";
            try
            {
                var results = await core.Danmaku.Search(query.Text, episode.Text, cancellation.Token);
                if (!Current(id)) return;
                searchResults = results; RefreshMatch();
                status.Text = results.Length == 0 ? "未找到剧集，可修改作品名或清空集数重试。" : $"找到 {results.Length} 部作品，请选择作品和剧集。";
                clearEpisode.Visibility = results.Length == 0 && !string.IsNullOrWhiteSpace(episode.Text) ? Visibility.Visible : Visibility.Collapsed;
            }
            catch (OperationCanceledException) { if (Current(id)) status.Text = "搜索超时，请重试。"; }
            catch (Exception ex) { if (Current(id)) status.Text = ex.Message; }
            finally { if (ReferenceEquals(_danmakuSearch, cancellation)) _danmakuSearch = null; if (Current(id)) search.IsEnabled = !string.IsNullOrWhiteSpace(query.Text); }
        }
        query.TextChanged += (_, _) => Invalidate(); episode.TextChanged += (_, _) => Invalidate();
        search.Click += async (_, _) => await Search();
        clearEpisode.Click += async (_, _) => { episode.Text = ""; await Search(); };
        async void Submit(object sender, KeyRoutedEventArgs args) { if (args.Key == VirtualKey.Enter) { args.Handled = true; await Search(); } }
        query.KeyDown += Submit; episode.KeyDown += Submit;
        animes.SelectionChanged += (_, _) =>
        {
            if (refreshingMatches || animes.SelectedItem is not DanmakuAnime anime) return;
            episodes.ItemsSource = anime.Episodes; dialog.IsPrimaryButtonEnabled = false;
            episodes.SelectedItem = anime.Episodes.FirstOrDefault(part => part.IsCurrentMatch);
            status.Text = anime.Title + " · 请选择剧集";
            clearEpisode.Visibility = Visibility.Collapsed;
            fields.Visibility = animes.Visibility = Visibility.Collapsed;
            back.Visibility = episodes.Visibility = Visibility.Visible;
        };
        back.Click += (_, _) =>
        {
            animes.SelectedItem = null; episodes.SelectedItem = null;
            fields.Visibility = animes.Visibility = Visibility.Visible;
            back.Visibility = episodes.Visibility = Visibility.Collapsed;
            status.Text = "请选择作品。"; dialog.IsPrimaryButtonEnabled = false;
        };
        episodes.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = episodes.SelectedItem is DanmakuEpisode;
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (generation != _mediaGeneration || episodes.SelectedItem is not DanmakuEpisode selected) { args.Cancel = true; return; }
            _danmaku?.Start(context, true, manual: selected);
        };
        dialog.Opened += async (_, _) => { RefreshMatch(); if (!string.IsNullOrWhiteSpace(query.Text)) await Search(); };
        search.IsEnabled = !string.IsNullOrWhiteSpace(query.Text);
        if (coordinator is not null) coordinator.Changed += RefreshMatch;
        BeginModalInteraction();
        try { await dialog.ShowAsync(); }
        catch (Exception ex) { ShowDanmakuError(ex.Message); }
        finally
        {
            if (coordinator is not null) coordinator.Changed -= RefreshMatch;
            Invalidate(); if (ReferenceEquals(_danmakuDialog, dialog)) _danmakuDialog = null; EndModalInteraction();
        }
    }

    private async void ShowDanmakuSettings()
    {
        if (_closed || _danmakuDialog is not null || !_demoMode && App.Core is null) return;
        var editor = new DanmakuSettingsEditor(CurrentDanmakuPreferences);
        editor.Content.Width = Math.Min(440, Math.Max(280, ActualWidth - 96));
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = _demoMode ? "" : App.Core?.Danmaku.Settings.LoadWarning ?? "" }; editor.Content.Children.Add(error);
        var dialog = _danmakuDialog = new ContentDialog { Title = "弹幕设置", XamlRoot = XamlRoot, PrimaryButtonText = "保存", CloseButtonText = "取消",
            Content = new ScrollViewer { Content = editor.Content, MaxHeight = 480 } };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            try { SaveDanmakuPreferences(editor.Read()); }
            catch (Exception ex) { args.Cancel = true; error.Text = ex.Message; }
        };
        BeginModalInteraction();
        try { await dialog.ShowAsync(); }
        catch (Exception ex) { ShowDanmakuError(ex.Message); }
        finally { if (ReferenceEquals(_danmakuDialog, dialog)) _danmakuDialog = null; EndModalInteraction(); }
    }

    private void DisposeDanmaku()
    {
        ResetDanmakuSource();
        if (App.Core is { } core) core.Danmaku.Settings.Changed -= DanmakuPreferencesChanged;
        if (_danmaku is not null) { _danmaku.Changed -= DanmakuChanged; _danmaku.Dispose(); }
    }
}
