using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.Features;

internal sealed partial class RuntimeSettingsPages
{
    private static string Bytes(long bytes) => bytes < 1024 * 1024 ? $"{bytes / 1024d:0.0} KiB" : $"{bytes / (1024d * 1024):0.0} MiB";
    private static nint WindowHandle(FrameworkElement element) => Microsoft.UI.Win32Interop.GetWindowFromWindowId(element.XamlRoot.ContentIslandEnvironment.AppWindowId);
    private static async Task<global::Windows.Storage.StorageFile?> SaveFile(FrameworkElement element, string name, string extension)
    {
        var picker = new global::Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = name };
        picker.FileTypeChoices.Add(extension == ".json" ? "JSON 配置文件" : "诊断文本", new List<string> { extension });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHandle(element)); return await picker.PickSaveFileAsync();
    }
    private static async Task<global::Windows.Storage.StorageFile?> OpenFile(FrameworkElement element)
    {
        var picker = new global::Windows.Storage.Pickers.FileOpenPicker(); picker.FileTypeFilter.Add(".json");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHandle(element)); return await picker.PickSingleFileAsync();
    }
    private void Maintenance(StackPanel page)
    {
        if (App.Core is not { } core) { page.Children.Add(Note("共享核心尚未就绪。")); return; }
        Heading(page, "缓存");
        var images = Note(""); var metadata = Note(""); page.Children.Add(images); page.Children.Add(metadata);
        void RefreshCache()
        {
            images.Text = $"图片缓存：{Bytes(ImageDiskCache.UsedBytes)} / {Bytes(ImageDiskCache.CapacityBytes)}";
            try { var result = PlaybackSession.Require(core.Client.Call("metadataDatabase.size", new { directory = core.DataDirectory })); metadata.Text = "媒体元数据缓存：" + Bytes(result.GetInt64()); }
            catch (Exception ex) { metadata.Text = "媒体元数据缓存不可用：" + ex.Message; }
        }
        RefreshCache();
        page.Children.Add(AsyncAction("清空图片缓存", async () => { if (!await Confirm(page, "清空图片缓存？", "已下载的海报和背景缓存将删除，需要时会重新下载。")) return;
            await ImageDiskCache.Clear(); RefreshCache(); _status.Text = "图片缓存已清空。"; }));
        page.Children.Add(AsyncAction("清空媒体元数据缓存", async () => { if (!await Confirm(page, "清空当前服务器的元数据缓存？", "将清除当前服务器的浏览缓存和本地进度副本，后续从服务器重新获取。其它服务器不受影响。")) return;
            if (core.Server is not { } server) throw new InvalidOperationException("当前未连接媒体服务器。");
            PlaybackSession.Require(core.Client.Call("cache.clear", new { tenantId = server.Profile.Id })); RefreshCache(); _status.Text = "当前服务器的媒体元数据缓存已清空。"; }));
        Heading(page, "配置备份与多端同步");
        page.Children.Add(Note("JSON 包含 TMDB 凭据、播放/字幕、弹幕、常规与镜像偏好；不会包含服务器账号密码或登录令牌。请妥善保管导出的配置。"));
        page.Children.Add(AsyncAction("导出配置文件…", async () =>
        {
            var json = SettingsBackup.Export(core, model.HomeSections.ToArray(), model.HiddenSections.ToArray(), model.ThemeMode, model.EpisodesDescending);
            var file = await SaveFile(page, $"OcPlayer-settings-{DateTime.Now:yyyyMMdd-HHmmss}", ".json"); if (file is null) return;
            await global::Windows.Storage.FileIO.WriteTextAsync(file, json); _status.Text = "已导出配置：" + file.Path;
        }));
        page.Children.Add(AsyncAction("从文件恢复配置…", async () =>
        {
            var file = await OpenFile(page); if (file is null) return;
            var properties = await file.GetBasicPropertiesAsync(); if (properties.Size > 4 * 1024 * 1024) throw new InvalidOperationException("配置文件过大。");
            var backup = SettingsBackup.Prepare(core, await global::Windows.Storage.FileIO.ReadTextAsync(file));
            if (!await Confirm(page, "预览要恢复的配置", backup.Preview)) return;
            SettingsBackup.Restore(core, backup);
            if (backup.HomeSections is { } sections)
            {
                var known = model.HomeSections.ToArray(); model.HomeSections.Clear();
                foreach (var name in sections.Concat(known).Distinct().Where(known.Contains)) model.HomeSections.Add(name);
            }
            if (backup.HiddenSections is { } hidden) { model.HiddenSections.Clear(); foreach (var name in hidden.Where(model.HomeSections.Contains)) model.HiddenSections.Add(name); }
            if (backup.EpisodesDescending is { } descending) model.EpisodesDescending = descending;
            model.SaveHomeSections();
            if (backup.Theme is { } theme) { model.ThemeMode = theme; themeChanged(model.DarkTheme); }
            _status.Text = "配置已恢复并立即应用。缓冲、渲染路线和画质增强将在下次播放生效。";
        }));
        Heading(page, "日志与诊断");
        Toggle(page, "详细日志", RuntimeSettings.Current.DetailedLogging, value => Save(() => RuntimeSettings.Save(RuntimeSettings.Current with { DetailedLogging = value })));
        page.Children.Add(Note("应用日志级别立即改变；内核 trace 从下次播放生效。"));
        Toggle(page, "弹幕诊断日志", RuntimeSettings.Current.DanmakuDiagnostics, value => Save(() => RuntimeSettings.Save(RuntimeSettings.Current with { DanmakuDiagnostics = value })));
        var expandedPath = false;
        var path = new Button { Content = "日志文件：" + Path.GetFileName(AppDiagnostics.FilePath), HorizontalAlignment = HorizontalAlignment.Left };
        path.Click += (_, _) => { expandedPath = !expandedPath; path.Content = "日志文件：" + (expandedPath ? AppDiagnostics.FilePath : Path.GetFileName(AppDiagnostics.FilePath)); }; page.Children.Add(path);
        var summary = Note("正在读取日志…"); page.Children.Add(summary);
        var records = new StackPanel { Spacing = 8 }; var expander = new Expander { Header = "最近的日志记录", Content = new ScrollViewer { Content = records, MaxHeight = 350 }, HorizontalAlignment = HorizontalAlignment.Stretch }; page.Children.Add(expander);
        async Task RefreshLogs()
        {
            var log = await AppDiagnostics.Read(); summary.Text = $"{log.Count} 条 · {Bytes(log.Bytes)} · 内核 trace {Bytes(AppDiagnostics.NativeTraceBytes)}"; records.Children.Clear();
            if (log.Recent.Length == 0) records.Children.Add(Note("尚无日志记录。"));
            foreach (var record in log.Recent.Reverse())
            {
                var row = new StackPanel { Spacing = 3 }; row.Children.Add(Note($"{record.Time:yyyy-MM-dd HH:mm:ss} · {record.Level} · 抑制 {record.Suppressed} 条"));
                row.Children.Add(new TextBlock { Text = record.Message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                row.Children.Add(Action("复制消息", () => { var data = new global::Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(record.Message); global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); })); records.Children.Add(row);
            }
        }
        page.Loaded += async (_, _) => { try { await RefreshLogs(); } catch (Exception ex) { summary.Text = ex.Message; } };
        page.Children.Add(AsyncAction("刷新日志", RefreshLogs));
        page.Children.Add(AsyncAction("导出诊断包…", async () =>
        {
            var file = await SaveFile(page, $"OcPlayer-diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}", ".txt"); if (file is null) return;
            Directory.CreateDirectory(AppDiagnostics.DirectoryPath);
            var snapshot = PlaybackSession.Require(core.Client.Call("diag.snapshot"));
            PlaybackSession.Require(core.Client.Call("diag.exportFile", new { logDirectory = AppDiagnostics.DirectoryPath, outputPath = file.Path,
                headerLines = new[] { "OcPlayer Windows " + AppReleaseService.DisplayVersion, "Erika " + KernelVersion.Read(), "Core " + core.Version, snapshot.GetRawText() },
                bodyByteBudget = 8 * 1024 * 1024, traces = AppDiagnostics.NativeTracePaths.Where(File.Exists).Select(path => new { path, name = Path.GetFileName(path), maxBytes = 4 * 1024 * 1024 }).ToArray(), username = Environment.UserName }));
            _status.Text = "诊断包已导出：" + file.Path;
        }));
        page.Children.Add(AsyncAction("清空日志", async () => { if (!await Confirm(page, "清空日志？", "将删除应用保存的日志记录；此操作不会清除媒体或偏好。")) return;
            AppDiagnostics.Clear(); await RefreshLogs(); _status.Text = "日志已清空。"; }));
        page.Children.Add(Note("数据目录：" + core.DataDirectory));
    }
}
