using System.Globalization;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using OcPlayer.Windows.Preview;
using Windows.Graphics;
using Windows.System;

namespace OcPlayer.Windows;

public sealed partial class PlayerWindow : Window
{
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool _playing = true;
    private double _previousVolume = 75;

    public PlayerWindow(DemoMedia media)
    {
        InitializeComponent();
        Title = "OcPlayer · 播放器演示";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(PlayerTitleBar);
        AppWindow.Resize(new SizeInt32(1100, 740));
        AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonForegroundColor = Microsoft.UI.Colors.White;
        SetMedia(media);
        _clock.Tick += (_, _) =>
        {
            if (!_playing) return;
            var rate = double.Parse((string)((ComboBoxItem)Rate.SelectedItem).Tag, CultureInfo.InvariantCulture);
            Timeline.Value = Math.Min(Timeline.Maximum, Timeline.Value + rate);
            if (Timeline.Value >= Timeline.Maximum) SetPlaying(false);
        };
        _clock.Start();
        Closed += (_, _) => _clock.Stop();
        AddShortcut(VirtualKey.Space, () => SetPlaying(!_playing));
        AddShortcut(VirtualKey.Left, () => Seek(-10));
        AddShortcut(VirtualKey.Right, () => Seek(10));
        AddShortcut(VirtualKey.F, ToggleFullscreen);
        AddShortcut(VirtualKey.Escape, () =>
        {
            if (AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen) ToggleFullscreen(); else Close();
        });
    }
    public void SetMedia(DemoMedia media)
    {
        MediaTitle.Text = media.Title;
        Backdrop.Source = new BitmapImage(new Uri(media.Id == "interstellar" ? DemoCatalog.BackdropPath : media.PosterPath));
        Timeline.Value = Timeline.Maximum * media.Progress / 100;
        SetPlaying(true);
    }
    private void SetPlaying(bool playing) { _playing = playing; PlayButton.Content = playing ? "暂停" : "播放"; }
    private void Seek(double seconds) => Timeline.Value = Math.Clamp(Timeline.Value + seconds, 0, Timeline.Maximum);
    private void ToggleFullscreen() => AppWindow.SetPresenter(AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen
        ? AppWindowPresenterKind.Overlapped : AppWindowPresenterKind.FullScreen);
    private void AddShortcut(VirtualKey key, Action action)
    {
        var shortcut = new KeyboardAccelerator { Key = key };
        shortcut.Invoked += (_, args) => { action(); args.Handled = true; };
        PlayerRoot.KeyboardAccelerators.Add(shortcut);
    }
    private void Play_Click(object sender, RoutedEventArgs e) => SetPlaying(!_playing);
    private void Back_Click(object sender, RoutedEventArgs e) => Seek(-10);
    private void Forward_Click(object sender, RoutedEventArgs e) => Seek(10);
    private void Fullscreen_Click(object sender, RoutedEventArgs e) => ToggleFullscreen();
    private void Timeline_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (PositionLabel is not null) PositionLabel.Text = TimeSpan.FromSeconds(e.NewValue).ToString(@"hh\:mm\:ss");
    }
    private void Subtitles_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SubtitlePreview is null) return;
        SubtitlePreview.Visibility = Subtitles.SelectedIndex == 2 ? Visibility.Collapsed : Visibility.Visible;
        SubtitlePreview.Text = Subtitles.SelectedIndex == 1 ? "Across the stars and time, finding our way home." : "越过星辰与时间，寻找家的方向。";
    }
    private void Mute_Click(object sender, RoutedEventArgs e)
    {
        if (Volume.Value > 0) { _previousVolume = Volume.Value; Volume.Value = 0; MuteButton.Content = "静音"; }
        else { Volume.Value = _previousVolume > 0 ? _previousVolume : 75; MuteButton.Content = "音量"; }
    }
}
