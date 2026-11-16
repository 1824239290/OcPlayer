#if DEBUG
using System.Reflection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows;

public sealed partial class MainWindow
{
    private static async Task VerifyPlayerMenus(PlayerView player, Action<bool, string> check)
    {
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
        T Field<T>(string name) => (T)typeof(PlayerView).GetField(name, flags)!.GetValue(player)!;
        void Call(string name, params object[] args) => typeof(PlayerView).GetMethod(name, flags)!.Invoke(player, args);
        async Task<MenuFlyout> Open(string button)
        {
            Field<MenuFlyout?>("_activeMenu")?.Hide();
            Call("ShowHud");
            await Task.Delay(250);
            var control = (Button)player.FindName(button);
            ((IInvokeProvider)new ButtonAutomationPeer(control).GetPattern(PatternInterface.Invoke)).Invoke();
            await Task.Delay(250);
            var menu = Field<MenuFlyout>("_activeMenu");
            check(menu.IsOpen, $"{button} opens a native menu");
            return menu;
        }
        static MenuFlyoutSubItem Sub(MenuFlyout menu, string prefix) => menu.Items.OfType<MenuFlyoutSubItem>().Single(item => item.Text.StartsWith(prefix));
        static async Task Expand(MenuFlyoutSubItem item)
        {
            var peer = FrameworkElementAutomationPeer.CreatePeerForElement(item);
            ((IExpandCollapseProvider)peer.GetPattern(PatternInterface.ExpandCollapse)).Expand();
            await Task.Delay(200);
        }
        static async Task Invoke(MenuFlyoutItem item)
        {
            var peer = FrameworkElementAutomationPeer.CreatePeerForElement(item);
            if (peer.GetPattern(PatternInterface.Invoke) is IInvokeProvider invoke) invoke.Invoke();
            else if (peer.GetPattern(PatternInterface.Toggle) is IToggleProvider toggle) toggle.Toggle();
            else throw new InvalidOperationException($"No native activation pattern: {item.Text}");
            await Task.Delay(200);
        }
        var hitTest = player.IsHitTestVisible;
        try
        {
            player.IsHitTestVisible = false;
            await Task.Delay(250);
            Call("SetPlaying", false);
            var menu = await Open("DanmakuButton");
            check(menu.Items.OfType<ToggleMenuFlyoutItem>().Any(item => item.Text == "启用弹幕")
                && menu.Items.OfType<MenuFlyoutItem>().Any(item => item.Text == "选择弹幕…")
                && menu.Items.OfType<MenuFlyoutItem>().Any(item => item.Text == "重新匹配"), "Danmaku retains enable, selection and rematching actions in preview");
            var opacity = Sub(menu, "不透明度");
            var area = Sub(menu, "显示区域");
            var font = Sub(menu, "字号大小");
            var filters = Sub(menu, "过滤与显示规则");
            check(opacity.Items.Count == 4 && area.Items.Count == 4 && font.Items.OfType<MenuFlyoutItem>().Select(x => x.Text).SequenceEqual(new[] { "减小 10%", "加大 10%" }) && filters.Items.Count == 5,
                "Danmaku includes all opacity, area, font-size and filtering options from macOS");
            await Expand(font);
            await Invoke(font.Items.OfType<MenuFlyoutItem>().Single(x => x.Text == "加大 10%"));
            check(Math.Abs(Field<DanmakuPreferences>("_demoDanmakuPreferences").FontSize - 24.2) < .001, "Danmaku larger increases by 2.2 points, ten percent of base 22");
            menu = await Open("DanmakuButton"); font = Sub(menu, "字号大小");
            check(font.Items.OfType<MenuFlyoutItem>().Any(x => x.Text == "重置"), "Danmaku reset appears away from the standard font size");
            await Expand(font); await Invoke(font.Items.OfType<MenuFlyoutItem>().Single(x => x.Text == "重置"));
            check(Field<DanmakuPreferences>("_demoDanmakuPreferences").FontSize == 22, "Danmaku reset restores exactly 22 points");
            menu = await Open("DanmakuButton"); opacity = Sub(menu, "不透明度");
            await Expand(opacity);
            await Invoke(opacity.Items.OfType<MenuFlyoutItem>().Single(item => item.Text == "50%"));
            check(Field<DanmakuPreferences>("_demoDanmakuPreferences").Opacity == .5, "Selecting danmaku opacity applies the chosen value");
            menu = await Open("DanmakuButton");
            opacity = Sub(menu, "不透明度");
            check(opacity.Text.Contains("50%") && opacity.Items.OfType<RadioMenuFlyoutItem>().Single(item => item.IsChecked).Text == "50%",
                "Reopening danmaku restores its current value and selected option");

            menu = await Open("SubtitlesButton");
            check(menu.Items.Count == 3 && menu.Items[0] is MenuFlyoutSubItem && menu.Items[1] is MenuFlyoutItem && menu.Items[2] is MenuFlyoutSubItem,
                "Subtitles exposes track selection, external import and font size as three root entries");
            var scale = Sub(menu, "字体大小");
            await Expand(scale);
            await Invoke(scale.Items.OfType<MenuFlyoutItem>().Single(item => item.Text == "加大"));
            check(Math.Abs(Field<double>("_subtitleScale") - 1.1) < .001, "Subtitle enlargement changes the rendering scale by ten percent");
            menu = await Open("SubtitlesButton");
            scale = Sub(menu, "字体大小");
            check(scale.Text.Contains("110%") && scale.Items.OfType<MenuFlyoutItem>().Any(item => item.Text == "重置"), "Subtitle scale is displayed and reset becomes available");
            var tracks = Sub(menu, "字幕轨道");
            await Expand(tracks);
            await Invoke(tracks.Items.OfType<MenuFlyoutItem>().Single(item => item.Text == "简体中文"));
            check(Field<int>("_demoSubtitleTrack") == 0 && ((TextBlock)player.FindName("SubtitlePreview")).Visibility == Visibility.Visible,
                "Choosing a subtitle track updates the selection and displayed subtitle");

            menu = await Open("ChaptersButton");
            var chapters = Field<PlaybackChapter[]>("_chapters");
            check(chapters.Length == 5 && menu.Items.Count == chapters.Length, "Chapter menu lists all preview chapters");
            await Invoke((MenuFlyoutItem)menu.Items[2]);
            check(Math.Abs(((Slider)player.FindName("Timeline")).Value - chapters[2].StartSeconds) < .1, "Chapter selection seeks to its real start time");
            menu = await Open("ChaptersButton");
            check(((MenuFlyoutItem)menu.Items[2]).Icon is not null, "Reopening chapters marks the current chapter");

            menu = await Open("RateButton");
            check(menu.Items.OfType<MenuFlyoutItem>().Any(item => item.Text is "进入全屏" or "退出全屏"), "More menu exposes the current fullscreen action");
            var speed = Sub(menu, "播放速度");
            check(speed.Items.Count == 6 && menu.Items.OfType<ToggleMenuFlyoutItem>().Any(item => item.Text == "播放信息")
                && menu.Items.OfType<MenuFlyoutItem>().Any(item => item.Text == "画面截图"), "More includes speed, playback information and frame capture");
            await Expand(speed);
            await Invoke(speed.Items.OfType<MenuFlyoutItem>().Single(item => item.Text == "1.5×"));
            check(Field<double>("_rate") == 1.5, "The speed submenu applies playback rate");
            menu = await Open("RateButton");
            await Invoke(menu.Items.OfType<MenuFlyoutItem>().Single(item => item.Text == "播放信息"));
            Field<PlayerHudVisibilityController>("_hudVisibility").Hide();
            await Task.Delay(300);
            check(Field<Border>("_playbackInfoPanel").Visibility == Visibility.Visible && ((FrameworkElement)player.FindName("Hud")).Visibility == Visibility.Collapsed,
                "Playback information remains visible independently of the HUD");

            var media = DemoCatalog.All[4];
            player.SetMedia(media with { SourceUri = "https://example.test/public.mp4" }); Call("SetPlaying", false);
            menu = await Open("RateButton");
            check(menu.Items.OfType<MenuFlyoutItem>().Any(item => item.Text == "分享媒体"), "Public media offers the native sharing entry");
            player.SetMedia(media with { SourceUri = "https://example.test/private.mp4?token=fixture" }); Call("SetPlaying", false);
            menu = await Open("RateButton");
            check(!menu.Items.OfType<MenuFlyoutItem>().Any(item => item.Text == "分享媒体"), "Credential-bearing media URLs are not offered for sharing");
            menu.Hide();
            player.SetMedia(media); Call("SetPlaying", false);
            await VerifyPlayerShareLifecycle(player, check);
            VerifyPlayerColorMetadata(check);
        }
        finally
        {
            Field<MenuFlyout?>("_activeMenu")?.Hide();
            player.IsHitTestVisible = hitTest;
        }
    }

    private static async Task VerifyPlayerShareLifecycle(PlayerView player, Action<bool, string> check)
    {
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
        T Field<T>(string name) => (T)typeof(PlayerView).GetField(name, flags)!.GetValue(player)!;
        void Set(string name, object? value) => typeof(PlayerView).GetField(name, flags)!.SetValue(player, value);
        void Call(string name, params object?[] args) => typeof(PlayerView).GetMethod(name, flags)!.Invoke(player, args);
        var originalMedia = Field<DemoMedia>("_media");
        var baselineModalCount = Field<int>("_modalInteractions");
        // Seed an already-open share operation without invoking the OS share UI.
        // A virtual in-memory file avoids filesystem permissions; nothing is shared.
        var localFile = await global::Windows.Storage.StorageFile.CreateStreamedFileAsync(
            "share-lifecycle-fixture.txt", async request =>
            {
                try
                {
                    using var writer = new global::Windows.Storage.Streams.DataWriter(request);
                    writer.WriteString("Share lifecycle fixture");
                    await writer.StoreAsync();
                    writer.DetachStream();
                    request.Dispose();
                }
                catch { request.FailAndClose(global::Windows.Storage.StreamedFileFailureMode.Incomplete); }
            }, null);
        var uri = new Uri("https://example.test/share-fixture.mp4");
        long BeginFixture(global::Windows.ApplicationModel.DataTransfer.DataPackage package)
        {
            var epoch = Field<long>("_shareEpoch") + 1;
            Set("_shareEpoch", epoch);
            Call("BeginModalInteraction");
            Set("_shareInteraction", true);
            Set("_shareUiShown", true);
            Set("_shareWindowDeactivated", true);
            Set("_sharePackage", package);
            Set("_shareFile", localFile);
            Set("_pendingShareUri", uri);
            Set("_pendingShareTitle", "Share lifecycle fixture");
            return epoch;
        }
        bool PayloadCleared() => Field<object?>("_sharePackage") is null
            && Field<object?>("_shareFile") is null && Field<Uri?>("_pendingShareUri") is null
            && Field<string>("_pendingShareTitle") == "OcPlayer"
            && !Field<bool>("_shareInteraction") && !Field<bool>("_shareUiShown") && !Field<bool>("_shareWindowDeactivated");
        try
        {
            var oldPackage = new global::Windows.ApplicationModel.DataTransfer.DataPackage();
            var oldEpoch = BeginFixture(oldPackage);
            Call("QueueEndShareInteraction", oldEpoch);
            // Reset and start another operation before the queued completion is dispatched.
            Call("ResetMoreMedia");
            check(PayloadCleared() && Field<long>("_shareEpoch") > oldEpoch
                && Field<int>("_modalInteractions") == baselineModalCount,
                "Resetting the media invalidates its share operation, clears its payload and releases its modal hold");
            var currentPackage = new global::Windows.ApplicationModel.DataTransfer.DataPackage();
            var currentEpoch = BeginFixture(currentPackage);
            await Task.Delay(100);
            check(Field<bool>("_shareInteraction") && Field<long>("_shareEpoch") == currentEpoch
                && ReferenceEquals(Field<object?>("_sharePackage"), currentPackage)
                && Field<int>("_modalInteractions") == baselineModalCount + 1,
                "A queued completion from the previous share cannot end a newer share or release its modal hold");

            Call("SharePackageFinished", oldPackage, new object());
            await Task.Delay(100);
            check(Field<bool>("_shareInteraction") && ReferenceEquals(Field<object?>("_sharePackage"), currentPackage)
                && Field<int>("_modalInteractions") == baselineModalCount + 1,
                "A late callback from an old data package cannot finish the current share");
            Call("SharePackageFinished", currentPackage, new object());
            await Task.Delay(100);
            check(PayloadCleared() && Field<int>("_modalInteractions") == baselineModalCount,
                "The current share completion clears its payload and releases exactly its own modal hold");

            var switchEpoch = BeginFixture(new global::Windows.ApplicationModel.DataTransfer.DataPackage());
            Call("QueueEndShareInteraction", switchEpoch);
            player.SetMedia(originalMedia);
            Call("SetPlaying", false);
            await Task.Delay(100);
            check(PayloadCleared() && Field<long>("_shareEpoch") > switchEpoch
                && Field<int>("_modalInteractions") == baselineModalCount,
                "Changing the playback source clears sharing state and ignores its pending completion");
        }
        finally { Call("EndShareInteraction", new object?[] { null }); }
    }

    private static void VerifyPlayerColorMetadata(Action<bool, string> check)
    {
        string Label(string method, int value) => (string)typeof(PlayerView)
            .GetMethod(method, BindingFlags.Static | BindingFlags.NonPublic)!.Invoke(null, new object[] { value })!;
        check(Label("VideoTransferLabel", 3) == "PQ" && Label("VideoTransferLabel", 4) == "HLG",
            "Windows ABI transfer values identify PQ and HLG without using macOS AVCol codes");
        check(Label("VideoPrimariesLabel", 3) == "BT.2020" && Label("VideoPrimariesLabel", 2) == "Display P3",
            "Windows ABI primaries identify BT.2020 and Display P3");
        check(Label("VideoTransferLabel", 1) == "sRGB" && Label("VideoTransferLabel", 2) == "BT.1886",
            "Windows ABI SDR transfer values retain their distinct sRGB and BT.1886 labels");
    }
}
#endif
