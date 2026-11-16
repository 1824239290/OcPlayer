#if DEBUG
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Features;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.Preview;

internal sealed partial class ViewingPageVerification
{
    private async Task VerifyBangumiPages(Grid root, IntegrationPages pages, List<string> routes, List<string> assertions,
        Func<string, Task> capture, Func<FrameworkElement, string, Task> captureElement)
    {
        Button Named(string name) => Descendants(root).OfType<Button>().Single(x => AutomationProperties.GetName(x) == name);
        DropDownButton Menu(string name) => Descendants(root).OfType<DropDownButton>().Single(x => AutomationProperties.GetName(x) == name);
        void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
        void Select(MenuFlyout menu, string label)
        {
            if (menu.Items.OfType<ToggleMenuFlyoutItem>().FirstOrDefault(x => x.Text == label) is { } toggle)
                ((IToggleProvider)new ToggleMenuFlyoutItemAutomationPeer(toggle).GetPattern(PatternInterface.Toggle)).Toggle();
            else
            {
                var item = menu.Items.OfType<MenuFlyoutItem>().Single(x => x.Text == label);
                ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(item).GetPattern(PatternInterface.Invoke)).Invoke();
            }
        }
        void Toggle(string name)
        {
            var button = Descendants(root).OfType<ToggleButton>().Single(x => AutomationProperties.GetName(x) == name);
            ((IToggleProvider)new ToggleButtonAutomationPeer(button).GetPattern(PatternInterface.Toggle)).Toggle();
        }
        async Task Wait(Func<bool> condition, string error)
        {
            for (var i = 0; i < 200 && !condition(); i++) await Task.Delay(30);
            root.UpdateLayout(); if (!condition()) throw new Exception(error);
        }
        Button Chapter(long subject, int sort) => Descendants(root).OfType<Button>().Single(x => x.Tag is JsonElement episode && Json.Number(episode, "id") == subject * 100 + sort);
        Button[] Posters() => Descendants(root).OfType<Button>().Where(x => AutomationProperties.GetName(x).StartsWith("Bangumi 条目 ")).ToArray();
        bool HasText(string value) => Descendants(root).OfType<TextBlock>().Any(x => x.Text == value);
        ContentDialog[] Dialogs() => VisualTreeHelper.GetOpenPopupsForXamlRoot(root.XamlRoot).SelectMany(x => Descendants(x.Child).Prepend(x.Child)).OfType<ContentDialog>().ToArray();
        async Task Themes(ScrollViewer page, string name)
        {
            var content = (FrameworkElement)page.Content;
            await capture(name + "-dark-top"); await captureElement(content, name + "-dark-full");
            root.RequestedTheme = ElementTheme.Light; root.Background = new SolidColorBrush(Microsoft.UI.Colors.White);
            await Task.Delay(120); root.UpdateLayout(); await capture(name + "-light-top");
            AppWindow.ResizeClient(new(650, 800)); await Task.Delay(150); root.UpdateLayout(); await capture(name + "-compact");
            var wide = Descendants(root).OfType<Button>().Where(x => x.IsLoaded && x.ActualWidth > root.ActualWidth).ToArray();
            if (wide.Length > 0) throw new Exception(name + " has buttons wider than its compact viewport");
            assertions.Add(name + " remains contained in dark, light and compact layouts");
            AppWindow.ResizeClient(new(1130, 800)); root.RequestedTheme = ElementTheme.Dark; root.Background = new SolidColorBrush(Microsoft.UI.Colors.Black);
            await Task.Delay(120); root.UpdateLayout();
        }
        TextBlock? title = null; TextBlock? subtitle = null;
        void UpdateTitle() { if (title is not null) title.Text = pages.HeaderTitle ?? ""; if (subtitle is not null) subtitle.Text = pages.HeaderSubtitle ?? ""; }
        pages.HeaderChanged += UpdateTitle;
        async Task<ScrollViewer> Mount(string route)
        {
            root.Children.Clear(); var page = (ScrollViewer)pages.Route(route); root.Children.Add(page);
            // The production shell mounts these controls outside the scrolling content.
            var header = new Grid { Height = 48, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(40, 0, 40, 0), ColumnSpacing = 12 };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition());
            var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center }; title = new TextBlock { FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }; subtitle = new TextBlock { FontSize = 10 }; names.Children.Add(title); names.Children.Add(subtitle); header.Children.Add(names);
            if (pages.HeaderLeading is { } leading) { Grid.SetColumn(leading, 1); header.Children.Add(leading); }
            if (pages.HeaderTrailing is { } trailing) { Grid.SetColumn(trailing, 2); trailing.HorizontalAlignment = HorizontalAlignment.Right; header.Children.Add(trailing); }
            root.Children.Add(header); UpdateTitle(); await Task.Delay(600); root.UpdateLayout();
            if (Descendants(root).OfType<TextBlock>().Any(x => x.Text.Contains("请求失败") || x.Text.Contains("加载失败"))) throw new Exception(route + " failed to load");
            return page;
        }
        try
        {
            var watching = await Mount("viewing:bangumi:3");
            if (Descendants(root).OfType<ComboBox>().Any() || !HasText("Bangumi 章节管理")) throw new Exception("Watching page retains the old form or has no toolbar title");
            if (Descendants(root).OfType<DropDownButton>().Count(x => AutomationProperties.GetName(x).StartsWith("Bangumi 收藏状态 ")) != 8) throw new Exception("Watching page lost collection rows");
            var first = Chapter(1, 1); var second = Chapter(1, 2);
            var firstBounds = first.TransformToVisual(root).TransformPoint(new(0, 0)); var secondBounds = second.TransformToVisual(root).TransformPoint(new(0, 0));
            await capture("bangumi-watching-initial");
            if (Math.Abs(firstBounds.Y - secondBounds.Y) > 1 || secondBounds.X <= firstBounds.X || Math.Abs(first.ActualWidth - first.ActualHeight) > 1 || first.ActualWidth != 48) throw new Exception($"Watching chapters are not rounded square tiles: first={firstBounds}, second={secondBounds}, size={first.ActualWidth}x{first.ActualHeight}");
            Invoke(first); await Wait(() => AutomationProperties.GetName(Chapter(1, 1)).EndsWith("未看"), "Watched chapter click did not undo watched state");
            Invoke(Chapter(1, 1)); await Wait(() => AutomationProperties.GetName(Chapter(1, 1)).EndsWith("看过"), "Unwatched chapter click did not mark watched");
            Invoke(Named("Bangumi 看完下一集 1")); await Wait(() => AutomationProperties.GetName(Chapter(1, 7)).EndsWith("看过"), "Quick next action did not mark the next chapter");
            if (Chapter(1, 8).IsEnabled || Named("Bangumi 看完下一集 1").IsEnabled) throw new Exception("Unaired next chapter became actionable");
            assertions.Add("Watching chapter click toggles watched state, next action advances progress and unaired chapters remain disabled");
            await Themes(watching, "bangumi-watching");
            Select((MenuFlyout)Menu("Bangumi 收藏状态 1").Flyout, "看过");
            await Wait(() => !Descendants(root).OfType<DropDownButton>().Any(x => AutomationProperties.GetName(x) == "Bangumi 收藏状态 1"), "Finished subject remains in watching membership");
            assertions.Add("Changing a watching subject's collection state removes its card");
            Invoke(Named("Bangumi 个人主页")); if (routes.Last() != "viewing:profile") throw new Exception("Watching toolbar profile route is missing");

            var profile = await Mount("viewing:profile");
            var sectionNames = new[] { "我的动画", "我的游戏", "我的书籍", "我的音乐", "我的三次元" };
            var displayed = Descendants(root).OfType<TextBlock>().Select(x => x.Text).Where(sectionNames.Contains).ToArray();
            if (!displayed.SequenceEqual(sectionNames) || !HasText("@test") || !HasText("此处是用户的个人签名")) throw new Exception("Profile identity or category order differs from macOS");
            var tabs = Descendants(root).OfType<ToggleButton>().Where(x => AutomationProperties.GetName(x).StartsWith("Bangumi 主页 ")).ToArray();
            if (tabs.Length != 25 || !tabs.Single(x => AutomationProperties.GetName(x) == "Bangumi 主页 4 筛选 2").IsChecked.GetValueOrDefault()) throw new Exception("Profile count chips or preferred nonempty state are incomplete");
            Toggle("Bangumi 主页 2 筛选 1"); await Wait(() => Descendants(root).OfType<Button>().Any(x => AutomationProperties.GetName(x) == "Bangumi 主页条目 21001"), "Profile chips do not load their selected collection");
            Invoke(Named("Bangumi 主页条目 21001")); if (routes.Last() != "viewing:subject:21001") throw new Exception("Profile poster opens the wrong subject");
            assertions.Add("Profile shows five ordered categories, count chips, account signature and preferred collections; chips and posters navigate correctly");
            await Themes(profile, "bangumi-profile");

            var wish = await Mount("viewing:bangumi:1");
            if (Posters().Length != 20 || !HasText("待看片单")) throw new Exception("Wish grid does not show its first 20 subjects");
            var posterGrid = (Grid)VisualTreeHelper.GetParent(Posters()[0]);
            if (posterGrid.ColumnDefinitions.Count != 4) throw new Exception("Wish posters do not preserve the four-column reference layout");
            Invoke(Posters()[0]); if (routes.Last() != "viewing:subject:21001") throw new Exception("Wish poster route is wrong");
            await Themes(wish, "bangumi-wish");
            Toggle("Bangumi 片单筛选 2"); await Wait(() => Posters().Length == 20 && HasText("看过片单"), "Watched segment does not replace the grid");
            Invoke(Descendants(root).OfType<Button>().Single(x => x.Content?.ToString() == "加载更多")); await Wait(() => Posters().Length == 31, "Collection pagination did not append the remaining 11 subjects");
            Toggle("Bangumi 片单筛选 1"); Toggle("Bangumi 片单筛选 4"); Toggle("Bangumi 片单筛选 5");
            await Wait(() => HasText("抛弃片单") && Posters().Length == 3 && Posters().All(x => x.Tag is JsonElement raw && Json.Number(raw, "type") == 5), "Fast segment changes published a stale collection");
            assertions.Add("Wish grid preserves four columns, opens subjects, appends pagination and rejects stale results after rapid segment changes");
            var search = await Mount("viewing:bangumi:q=测试");
            if (Posters().Length != 1 || ((MenuFlyout)Menu("Bangumi 收藏与搜索类型").Flyout).Items.Count != 6) throw new Exception("Remote search result or type filters are missing");
            assertions.Add("Bangumi remote search loads results and exposes all six search types");

            var detail = await Mount("viewing:subject:1");
            if ((int)Menu("Bangumi 收藏状态 1").Tag != 2 || (int)Menu("Bangumi 我的评分 1").Tag != 8) throw new Exception("Subject menus do not reflect the fetched account state");
            if (!HasText("英文：A longer alternate title that wraps over several lines")) throw new Exception("Subject infobox array values were not decoded");
            var cells = Descendants(root).OfType<Border>().Where(x => x.Tag is JsonElement field && Json.Text(field, "key").Length > 0).ToArray();
            if (cells.Length != 20 || ((Grid)VisualTreeHelper.GetParent(cells[0])).ColumnDefinitions.Count < 3) throw new Exception("Subject infobox did not form an adaptive information grid");
            foreach (var row in cells.GroupBy(x => Grid.GetRow(x))) if (row.Max(x => x.ActualHeight) - row.Min(x => x.ActualHeight) > 1) throw new Exception("Infobox row heights are inconsistent");
            if (Chapter(1, 8).IsEnabled || Chapter(1, 7).ContextFlyout is not MenuFlyout { Items.Count: 5 }) throw new Exception("Subject chapter context actions or unaired protection are incomplete");
            Select((MenuFlyout)Menu("Bangumi 我的评分 1").Flyout, "9 神作"); await Wait(() => (int)Menu("Bangumi 我的评分 1").Tag == 9, "Rating selection did not persist");
            Select((MenuFlyout)Menu("Bangumi 我的评分 1").Flyout, "未评分"); await Wait(() => (int)Menu("Bangumi 我的评分 1").Tag == 0, "Rating could not be withdrawn");
            Select((MenuFlyout)Menu("Bangumi 收藏状态 1").Flyout, "想看"); await Wait(() => (int)Menu("Bangumi 收藏状态 1").Tag == 1, "Subject collection selection did not persist");
            Invoke(Named("刷新 Bangumi 详情与章节")); await Wait(() => (int)Menu("Bangumi 我的评分 1").Tag == 0 && (int)Menu("Bangumi 收藏状态 1").Tag == 1, "Refresh reset the saved collection or withdrawn score");
            Select((MenuFlyout)Chapter(1, 7).ContextFlyout, "看到此集"); await Wait(() => AutomationProperties.GetName(Chapter(1, 7)).EndsWith("看过"), "Subject batch chapter action did not refresh");
            Invoke(Named("MoviePilot 下载 Bangumi 条目 1")); if (!routes.Last().StartsWith("viewing:resources:")) throw new Exception("Subject MoviePilot download route is missing");
            assertions.Add("Subject reflects fetched collection and score; rating withdrawal, collection changes, refresh, chapter context actions and MoviePilot navigation work");
            await Themes(detail, "bangumi-subject");
            detail.ChangeView(null, detail.ScrollableHeight, null, true); await Task.Delay(120); var offset = detail.VerticalOffset;
            Invoke(Named("展开全文"));
            await Wait(() => Dialogs().Length > 0, "Synopsis did not open a separate dialog");
            var dialog = Dialogs().Single();
            if (dialog.Content is not ScrollViewer { Content: TextBlock { IsTextSelectionEnabled: true } }) throw new Exception("Synopsis dialog lost selectable full text");
            await capture("bangumi-subject-synopsis-dialog"); var closed = new TaskCompletionSource(); dialog.Closed += (_, _) => closed.TrySetResult(); dialog.Hide(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(5)); await Task.Delay(120);
            if (Math.Abs(detail.VerticalOffset - offset) > 1) throw new Exception("Synopsis expansion changed the background page offset");
            assertions.Add("Full synopsis opens in a selectable-text dialog and retains the background page scroll position");
        }
        finally { pages.HeaderChanged -= UpdateTitle; }
    }
}
#endif
