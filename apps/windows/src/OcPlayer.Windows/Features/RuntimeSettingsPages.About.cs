using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.Features;

internal sealed partial class RuntimeSettingsPages
{
    private void About(StackPanel page)
    {
        var information = Section(page, "OcPlayer Windows");
        Add(information, SettingsUi.Row("应用版本", SettingsUi.Value(AppReleaseService.DisplayVersion)));
        Add(information, SettingsUi.Row("共享核心", SettingsUi.Value(App.Core?.Version ?? "未就绪")));
        Add(information, SettingsUi.Row("播放内核", SettingsUi.Value("liberika " + KernelVersion.Read())));
        var updates = Section(page, "更新");
        var state = Note("尚未检查更新。");
        Button? view = null; Button? check = null;
        check = AsyncAction("检查更新", async () =>
        {
            state.Text = "正在检查更新…";
            try
            {
                var release = await AppReleaseService.Check();
                state.Text = release?.IsNewer == true ? "发现新版本：" + release.Version + (AppReleaseService.IgnoredVersion == release.Version ? "（已忽略自动提醒）" : "") : "当前已是最新版本。";
                if (view is not null) view.Visibility = release?.IsNewer == true ? Visibility.Visible : Visibility.Collapsed;
                check!.Content = "重新检查更新";
                if (release?.IsNewer == true) await ShowRelease(page.XamlRoot, release);
            }
            catch (Exception ex) { state.Text = "检查更新失败：" + ex.Message; check!.Content = "重试"; }
        }); Add(updates, check);
        view = AsyncAction("查看新版说明", async () => { if (AppReleaseService.Latest is { } release) await ShowRelease(page.XamlRoot, release); });
        view.Visibility = AppReleaseService.Latest?.IsNewer == true ? Visibility.Visible : Visibility.Collapsed; Add(updates, view); Add(updates, state);
        var links = Section(page, "");
        Add(links, Action($"开源许可证 · {OpenSourceCatalog.Entries.Length} 项", () => navigate("settings:开源许可证")));
        Add(links, AsyncAction("项目主页", async () => { await global::Windows.System.Launcher.LaunchUriAsync(new Uri("http://192.168.5.107:8418/jumusu/OcPlayer")); }));
        page.Children.Add(Note("This product uses the TMDB API but is not endorsed or certified by TMDB."));
    }
    public static async Task CheckAutomaticUpdate(FrameworkElement owner)
    {
        try
        {
            var release = await AppReleaseService.Check();
            if (release?.IsNewer == true && release.Version != AppReleaseService.IgnoredVersion && owner.XamlRoot is not null) await ShowRelease(owner.XamlRoot, release);
        }
        catch (Exception ex) { AppDiagnostics.Write("debug", "自动检查更新失败：" + ex.Message); }
    }
    private static async Task ShowRelease(XamlRoot root, AppRelease release)
    {
        var panel = new StackPanel { Spacing = 12, Width = Math.Min(460, Math.Max(200, root.Size.Width - 100)) };
        panel.Children.Add(Note("发布日期：" + (release.PublishedAt?.ToLocalTime().ToString("yyyy-MM-dd HH:mm") ?? "未提供")));
        panel.Children.Add(new TextBlock { Text = string.IsNullOrWhiteSpace(release.Notes) ? "此版本未提供更新日志。" : release.Notes, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        var dialog = new ContentDialog { XamlRoot = root, Title = "OcPlayer " + release.Version, Content = new ScrollViewer { Content = panel, MaxHeight = 440 },
            PrimaryButtonText = "前往下载", SecondaryButtonText = "忽略此版本", CloseButtonText = "关闭" };
        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary) await global::Windows.System.Launcher.LaunchUriAsync(new Uri(release.DownloadUrl));
        if (result == ContentDialogResult.Secondary) AppReleaseService.Ignore(release.Version);
    }
    private void Licenses(StackPanel page)
    {
        page.Children.Add(Note($"{OpenSourceCatalog.Entries.Length} 个组件与数据服务。许可文本随应用打包，可离线阅读和复制。Rust 清单按 Windows 构建依赖图生成。"));
        foreach (var group in OpenSourceCatalog.Entries.GroupBy(x => x.Group))
        {
            var rows = Section(page, $"{group.Key} · {group.Count()} 项", collapsed: true);
            foreach (var entry in group)
            {
                var button = AsyncAction($"{entry.Name} · {entry.Version} · {entry.License}", async () =>
                {
                    var panel = new StackPanel { Spacing = 12, Width = Math.Min(500, Math.Max(200, page.XamlRoot.Size.Width - 100)) };
                    panel.Children.Add(Note(entry.Purpose)); panel.Children.Add(Note("许可证：" + entry.License));
                    var home = new HyperlinkButton { Content = "项目主页", NavigateUri = Uri.TryCreate(entry.HomeUrl, UriKind.Absolute, out var h) && h.Scheme is "http" or "https" ? h : null };
                    var license = new HyperlinkButton { Content = "许可证 / 发布源包", NavigateUri = Uri.TryCreate(entry.LicenseUrl, UriKind.Absolute, out var u) && u.Scheme is "http" or "https" ? u : null };
                    panel.Children.Add(home); panel.Children.Add(license);
                    panel.Children.Add(Action("复制许可证文本", () => { var data = new global::Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(entry.Text); global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); }));
                    panel.Children.Add(new TextBlock { Text = entry.Text, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"), FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                    await new ContentDialog { XamlRoot = page.XamlRoot, Title = entry.Name + " " + entry.Version, Content = new ScrollViewer { Content = panel, MaxHeight = 500 }, CloseButtonText = "关闭" }.ShowAsync();
                });
                button.Content = new TextBlock { Text = $"{entry.Name} · {entry.Version} · {entry.License}", FontSize = 13, TextWrapping = TextWrapping.Wrap };
                Add(rows, button);
            }
        }
    }
}
