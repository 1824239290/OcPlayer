using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.Features;

internal sealed partial class RuntimeSettingsPages
{
    private void About(StackPanel page)
    {
        Heading(page, "OcPlayer Windows"); page.Children.Add(Note(AppReleaseService.DisplayVersion));
        page.Children.Add(Note("共享核心：" + (App.Core?.Version ?? "未就绪")));
        page.Children.Add(Note("播放内核：liberika " + KernelVersion.Read()));
        var state = new TextBlock { Text = "尚未检查更新。", TextWrapping = TextWrapping.Wrap }; page.Children.Add(state);
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
        }); page.Children.Add(check);
        view = AsyncAction("查看新版说明", async () => { if (AppReleaseService.Latest is { } release) await ShowRelease(page.XamlRoot, release); });
        view.Visibility = AppReleaseService.Latest?.IsNewer == true ? Visibility.Visible : Visibility.Collapsed; page.Children.Add(view);
        page.Children.Add(Action($"开源许可证 · {OpenSourceCatalog.Entries.Length} 项", () => navigate("settings:开源许可证")));
        page.Children.Add(AsyncAction("项目主页", async () => { await global::Windows.System.Launcher.LaunchUriAsync(new Uri("http://192.168.5.107:8418/jumusu/OcPlayer-Windows")); }));
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
        var panel = new StackPanel { Spacing = 12, Width = 460 };
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
            Heading(page, group.Key);
            foreach (var entry in group)
            {
                page.Children.Add(AsyncAction($"{entry.Name} · {entry.Version} · {entry.License}", async () =>
                {
                    var panel = new StackPanel { Spacing = 12, Width = 500 };
                    panel.Children.Add(Note(entry.Purpose)); panel.Children.Add(Note("许可证：" + entry.License));
                    var home = new HyperlinkButton { Content = "项目主页", NavigateUri = Uri.TryCreate(entry.HomeUrl, UriKind.Absolute, out var h) && h.Scheme is "http" or "https" ? h : null };
                    var license = new HyperlinkButton { Content = "许可证 / 发布源包", NavigateUri = Uri.TryCreate(entry.LicenseUrl, UriKind.Absolute, out var u) && u.Scheme is "http" or "https" ? u : null };
                    panel.Children.Add(home); panel.Children.Add(license);
                    panel.Children.Add(Action("复制许可证文本", () => { var data = new global::Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(entry.Text); global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); }));
                    panel.Children.Add(new TextBlock { Text = entry.Text, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"), FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                    await new ContentDialog { XamlRoot = page.XamlRoot, Title = entry.Name + " " + entry.Version, Content = new ScrollViewer { Content = panel, MaxHeight = 500 }, CloseButtonText = "关闭" }.ShowAsync();
                }));
            }
        }
    }
}
