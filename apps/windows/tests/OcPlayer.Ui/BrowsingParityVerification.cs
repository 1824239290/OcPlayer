#if DEBUG
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Features;

namespace OcPlayer.Windows;

public sealed partial class MainWindow
{
    private void AttachBrowsingVerification()
    {
        var output = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--demo-verify-browser="))?.Split('=', 2)[1];
        if (output is null) return;
        WindowRoot.Loaded += async (_, _) =>
        {
            var assertions = new List<string>();
            void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); assertions.Add(message); }
            static IEnumerable<DependencyObject> Walk(DependencyObject root)
            { yield return root; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var item in Walk(VisualTreeHelper.GetChild(root, i))) yield return item; }
            string[] Texts() => Walk(PageHost).OfType<TextBlock>().Select(x => x.Text).ToArray();
            async Task Settle() { for (var i = 0; i < 50 && _transitions.IsTransitioning; i++) await Task.Delay(50); PageHost.UpdateLayout(); Check(!_transitions.IsTransitioning, "route transition finishes before inspecting controls"); }
            async Task Refresh(string route) { Navigate(route); await Task.Delay(120); await Settle(); }
            void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
            try
            {
                _transitions.SetAnimationsEnabled(false);
                _model.HiddenSections.UnionWith(_model.HomeSections); await Refresh("home");
                Check(Texts().Contains("首页栏目都已关闭") && Walk(PageHost).OfType<Button>().Any(x => Equals(x.Content, "去设置")), "all-disabled home explains state and exposes settings action");
                _model.HiddenSections.Clear(); _model.HomeLoading = true; await Refresh("home");
                Check(Walk(PageHost).OfType<ProgressBar>().Any(x => x.IsIndeterminate), "home refresh exposes a busy indicator"); _model.HomeLoading = false;
                var media = DemoCatalog.All[4] with { Id = "parity-long", Description = new string('长', 2000), CommunityRating = 8.8, OfficialRating = "TV-14", SeasonNumber = 1,
                    SelectedSeasonId = "s1", Seasons = [new("s1", "第1季", 1)], EpisodeNumber = 65, EpisodeLabel = "S1E65",
                    Episodes = Enumerable.Range(1, 70).Select(n => new DemoEpisode(n, "标题" + n, "", MediaId: "e" + n, Overview: "简介" + n)).ToArray() };
                _model.SelectedMedia = media; _model.SelectedEpisode = 65; await Refresh("detail");
                var ranges = Walk(PageHost).OfType<ComboBox>().Single(x => Equals(x.Header, "分集范围"));
                Check(ranges.Items.Count == 3 && ranges.SelectedIndex == 2, "seventy episodes divide into thirty-entry ranges and reveal selected episode");
                Check(Texts().Contains("TV-14") && Texts().Any(x => x.Contains("8.8")), "real rating and official rating are visible in detail header");
                var expand = Walk(PageHost).OfType<Button>().Single(x => Equals(x.Content, "展开全文")); Invoke(expand); await Task.Delay(300);
                var synopsisDialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(WindowRoot.XamlRoot).SelectMany(x => Walk(x.Child)).OfType<ContentDialog>().Single();
                Check(synopsisDialog.Content is ScrollViewer { Content: TextBlock { MaxLines: 0, IsTextSelectionEnabled: true } fullSynopsis }
                    && fullSynopsis.Text == media.Description, "expand synopsis opens a dialog with complete selectable text");
                Check(Equals(expand.Content, "展开全文") && Walk(PageHost).OfType<TextBlock>().Any(x => x.Text == media.Description && x.MaxLines == 3), "opening synopsis keeps the detail preview at three lines");
                var synopsisScroll = (ScrollViewer)synopsisDialog.Content;
                Check(synopsisScroll.ScrollableHeight > 0, "long synopsis scrolls within the dialog");
                synopsisScroll.ChangeView(null, synopsisScroll.ScrollableHeight, null, true); await Task.Delay(60);
                Check(_model.Route == "detail", "scrolling the synopsis dialog keeps the current detail page");
                Invoke(Walk(synopsisDialog).OfType<Button>().Single(x => Equals(x.Content, "关闭"))); await Task.Delay(300);
                Check(expand.IsEnabled && _model.Route == "detail", "closing the synopsis dialog restores the detail page");
                var reverse = Walk(PageHost).OfType<Button>().Single(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "分集排序：正序"); Invoke(reverse); await Task.Delay(150); await Settle();
                Check(_model.EpisodesDescending, "episode direction action changes saved ordering");
                Check(Walk(PageHost).OfType<Button>().Any(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "分集排序：倒序"), "episode direction toggle renders descending control");
                await Refresh("detail-info");
                Check(Texts().Contains("简介65"), "second detail page uses selected episode overview");
                var restored = new ViewModels.DemoViewModel(); Check(restored.EpisodesDescending, "new view-model restores episode order");
                _model.ThemeMode = "light"; SetTheme(false); await Task.Delay(100); Check(Root.RequestedTheme == ElementTheme.Light, "manual light theme is applied");
                _model.ThemeMode = "system"; SetTheme(false); await Task.Delay(100); Check(Root.RequestedTheme == ElementTheme.Default, "follow-system theme returns to platform default");
                var settings = new StackPanel(); new RuntimeSettingsPages(_model, Navigate, SetTheme).Build("播放", settings);
                Check(settings.Children.Count > 4, "real playback settings page builds all sections without an account");
                Check(WindowRoot.KeyboardAccelerators.Count(x => x.Key == global::Windows.System.VirtualKey.O) == 2, "file and link shortcuts stay registered above the player overlay");
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
                File.WriteAllText(output, JsonSerializer.Serialize(new { passed = true, assertions }, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch (Exception ex) { Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!); File.WriteAllText(output, JsonSerializer.Serialize(new { passed = false, error = ex.ToString(), assertions })); }
            finally { Close(); }
        };
    }
}
#endif
