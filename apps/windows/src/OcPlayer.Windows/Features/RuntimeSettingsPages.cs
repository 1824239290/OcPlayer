using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Services;
using OcPlayer.Windows.ViewModels;

namespace OcPlayer.Windows.Features;

internal sealed partial class RuntimeSettingsPages(DemoViewModel model, Action<string> navigate, Action<bool> themeChanged)
{
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private static TextBlock Note(string text) => SettingsUi.Caption(text);
    private static Button Action(string text, Action clicked, bool destructive = false) { var b = SettingsUi.Action(new Button { Content = text }, destructive); b.Click += (_, _) => clicked(); return b; }
    private Button AsyncAction(string text, Func<Task> clicked, bool destructive = false)
    {
        var b = SettingsUi.Action(new Button { Content = text }, destructive); b.Click += async (_, _) => { b.IsEnabled = false;
            try { await clicked(); } catch (Exception ex) { _status.Text = ex.Message; AppDiagnostics.Write("error", ex.Message); }
            finally { b.IsEnabled = true; } }; return b;
    }
    private void Save(Action action) { try { action(); _status.Text = "设置已保存。"; } catch (Exception ex) { _status.Text = ex.Message; } }
    private static StackPanel Section(StackPanel page, string title, bool collapsed = false) => SettingsUi.Section(page, title, collapsed);
    private static void Add(Panel page, UIElement item) => SettingsUi.Add(page, item);
    private static ToggleSwitch Toggle(Panel page, string title, bool value, Action<bool> change)
    { var b = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "", MinWidth = 0 }; b.Toggled += (_, _) => change(b.IsOn); Add(page, SettingsUi.Row(title, b)); return b; }
    private static ComboBox Choice(Panel page, string title, (string Label, string Key)[] options, string selected, Action<string> change)
    {
        var b = new ComboBox { ItemsSource = options.Select(x => x.Label).ToArray(), SelectedIndex = Array.FindIndex(options, x => x.Key == selected), FontSize = 13 };
        b.SelectionChanged += (_, _) => { if (b.SelectedIndex >= 0) change(options[b.SelectedIndex].Key); }; Add(page, SettingsUi.Row(title, b, field: true)); return b;
    }
    private static NumberBox Number(Panel page, string title, double value, double min, double max, double step, Action<double> change)
    { var b = new NumberBox { Value = value, Minimum = min, Maximum = max, SmallChange = step, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, Width = 120, FontSize = 13 };
        b.ValueChanged += (_, _) => { if (!double.IsFinite(b.Value)) return; var rounded = Math.Clamp(min + Math.Round((b.Value - min) / step) * step, min, max);
            if (Math.Abs(rounded - b.Value) > .00001) { b.Value = rounded; return; } change(b.Value); }; Add(page, SettingsUi.Row(title, b)); return b; }
    public void Build(string name, StackPanel page)
    {
        page.Spacing = 28;
        SettingsUi.Status(_status);
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
        var rows = Section(page, "");
        var field = new TextBox { Text = RuntimeSettings.Current.UserAgent, PlaceholderText = "留空使用默认值", FontSize = 13 };
        Add(rows, SettingsUi.Row("User-Agent", field, field: true));
        Add(rows, Action("保存 User-Agent", () => Save(() => { RuntimeSettings.Save(RuntimeSettings.Current with { UserAgent = field.Text }); field.Text = RuntimeSettings.Current.UserAgent; })));
        Add(rows, Note("保存后媒体浏览与新拉流请求立即使用此值，无需重新连接服务器。"));
        page.Children.Add(Note("默认值：" + new RuntimePreferences().EffectiveUserAgent));
    }
    private void Playback(StackPanel page)
    {
        void Update(Func<RuntimePreferences, RuntimePreferences> f) => Save(() => RuntimeSettings.Save(f(RuntimeSettings.Current)));
        var p = RuntimeSettings.Current;
        var buffers = Section(page, "网络缓冲");
        Choice(buffers, "网络预读缓冲", [("默认（2 MiB）", "2"), ("8 MiB", "8"), ("16 MiB", "16"), ("32 MiB", "32")], p.NetworkBufferMiB.ToString(), v => Update(x => x with { NetworkBufferMiB = int.Parse(v) }));
        Choice(buffers, "回退缓冲", [("默认（16 MiB）", "16"), ("32 MiB", "32"), ("64 MiB", "64"), ("128 MiB", "128")], p.BackBufferMiB.ToString(), v => Update(x => x with { BackBufferMiB = int.Parse(v) }));
        Add(buffers, Note("缓冲在下次打开片源时生效。预读越大越能抵抗网络抖动；回退缓存保留已经播放的数据。"));
        var skips = Section(page, "跳过片头与片尾");
        Toggle(skips, "跳过片头", p.SkipIntro, value => Update(x => x with { SkipIntro = value }));
        ComboBox? retention = null;
        Toggle(skips, "跳过片尾", p.SkipOutro, value => { Update(x => x with { SkipOutro = value }); if (retention is not null) retention.IsEnabled = value; });
        retention = Choice(skips, "片尾保留", [("不保留", "0"), ("5 秒", "5"), ("10 秒（默认）", "10"), ("15 秒", "15"), ("20 秒", "20"), ("30 秒", "30")], p.OutroRetainSeconds.ToString(), value => Update(x => x with { OutroRetainSeconds = int.Parse(value) })); retention.IsEnabled = p.SkipOutro;
        Add(skips, Note("跳过开关立即生效。不保留片尾时，也会停在结束前 0.5 秒。"));
        var subtitles = Section(page, "字幕");
        Choice(subtitles, "默认字幕语言", [("中文优先（简体）", "zh-Hans"), ("中文优先（繁体）", "zh-Hant"), ("跟随文件默认", "default"), ("默认关闭", "off")], p.SubtitleLanguage, value => Update(x => x with { SubtitleLanguage = value }));
        Add(subtitles, Note("打开片源时按偏好选轨；手动选择轨道后，本片不会再被自动切换。"));
        var appearance = Section(page, "字幕外观", collapsed: true);
        Choice(appearance, "位置", [("不设置", "unset"), ("底部居中", "bottom-center"), ("左下角", "bottom-left"), ("右下角", "bottom-right"), ("顶部居中", "top-center")], p.SubtitlePosition, value => Update(x => x with { SubtitlePosition = value }));
        Number(appearance, "上下边距（0 = 不设置）", p.SubtitleMargin, 0, 200, 10, value => Update(x => x with { SubtitleMargin = (int)Math.Round(value / 10) * 10 }));
        Color(appearance, "字幕颜色", p.SubtitleColor, value => Update(x => x with { SubtitleColor = value }));
        Color(appearance, "描边颜色", p.SubtitleOutlineColor, value => Update(x => x with { SubtitleOutlineColor = value }));
        Number(appearance, "描边粗细（0 = 不设置）", p.SubtitleOutlineWidth, 0, 32, 1, value => Update(x => x with { SubtitleOutlineWidth = (int)value }));
        var bold = Choice(appearance, "加粗", [("不设置", "unset"), ("明确加粗", "true"), ("明确不加粗", "false")], p.SubtitleBold?.ToString().ToLowerInvariant() ?? "unset", value => Update(x => x with { SubtitleBold = value == "unset" ? null : bool.Parse(value) }));
        var reset = Action("还原加粗", () => bold.SelectedIndex = 0); reset.Visibility = p.SubtitleBold is null ? Visibility.Collapsed : Visibility.Visible;
        bold.SelectionChanged += (_, _) => reset.Visibility = bold.SelectedIndex == 0 ? Visibility.Collapsed : Visibility.Visible; Add(appearance, reset);
        Toggle(appearance, "覆盖字幕自带样式", p.OverrideSubtitleStyles, value => Update(x => x with { OverrideSubtitleStyles = value }));
        Add(appearance, Note("外观修改实时应用。关闭覆盖时只补充未指定的样式；开启时覆盖 ASS 的排版与特效。无法应用的内核会在播放器中显示说明。"));
        var kernel = Section(page, "播放内核"); Add(kernel, SettingsUi.Row("内核", SettingsUi.Value("liberika " + KernelVersion.Read())));
        Choice(kernel, "画质增强", [("关闭", "off"), ("ArtCNN F16", "artcnn-f16"), ("ArtCNN F32", "artcnn-f32"), ("ArtCNN F16 去噪", "artcnn-f16-denoise")], p.QualityEnhancement, value => Update(x => x with { QualityEnhancement = value }));
        Add(kernel, Note("下次播放生效；当前 GPU 后端不支持时回退到原生采样。"));
        var theme = Section(page, "外观");
        Choice(theme, "主题", [("跟随系统", "system"), ("浅色", "light"), ("深色", "dark")], model.ThemeMode, value => { model.ThemeMode = value; themeChanged(model.DarkTheme); });
        if (RuntimeSettings.LoadWarning is { } warning) _status.Text = warning;
    }
    private void Color(Panel page, string title, string? value, Action<string?> change)
    {
        var field = new TextBox { Text = value ?? "", PlaceholderText = "#RRGGBBAA", FontSize = 13 };
        Add(page, SettingsUi.Row(title + "（RGBA）", field, field: true));
        field.LostFocus += (_, _) => change(field.Text.Length == 0 ? null : field.Text);
        var picker = new ColorPicker { IsAlphaEnabled = true, IsAlphaSliderVisible = true, IsAlphaTextInputVisible = true, Width = 300 };
        if (value is { Length: 9 } && uint.TryParse(value[1..], System.Globalization.NumberStyles.HexNumber, null, out var rgba)) picker.Color = global::Windows.UI.Color.FromArgb((byte)rgba, (byte)(rgba >> 24), (byte)(rgba >> 16), (byte)(rgba >> 8));
        var pick = new Button { Content = "选择颜色…", Flyout = new Flyout { Content = picker }, Padding = new Thickness(12, 4, 12, 4) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(pick);
        var reset = new Button { Content = "还原", Padding = new Thickness(12, 4, 12, 4) }; reset.Click += (_, _) => { field.Text = ""; change(null); }; buttons.Children.Add(reset);
        picker.ColorChanged += (_, args) => { var c = args.NewColor; field.Text = $"#{c.R:X2}{c.G:X2}{c.B:X2}{c.A:X2}"; change(field.Text); };
        buttons.Margin = new Thickness(0, 0, 0, 8); page.Children.Add(buttons);
    }
    private static async Task<bool> Confirm(FrameworkElement owner, string title, string text) => await new ContentDialog { XamlRoot = owner.XamlRoot, Title = title,
        Content = new ScrollViewer { Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }, MaxHeight = 420 },
        PrimaryButtonText = "确认", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary;
}
