using System.Globalization;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Services;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;

namespace OcPlayer.Windows;

public sealed partial class PlayerView
{
    private Border? _playbackInfoPanel;
    private TextBlock? _infoTitle, _infoKicker;
    private readonly Dictionary<string, TextBlock> _infoValues = [];
    private InfoBar? _moreNotice;
    private bool _showPlaybackInfo, _capturingScreenshot, _shareInteraction;
    private bool _shareUiShown, _shareWindowDeactivated;
    private double _lastInfoUpdate = double.NegativeInfinity;
    private long _moreNoticeToken, _shareEpoch;
    private Uri? _shareUri;
    private DataTransferManager? _shareManager;
    private global::Windows.Foundation.TypedEventHandler<DataTransferManager, DataRequestedEventArgs>? _shareDataRequested;
    private global::Windows.Foundation.TypedEventHandler<DataTransferManager, TargetApplicationChosenEventArgs>? _shareTargetChosen;
    private DataPackage? _sharePackage;
    private StorageFile? _shareFile;
    private Uri? _pendingShareUri;
    private string _pendingShareTitle = "OcPlayer";

    private void InitializeMoreMenu()
    {
        var content = new StackPanel { Spacing = 10 };
        _infoTitle = new TextBlock { FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, MaxLines = 2 };
        _infoKicker = new TextBlock { FontSize = 11, Foreground = InfoBrush(194), TextWrapping = TextWrapping.Wrap, MaxLines = 2 };
        var heading = new StackPanel { Spacing = 4 };
        heading.Children.Add(_infoTitle);
        heading.Children.Add(_infoKicker);
        content.Children.Add(heading);
        AddInfoSection(content, "播放", ("state", "状态"), ("progress", "进度"), ("rate", "倍速"), ("volume", "音量"), ("chapters", "章节"));
        AddInfoSection(content, "视频", ("resolution", "分辨率"), ("range", "源动态范围"), ("color", "色彩"), ("surface", "输出表面"), ("output", "输出"));
        AddInfoSection(content, "音频", ("audio", "音轨"));
        AddInfoSection(content, "字幕", ("subtitle", "字幕"));
        var statistics = new StackPanel { Spacing = 6 };
        statistics.Children.Add(InfoHeading("内核统计"));
        var statisticsGrid = new Grid { ColumnSpacing = 16, RowSpacing = 6 };
        statisticsGrid.ColumnDefinitions.Add(new ColumnDefinition());
        statisticsGrid.ColumnDefinitions.Add(new ColumnDefinition());
        var counters = new (string Key, string Label)[]
        {
            ("decodedVideoFrames", "解码"), ("renderedVideoFrames", "渲染"),
            ("hardwareVideoFrames", "硬解"), ("softwareVideoFrames", "软解"),
            ("zeroCopyVideoFrames", "零拷贝"), ("pushedAudioFrames", "音频帧"),
            ("renderFailures", "渲染失败"), ("audioFailures", "音频失败")
        };
        for (var index = 0; index < counters.Length; index++)
        {
            if (index % 2 == 0) statisticsGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var cell = new StackPanel { Spacing = 1 };
            cell.Children.Add(new TextBlock { Text = counters[index].Label, FontSize = 11, Foreground = InfoBrush(153) });
            var value = new TextBlock { Text = "0", FontSize = 11 };
            Typography.SetNumeralAlignment(value, FontNumeralAlignment.Tabular);
            _infoValues[counters[index].Key] = value;
            cell.Children.Add(value);
            Grid.SetRow(cell, index / 2); Grid.SetColumn(cell, index % 2);
            statisticsGrid.Children.Add(cell);
        }
        statistics.Children.Add(statisticsGrid);
        content.Children.Add(statistics);
        _playbackInfoPanel = new Border
        {
            Child = content, Padding = new Thickness(14), CornerRadius = new CornerRadius(14),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(184, 0, 0, 0)),
            BorderBrush = InfoBrush(41), BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Width = 340, IsHitTestVisible = false, Visibility = Visibility.Collapsed
        };
        AutomationProperties.SetName(_playbackInfoPanel, "播放信息");
        // The information panel remains visible when the regular HUD fades out.
        PlayerRoot.Children.Add(_playbackInfoPanel);
        _moreNotice = new InfoBar
        {
            IsOpen = false, IsClosable = true, HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(24, 104, 24, 0), MaxWidth = 850
        };
        PlayerRoot.Children.Add(_moreNotice);
        _window.Activated += ShareWindowActivated;
    }

    private static SolidColorBrush InfoBrush(byte alpha) => new(global::Windows.UI.Color.FromArgb(alpha, 255, 255, 255));
    private static TextBlock InfoHeading(string title) => new() { Text = title, FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = InfoBrush(153) };

    private void AddInfoSection(StackPanel content, string title, params (string Key, string Label)[] rows)
    {
        var section = new StackPanel { Spacing = 4 };
        section.Children.Add(InfoHeading(title));
        foreach (var (key, label) in rows)
        {
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.Children.Add(new TextBlock { Text = label, FontSize = 11, Foreground = InfoBrush(153) });
            var value = new TextBlock
            {
                Text = "—", FontSize = 11, Foreground = InfoBrush(194), HorizontalAlignment = HorizontalAlignment.Right,
                TextAlignment = TextAlignment.Right, TextWrapping = TextWrapping.Wrap, MaxLines = 3
            };
            Typography.SetNumeralAlignment(value, FontNumeralAlignment.Tabular);
            Grid.SetColumn(value, 1); row.Children.Add(value);
            _infoValues[key] = value;
            section.Children.Add(row);
        }
        content.Children.Add(section);
    }

    private void ResetMoreMedia()
    {
        EndShareInteraction();
        _shareUri = ComputeShareUri();
        _lastInfoUpdate = double.NegativeInfinity;
        _moreNoticeToken++;
        if (_moreNotice is not null) _moreNotice.IsOpen = false;
        RefreshMoreInfo();
    }

    private void ShowMoreMenu(object sender)
    {
        var menu = new MenuFlyout();
        var speed = new MenuFlyoutSubItem { Text = $"播放速度 · {_rate:0.##}×", Icon = new FontIcon { Glyph = "\uEC4A" } };
        foreach (var rate in new[] { .5, .75, 1, 1.25, 1.5, 2 })
        {
            var item = new RadioMenuFlyoutItem { Text = $"{rate:0.##}×", GroupName = "PlaybackRate", IsChecked = Math.Abs(_rate - rate) < .01 };
            item.Click += (_, _) => SetRate(rate);
            speed.Items.Add(item);
        }
        menu.Items.Add(speed);
        var fullscreen = MenuAction(_window.AppWindow.Presenter.Kind == Microsoft.UI.Windowing.AppWindowPresenterKind.FullScreen ? "退出全屏" : "进入全屏", ToggleFullscreen);
        fullscreen.Icon = new SymbolIcon(Symbol.FullScreen);
        menu.Items.Add(fullscreen);
        var info = new ToggleMenuFlyoutItem { Text = "播放信息", Icon = new FontIcon { Glyph = "\uE946" }, IsChecked = _showPlaybackInfo };
        info.Click += (_, _) =>
        {
            _showPlaybackInfo = info.IsChecked;
            _lastInfoUpdate = double.NegativeInfinity;
            RefreshMoreInfo(); ShowHud();
        };
        menu.Items.Add(info);
        menu.Items.Add(new MenuFlyoutSeparator());
        var screenshot = MenuAction("画面截图", CaptureScreenshot);
        screenshot.Icon = new SymbolIcon(Symbol.Camera);
        screenshot.IsEnabled = !_capturingScreenshot && _session is { Ready: true, VideoWidth: > 0, VideoHeight: > 0 };
        menu.Items.Add(screenshot);
        if (_shareUri is not null)
        {
            var share = MenuAction("分享媒体", ShareMedia);
            share.Icon = new SymbolIcon(Symbol.Share);
            menu.Items.Add(share);
        }
        ShowMenu(sender, menu);
    }

    private void RefreshMoreInfo()
    {
        if (_closed || _playbackInfoPanel is null) return;
        _playbackInfoPanel.Visibility = _showPlaybackInfo ? Visibility.Visible : Visibility.Collapsed;
        var narrow = PlayerRoot.ActualWidth < 560;
        var inset = narrow ? 16 : 28;
        _playbackInfoPanel.Margin = new Thickness(inset, narrow ? 70 : 82, inset, 16);
        _playbackInfoPanel.Width = Math.Min(340, Math.Max(1, PlayerRoot.ActualWidth - inset * 2));
        if (!_showPlaybackInfo || _time.Elapsed.TotalSeconds - _lastInfoUpdate < 1) return;
        _lastInfoUpdate = _time.Elapsed.TotalSeconds;
        _infoTitle!.Text = MediaTitle.Text;
        _infoKicker!.Text = EpisodeTitle.Text;
        _infoKicker.Visibility = string.IsNullOrWhiteSpace(EpisodeTitle.Text) ? Visibility.Collapsed : Visibility.Visible;
        var state = _demoMode ? (_playing ? 3 : 4) : _session?.PlaybackState ?? 0;
        var stateLabel = state switch { 0 => "空闲", 1 => "打开中", 2 => "就绪", 3 => "播放中", 4 => "已暂停", 5 => "已停止", 6 => "已关闭", 7 => "错误", _ => "—" };
        if (state == 3 && _session?.Buffering == true) stateLabel += " · 缓冲中";
        SetInfo("state", stateLabel);
        var position = _demoMode ? Timeline.Value : _session?.PositionSeconds ?? 0;
        var duration = _demoMode ? Timeline.Maximum : _session?.DurationSeconds ?? 0;
        SetInfo("progress", $"{TimeLabel(position)} / {TimeLabel(duration)}" + (duration > 0 ? $" · {Math.Clamp(position / duration * 100, 0, 100):0}%" : ""));
        SetInfo("rate", $"{_rate:0.##}×");
        SetInfo("volume", _muted || Volume.Value == 0 ? "已静音" : $"{Volume.Value:0}%");
        SetInfo("chapters", PlaybackChapterCount == 0 ? "无" : $"{PlaybackChapterCount} 章");
        var width = _session?.VideoWidth ?? 0;
        var height = _session?.VideoHeight ?? 0;
        var transfer = _session?.VideoTransfer ?? 0;
        var primaries = _session?.VideoPrimaries ?? 0;
        SetInfo("resolution", width > 0 && height > 0 ? $"{width}×{height} · {VideoAspect(width, height)}" : "—");
        SetInfo("range", width > 0 ? transfer switch { 1 or 2 => "SDR", 3 => "HDR (PQ)", 4 => "HDR (HLG)", _ => "未知" } : "—");
        SetInfo("color", width > 0 ? $"{VideoPrimariesLabel(primaries)} · {VideoTransferLabel(transfer)}" : "—");
        SetInfo("surface", _demoMode ? "演示画面" : _session?.HasSurface == true ? "已连接" : "未连接");
        if (_session is { } outputSession)
        {
            try
            {
                var output = outputSession.GetOutputStatus();
                var encoding = output.GetProperty("activeEncoding").GetInt32();
                var format = output.GetProperty("surfaceFormat").GetInt32();
                var fallback = output.GetProperty("fallbackReason").GetInt32();
                var label = encoding switch { 0 => "SDR", 1 => "Apple EDR", 2 => "扩展线性", 3 => "HDR10 PQ", _ => "未知输出" };
                label += " · " + (format switch { 0 => "8bit", 1 => "10bit", 2 => "16bit 浮点", _ => "未知格式" });
                if (fallback > 0) label += "\n" + (fallback switch { 1 => "显示器不支持 HDR", 2 => "需要混合合成", 3 => "输出后端不支持", 4 => "16bit 浮点表面不可用", 5 => "系统色彩空间接口不可用", 6 => "scRGB 验证失败", 7 => "表面配置失败", 8 => "EDR 不受支持", _ => $"HDR 回退 {fallback}" });
                SetInfo("output", label);
                if (outputSession.DolbyVisionProfile > 0)
                    SetInfo("range", encoding == 0 ? "杜比视界（映射 SDR）" : encoding == 3 ? "杜比视界（HDR）" : "杜比视界");
            }
            catch { SetInfo("output", "暂不可用"); }
        }
        var audio = CurrentTracks(false).FirstOrDefault(TrackSelected);
        var audioLabel = audio.ValueKind == JsonValueKind.Object ? TrackLabel(audio) : "无独立音轨";
        if (audio.ValueKind == JsonValueKind.Object && audio.TryGetProperty("sampleRate", out var sampleRate) && sampleRate.TryGetDouble(out var hz) && hz > 0)
            audioLabel += $" · {hz / 1000:0.###} kHz";
        SetInfo("audio", _demoMode ? (_demoAudioTrack == 1 ? "English · 5.1" : "中文 · 立体声") : audioLabel);
        SetInfo("subtitle", CurrentSubtitleLabel());
        foreach (var key in new[] { "decodedVideoFrames", "renderedVideoFrames", "hardwareVideoFrames", "softwareVideoFrames", "zeroCopyVideoFrames", "pushedAudioFrames", "renderFailures", "audioFailures" })
        {
            var count = _session?.Stats is { ValueKind: JsonValueKind.Object } stats && stats.TryGetProperty(key, out var value) && value.TryGetUInt64(out var number) ? number : 0;
            SetInfo(key, count.ToString("N0", CultureInfo.CurrentCulture));
        }
    }

    private void SetInfo(string key, string value) => _infoValues[key].Text = value;
    private static string VideoAspect(uint width, uint height)
    {
        var first = width; var second = height;
        while (second != 0) (first, second) = (second, first % second);
        return width / first <= 50 && height / first <= 50 ? $"{width / first}:{height / first}" : $"{(double)width / height:0.00}:1";
    }
    // Windows' Erika C ABI exposes its own color enums, not the AVCol codes used by macOS.
    private static string VideoPrimariesLabel(int value) => value switch { 0 => "未知原色", 1 => "BT.709", 2 => "Display P3", 3 => "BT.2020", _ => $"原色 {value}" };
    private static string VideoTransferLabel(int value) => value switch { 0 => "未知传输函数", 1 => "sRGB", 2 => "BT.1886", 3 => "PQ", 4 => "HLG", _ => $"TRC {value}" };

    private async void CaptureScreenshot()
    {
        if (_closed || _capturingScreenshot) return;
        var generation = _mediaGeneration;
        _capturingScreenshot = true;
        try
        {
            if (_session is not { Ready: true, VideoWidth: > 0, VideoHeight: > 0 } session)
                throw new InvalidOperationException("还没有可截的画面。");
            var width = session.VideoWidth; var height = session.VideoHeight;
            // The presenter renders video and subtitles into RGBA8, excluding HUD and danmaku.
            var pixels = session.CaptureFrameRgba(width, height);
            var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "OcPlayer");
            Directory.CreateDirectory(directory);
            var title = string.Concat(MediaTitle.Text.Take(40).Select(character => Path.GetInvalidFileNameChars().Contains(character) || char.IsControl(character) ? '_' : character));
            var fileName = $"截图-{title}-{DateTime.Now:yyyyMMdd-HHmmss-fff}.png";
            using (var file = new FileStream(Path.Combine(directory, fileName), FileMode.CreateNew, FileAccess.Write))
            using (var stream = file.AsRandomAccessStream())
            {
                var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
                encoder.SetPixelData(BitmapPixelFormat.Rgba8, BitmapAlphaMode.Straight, width, height, 96, 96, pixels);
                await encoder.FlushAsync();
            }
            if (!_closed && generation == _mediaGeneration) ShowMoreNotice($"已保存：{fileName}", InfoBarSeverity.Success, 2);
        }
        catch (Exception ex) { if (!_closed && generation == _mediaGeneration) ShowMoreNotice($"截图失败：{ex.Message}", InfoBarSeverity.Error); }
        finally { _capturingScreenshot = false; }
    }

    private async void ShowMoreNotice(string message, InfoBarSeverity severity, int seconds = 0)
    {
        if (_closed || _moreNotice is null) return;
        var token = ++_moreNoticeToken;
        _moreNotice.Message = message; _moreNotice.Severity = severity; _moreNotice.IsOpen = true;
        ShowHud();
        if (seconds <= 0) return;
        await Task.Delay(TimeSpan.FromSeconds(seconds));
        if (!_closed && token == _moreNoticeToken) _moreNotice.IsOpen = false;
    }

    private Uri? ComputeShareUri()
    {
        var value = _source?.Uri ?? _media.SourceUri;
        if (string.IsNullOrWhiteSpace(value)) return null;
        if (File.Exists(value)) return new Uri(Path.GetFullPath(value));
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)) return null;
        if (uri.IsFile) return File.Exists(uri.LocalPath) ? uri : null;
        // Match macOS: a URL requiring authentication is not a shareable media URL.
        if (uri.Scheme is not ("http" or "https") || _source?.HttpHeaders?.Count > 0 || _source?.Report is not null || !string.IsNullOrEmpty(uri.UserInfo)) return null;
        var credentialKeys = new[] { "api_key", "apikey", "token", "access_token", "auth", "authorization", "signature", "sig", "x-amz-signature" };
        foreach (var parameter in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var key = Uri.UnescapeDataString(parameter.Split('=', 2)[0]);
            if (credentialKeys.Contains(key, StringComparer.OrdinalIgnoreCase)) return null;
        }
        return uri;
    }

    private async void ShareMedia()
    {
        if (_closed || _shareUri is not { } uri || _shareInteraction) return;
        var generation = _mediaGeneration;
        var epoch = ++_shareEpoch;
        BeginModalInteraction(); _shareInteraction = true;
        try
        {
            var file = uri.IsFile ? await ShareableMediaFile.PrepareAsync(uri.LocalPath) : null;
            if (_closed || generation != _mediaGeneration || epoch != _shareEpoch || !_shareInteraction) return;
            _shareFile = file;
            _pendingShareUri = uri;
            _pendingShareTitle = string.IsNullOrWhiteSpace(MediaTitle.Text) ? "OcPlayer" : MediaTitle.Text;
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(_window);
            _shareManager ??= DataTransferManagerInterop.GetForWindow(hwnd);
            _shareDataRequested = (sender, args) => ShareDataRequested(epoch, sender, args);
            _shareTargetChosen = (_, _) => QueueEndShareInteraction(epoch);
            _shareManager.DataRequested += _shareDataRequested;
            _shareManager.TargetApplicationChosen += _shareTargetChosen;
            _shareUiShown = true;
            DataTransferManagerInterop.ShowShareUIForWindow(hwnd);
        }
        catch (Exception ex)
        {
            if (epoch != _shareEpoch) return;
            EndShareInteraction(epoch);
            if (!_closed && generation == _mediaGeneration) ShowMoreNotice($"无法打开分享面板：{ex.Message}", InfoBarSeverity.Error);
        }
    }

    private void ShareDataRequested(long epoch, DataTransferManager sender, DataRequestedEventArgs args)
    {
        if (_closed || epoch != _shareEpoch || !_shareInteraction || _pendingShareUri is null)
        { args.Request.FailWithDisplayText("当前媒体无法分享。"); return; }
        ClearSharePackage();
        _sharePackage = args.Request.Data;
        _sharePackage.Properties.Title = _pendingShareTitle;
        _sharePackage.RequestedOperation = DataPackageOperation.Copy;
        if (_shareFile is not null) _sharePackage.SetStorageItems(new[] { _shareFile });
        else _sharePackage.SetWebLink(_pendingShareUri);
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) _sharePackage.ShareCanceled += SharePackageFinished;
        _sharePackage.Destroyed += SharePackageFinished;
        _sharePackage.ShareCompleted += ShareCompleted;
    }

    private void QueueEndShareInteraction(long epoch) => DispatcherQueue.TryEnqueue(() => EndShareInteraction(epoch));
    private void SharePackageFinished(DataPackage sender, object args)
    {
        if (ReferenceEquals(sender, _sharePackage)) QueueEndShareInteraction(_shareEpoch);
    }
    private void ShareCompleted(DataPackage sender, ShareCompletedEventArgs args)
    {
        if (ReferenceEquals(sender, _sharePackage)) QueueEndShareInteraction(_shareEpoch);
    }
    private void ShareWindowActivated(object sender, WindowActivatedEventArgs args)
    {
        if (!_shareInteraction || !_shareUiShown) return;
        if (args.WindowActivationState == WindowActivationState.Deactivated) _shareWindowDeactivated = true;
        else if (_shareWindowDeactivated) EndShareInteraction(_shareEpoch);
    }
    private void EndShareInteraction(long? expectedEpoch = null)
    {
        if (expectedEpoch.HasValue && expectedEpoch.Value != _shareEpoch) return;
        _shareEpoch++;
        var wasActive = _shareInteraction;
        _shareInteraction = _shareUiShown = _shareWindowDeactivated = false;
        if (_shareManager is not null)
        {
            if (_shareDataRequested is not null) _shareManager.DataRequested -= _shareDataRequested;
            if (_shareTargetChosen is not null) _shareManager.TargetApplicationChosen -= _shareTargetChosen;
        }
        _shareDataRequested = null; _shareTargetChosen = null;
        ClearSharePackage();
        _shareFile = null; _pendingShareUri = null; _pendingShareTitle = "OcPlayer";
        if (wasActive) EndModalInteraction();
    }
    private void ClearSharePackage()
    {
        if (_sharePackage is null) return;
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) _sharePackage.ShareCanceled -= SharePackageFinished;
        _sharePackage.Destroyed -= SharePackageFinished;
        _sharePackage.ShareCompleted -= ShareCompleted;
        _sharePackage = null;
    }
    private void DisposeMoreMenu()
    {
        _moreNoticeToken++;
        _window.Activated -= ShareWindowActivated;
        EndShareInteraction();
        _shareManager = null;
    }
}
