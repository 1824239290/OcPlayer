using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    private UIElement Resources(string keyword)
    {
        var page = new Page(); page.Body.MaxWidth = 10000; page.Body.Spacing = 18; HeaderTitle = "资源搜索";
        if (Gate(page, false)) return Show(page); JsonElement? selectedMedia = null;
        if (keyword.StartsWith("media=", StringComparison.Ordinal)) { selectedMedia = JsonDocument.Parse(keyword[6..]).RootElement.Clone(); keyword = Json.Title(selectedMedia.Value); }
        var mediaHeader = new Grid(); var search = new AutoSuggestBox { Text = keyword, PlaceholderText = "搜索关键词", QueryIcon = new SymbolIcon(Symbol.Find), HorizontalAlignment = HorizontalAlignment.Stretch };
        MpName(search, "MoviePilot 资源搜索关键词"); var sites = new ListView { SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 320 };
        var mediaChoice = new ComboBox { Header = "下载归属媒体", HorizontalAlignment = HorizontalAlignment.Stretch, PlaceholderText = "选择准确的媒体条目" }; var identity = DashboardMuted("");
        void SelectIdentity()
        {
            selectedMedia = mediaChoice.SelectedItem is ComboBoxItem { Tag: JsonElement media } ? media : null; mediaHeader.Children.Clear();
            if (selectedMedia is { } chosen)
            {
                mediaHeader.Children.Add(MpMediaCard(chosen, true)); HeaderTitle = Json.Title(chosen); HeaderBackdrop = Cover(chosen);
                identity.Text = MoviePilotPolicies.Identity(chosen);
            }
            else { mediaHeader.Children.Add(MpEmpty("请选择下载归属媒体，再搜索站点资源。", "\uE8B2")); HeaderTitle = "资源搜索"; HeaderBackdrop = null; identity.Text = "请先选择归属媒体"; }
            HeaderChanged?.Invoke();
        }
        void AddMedia(JsonElement media) => mediaChoice.Items.Add(new ComboBoxItem { Content = $"{Json.Title(media)} · {Json.Text(media, "year")} · {Json.First(media, "type", "media_type")} · {MoviePilotPolicies.Identity(media)}", Tag = media });
        if (selectedMedia is { } initial) { AddMedia(initial); mediaChoice.SelectedIndex = 0; }
        SelectIdentity(); mediaChoice.SelectionChanged += (_, _) => SelectIdentity();
        async Task FindMedia()
        {
            if (string.IsNullOrWhiteSpace(search.Text)) throw new ArgumentException("请输入搜索关键词。");
            var current = selectedMedia; var items = Json.Items(await Service.Mp("mediaSearch", new { title = search.Text.Trim() }, page.Token)); mediaChoice.Items.Clear();
            if (current is { } chosen) AddMedia(chosen);
            foreach (var media in items.Where(x => current is null || MoviePilotPolicies.Identity(x) != MoviePilotPolicies.Identity(current.Value))) AddMedia(media);
            if (current is not null) mediaChoice.SelectedIndex = 0;
        }
        var filter = new TextBox { Header = "结果标题关键词", PlaceholderText = "标题关键词" }; var list = Stack(12); var heading = new Grid();
        var progressText = DashboardLabel("", 12, true); var progressCount = DashboardMuted("", 11); var progressDetails = Stack(3); progressDetails.Children.Add(progressText); progressDetails.Children.Add(progressCount);
        var progressRow = new Grid { ColumnSpacing = 12 }; progressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); progressRow.ColumnDefinitions.Add(new ColumnDefinition());
        var ring = new ProgressRing { Width = 30, Height = 30, IsActive = false }; progressRow.Children.Add(ring); Grid.SetColumn(progressDetails, 1); progressRow.Children.Add(progressDetails);
        var progressCard = DashboardCard(progressRow, 14); progressCard.Visibility = Visibility.Collapsed;
        var filters = Enumerable.Range(0, 7).Select(_ => new HashSet<string>(StringComparer.Ordinal)).ToArray(); var chips = new Grid();
        var sort = new ComboBox { ItemsSource = new[] { "默认", "站点", "大小", "做种", "时间" }, SelectedIndex = int.TryParse(Service.Preference("moviepilot.resource.sort"), out var field) ? Math.Clamp(field, 0, 4) : 0,
            Height = 30, MinHeight = 0, MinWidth = 0, Width = 108, Padding = new Thickness(10, 3, 10, 3), FontSize = 12 }; MpName(sort, "MoviePilot 资源排序");
        var ascending = Service.Preference("moviepilot.resource.ascending") == "true";
        var direction = MpCompact(Button("", () => { }), ascending ? "\uE74A" : "\uE74B", "", "MoviePilot 切换排序方向");
        var more = MpCompact(Button("再显示 60 条", () => { }), "\uE70D", "再显示 60 条"); JsonElement[] results = []; var window = 60; var searched = false; var searching = false; string? searchError = null;
        var filterButtons = new List<Button>(); var filterControls = new List<FrameworkElement> { sort, direction }; var filterBar = new Grid { Visibility = Visibility.Collapsed };
        void Render()
        {
            list.Children.Clear(); var matches = MoviePilotPolicies.Filter(results, filters, filter.Text); heading.Children.Clear();
            heading.Children.Add(MpSectionHeading("资源", results.Length == 0 ? "" : matches.Length == results.Length ? results.Length.ToString() : $"{matches.Length} / {results.Length}"));
            filterBar.Visibility = results.Length > 0 || filters.Any(x => x.Count > 0) || filter.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            progressCard.Visibility = searching ? Visibility.Visible : Visibility.Collapsed; ring.IsActive = searching;
            progressCount.Text = results.Length > 0 ? $"已收到 {results.Length} 条，边搜边出，可以直接挑选下载" : "正在等待站点返回资源…";
            if (searchError is { } error)
            {
                var row = new Grid { ColumnSpacing = 12 }; row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var label = DashboardMuted("⚠ " + error, 12); label.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(label);
                var retry = MpCompact(page.Action("", Search), "\uE72C", "重试"); Grid.SetColumn(retry, 1); row.Children.Add(retry); list.Children.Add(DashboardCard(row, 14));
            }
            var chipItems = new List<FrameworkElement>();
            for (var i = 0; i < filters.Length; i++)
            {
                var index = i;
                if (i < filterButtons.Count) filterButtons[i].Content = MpButtonContent(MpFilterGlyphs[i], MpFilterLabels[i] + (filters[i].Count > 0 ? $" ({filters[i].Count})" : ""));
                foreach (var selected in filters[i].Order()) chipItems.Add(MpCompact(Button("", () => { filters[index].Remove(selected); window = 60; Render(); }), "\uE711", MpFilterLabels[i] + " " + selected));
            }
            chips.Children.Clear(); if (chipItems.Count > 0) chips.Children.Add(MpWrap(chipItems)); chips.Visibility = chipItems.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            foreach (var result in MoviePilotPolicies.Sort(matches, sort.SelectedIndex, ascending).Take(window))
            {
                var torrent = Json.Get(result, "torrent"); var details = Stack(6); var title = DashboardLabel(Json.Title(torrent), 13, true); title.TextWrapping = TextWrapping.Wrap; title.MaxLines = 2; details.Children.Add(title);
                var description = Json.First(torrent, "description", "subtitle"); if (description.Length > 0) { var label = DashboardMuted(description, 11); label.MaxLines = 1; label.TextTrimming = TextTrimming.CharacterEllipsis; details.Children.Add(label); }
                var badges = new List<FrameworkElement>(); var site = Json.First(torrent, "site_name", "site"); if (site.Length > 0) badges.Add(MpBadge(site));
                if (Json.Number(torrent, "downloadvolumefactor", 1) == 0 || Json.Text(torrent, "volume_factor").Contains("FREE", StringComparison.OrdinalIgnoreCase)) badges.Add(MpBadge("免费", "green"));
                foreach (var label in Json.OptionalItems(Json.Get(torrent, "labels")).Select(x => x.ToString()).Take(2)) badges.Add(MpBadge(label, "orange"));
                badges.Add(MpBadge($"{Json.Number(torrent, "size") / 1073741824:0.##} GB")); badges.Add(MpBadge($"↑ {Json.Number(torrent, "seeders"):0}", Json.Number(torrent, "seeders") >= 5 ? "green" : "neutral"));
                badges.Add(DashboardMuted(Json.First(torrent, "date_elapsed", "dateElapsed", "pubdate"), 10)); details.Children.Add(MpWrap(badges));
                var download = MpCompact(Button("", () => { }), "\uE896", "下载", "MoviePilot 下载 " + Json.Title(torrent));
                // Downloads remain independent of the long-running search operation.
                download.Click += async (_, _) =>
                {
                    download.IsEnabled = false;
                    try
                    {
                        if (selectedMedia is not { } media) throw new InvalidOperationException("请先选择下载归属媒体。");
                        if (await Confirm(page, "添加下载", Json.Title(media) + "\n" + Json.Title(torrent))) { await Service.Mp("download.add", new { media, torrent }, page.Token); download.Content = MpButtonContent("\uE73E", "已加入下载"); }
                    }
                    catch (OperationCanceledException) { }
                    catch (Exception ex) { if (!page.Token.IsCancellationRequested) page.Status.Text = ex.Message; }
                    finally { download.IsEnabled = true; }
                };
                var row = new Grid { ColumnSpacing = 14 }; row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(details); Grid.SetColumn(download, 1); download.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(download);
                var card = DashboardCard(row, 14); card.Tag = "MoviePilot.TorrentResult"; card.CornerRadius = new CornerRadius(14); list.Children.Add(card);
            }
            if (matches.Length == 0 && !searching && searchError is null) list.Children.Add(MpEmpty(!searched ? "点击「搜索」开始；关键词已按剧名预填，可自行修改。" : results.Length > 0 ? $"筛掉了全部 {results.Length} 条结果，放宽条件试试。" : "没有搜到资源，试试其他关键词或调整站点。"));
            more.Visibility = matches.Length > window ? Visibility.Visible : Visibility.Collapsed;
        }
        async Task ChooseFilter(int index)
        {
            var choices = results.Select(row => MoviePilotPolicies.FilterValue(row, index)).Where(x => x.Length > 0).Distinct().Order().ToArray();
            var options = new ListView { SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 420, ItemsSource = choices };
            foreach (var value in filters[index]) if (choices.Contains(value)) options.SelectedItems.Add(value);
            var panel = Stack(10); panel.Children.Add(options); var controls = Row(8); controls.Children.Add(Button("全选", () => options.SelectAll())); controls.Children.Add(Button("清除", () => options.SelectedItems.Clear())); panel.Children.Add(controls);
            var dialog = new ContentDialog { XamlRoot = page.Body.XamlRoot, Title = MoviePilotPolicies.FilterFields[index].Label, Content = panel, PrimaryButtonText = "应用", CloseButtonText = "取消" };
            using var registration = page.Token.Register(() => page.Body.DispatcherQueue.TryEnqueue(dialog.Hide));
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) { filters[index].Clear(); filters[index].UnionWith(options.SelectedItems.OfType<string>()); window = 60; Render(); }
        }
        for (var i = 0; i < 7; i++)
        {
            var index = i; var button = MpCompact(Button("", () => { }), MpFilterGlyphs[i], MpFilterLabels[i], "MoviePilot 筛选 " + MpFilterLabels[i]);
            button.Click += async (_, _) => { try { await ChooseFilter(index); } catch (OperationCanceledException) { } catch (Exception ex) { page.Status.Text = ex.Message; } };
            filterButtons.Add(button); filterControls.Add(button);
        }
        var filterOptions = Stack(10); filterOptions.Children.Add(filter); filterOptions.Children.Add(Button("清除全部筛选", () => { foreach (var selected in filters) selected.Clear(); filter.Text = ""; window = 60; Render(); }));
        var extra = MpCompact(Button("", () => { }), "\uE712", "", "MoviePilot 结果关键词与清除筛选"); extra.Flyout = new Flyout { Content = filterOptions }; filterControls.Add(extra); filterBar.Children.Add(MpWrap(filterControls));
        async Task Search()
        {
            if (string.IsNullOrWhiteSpace(search.Text)) throw new ArgumentException("请输入搜索关键词。");
            var selected = sites.SelectedItems.OfType<ListViewItem>().Select(x => (long)x.Tag).ToArray(); results = []; searched = searching = true; window = 60; searchError = null;
            foreach (var choices in filters) choices.Clear(); filter.Text = ""; progressText.Text = "正在搜索各站点资源…"; Render();
            try
            {
                results = await Service.TorrentSearch(search.Text.Trim(), selected, update => page.Body.DispatcherQueue.TryEnqueue(() =>
                {
                    if (page.Token.IsCancellationRequested || !searching) return;
                    results = Json.Items(update); var state = Json.Get(update, "progress"); var text = Json.Text(state, "text");
                    progressText.Text = text.Length > 0 ? text : $"正在搜索 {search.Text.Trim()}，已完成 {Json.Number(state, "finished"):0} / {Json.Number(state, "total"):0} 个请求…"; Render();
                }), page.Token);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex) { searchError = ex.Message; }
            finally { searching = false; Render(); }
        }
        filter.TextChanged += (_, _) => { window = 60; Render(); }; sort.SelectionChanged += (_, _) => { Service.SetPreference("moviepilot.resource.sort", sort.SelectedIndex.ToString()); Render(); };
        direction.Click += (_, _) => { ascending = !ascending; direction.Content = MpButtonContent(ascending ? "\uE74A" : "\uE74B", ""); Service.SetPreference("moviepilot.resource.ascending", ascending ? "true" : "false"); Render(); };
        more.Click += (_, _) => { window += 60; Render(); };
        var searchButton = MpCompact(Button("", () => { }), "\uE72A", "搜索", "搜索 MoviePilot 站点资源"); searchButton.Height = 32;
        async Task RunSearch()
        {
            if (!searchButton.IsEnabled || searching) return; searchButton.IsEnabled = false;
            try { await page.Run(Search); } finally { searchButton.IsEnabled = !string.IsNullOrWhiteSpace(search.Text); }
        }
        searchButton.Click += async (_, _) => await RunSearch(); search.QuerySubmitted += async (_, _) => await RunSearch();
        search.TextChanged += (_, _) => searchButton.IsEnabled = !searching && !string.IsNullOrWhiteSpace(search.Text); searchButton.IsEnabled = !string.IsNullOrWhiteSpace(search.Text);
        var searchRow = new Grid { ColumnSpacing = 10 }; searchRow.ColumnDefinitions.Add(new ColumnDefinition()); searchRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); searchRow.Children.Add(search); Grid.SetColumn(searchButton, 1); searchRow.Children.Add(searchButton);
        var siteOptions = Stack(10); siteOptions.Children.Add(DashboardLabel("选择搜索站点", 14, true)); siteOptions.Children.Add(DashboardMuted("不选择表示搜索全部站点")); siteOptions.Children.Add(sites); siteOptions.Children.Add(Button("使用全部站点", () => sites.SelectedItems.Clear()));
        var siteButton = MpCompact(Button("", () => { }), "\uE774", "", "MoviePilot 搜索站点"); siteButton.Flyout = new Flyout { Content = siteOptions };
        var mediaOptions = Stack(12); mediaOptions.Children.Add(page.Action("按关键词查找媒体", FindMedia)); mediaOptions.Children.Add(mediaChoice); mediaOptions.Children.Add(identity);
        var mediaButton = MpCompact(Button("", () => { }), "\uE8B2", "", "MoviePilot 下载归属媒体"); mediaButton.Flyout = new Flyout { Content = mediaOptions };
        var menu = new MenuFlyout(); MpMenuAction(menu, page, "下载管理", "\uE896", () => { navigate("viewing:downloads"); return Task.CompletedTask; }); MpMenuAction(menu, page, "重新登录 MoviePilot", "\uE77B", () => ReconnectMoviePilot(page));
        var toolbar = Row(6); toolbar.Children.Add(siteButton); toolbar.Children.Add(mediaButton); toolbar.Children.Add(MpMenu("\uE712", "", "MoviePilot 资源操作", menu)); HeaderLeading = toolbar;
        var resources = Stack(12); foreach (var element in new UIElement[] { heading, progressCard, list, more }) resources.Children.Add(element);
        foreach (var element in new UIElement[] { mediaHeader, searchRow, filterBar, chips, resources }) page.Body.Children.Add(element);
        Render();
        var scroll = (ScrollViewer)Show(page, async () =>
        {
            try { foreach (var site in Json.Items(await Service.Mp("sites", null, page.Token))) sites.Items.Add(new ListViewItem { Content = Json.Title(site), Tag = (long)Json.Number(site, "id") }); }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex) { siteOptions.Children.Add(DashboardMuted("站点加载失败，搜索仍使用全部站点：" + ex.Message)); }
            if (selectedMedia is null && !string.IsNullOrWhiteSpace(keyword)) await FindMedia(); Render();
        }, new Thickness(52, 16, 52, 48));
        scroll.ViewChanged += (_, _) => { if (scroll.ScrollableHeight > 0 && scroll.VerticalOffset >= scroll.ScrollableHeight - 150 && more.Visibility == Visibility.Visible) { window += 60; Render(); } };
        return scroll;
    }
    private static ItemsPanelTemplate WrapPanelTemplate() => (ItemsPanelTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("<ItemsPanelTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><ItemsWrapGrid Orientation='Horizontal'/></ItemsPanelTemplate>");
}
