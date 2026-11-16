using System.Globalization;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;
using Windows.System;

namespace OcPlayer.Windows;

public sealed partial class PlayerView
{
    private DanmakuPreferences _demoDanmakuPreferences = new();
    private PreviewDanmakuEpisode? _demoDanmakuEpisode;
    private DanmakuPreferences CurrentDanmakuPreferences => _demoMode ? _demoDanmakuPreferences
        : App.Core?.Danmaku.Settings.Current ?? _danmakuPreferences ?? new();
    private string DanmakuStatus => _demoMode
        ? _demoDanmakuEpisode is { } episode ? $"已选择 · {episode.WorkTitle} · {episode.Label}"
            : _demoDanmakuPreferences.AutoLoad ? "等待选择" : "自动加载已关闭"
        : _danmaku?.Status ?? "等待加载";

    // Call after assigning the new _media in SetMedia. Demo preferences stay
    // within this player; selecting another source only resets its match.
    private void ResetDanmakuMenuState()
    {
        _danmakuStatusItem = null;
        _danmakuEnabled = CurrentDanmakuPreferences.Enabled;
        if (_demoMode)
        {
            _demoDanmakuEpisode = null;
            if (_demoDanmakuPreferences.AutoLoad) MatchDemoDanmaku();
        }
        UpdateMenuIndicators(); DanmakuChanged();
    }

    private void SaveDanmakuPreferences(DanmakuPreferences preferences)
    {
        if (_closed) return;
        if (_demoMode)
        {
            _demoDanmakuPreferences = preferences.Validated();
            _danmakuEnabled = preferences.Enabled;
        }
        else
        {
            var settings = App.Core?.Danmaku.Settings ?? throw new InvalidOperationException("弹幕服务尚未就绪。");
            settings.Save(preferences);
        }
        UpdateMenuIndicators(); DanmakuChanged(); ShowHud();
    }

    private bool HasLoadedDanmaku()
    {
        if (_demoMode) return _demoDanmakuEpisode is not null;
        if (!_useKernelDanmaku) return _overlayComments.Count > 0;
        try
        {
            return _session?.DanmakuTracks is { ValueKind: JsonValueKind.Array } tracks
                && tracks.EnumerateArray().Any(track => track.TryGetProperty("itemCount", out var count)
                    && count.TryGetInt64(out var items) && items > 0);
        }
        catch { return false; }
    }

    private ToggleMenuFlyoutItem DanmakuToggle(string title, Func<DanmakuPreferences, bool> read,
        Func<DanmakuPreferences, bool, DanmakuPreferences> update)
    {
        var item = new ToggleMenuFlyoutItem { Text = title, IsChecked = read(CurrentDanmakuPreferences) };
        item.Click += (_, _) =>
        {
            try { SaveDanmakuPreferences(update(CurrentDanmakuPreferences, item.IsChecked)); }
            catch (Exception ex) { ShowDanmakuError(ex.Message); }
            item.IsChecked = read(CurrentDanmakuPreferences);
        };
        return item;
    }

    private MenuFlyoutSubItem DanmakuOptions(string title, string group, double current,
        IEnumerable<(string Label, double Value)> options, Func<DanmakuPreferences, double, DanmakuPreferences> update)
    {
        var submenu = new MenuFlyoutSubItem { Text = title };
        foreach (var (label, value) in options)
        {
            var item = new RadioMenuFlyoutItem { Text = label, GroupName = group, IsChecked = Math.Abs(current - value) < .001 };
            item.Click += (_, _) =>
            {
                try { SaveDanmakuPreferences(update(CurrentDanmakuPreferences, value)); }
                catch (Exception ex) { item.IsChecked = Math.Abs(current - value) < .001; ShowDanmakuError(ex.Message); }
            };
            submenu.Items.Add(item);
        }
        return submenu;
    }

    private void AddDanmakuAppearanceMenus(MenuFlyout menu)
    {
        var preferences = CurrentDanmakuPreferences;
        static string Percent(double value) => $"{value * 100:0}%";
        var percentages = new[] { .25, .5, .75, 1d };
        menu.Items.Add(DanmakuOptions($"不透明度 · {Percent(preferences.Opacity)}", "DanmakuOpacity", preferences.Opacity,
            percentages.Select(value => (Percent(value), value)), (p, value) => p with { Opacity = value }));
        menu.Items.Add(DanmakuOptions($"显示区域 · 顶部 {Percent(preferences.DisplayArea)}", "DanmakuArea", preferences.DisplayArea,
            percentages.Select(value => ($"顶部 {Percent(value)}", value)), (p, value) => p with { DisplayArea = value }));
        var fonts = new MenuFlyoutSubItem { Text = $"字号大小 · {preferences.FontSize / 22 * 100:0}%" };
        var smaller = DanmakuAction("减小 10%", () => SaveDanmakuPreferences(CurrentDanmakuPreferences with { FontSize = Math.Max(11, Math.Round(CurrentDanmakuPreferences.FontSize - 2.2, 2)) }));
        smaller.IsEnabled = preferences.FontSize > 11; fonts.Items.Add(smaller);
        var larger = DanmakuAction("加大 10%", () => SaveDanmakuPreferences(CurrentDanmakuPreferences with { FontSize = Math.Min(44, Math.Round(CurrentDanmakuPreferences.FontSize + 2.2, 2)) }));
        larger.IsEnabled = preferences.FontSize < 44; fonts.Items.Add(larger);
        if (Math.Abs(preferences.FontSize - 22) > .001) fonts.Items.Add(DanmakuAction("重置", () => SaveDanmakuPreferences(CurrentDanmakuPreferences with { FontSize = 22 })));
        menu.Items.Add(fonts);
        var filters = new MenuFlyoutSubItem { Text = "过滤与显示规则" };
        filters.Items.Add(DanmakuToggle("滚动", p => !p.BlockScroll, (p, enabled) => p with { BlockScroll = !enabled }));
        filters.Items.Add(DanmakuToggle("顶部", p => !p.BlockTop, (p, enabled) => p with { BlockTop = !enabled }));
        filters.Items.Add(DanmakuToggle("底部", p => !p.BlockBottom, (p, enabled) => p with { BlockBottom = !enabled }));
        filters.Items.Add(DanmakuToggle("合并重复", p => p.MergeDuplicates, (p, enabled) => p with { MergeDuplicates = enabled }));
        filters.Items.Add(DanmakuToggle("允许堆叠", p => p.AllowStacking, (p, enabled) => p with { AllowStacking = enabled }));
        menu.Items.Add(filters);
    }

    private sealed record PreviewDanmakuEpisode(string Key, string WorkTitle, string Label, int? Number, bool IsCurrent = false)
    {
        public override string ToString() => IsCurrent ? $"✓ {Label} · 当前匹配" : Label;
    }
    private sealed record PreviewDanmakuWork(string Title, PreviewDanmakuEpisode[] Episodes)
    {
        public override string ToString() => $"{Title} · {Episodes.Length} 集";
    }
    private static PreviewDanmakuWork PreviewDanmaku(DemoMedia media)
    {
        var title = media.Kind == "episode" && !string.IsNullOrWhiteSpace(media.SeriesTitle) ? media.SeriesTitle : media.Title;
        var episodes = media.Episodes is { Length: > 0 }
            ? media.Episodes.Select(episode => new PreviewDanmakuEpisode($"{media.Id}:{episode.SeasonNumber}:{episode.Number}", title,
                $"S{episode.SeasonNumber}E{episode.Number} · {episode.Title}", episode.Number)).ToArray()
            : new[] { new PreviewDanmakuEpisode(media.Id, title, media.EpisodeLabel is { Length: > 0 } label ? $"{label} · {media.Title}" : "正片", media.EpisodeNumber) };
        return new(title, episodes);
    }
    private void MatchDemoDanmaku()
    {
        var work = PreviewDanmaku(_media);
        _demoDanmakuEpisode = work.Episodes.FirstOrDefault(x => x.Number == (_media.EpisodeNumber ?? _media.InitialEpisodeNumber))
            ?? work.Episodes.FirstOrDefault();
        DanmakuChanged(); ShowHud();
    }

    private async void ShowDemoDanmakuSearch()
    {
        if (_closed || _danmakuDialog is not null) return;
        var generation = _mediaGeneration;
        var current = PreviewDanmaku(_media);
        var catalog = new[] { _media }.Concat(DemoCatalog.All).Concat(DemoCatalog.Movies)
            .DistinctBy(media => media.Id).Select(PreviewDanmaku).ToArray();
        var query = new TextBox { Header = "作品名", Text = current.Title, PlaceholderText = "输入作品名" };
        var episode = new TextBox { Header = "集数（可选）", Text = _demoDanmakuEpisode?.Number?.ToString(CultureInfo.InvariantCulture) ?? "" };
        var search = new Button { Content = "搜索", VerticalAlignment = VerticalAlignment.Bottom };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var clearEpisode = new Button { Content = "清空集数重新搜索", Visibility = Visibility.Collapsed };
        var animes = new ListView { Height = 230, SelectionMode = ListViewSelectionMode.Single };
        var episodes = new ListView { Height = 230, SelectionMode = ListViewSelectionMode.Single };
        AutomationProperties.SetName(animes, "作品列表"); AutomationProperties.SetName(episodes, "剧集列表");
        var fields = new Grid { ColumnSpacing = 10 };
        fields.ColumnDefinitions.Add(new ColumnDefinition());
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(105) });
        fields.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(episode, 1); Grid.SetColumn(search, 2);
        fields.Children.Add(query); fields.Children.Add(episode); fields.Children.Add(search);
        var results = new Grid { ColumnSpacing = 12 };
        results.ColumnDefinitions.Add(new ColumnDefinition()); results.ColumnDefinitions.Add(new ColumnDefinition());
        var works = new StackPanel { Spacing = 6 }; works.Children.Add(new TextBlock { Text = "作品", Opacity = .65 }); works.Children.Add(animes);
        var parts = new StackPanel { Spacing = 6 }; parts.Children.Add(new TextBlock { Text = "剧集", Opacity = .65 }); parts.Children.Add(episodes);
        Grid.SetColumn(parts, 1); results.Children.Add(works); results.Children.Add(parts);
        var panel = new StackPanel { Spacing = 14, Width = Math.Min(480, Math.Max(280, ActualWidth - 96)) };
        foreach (var child in new UIElement[] { fields, status, clearEpisode, results }) panel.Children.Add(child);
        var dialog = _danmakuDialog = new ContentDialog { Title = "选择弹幕", XamlRoot = XamlRoot,
            Content = new ScrollViewer { Content = panel, MaxHeight = 480 }, PrimaryButtonText = "选择", CloseButtonText = "取消", IsPrimaryButtonEnabled = false };
        void Invalidate()
        {
            animes.ItemsSource = null; episodes.ItemsSource = null; dialog.IsPrimaryButtonEnabled = false;
            search.IsEnabled = !string.IsNullOrWhiteSpace(query.Text); clearEpisode.Visibility = Visibility.Collapsed;
            status.Text = _demoDanmakuEpisode is { } selected ? $"当前匹配：{selected.WorkTitle} · {selected.Label}" : "输入作品名与集数搜索。";
        }
        void Search()
        {
            Invalidate();
            if (string.IsNullOrWhiteSpace(query.Text)) return;
            var filter = episode.Text.Trim();
            var found = catalog.Where(work => work.Title.Contains(query.Text.Trim(), StringComparison.OrdinalIgnoreCase))
                .Select(work => work with { Episodes = work.Episodes.Where(part => filter.Length == 0
                    || part.Number?.ToString(CultureInfo.InvariantCulture) == filter || part.Label.Contains(filter, StringComparison.OrdinalIgnoreCase))
                    .Select(part => part with { IsCurrent = part.Key == _demoDanmakuEpisode?.Key }).ToArray() })
                .Where(work => work.Episodes.Length > 0).ToArray();
            animes.ItemsSource = found;
            if (found.Length == 0)
            {
                status.Text = "未找到相关剧集，可修改作品名或清空集数重试。";
                clearEpisode.Visibility = filter.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            }
            else
            {
                status.Text = $"找到 {found.Length} 部作品。" + (_demoDanmakuEpisode is { } selected ? $" 当前匹配：{selected.Label}" : "请选择作品和剧集。");
                if (found.Length == 1) animes.SelectedIndex = 0;
            }
        }
        query.TextChanged += (_, _) => Invalidate(); episode.TextChanged += (_, _) => Invalidate();
        search.Click += (_, _) => Search();
        clearEpisode.Click += (_, _) => { episode.Text = ""; Search(); };
        void Submit(object sender, KeyRoutedEventArgs args) { if (args.Key == VirtualKey.Enter) { args.Handled = true; Search(); } }
        query.KeyDown += Submit; episode.KeyDown += Submit;
        animes.SelectionChanged += (_, _) =>
        {
            var choices = (animes.SelectedItem as PreviewDanmakuWork)?.Episodes;
            episodes.ItemsSource = choices; dialog.IsPrimaryButtonEnabled = false;
            episodes.SelectedItem = choices?.FirstOrDefault(part => part.IsCurrent);
        };
        episodes.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = episodes.SelectedItem is PreviewDanmakuEpisode;
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (generation != _mediaGeneration || episodes.SelectedItem is not PreviewDanmakuEpisode selected) { args.Cancel = true; return; }
            _demoDanmakuEpisode = selected; DanmakuChanged(); ShowHud();
        };
        dialog.Opened += (_, _) => Search();
        BeginModalInteraction();
        try { await dialog.ShowAsync(); }
        catch (Exception ex) { ShowDanmakuError(ex.Message); }
        finally { if (ReferenceEquals(_danmakuDialog, dialog)) _danmakuDialog = null; EndModalInteraction(); }
    }
}
