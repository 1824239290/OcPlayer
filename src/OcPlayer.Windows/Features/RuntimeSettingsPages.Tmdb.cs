using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.Features;

internal sealed partial class RuntimeSettingsPages
{
    private void Tmdb(StackPanel page)
    {
        if (App.Core is not { } core) { page.Children.Add(Note("共享核心尚未就绪。")); return; }
        var service = core.Tmdb; var settings = service.Settings; var current = settings.Current;
        void Update(Func<TmdbPreferences, TmdbPreferences> update) => Save(() => settings.Save(update(settings.Current)));
        var state = Note(current.Configured ? "已配置 TMDB 凭据。可以替换 API Key 或 Read Access Token。" : "尚未配置 TMDB 凭据。"); page.Children.Add(state);
        var key = new PasswordBox { Header = "v3 API Key 或 v4 Read Access Token", PlaceholderText = "输入新凭据" }; page.Children.Add(key);
        var save = Action(current.Configured ? "替换凭据" : "保存凭据", () => Save(() => { settings.Save(settings.Current with { ApiKey = key.Password }); key.Password = ""; state.Text = "已配置 TMDB 凭据（保存在 Windows 凭据保险箱中）。"; }));
        save.IsEnabled = false; key.PasswordChanged += (_, _) => save.IsEnabled = !string.IsNullOrWhiteSpace(key.Password); page.Children.Add(save);
        Choice(page, "元数据语言", [("简体中文", "zh-CN"), ("繁體中文", "zh-TW"), ("English", "en"), ("日本語", "ja"), ("한국어", "ko")], current.Language, value => Update(x => x with { Language = value }));
        page.Children.Add(Note("缺少翻译的字段会回退为英文。"));
        Toggle(page, "优先使用 TMDB 文本", current.PreferText, value => Update(x => x with { PreferText = value }));
        page.Children.Add(Note("开启后替换服务端的标题、简介和类型；关闭时只补缺字段。"));
        Toggle(page, "替换已有图片", current.ReplaceImages, value => Update(x => x with { ReplaceImages = value }));
        page.Children.Add(Note("开启后替换海报、背景与分集剧照；关闭时只补缺图。"));
        Toggle(page, "显示未入库剧集占位", current.ShowMissingEpisodes, value => Update(x => x with { ShowMissingEpisodes = value }));
        page.Children.Add(Note("该选项不要求配置 TMDB 凭据，已关联的 Bangumi 章节也可以提供占位。"));
        Heading(page, "镜像源");
        var api = new TextBox { Header = "API 镜像地址", Text = current.ApiMirror, PlaceholderText = "留空单独使用官方 API" };
        var images = new TextBox { Header = "图片镜像地址", Text = current.ImageMirror, PlaceholderText = "留空单独使用官方图片" };
        var preview = Note("");
        void Preview() => preview.Text = $"当前 API：{settings.Current.ApiBase}\n当前图片：{settings.Current.ImageBase}";
        var mirror = Toggle(page, "使用镜像源", current.UseMirror, value => { Update(x => x with { UseMirror = value }); Preview(); });
        page.Children.Add(api); page.Children.Add(images);
        page.Children.Add(Action("应用镜像地址", () => Save(() => { settings.Save(settings.Current with { ApiMirror = api.Text, ImageMirror = images.Text }); api.Text = settings.Current.ApiMirror; images.Text = settings.Current.ImageMirror; Preview(); })));
        page.Children.Add(preview); Preview();
        page.Children.Add(Action("填入官方备用域 api.tmdb.org", () => Save(() => { settings.Save(settings.Current with { UseMirror = true, ApiMirror = "https://api.tmdb.org/3", ImageMirror = "https://image.tmdb.org/t/p" }); api.Text = settings.Current.ApiMirror; images.Text = settings.Current.ImageMirror; mirror.IsOn = true; Preview(); })));
        page.Children.Add(Action("恢复官方直连", () => Save(() => { settings.Save(settings.Current with { UseMirror = false, ApiMirror = "", ImageMirror = "" }); api.Text = images.Text = ""; mirror.IsOn = false; Preview(); })));
        Heading(page, "补全媒体库");
        var count = Note($"已补全 {service.EnrichedCount} 个条目"); page.Children.Add(count);
        var progress = new TextBlock { Text = service.LastBatch?.ToString() ?? "尚未运行整库补全。", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }; page.Children.Add(progress);
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, Visibility = Visibility.Collapsed }; page.Children.Add(bar);
        CancellationTokenSource? cancellation = null;
        var cancel = Action("取消补全", () => cancellation?.Cancel()); cancel.IsEnabled = false;
        var run = AsyncAction("补全整个媒体库", async () =>
        {
            if (core.Server is not { } server) throw new InvalidOperationException("请先连接媒体服务器。");
            cancellation = new CancellationTokenSource(); cancel.IsEnabled = true; bar.Visibility = Visibility.Visible;
            try
            {
                await service.EnrichLibrary(server, new Progress<TmdbBatchProgress>(value => { progress.Text = value.ToString(); bar.Maximum = Math.Max(1, value.Total); bar.Value = value.Completed; count.Text = $"已补全 {service.EnrichedCount} 个条目"; }), cancellation.Token);
                progress.Text = service.LastBatch?.ToString() ?? "补全结束。";
            }
            finally { cancellation.Dispose(); cancellation = null; cancel.IsEnabled = false; bar.Visibility = Visibility.Collapsed; }
        });
        page.Children.Add(run); page.Children.Add(cancel);
        page.Unloaded += (_, _) => cancellation?.Cancel();
        page.Children.Add(Note("补全电影、剧集及所有季。取消或退出后会保留成功结果；再次运行复用已有结果，并继续缺失的季。"));
        page.Children.Add(AsyncAction("清除 TMDB 补全数据", async () =>
        {
            if (!await Confirm(page, "清除 TMDB 数据？", "将删除已保存的对应关系和下载元数据；凭据与偏好会保留。")) return;
            await service.Clear(); count.Text = "已补全 0 个条目"; progress.Text = "TMDB 补全数据已清除。";
        }));
        if (settings.LoadWarning is { } warning) _status.Text = warning;
    }
}
