#if DEBUG
using Microsoft.UI.Xaml;
using OcPlayer.CoreAdapter;
using OcPlayer.Tests;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.Preview;

/// Interactive native-player fixture. No production account, gateway or media-server requests are used.
internal sealed class DanmakuVerificationWindow : Window
{
    private readonly DanmakuFixture _gateway = new() { RepeatedComments = true };
    private readonly PlayerView _player;
    public DanmakuVerificationWindow(string mediaPath, string resource)
    {
        Title = "弹幕接入验证";
        AppWindow.ResizeClient(new global::Windows.Graphics.SizeInt32(1120, 760));
        App.Core!.Danmaku.Settings.Save(new DanmakuPreferences(GatewayUrl: _gateway.Url, ApiKey: "fixture-danmaku-key"));
        var media = new DemoMedia("danmaku-ui", "葬送的芙莉莲", "", "", "", "", "", SourceUri: mediaPath);
        var source = new PlaybackSource(media.Id, media.Title, mediaPath, Metadata:
            new("葬送的芙莉莲.S01E01.mkv", new FileInfo(mediaPath).Length, null, media.Title, null, 1, 1));
        _player = new PlayerView(this, media, source) { RequestedTheme = ElementTheme.Dark };
        Content = _player;
        _player.CloseRequested += (_, _) => Close();
        Closed += (_, _) =>
        {
            _player.Dispose(); _gateway.Dispose();
            var vault = new global::Windows.Security.Credentials.PasswordVault();
            try { vault.Remove(vault.Retrieve(resource, "danmaku-settings")); }
            catch (System.Runtime.InteropServices.COMException) { }
        };
    }
}
#endif
