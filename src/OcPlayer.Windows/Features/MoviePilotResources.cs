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
        var page = new Page(); if (Gate(page, false)) return Show(page); JsonElement? selectedMedia = null;
        if (keyword.StartsWith("media=", StringComparison.Ordinal)) { selectedMedia = JsonDocument.Parse(keyword[6..]).RootElement.Clone(); keyword = Json.Title(selectedMedia.Value); }
        var search = new TextBox { Header = "站点资源搜索", Text = keyword }; var sites = new ListView { SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 180 };
        var mediaChoice = new ComboBox { Header = "下载归属媒体", HorizontalAlignment = HorizontalAlignment.Stretch, PlaceholderText = "选择准确的媒体来源编号" };
        var identity = Muted("");
        void SelectIdentity()
        {
            selectedMedia = mediaChoice.SelectedItem is ComboBoxItem { Tag: JsonElement media } ? media : null;
            identity.Text = selectedMedia is { } chosen ? MoviePilotPolicies.Identity(chosen) + (Json.First(chosen, "tmdbid", "tmdb_id").Length == 0 ? "\n此媒体没有 TMDB 编号，自动刮削可能缺少字段；下载将保留实际来源编号。" : "") : "请先选择归属媒体";
        }
        void AddMedia(JsonElement media) => mediaChoice.Items.Add(new ComboBoxItem { Content = $"{Json.Title(media)} · {Json.Text(media, "year")} · {Json.First(media, "type", "media_type")} · {MoviePilotPolicies.Identity(media)}", Tag = media });
        if (selectedMedia is { } initial) { AddMedia(initial); mediaChoice.SelectedIndex = 0; SelectIdentity(); }
        mediaChoice.SelectionChanged += (_, _) => SelectIdentity();
        async Task FindMedia()
        {
            if (string.IsNullOrWhiteSpace(search.Text)) throw new ArgumentException("请输入搜索关键词。");
            var current = selectedMedia; var items = Json.Items(await Service.Mp("mediaSearch", new { title = search.Text.Trim() }, page.Token)); mediaChoice.Items.Clear();
            if (current is { } chosen) AddMedia(chosen);
            foreach (var media in items.Where(x => current is null || MoviePilotPolicies.Identity(x) != MoviePilotPolicies.Identity(current.Value))) AddMedia(media);
            if (current is not null) mediaChoice.SelectedIndex = 0;
        }
        var filter = new TextBox { Header = "结果关键词", PlaceholderText = "标题关键词" }; var list = Stack(12); var counts = Muted("尚未搜索资源"); var progress = Muted("");
        var filters = Enumerable.Range(0, 7).Select(_ => new HashSet<string>(StringComparer.Ordinal)).ToArray(); var filterButtons = Row(6); var chips = new ItemsControl { ItemsPanel = WrapPanelTemplate() };
        var sort = new ComboBox { Header = "排序", ItemsSource = new[] { "默认（站点优先级）", "站点", "大小", "做种", "时间" }, SelectedIndex = int.TryParse(Service.Preference("moviepilot.resource.sort"), out var field) ? Math.Clamp(field, 0, 4) : 0 };
        var ascending = new ToggleSwitch { Header = "升序", IsOn = Service.Preference("moviepilot.resource.ascending") == "true" };
        var more = Button("再显示 60 条", () => { }); JsonElement[] results = []; var window = 60; var searched = false; var searching = false;
        void Render()
        {
            list.Children.Clear(); var matches = MoviePilotPolicies.Filter(results, filters, filter.Text); counts.Text = $"资源 {results.Length} · 命中 {matches.Length} / 总 {results.Length}";
            var chipItems = new List<UIElement>();
            for (var i = 0; i < filters.Length; i++)
            {
                var index = i; if (i < filterButtons.Children.Count && filterButtons.Children[i] is Button button) button.Content = MoviePilotPolicies.FilterFields[i].Label + (filters[i].Count > 0 ? $" ({filters[i].Count})" : "");
                foreach (var selected in filters[i].Order()) chipItems.Add(Button(MoviePilotPolicies.FilterFields[i].Label + " " + selected + " ×", () => { filters[index].Remove(selected); window = 60; Render(); }));
            }
            chips.ItemsSource = chipItems;
            foreach (var result in MoviePilotPolicies.Sort(matches, sort.SelectedIndex, ascending.IsOn).Take(window))
            {
                var torrent = Json.Get(result, "torrent"); var details = Stack(6);
                details.Children.Add(Muted(string.Join(" · ", Enumerable.Range(0, 7).Select(i => MoviePilotPolicies.FilterValue(result, i)).Where(x => x.Length > 0))));
                details.Children.Add(Muted($"{Json.Number(torrent, "size") / 1073741824:0.##} GB · 做种 {Json.Number(torrent, "seeders"):0} · 发布 {Json.Text(torrent, "pubdate")}"));
                var download = Button("下载…", () => { });
                // Search owns its own long-running operation; each download remains actionable while SSE is arriving.
                download.Click += async (_, _) =>
                {
                    download.IsEnabled = false;
                    try
                    {
                        if (selectedMedia is not { } media) throw new InvalidOperationException("请先选择下载归属媒体。");
                        if (await Confirm(page, "添加下载", Json.Title(media) + "\n" + Json.Title(torrent))) { await Service.Mp("download.add", new { media, torrent }, page.Token); download.Content = "已加入下载"; }
                    }
                    catch (OperationCanceledException) { }
                    catch (Exception ex) { if (!page.Token.IsCancellationRequested) page.Status.Text = ex.Message; }
                    finally { download.IsEnabled = true; }
                };
                list.Children.Add(Item(torrent, details, download));
            }
            if (matches.Length == 0) list.Children.Add(Muted(!searched ? "尚未搜索资源" : results.Length > 0 ? $"筛选排除了全部 {results.Length} 条资源" : searching ? "正在等待站点返回资源…" : "未找到资源"));
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
        for (var i = 0; i < 7; i++) { var index = i; var button = Button(MoviePilotPolicies.FilterFields[i].Label, () => { }); button.Click += async (_, _) => { try { await ChooseFilter(index); } catch (Exception ex) { page.Status.Text = ex.Message; } }; filterButtons.Children.Add(button); }
        async Task Search()
        {
            if (string.IsNullOrWhiteSpace(search.Text)) throw new ArgumentException("请输入搜索关键词。");
            var selected = sites.SelectedItems.OfType<ListViewItem>().Select(x => (long)x.Tag).ToArray(); results = []; searched = searching = true; window = 60; Render();
            try
            {
                results = await Service.TorrentSearch(search.Text.Trim(), selected, update => page.Body.DispatcherQueue.TryEnqueue(() =>
                {
                    if (page.Token.IsCancellationRequested || !searching) return;
                    results = Json.Items(update); var state = Json.Get(update, "progress"); progress.Text = $"{Json.Text(state, "text")} · 站点 {Json.Number(state, "finished"):0}/{Json.Number(state, "total"):0} · 已收到 {results.Length} 条"; Render();
                }), page.Token);
            }
            finally { searching = false; Render(); }
        }
        filter.TextChanged += (_, _) => { window = 60; Render(); }; sort.SelectionChanged += (_, _) => { Service.SetPreference("moviepilot.resource.sort", sort.SelectedIndex.ToString()); Render(); }; ascending.Toggled += (_, _) => { Service.SetPreference("moviepilot.resource.ascending", ascending.IsOn ? "true" : "false"); Render(); };
        more.Click += (_, _) => { window += 60; Render(); }; Submit(search, page, Search);
        page.Body.Children.Add(search); page.Body.Children.Add(page.Action("搜索归属媒体", FindMedia)); page.Body.Children.Add(mediaChoice); page.Body.Children.Add(identity);
        page.Body.Children.Add(Muted("选择搜索站点；不选表示全部站点")); page.Body.Children.Add(sites); page.Body.Children.Add(page.Action("搜索资源", Search)); page.Body.Children.Add(progress);
        page.Body.Children.Add(filter); page.Body.Children.Add(filterButtons); page.Body.Children.Add(chips); page.Body.Children.Add(Button("清除全部筛选", () => { foreach (var selected in filters) selected.Clear(); filter.Text = ""; window = 60; Render(); }));
        var ordering = Row(10); ordering.Children.Add(sort); ordering.Children.Add(ascending); page.Body.Children.Add(ordering); page.Body.Children.Add(counts); page.Body.Children.Add(list); page.Body.Children.Add(more); Reconnect(page);
        var scroll = (ScrollViewer)Show(page, async () => { foreach (var site in Json.Items(await Service.Mp("sites", null, page.Token))) sites.Items.Add(new ListViewItem { Content = Json.Title(site), Tag = (long)Json.Number(site, "id") }); if (selectedMedia is null && !string.IsNullOrWhiteSpace(keyword)) await FindMedia(); Render(); });
        scroll.ViewChanged += (_, _) => { if (scroll.ScrollableHeight > 0 && scroll.VerticalOffset >= scroll.ScrollableHeight - 150 && more.Visibility == Visibility.Visible) { window += 60; Render(); } };
        return scroll;
    }
    private static ItemsPanelTemplate WrapPanelTemplate() => (ItemsPanelTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("<ItemsPanelTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><ItemsWrapGrid Orientation='Horizontal'/></ItemsPanelTemplate>");
}
