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
    private readonly DispatcherTimer _clock=new(){Interval=TimeSpan.FromSeconds(1)};
    private bool _playing=true, _scrubbing, _menuOpen;
    private double _rate=1, _previousVolume=40;
    private DateTime _lastInteraction=DateTime.UtcNow;
    private DemoMedia _media=null!;
    public PlayerWindow(DemoMedia media)
    {
        InitializeComponent();Title="OcPlayer · 播放器演示";ExtendsContentIntoTitleBar=true;SetTitleBar(PlayerTitleBar);
        AppWindow.ResizeClient(new SizeInt32(1130,670));AppWindow.TitleBar.ButtonBackgroundColor=Microsoft.UI.Colors.Transparent;AppWindow.TitleBar.ButtonForegroundColor=Microsoft.UI.Colors.White;
        PlayerRoot.Loaded+=(_,_)=>UpdateRegions();PlayerRoot.SizeChanged+=(_,_)=>UpdateRegions();
        Timeline.AddHandler(UIElement.PointerPressedEvent,new PointerEventHandler((_,_)=>_scrubbing=true),true);
        Timeline.AddHandler(UIElement.PointerReleasedEvent,new PointerEventHandler((_,_)=>_scrubbing=false),true);
        Timeline.PointerCaptureLost+=(_,_)=>_scrubbing=false;
        SetMedia(media);
        _clock.Tick+=(_,_)=>{if(_playing&&!_scrubbing){Timeline.Value=Math.Min(Timeline.Maximum,Timeline.Value+_rate);if(Timeline.Value>=Timeline.Maximum)SetPlaying(false);}if(_playing&&!_scrubbing&&!_menuOpen&&DateTime.UtcNow-_lastInteraction>TimeSpan.FromSeconds(3)&&!HasControlFocus())Hud.Visibility=Visibility.Collapsed;};
        _clock.Start();Closed+=(_,_)=>_clock.Stop();
        AddShortcut(VirtualKey.Space,()=>SetPlaying(!_playing));AddShortcut(VirtualKey.Left,()=>Seek(-10));AddShortcut(VirtualKey.Right,()=>Seek(10));AddShortcut(VirtualKey.F,ToggleFullscreen);AddShortcut(VirtualKey.M,ToggleMute);
        AddShortcut(VirtualKey.Escape,()=>{if(_menuOpen)return;if(AppWindow.Presenter.Kind==AppWindowPresenterKind.FullScreen)ToggleFullscreen();else Close();});
    }
    public void SetMedia(DemoMedia media)
    {
        _media=media;MediaTitle.Text=media.Title;EpisodeTitle.Text=media.EpisodeLabel??(media.Kind=="series"?"S1E1":"界面演示 · 模拟时钟");
        Backdrop.Source=new BitmapImage(new Uri(media.Backdrop));Timeline.Maximum=media.DurationSeconds>0?media.DurationSeconds:1440;DurationLabel.Text=TimeLabel(Timeline.Maximum);Timeline.Value=Timeline.Maximum*media.Progress/100;SetPlaying(!Environment.GetCommandLineArgs().Any(x=>x.StartsWith("--demo-capture=")));
    }
    static string TimeLabel(double seconds)=>TimeSpan.FromSeconds(seconds).ToString(seconds>=3600?@"h\:mm\:ss":@"m\:ss");
    void ShowHud(){_lastInteraction=DateTime.UtcNow;Hud.Visibility=Visibility.Visible;}
    bool HasControlFocus()=>Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(PlayerRoot.XamlRoot) is Control;
    void SetPlaying(bool playing){_playing=playing;PlayButton.Content=playing?"\uE769":"\uE768";ShowHud();}
    void Seek(double seconds){Timeline.Value=Math.Clamp(Timeline.Value+seconds,0,Timeline.Maximum);ShowHud();}
    void ToggleFullscreen(){AppWindow.SetPresenter(AppWindow.Presenter.Kind==AppWindowPresenterKind.FullScreen?AppWindowPresenterKind.Overlapped:AppWindowPresenterKind.FullScreen);VolumeControls.Margin=new Thickness(0,16,AppWindow.Presenter.Kind==AppWindowPresenterKind.FullScreen?24:150,0);ShowHud();}
    void AddShortcut(VirtualKey key,Action action){var shortcut=new KeyboardAccelerator{Key=key};shortcut.Invoked+=(_,args)=>{var focus=Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(PlayerRoot.XamlRoot);if(focus is TextBox or PasswordBox||_menuOpen)return;action();args.Handled=true;};PlayerRoot.KeyboardAccelerators.Add(shortcut);}
    void UpdateRegions()
    {
        var scale=PlayerRoot.XamlRoot?.RasterizationScale??1;RectInt32 Bounds(FrameworkElement e){var p=e.TransformToVisual(PlayerRoot).TransformPoint(new global::Windows.Foundation.Point());return new RectInt32((int)(p.X*scale),(int)(p.Y*scale),(int)(e.ActualWidth*scale),(int)(e.ActualHeight*scale));}
        Microsoft.UI.Input.InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(Microsoft.UI.Input.NonClientRegionKind.Passthrough,[Bounds(TopActions),Bounds(VolumeControls)]);
    }
    void Menu(object sender, params (string Label,Action Action)[] items)
    {
        var menu=new MenuFlyout();foreach(var pair in items){var item=new MenuFlyoutItem{Text=pair.Label};item.Click+=(_,_)=>pair.Action();menu.Items.Add(item);}menu.Opened+=(_,_)=>{_menuOpen=true;ShowHud();};menu.Closed+=(_,_)=>{_menuOpen=false;ShowHud();};menu.ShowAt((FrameworkElement)sender);
    }
    void Audio_Click(object sender,RoutedEventArgs e)=>Menu(sender,("音轨 · 中文 · 立体声",()=>{}),("English · 5.1",()=>{}));
    void Subtitles_Click(object sender,RoutedEventArgs e)=>Menu(sender,("字幕轨道 · 关闭",()=>SubtitlePreview.Visibility=Visibility.Collapsed),("简体中文",()=>{SubtitlePreview.Text="字幕预览";SubtitlePreview.Visibility=Visibility.Visible;}),("English",()=>{SubtitlePreview.Text="Subtitle preview";SubtitlePreview.Visibility=Visibility.Visible;}),("字体大小 · 100%",()=>SubtitlePreview.FontSize=24));
    void Danmaku_Click(object sender,RoutedEventArgs e)=>Menu(sender,("自动加载弹幕",()=>{}),("手动匹配…",()=>{}),("显示弹幕",()=>{}));
    void Chapters_Click(object sender,RoutedEventArgs e)=>Menu(sender,("第 1 章",()=>{Timeline.Value=0;}),("第 2 章",()=>{Timeline.Value=Timeline.Maximum*.5;}));
    void More_Click(object sender,RoutedEventArgs e)=>Menu(sender,("播放速度 · 1.0×",()=>_rate=1),("播放速度 · 1.5×",()=>_rate=1.5),("播放速度 · 2.0×",()=>_rate=2),("从头播放",()=>{Timeline.Value=0;}),("全屏",ToggleFullscreen));
    void Player_PointerMoved(object sender,PointerRoutedEventArgs e)=>ShowHud();
    void Close_Click(object sender,RoutedEventArgs e)=>Close();
    void Play_Click(object sender,RoutedEventArgs e)=>SetPlaying(!_playing);
    void Back_Click(object sender,RoutedEventArgs e)=>Seek(-10);
    void Forward_Click(object sender,RoutedEventArgs e)=>Seek(10);
    void Fullscreen_Click(object sender,RoutedEventArgs e)=>ToggleFullscreen();
    void Timeline_ValueChanged(object sender,Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e){if(PositionLabel!=null)PositionLabel.Text=TimeLabel(e.NewValue);}
    void ToggleMute(){if(Volume.Value>0){_previousVolume=Volume.Value;Volume.Value=0;MuteButton.Content="\uE74F";}else{Volume.Value=_previousVolume>0?_previousVolume:40;MuteButton.Content="\uE767";}}
    void Mute_Click(object sender,RoutedEventArgs e)=>ToggleMute();
}
