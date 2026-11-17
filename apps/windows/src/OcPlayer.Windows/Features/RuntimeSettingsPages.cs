using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;
using OcPlayer.Windows.ViewModels;

namespace OcPlayer.Windows.Features;

internal sealed partial class RuntimeSettingsPages(DemoViewModel model, Action<string> navigate, Action<bool> themeChanged)
{
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private static TextBlock Note(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Opacity = .7, FontSize = 12, IsTextSelectionEnabled = true };
    private static Button Action(string text, Action clicked) { var b = new Button { Content = text }; b.Click += (_, _) => clicked(); return b; }
    private Button AsyncAction(string text, Func<Task> clicked)
    {
        var b = new Button { Content = text }; b.Click += async (_, _) => { b.IsEnabled = false;
            try { await clicked(); } catch (Exception ex) { _status.Text = ex.Message; AppDiagnostics.Write("error", ex.Message); }
            finally { b.IsEnabled = true; } }; return b;
    }
    private void Save(Action action) { try { action(); _status.Text = "设置已保存。"; } catch (Exception ex) { _status.Text = ex.Message; } }
    private static void Heading(Panel page, string text) => page.Children.Add(new TextBlock { Text = text, FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(0, 15, 0, 0) });
    private static ToggleSwitch Toggle(Panel page, string title, bool value, Action<bool> change)
    { var b = new ToggleSwitch { Header = title, IsOn = value }; b.Toggled += (_, _) => change(b.IsOn); page.Children.Add(b); return b; }
    private static ComboBox Choice(Panel page, string title, (string Label, string Key)[] options, string selected, Action<string> change)
    {
        var b = new ComboBox { Header = title, ItemsSource = options.Select(x => x.Label).ToArray(), SelectedIndex = Array.FindIndex(options, x => x.Key == selected), MinWidth = 260 };
        b.SelectionChanged += (_, _) => { if (b.SelectedIndex >= 0) change(options[b.SelectedIndex].Key); }; page.Children.Add(b); return b;
    }
    private static NumberBox Number(Panel page, string title, double value, double min, double max, double step, Action<double> change)
    { var b = new NumberBox { Header = title, Value = value, Minimum = min, Maximum = max, SmallChange = step, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
        b.ValueChanged += (_, _) => { if (!double.IsFinite(b.Value)) return; var rounded = Math.Clamp(min + Math.Round((b.Value - min) / step) * step, min, max);
            if (Math.Abs(rounded - b.Value) > .00001) { b.Value = rounded; return; } change(b.Value); }; page.Children.Add(b); return b; }
    public void Build(string name, StackPanel page)
    {
        switch (name)
        {
            case "播放": Playback(page); break;
            case "网络": Network(page); break;
            case "TMDB 元数据补全": Tmdb(page); break;
            case "维护": Maintenance(page); break;
            case "关于": About(page); break;
            case "开源许可证": Licenses(page); break;
        }
        page.Children.Add(_status);
    }
    private void Network(StackPanel page)
    {
        var field = new TextBox { Header = "自定义全局 User-Agent", Text = RuntimeSettings.Current.UserAgent, PlaceholderText = "留空使用默认值" }; page.Children.Add(field);
        page.Children.Add(Action("保存 User-Agent", () => Save(() => { RuntimeSettings.Save(RuntimeSettings.Current with { UserAgent = field.Text }); field.Text = RuntimeSettings.Current.UserAgent; })));
        page.Children.Add(Note("控制字符会自动移除。保存后媒体浏览与新拉流请求立即使用此值，无需重新连接服务器。"));
        page.Children.Add(Note("默认值：" + new RuntimePreferences().EffectiveUserAgent));
    }
    private void Playback(StackPanel page)
    {
        void Update(Func<RuntimePreferences, RuntimePreferences> f) => Save(() => RuntimeSettings.Save(f(RuntimeSettings.Current)));
        var p = RuntimeSettings.Current;
        Heading(page, "网络缓冲");
        Choice(page, "网络预读缓冲", [("默认（2 MiB）", "2"), ("8 MiB", "8"), ("16 MiB", "16"), ("32 MiB", "32")], p.NetworkBufferMiB.ToString(), v => Update(x => x with { NetworkBufferMiB = int.Parse(v) }));
        Choice(page, "回退缓冲", [("默认（16 MiB）", "16"), ("32 MiB", "32"), ("64 MiB", "64"), ("128 MiB", "128")], p.BackBufferMiB.ToString(), v => Update(x => x with { BackBufferMiB = int.Parse(v) }));
        page.Children.Add(Note("缓冲在下次打开片源时生效。预读越大越能抵抗网络抖动；回退缓存保留已经播放的数据。"));
        Heading(page, "跳过片头与片尾");
        Toggle(page, "跳过片头", p.SkipIntro, value => Update(x => x with { SkipIntro = value }));
        ComboBox? retention = null;
        Toggle(page, "跳过片尾", p.SkipOutro, value => { Update(x => x with { SkipOutro = value }); if (retention is not null) retention.IsEnabled = value; });
        retention = Choice(page, "片尾保留", [("不保留", "0"), ("5 秒", "5"), ("10 秒（默认）", "10"), ("15 秒", "15"), ("20 秒", "20"), ("30 秒", "30")], p.OutroRetainSeconds.ToString(), value => Update(x => x with { OutroRetainSeconds = int.Parse(value) })); retention.IsEnabled = p.SkipOutro;
        page.Children.Add(Note("跳过开关立即生效。不保留片尾时，也会停在结束前 0.5 秒。"));
        Heading(page, "字幕");
        Choice(page, "默认字幕语言", [("中文优先（简体）", "zh-Hans"), ("中文优先（繁体）", "zh-Hant"), ("跟随文件默认", "default"), ("默认关闭", "off")], p.SubtitleLanguage, value => Update(x => x with { SubtitleLanguage = value }));
        page.Children.Add(Note("打开片源时按偏好选轨；手动选择轨道后，本片不会再被自动切换。"));
        Heading(page, "字幕外观");
        Choice(page, "位置", [("不设置", "unset"), ("底部居中", "bottom-center"), ("左下角", "bottom-left"), ("右下角", "bottom-right"), ("顶部居中", "top-center")], p.SubtitlePosition, value => Update(x => x with { SubtitlePosition = value }));
        Number(page, "上下边距（0 = 不设置）", p.SubtitleMargin, 0, 200, 10, value => Update(x => x with { SubtitleMargin = (int)Math.Round(value / 10) * 10 }));
        Color(page, "字幕颜色", p.SubtitleColor, value => Update(x => x with { SubtitleColor = value }));
        Color(page, "描边颜色", p.SubtitleOutlineColor, value => Update(x => x with { SubtitleOutlineColor = value }));
        Number(page, "描边粗细（0 = 不设置）", p.SubtitleOutlineWidth, 0, 32, 1, value => Update(x => x with { SubtitleOutlineWidth = (int)value }));
        var bold = Choice(page, "加粗", [("不设置", "unset"), ("明确加粗", "true"), ("明确不加粗", "false")], p.SubtitleBold?.ToString().ToLowerInvariant() ?? "unset", value => Update(x => x with { SubtitleBold = value == "unset" ? null : bool.Parse(value) }));
        var reset = Action("还原加粗", () => bold.SelectedIndex = 0); reset.Visibility = p.SubtitleBold is null ? Visibility.Collapsed : Visibility.Visible;
        bold.SelectionChanged += (_, _) => reset.Visibility = bold.SelectedIndex == 0 ? Visibility.Collapsed : Visibility.Visible; page.Children.Add(reset);
        Toggle(page, "覆盖字幕自带样式", p.OverrideSubtitleStyles, value => Update(x => x with { OverrideSubtitleStyles = value }));
        page.Children.Add(Note("外观修改实时应用。关闭覆盖时只补充未指定的样式；开启时覆盖 ASS 的排版与特效。无法应用的内核会在播放器中显示说明。"));
        Heading(page, "播放内核"); page.Children.Add(Note("Erika " + KernelVersion.Read()));
        Choice(page, "画质增强", [("关闭", "off"), ("ArtCNN F16", "artcnn-f16"), ("ArtCNN F32", "artcnn-f32"), ("ArtCNN F16 去噪", "artcnn-f16-denoise")], p.QualityEnhancement, value => Update(x => x with { QualityEnhancement = value }));
        page.Children.Add(Note("下次播放生效；当前 GPU 后端不支持时回退到原生采样。"));
        Heading(page, "外观");
        Choice(page, "主题", [("跟随系统", "system"), ("浅色", "light"), ("深色", "dark")], model.ThemeMode, value => { model.ThemeMode = value; themeChanged(model.DarkTheme); });
        if (RuntimeSettings.LoadWarning is { } warning) _status.Text = warning;
    }
    private void Color(Panel page, string title, string? value, Action<string?> change)
    {
        var field = new TextBox { Header = title + "（RGBA）", Text = value ?? "", PlaceholderText = "不设置 · #RRGGBBAA", Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
        page.Children.Add(field);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(Action("应用色值", () => change(field.Text.Length == 0 ? null : field.Text)));
        buttons.Children.Add(Action("还原", () => { field.Text = ""; change(null); }));
        var picker = new ColorPicker { IsAlphaEnabled = true, IsAlphaSliderVisible = true, IsAlphaTextInputVisible = true, Width = 300 };
        if (value is { Length: 9 } && uint.TryParse(value[1..], System.Globalization.NumberStyles.HexNumber, null, out var rgba)) picker.Color = global::Windows.UI.Color.FromArgb((byte)rgba, (byte)(rgba >> 24), (byte)(rgba >> 16), (byte)(rgba >> 8));
        var pick = new Button { Content = "选择颜色…", Flyout = new Flyout { Content = picker } }; buttons.Children.Add(pick);
        picker.ColorChanged += (_, args) => { var c = args.NewColor; field.Text = $"#{c.R:X2}{c.G:X2}{c.B:X2}{c.A:X2}"; change(field.Text); };
        page.Children.Add(buttons);
    }
    private static async Task<bool> Confirm(FrameworkElement owner, string title, string text) => await new ContentDialog { XamlRoot = owner.XamlRoot, Title = title,
        Content = new ScrollViewer { Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }, MaxHeight = 420 },
        PrimaryButtonText = "确认", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary;
}
