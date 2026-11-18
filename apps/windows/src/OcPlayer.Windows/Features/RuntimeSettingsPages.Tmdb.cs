using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.Features;

internal sealed partial class RuntimeSettingsPages
{
    private void Tmdb(StackPanel page)
    {
        if (App.Core is not { } core) { page.Children.Add(Note("共享核心尚未就绪。")); return; }
        var service = core.Tmdb; var settings = service.Settings; var current = settings.Current;
        void Update(Func<TmdbPreferences, TmdbPreferences> update) => Save(() => settings.Save(update(settings.Current)));
        var credentials = Section(page, "凭据");
        var state = SettingsUi.Value(current.Configured ? "已配置" : "未配置"); Add(credentials, SettingsUi.Row("TMDB 凭据", state));
        var key = new PasswordBox { PlaceholderText = "输入新凭据", FontSize = 13 }; Add(credentials, SettingsUi.Row("API Key / Read Access Token", key, field: true));
        var save = Action(current.Configured ? "替换凭据" : "保存凭据", () => Save(() => { settings.Save(settings.Current with { ApiKey = key.Password }); key.Password = ""; state.Text = "已配置"; }));
        save.IsEnabled = false; key.PasswordChanged += (_, _) => save.IsEnabled = !string.IsNullOrWhiteSpace(key.Password); Add(credentials, save);
        Add(credentials, Note("支持 v3 API Key 或 v4 Read Access Token，保存在 Windows 凭据保险箱中。"));
        var preferences = Section(page, "元数据");
        Choice(preferences, "元数据语言", [("简体中文", "zh-CN"), ("繁體中文", "zh-TW"), ("English", "en"), ("日本語", "ja"), ("한국어", "ko")], current.Language, value => Update(x => x with { Language = value }));
        Add(preferences, Note("缺少翻译的字段会回退为英文。"));
        Toggle(preferences, "优先使用 TMDB 文本", current.PreferText, value => Update(x => x with { PreferText = value }));
        Add(preferences, Note("开启后替换标题、简介和类型；关闭时只补缺字段。"));
        Toggle(preferences, "替换已有图片", current.ReplaceImages, value => Update(x => x with { ReplaceImages = value }));
        Add(preferences, Note("开启后替换海报、背景与分集剧照；关闭时只补缺图。"));
        Toggle(preferences, "显示未入库剧集占位", current.ShowMissingEpisodes, value => Update(x => x with { ShowMissingEpisodes = value }));
        Add(preferences, Note("无需 TMDB 凭据，已关联的 Bangumi 章节也可以提供占位。"));
        var mirrors = Section(page, "镜像源");
        var api = new TextBox { Text = current.ApiMirror, PlaceholderText = "留空使用官方 API", FontSize = 13 };
        var images = new TextBox { Text = current.ImageMirror, PlaceholderText = "留空使用官方图片", FontSize = 13 };
        var currentApi = SettingsUi.Value(""); var currentImages = SettingsUi.Value("");
        void Preview() { currentApi.Text = settings.Current.ApiBase; currentImages.Text = settings.Current.ImageBase; }
        var mirror = Toggle(mirrors, "使用镜像源", current.UseMirror, value => { Update(x => x with { UseMirror = value }); Preview(); });
        Add(mirrors, SettingsUi.Row("API 镜像地址", api, field: true)); Add(mirrors, SettingsUi.Row("图片镜像地址", images, field: true));
        Add(mirrors, Action("应用镜像地址", () => Save(() => { settings.Save(settings.Current with { ApiMirror = api.Text, ImageMirror = images.Text }); api.Text = settings.Current.ApiMirror; images.Text = settings.Current.ImageMirror; Preview(); })));
        Add(mirrors, SettingsUi.Row("当前 API", currentApi)); Add(mirrors, SettingsUi.Row("当前图片", currentImages)); Preview();
        Add(mirrors, Action("填入官方备用域 api.tmdb.org", () => Save(() => { settings.Save(settings.Current with { UseMirror = true, ApiMirror = "https://api.tmdb.org/3", ImageMirror = "https://image.tmdb.org/t/p" }); api.Text = settings.Current.ApiMirror; images.Text = settings.Current.ImageMirror; mirror.IsOn = true; Preview(); })));
        Add(mirrors, Action("恢复官方直连", () => Save(() => { settings.Save(settings.Current with { UseMirror = false, ApiMirror = "", ImageMirror = "" }); api.Text = images.Text = ""; mirror.IsOn = false; Preview(); }), destructive: true));
        var batch = Section(page, "补全媒体库", collapsed: true);
        var count = SettingsUi.Value($"{service.EnrichedCount} 个条目"); Add(batch, SettingsUi.Row("已补全", count));
        var progress = Note(service.LastBatch?.ToString() ?? "尚未运行整库补全。"); Add(batch, progress);
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, Visibility = Visibility.Collapsed }; Add(batch, bar);
        CancellationTokenSource? cancellation = null;
        var cancel = Action("取消补全", () => cancellation?.Cancel()); cancel.IsEnabled = false;
        var run = AsyncAction("补全整个媒体库", async () =>
        {
            if (core.Server is not { } server) throw new InvalidOperationException("请先连接媒体服务器。");
            cancellation = new CancellationTokenSource(); cancel.IsEnabled = true; bar.Visibility = Visibility.Visible;
            try
            {
                await service.EnrichLibrary(server, new Progress<TmdbBatchProgress>(value => { progress.Text = value.ToString(); bar.Maximum = Math.Max(1, value.Total); bar.Value = value.Completed; count.Text = $"{service.EnrichedCount} 个条目"; }), cancellation.Token);
                progress.Text = service.LastBatch?.ToString() ?? "补全结束。";
            }
            finally { cancellation.Dispose(); cancellation = null; cancel.IsEnabled = false; bar.Visibility = Visibility.Collapsed; }
        });
        Add(batch, run); Add(batch, cancel);
        page.Unloaded += (_, _) => cancellation?.Cancel();
        Add(batch, Note("补全电影、剧集及所有季。取消或退出后保留成功结果，再次运行会继续补全缺失内容。"));
        Add(batch, AsyncAction("清除 TMDB 补全数据", async () =>
        {
            if (!await Confirm(page, "清除 TMDB 数据？", "将删除已保存的对应关系和下载元数据；凭据与偏好会保留。")) return;
            await service.Clear(); count.Text = "0 个条目"; progress.Text = "TMDB 补全数据已清除。";
        }, destructive: true));
        if (settings.LoadWarning is { } warning) _status.Text = warning;
    }
}
