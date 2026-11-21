#if DEBUG
using System.Reflection;
using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Preview;

namespace OcPlayer.Windows;

public sealed partial class MainWindow
{
    private void AttachPlayerVerification()
    {
        AttachPlayerSizingVerification();
        var output = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--demo-verify-player="))?.Split('=', 2)[1];
        if (output is null) return;
        WindowRoot.Loaded += async (_, _) =>
        {
            var assertions = new List<string>();
            void Check(bool condition, string message)
            {
                if (!condition) throw new InvalidOperationException(message);
                assertions.Add(message);
            }
            async Task VerifyHud(PlayerView player, DemoMedia originalMedia)
            {
                var wasHitTestVisible = player.IsHitTestVisible;
                var readerSource = typeof(PlayerView).GetField("_readScreenReader", BindingFlags.Instance | BindingFlags.NonPublic)!;
                var actualReaderSource = (Func<bool>)readerSource.GetValue(player)!;
                try
                {
                    // Isolate regular idle behavior from the user's accessibility state.
                    // VerifyHudCore separately enables the reader through this same polled source.
                    readerSource.SetValue(player, (Func<bool>)(() => false));
                    // This offline fixture drives controls through automation.
                    // Stop unrelated physical pointer movement from renewing the
                    // production idle deadline; keep Tick, focus and flyout events live.
                    player.IsHitTestVisible = false;
                    player.UpdateLayout();
                    // Flush the one-off pointer exits caused by input isolation
                    // before any test starts its real three-second idle interval.
                    await Task.Delay(250);
                    await VerifyHudCore(player, originalMedia);
                }
                catch (Exception error)
                {
                    const BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
                    object? Field(string name) => typeof(PlayerView).GetField(name, instance)?.GetValue(player);
                    var hud = player.FindName("Hud") as FrameworkElement;
                    var visibility = Field("_hudVisibility") as Services.PlayerHudVisibilityController;
                    var focused = player.XamlRoot is { } root
                        ? Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(root) : null;
                    var interaction = Field("_lastInteraction") is DateTime last
                        ? $"{last:O}, idle={(DateTime.UtcNow - last).TotalMilliseconds:0}ms" : "unavailable";
                    var diagnostics = $"HUD target={visibility?.IsVisible}, visibility={hud?.Visibility}, opacity={hud?.Opacity:0.###}, hitTest={hud?.IsHitTestVisible}; "
                        + $"player hitTest={player.IsHitTestVisible}, loaded={player.IsLoaded}, disposed={player.IsDisposed}; "
                        + $"lastInteraction={interaction}; playing={Field("_playing")}, hover={Field("_controlsHovered")}, pointerInside={Field("_pointerInside")}, "
                        + $"scrubbing={Field("_scrubbing")}, userHidden={Field("_userHidden")}, screenReader={Field("_screenReader")}, keyboardHudFocus={typeof(PlayerView).GetMethod("HasControlFocus", instance)?.Invoke(player, null)}, menuOpen={typeof(PlayerView).GetProperty("_menuOpen", instance)?.GetValue(player)}; "
                        + $"focus={focused?.GetType().Name}/{(focused as FrameworkElement)?.Name}/{(focused as Control)?.FocusState}";
                    throw new InvalidOperationException($"HUD verification failed. {diagnostics}", error);
                }
                finally { readerSource.SetValue(player, actualReaderSource); player.IsHitTestVisible = wasHitTestVisible; }
            }
            async Task VerifyHudCore(PlayerView player, DemoMedia originalMedia)
            {
                const BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
                T Element<T>(string name) where T : class => player.FindName(name) as T
                    ?? throw new InvalidOperationException($"Player element {name} was not found");
                void Call(string method, params object[] arguments) =>
                    (typeof(PlayerView).GetMethod(method, instance)
                        ?? throw new InvalidOperationException($"Player method {method} was not found"))
                    .Invoke(player, arguments);
                void InvokeButton(string name) =>
                    ((IInvokeProvider)new ButtonAutomationPeer(Element<Button>(name)).GetPattern(PatternInterface.Invoke)).Invoke();
                void IdleInput()
                {
                    // Establish an idle pointer/focus fixture without shortening
                    // the real timer or invoking Tick directly.
                    typeof(PlayerView).GetField("_controlsHovered", instance)?.SetValue(player, false);
                    player.Focus(FocusState.Programmatic);
                }

                var hud = Element<FrameworkElement>("Hud");
                var visibility = (Services.PlayerHudVisibilityController)(typeof(PlayerView)
                    .GetField("_hudVisibility", instance)?.GetValue(player)
                    ?? throw new InvalidOperationException("HUD visibility controller was not found"));
                var windowedPresenter = (OverlappedPresenter)AppWindow.Presenter;
                var originalBorder = windowedPresenter.HasBorder;
                var originalTitleBar = windowedPresenter.HasTitleBar;
                var movie = DemoCatalog.Movies[0] with { DurationSeconds = 7200, Progress = 25 };
                player.SetMedia(movie); Call("SetPlaying", false);
                Check(Element<TextBlock>("MediaTitle").Text == movie.Title
                    && Element<TextBlock>("EpisodeTitle").Visibility == Visibility.Collapsed,
                    "Movies show their title without an episode or category kicker");
                Check(Element<Slider>("Timeline").Value == 1800 && Element<Slider>("Timeline").Maximum == 7200
                    && Element<TextBlock>("PositionLabel").Text == "30:00" && Element<TextBlock>("DurationLabel").Text == "2:00:00",
                    "The initial timeline and time labels reflect media progress and duration");
                var series = movie with
                {
                    Title = "HUD verification series", Kind = "series", SeriesTitle = null,
                    EpisodeLabel = null, EpisodeNumber = 3, Progress = 0, DurationSeconds = 1440,
                    Episodes = [new DemoEpisode(3, "Episode three", movie.Artwork, SeasonNumber: 2)]
                };
                player.SetMedia(series); Call("SetPlaying", false);
                Check(Element<TextBlock>("MediaTitle").Text == series.Title
                    && Element<TextBlock>("EpisodeTitle").Visibility == Visibility.Visible
                    && Element<TextBlock>("EpisodeTitle").Text == "S2E3 · Episode three",
                    "Series playback shows the selected season, episode and episode title");
                Check(Element<Slider>("Timeline").Value == 0 && Element<TextBlock>("PositionLabel").Text == "0:00"
                    && Element<TextBlock>("DurationLabel").Text == "24:00",
                    "Starting unwatched media resets the timeline and elapsed label to zero");
                player.SetMedia(series with { Kind = "episode", Title = "Episode three", SeriesTitle = series.Title, EpisodeLabel = "S2E3", Episodes = null });
                Call("SetPlaying", false);
                Check(Element<TextBlock>("MediaTitle").Text == series.Title
                    && Element<TextBlock>("EpisodeTitle").Text == "S2E3 · Episode three",
                    "Individual episode metadata retains the series title and episode kicker");

                player.UpdateLayout();
                var rasterizationScale = player.XamlRoot.RasterizationScale;
                var nativeHeight = AppWindow.TitleBar.Height;
                var nativeWidth = AppWindow.TitleBar.RightInset / 3d;
                if (nativeHeight <= 0 || nativeWidth <= 0)
                    throw new InvalidOperationException("Native caption metrics are unavailable for hover verification");
                foreach (var name in new[] { "ReturnButton", "FullscreenButton", "VolumeButton" })
                {
                    var button = Element<Button>(name);
                    button.ApplyTemplate(); button.UpdateLayout();
                    try
                    {
                        Check(VisualStateManager.GoToState(button, "PointerOver", false),
                            $"{name} exposes its native PointerOver visual state");
                        // Allow the native visual state to settle, then inspect
                        // actual template dimensions without prescribing its colors.
                        await Task.Delay(120);
                        var surface = (VisualTreeHelper.GetChildrenCount(button) > 0
                            ? VisualTreeHelper.GetChild(button, 0) as FrameworkElement : null)
                            ?? throw new InvalidOperationException($"No rendered caption template was found for {name}");
                        Check(Math.Abs(button.ActualHeight * rasterizationScale - nativeHeight) <= 1
                            && Math.Abs(button.ActualWidth * rasterizationScale - nativeWidth) <= 1
                            && Math.Abs(surface.ActualHeight * rasterizationScale - nativeHeight) <= 1
                            && Math.Abs(surface.ActualWidth * rasterizationScale - nativeWidth) <= 1,
                            $"{name} and its native template match caption dimensions "
                            + $"({nativeWidth:0.##} × {nativeHeight:0.##} pixels; button {button.ActualWidth * rasterizationScale:0.##} × {button.ActualHeight * rasterizationScale:0.##})");
                    }
                    finally { VisualStateManager.GoToState(button, "Normal", false); }
                }

                await Task.Delay(300);
                visibility.Hide();
                Check(!hud.IsHitTestVisible, "Hiding immediately stops HUD controls intercepting input");
                if (new global::Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
                {
                    Check(hud.Visibility == Visibility.Visible, "The HUD stays mounted while its fade-out runs");
                    await Task.Delay(75);
                    var fadingOpacity = hud.Opacity;
                    Check(fadingOpacity > 0 && fadingOpacity < 1, "The HUD fades through an intermediate opacity");
                    Call("ShowHud");
                    Check(hud.IsHitTestVisible && Math.Abs(hud.Opacity - fadingOpacity) < .05,
                        "Reversing a fade restores input without an opacity jump");
                    await Task.Delay(300);
                    Check(hud.Visibility == Visibility.Visible && hud.Opacity > .99 && hud.IsHitTestVisible,
                        "A reversed fade remains visible after the old hide completion would have run");
                    visibility.Hide();
                    await Task.Delay(300);
                }
                else
                {
                    Check(hud.Visibility == Visibility.Collapsed && hud.Opacity == 0,
                        "Disabling system animations makes HUD hiding immediate");
                }
                Check(hud.Visibility == Visibility.Collapsed && !hud.IsHitTestVisible && hud.Opacity < .01,
                    "A completed hide collapses the HUD and leaves video input unobstructed");
                Check(!windowedPresenter.HasTitleBar && windowedPresenter.HasBorder == originalBorder,
                    "Hiding the HUD removes WinUI's native caption surface and preserves the window border");
                Call("ShowHud");
                await Task.Delay(300);
                Check(hud.Visibility == Visibility.Visible && hud.Opacity > .99 && hud.IsHitTestVisible,
                    "Showing a collapsed HUD restores its opacity and controls");
                Check(windowedPresenter.HasTitleBar == originalTitleBar && windowedPresenter.HasBorder == originalBorder,
                    "Showing the HUD restores the original native title bar and border");
                IdleInput(); Call("SetPlaying", false);
                await Task.Delay(3400);
                Check(hud.Visibility == Visibility.Visible && hud.Opacity > .99,
                    "Paused playback keeps the HUD visible beyond the idle deadline");
                IdleInput(); Call("SetPlaying", true);
                await Task.Delay(2600);
                Check(hud.Visibility == Visibility.Visible && hud.IsHitTestVisible,
                    "Playing retains the HUD until the three-second idle deadline");
                await Task.Delay(800);
                Check(hud.Visibility == Visibility.Collapsed && !hud.IsHitTestVisible,
                    "Playing automatically fades out the HUD after three idle seconds");
                Check(!windowedPresenter.HasTitleBar,
                    "The native caption buttons also hide after the playback idle timeout");

                Call("ShowHud"); await Task.Delay(300);
                InvokeButton("RateButton"); await Task.Delay(250);
                var menu = (MenuFlyout?)(typeof(PlayerView).GetField("_activeMenu", instance)?.GetValue(player));
                Check(menu?.IsOpen == true, "The playback settings button opens its native menu");
                await Task.Delay(3400);
                Check(menu!.IsOpen && hud.Visibility == Visibility.Visible && hud.IsHitTestVisible,
                    "An open menu holds the HUD beyond the playback idle deadline");
                menu.Hide(); await Task.Delay(250);
                IdleInput(); Call("ShowHud");
                await Task.Delay(3400);
                Check(!menu.IsOpen && hud.Visibility == Visibility.Collapsed,
                    "Closing the menu releases the HUD for normal automatic hiding");

                var readerSource = typeof(PlayerView).GetField("_readScreenReader", instance)!;
                readerSource.SetValue(player, (Func<bool>)(() => true));
                IdleInput(); Call("ShowHud");
                await Task.Delay(3600);
                Check((bool)typeof(PlayerView).GetField("_screenReader", instance)!.GetValue(player)!
                    && hud.Visibility == Visibility.Visible,
                    "An active screen reader retains the HUD beyond the normal three-second idle deadline");
                readerSource.SetValue(player, (Func<bool>)(() => false));
                await Task.Delay(2400);
                Check(!(bool)typeof(PlayerView).GetField("_screenReader", instance)!.GetValue(player)!
                    && hud.Visibility == Visibility.Collapsed,
                    "Disabling the screen reader restores automatic HUD hiding through the regular polling path");

                Call("SetPlaying", false); await Task.Delay(300);
                InvokeButton("VolumeButton"); await Task.Delay(250);
                var volumeFlyout = Element<Flyout>("VolumeFlyout");
                Check(volumeFlyout.IsOpen, "The title-bar volume button opens the adjustment flyout");
                var volume = Element<Slider>("Volume");
                volume.Value = 73;
                Check(Element<TextBlock>("VolumeLabel").Text == "73" && Element<SymbolIcon>("VolumeIcon").Symbol == Symbol.Volume,
                    "Adjusting volume updates the displayed number and title-bar icon");
                InvokeButton("MuteButton"); await Task.Delay(100);
                Check(volume.Value == 73 && Element<TextBlock>("VolumeLabel").Text == "73"
                    && Element<SymbolIcon>("MuteIcon").Symbol == Symbol.Mute && Element<SymbolIcon>("VolumeIcon").Symbol == Symbol.Mute,
                    "Muting preserves the independent volume slider and number while updating both icons");
                InvokeButton("MuteButton"); await Task.Delay(100);
                Check(volume.Value == 73 && Element<TextBlock>("VolumeLabel").Text == "73"
                    && Element<SymbolIcon>("MuteIcon").Symbol == Symbol.Volume && Element<SymbolIcon>("VolumeIcon").Symbol == Symbol.Volume,
                    "Unmuting restores the previous volume consistently");
                volumeFlyout.Hide();
                Call("SetRate", 1.25);
                var stopwatch = (System.Diagnostics.Stopwatch)typeof(PlayerView).GetField("_time", instance)!.GetValue(player)!;
                typeof(PlayerView).GetField("_rightDown", instance)!.SetValue(player, true);
                typeof(PlayerView).GetField("_rightPressedAt", instance)!.SetValue(player, stopwatch.Elapsed.TotalSeconds - .4);
                await Task.Delay(120);
                Check((bool)typeof(PlayerView).GetField("_fastForward", instance)!.GetValue(player)!
                    && (double)typeof(PlayerView).GetField("_rate", instance)!.GetValue(player)! == 1.25
                    && ((Border)typeof(PlayerView).GetField("_fastForwardBadge", instance)!.GetValue(player)!).Visibility == Visibility.Visible,
                    "Holding right activates a separate 2x badge without changing the persistent playback rate");
                Call("EndFastForward");
                Check(!(bool)typeof(PlayerView).GetField("_fastForward", instance)!.GetValue(player)!
                    && (double)typeof(PlayerView).GetField("_rate", instance)!.GetValue(player)! == 1.25
                    && ((Border)typeof(PlayerView).GetField("_fastForwardBadge", instance)!.GetValue(player)!).Visibility == Visibility.Collapsed,
                    "Ending temporary fast-forward removes its badge and preserves the original playback rate");
                Call("SetPosition", Element<Slider>("Timeline").Maximum);
                Check(Math.Abs(Element<Slider>("Timeline").Value - (Element<Slider>("Timeline").Maximum - .5)) < .001,
                    "Seeking to the final timeline value preserves the half-second EOF guard");
                player.SetMedia(originalMedia); Call("SetPlaying", false);
                await Task.Delay(250);
            }
            try
            {
                if (!App.DemoMode) throw new InvalidOperationException("Player verification requires offline demo mode");
                await Task.Delay(500);
                var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
                var root = Content;
                var presenter = (OverlappedPresenter)AppWindow.Presenter;
                var borderBeforePlayback = presenter.HasBorder;
                var titleBarBeforePlayback = presenter.HasTitleBar;
                var media = DemoCatalog.All[4] with { Progress = 10 };
                _model.SelectedMedia = media; _model.SelectedEpisode = 1;
                Navigate("detail");
                await Task.Delay(800);
                var detail = _transitions.Content;
                PresentPlayer(media);
                await Task.Delay(300);
                var player = _player!;
                Check(ReferenceEquals(root, Content) && WinRT.Interop.WindowNative.GetWindowHandle(this) == hwnd,
                    "Playback uses the original window and root");
                Check(Root.Visibility == Visibility.Collapsed && PlayerHost.Children.Count == 1 && player.IsLoaded,
                    "Only the player is visible and interactive");
                PresentPlayer(media with { Title = "Second media" });
                Check(ReferenceEquals(player, _player), "Changing media reuses the embedded player");
                await VerifyHud(player, media);
                await VerifyPlayerMenus(player, Check);
                player.ToggleFullscreen();
                await Task.Delay(250);
                Check(AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen, "Fullscreen uses the main window");
                player.ToggleFullscreen();
                await Task.Delay(250);
                Check(AppWindow.Presenter == presenter, "Leaving fullscreen restores the original presenter");
                player.ToggleFullscreen();
                await Task.Delay(250);
                var close = (Button)player.FindName("ReturnButton");
                ((IInvokeProvider)new ButtonAutomationPeer(close).GetPattern(PatternInterface.Invoke)).Invoke();
                await Task.Delay(300);
                Check(_player is null && player.IsDisposed && PlayerHost.Children.Count == 0,
                    "The close control disposes playback and removes the overlay");
                Check(AppWindow.Presenter == presenter && Root.Visibility == Visibility.Visible,
                    "Closing fullscreen playback restores the original window");
                Check(presenter.HasBorder == borderBeforePlayback && presenter.HasTitleBar == titleBarBeforePlayback,
                    "Closing playback restores the original native title bar and border");
                Check(ReferenceEquals(detail, _transitions.Content) && _model.Route == "detail" && _model.SelectedEpisode == 1,
                    "Returning preserves the detail page instance and episode selection");
                var scroll = new ScrollViewer { Content = new Border { Height = 3000 } };
                _transitions.Show(scroll, Services.PageTransitionKind.None);
                Root.UpdateLayout(); scroll.ChangeView(null, 240, null, true);
                await Task.Delay(200);
                var offset = scroll.VerticalOffset;
                Check(offset > 0, "The return-position fixture is scrolled");
                PresentPlayer(media); await Task.Delay(200); DismissPlayer(); await Task.Delay(200);
                Check(Math.Abs(scroll.VerticalOffset - offset) < 1, "Playback preserves the previous scroll position");
                for (var i = 0; i < 3; i++)
                {
                    PresentPlayer(media); await Task.Delay(100); var old = _player!; DismissPlayer();
                    Check(old.IsDisposed && _player is null, $"Repeated playback {i + 1} releases the view");
                }
                File.WriteAllText(output, JsonSerializer.Serialize(new { passed = true, assertions }, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch (Exception error)
            {
                File.WriteAllText(output, JsonSerializer.Serialize(new { passed = false, error = error.ToString(), assertions }));
            }
            finally { Close(); }
        };
    }

    private void AttachPlayerSizingVerification()
    {
        var output = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--demo-verify-player-sizing="))?.Split('=', 2)[1];
        if (output is null) return;
        WindowRoot.Loaded += async (_, _) =>
        {
            var assertions = new List<string>();
            var measurements = new List<object>();
            void Check(bool condition, string message)
            {
                if (!condition) throw new InvalidOperationException(message);
                assertions.Add(message);
            }
            try
            {
                await Task.Delay(300);
                var originalSize = AppWindow.Size;
                PresentPlayer(DemoCatalog.Movies[0]);
                await Task.Delay(250);
                var player = _player!;
                const BindingFlags instance = BindingFlags.Instance | BindingFlags.NonPublic;
                var video = (FrameworkElement)player.FindName("VideoPanel");
                video.Visibility = Visibility.Visible;
                player.IsHitTestVisible = false;
                typeof(PlayerView).GetMethod("SetPlaying", instance)!.Invoke(player, [false]);
                var hud = (Services.PlayerHudVisibilityController)typeof(PlayerView).GetField("_hudVisibility", instance)!.GetValue(player)!;
                void ReportDimensions(uint width, uint height) => typeof(PlayerView).GetMethod("OnNativeDimensions", instance)!.Invoke(player, [width, height]);
                void CheckSurface(uint width, uint height, string state)
                {
                    player.UpdateLayout();
                    var scale = player.XamlRoot.RasterizationScale;
                    var surfaceWidth = video.ActualWidth * scale;
                    var surfaceHeight = video.ActualHeight * scale;
                    var aspect = (double)width / height;
                    var fittedWidth = Math.Min(surfaceWidth, surfaceHeight * aspect);
                    var fittedHeight = fittedWidth / aspect;
                    var barPixels = Math.Max((surfaceWidth - fittedWidth) / 2, (surfaceHeight - fittedHeight) / 2);
                    measurements.Add(new { width, height, state, scale, surfaceWidth, surfaceHeight, barPixels, client = AppWindow.ClientSize, window = AppWindow.Size });
                    Check(barPixels <= 1, $"{width}x{height} {state}: video viewport fits without letterboxing (error {barPixels:0.###} px)");
                }
                foreach (var (width, height) in new (uint Width, uint Height)[] { (1920, 1080), (1440, 1080), (2520, 1080), (1080, 1920) })
                {
                    hud.Show();
                    await Task.Delay(100);
                    ReportDimensions(width, height);
                    await Task.Delay(300);
                    CheckSurface(width, height, "HUD visible");
                    hud.Hide();
                    await Task.Delay(300);
                    CheckSurface(width, height, "HUD hidden");
                    hud.Show();
                    await Task.Delay(300);
                    CheckSurface(width, height, "HUD restored");
                }
                var presenter = (OverlappedPresenter)AppWindow.Presenter;
                presenter.Maximize();
                await Task.Delay(250);
                var maximizedSize = AppWindow.Size;
                ReportDimensions(1920, 1080);
                await Task.Delay(250);
                Check(AppWindow.Size == maximizedSize, "Video metadata does not resize a maximized window");
                presenter.Restore();
                await Task.Delay(250);
                player.ToggleFullscreen();
                await Task.Delay(250);
                var fullscreenSize = AppWindow.Size;
                ReportDimensions(1440, 1080);
                await Task.Delay(250);
                Check(AppWindow.Size == fullscreenSize, "Video metadata does not resize a fullscreen window");
                DismissPlayer();
                await Task.Delay(250);
                Check(AppWindow.Presenter == presenter && AppWindow.Size == originalSize, "Leaving playback restores the original window size and presenter");
                File.WriteAllText(output, JsonSerializer.Serialize(new { passed = true, assertions, measurements }, new JsonSerializerOptions { WriteIndented = true, IncludeFields = true }));
            }
            catch (Exception error)
            {
                File.WriteAllText(output, JsonSerializer.Serialize(new { passed = false, error = error.ToString(), assertions, measurements }, new JsonSerializerOptions { WriteIndented = true, IncludeFields = true }));
            }
            finally { Close(); }
        };
    }

}
#endif
