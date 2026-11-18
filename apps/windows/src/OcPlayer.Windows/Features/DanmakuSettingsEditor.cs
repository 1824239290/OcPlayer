using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed class DanmakuSettingsEditor
{
    private readonly DanmakuPreferences _original;
    private readonly TextBox _gateway, _animeSkip;
    private readonly PasswordBox _key;
    private readonly ToggleSwitch _automatic, _enabled, _top, _bottom, _scroll, _merge, _stack, _kernel;
    private readonly NumberBox _font, _opacity, _area;
    private readonly bool _settingsPage;
    private DanmakuSettings? _settings;
    private Action<string>? _showStatus;
    private TextBlock? _gatewayValue;
    private ContentDialog? _gatewayDialog;
    public StackPanel Content { get; } = new() { Spacing = 28 };

    public DanmakuSettingsEditor(DanmakuPreferences preferences, bool settingsPage = false)
    {
        _original = preferences;
        _settingsPage = settingsPage;
        _automatic = Toggle("自动加载弹幕", preferences.AutoLoad);
        _enabled = Toggle("显示弹幕", preferences.Enabled);
        _gateway = new TextBox { Text = preferences.GatewayUrl, PlaceholderText = DanmakuPreferences.DefaultGateway };
        _key = new PasswordBox { Password = preferences.ApiKey, PlaceholderText = "留空使用默认 Key" };
        var reset = new Button
        {
            Content = "恢复默认网关", HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left, MinHeight = 42,
            Padding = new Thickness(0, 4, 0, 4), Background = null, BorderThickness = new Thickness(0)
        };
        reset.Click += (_, _) => { _gateway.Text = ""; _key.Password = ""; };
        _animeSkip = new TextBox { Text = preferences.AnimeSkipClientId, PlaceholderText = "可选" };
        _kernel = Toggle("用内核渲染弹幕", preferences.UseKernelRenderer);
        _font = Number("字号（11–44 pt）", preferences.FontSize, 11, 44, 2.2);
        _opacity = Number("不透明度（%）", preferences.Opacity * 100, 25, 100, 5);
        _area = Number("显示区域（%）", preferences.DisplayArea * 100, 25, 100, 5);
        _top = Toggle("屏蔽顶部弹幕", preferences.BlockTop);
        _bottom = Toggle("屏蔽底部弹幕", preferences.BlockBottom);
        _scroll = Toggle("屏蔽滚动弹幕", preferences.BlockScroll);
        _merge = Toggle("合并重复弹幕", preferences.MergeDuplicates);
        _stack = Toggle("允许弹幕重叠", preferences.AllowStacking);

        if (settingsPage)
        {
            _animeSkip.TextAlignment = TextAlignment.Right;
            _gatewayValue = Caption(preferences.EffectiveUrl, 13);
            _gatewayValue.TextWrapping = TextWrapping.NoWrap;
            _gatewayValue.TextTrimming = TextTrimming.CharacterEllipsis;
            _gatewayValue.VerticalAlignment = VerticalAlignment.Center;
            var configure = new Button { Content = "配置", Padding = new Thickness(12, 4, 12, 4) };
            AutomationProperties.SetName(configure, "配置弹幕网关");
            configure.Click += (_, _) => ShowGatewayDialog(configure);
            var gateway = new Grid { ColumnSpacing = 10 };
            gateway.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            gateway.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            gateway.Children.Add(_gatewayValue);
            Grid.SetColumn(configure, 1); gateway.Children.Add(configure);
            Group("", SettingRow("自动加载弹幕", _automatic), SettingRow("显示弹幕", _enabled),
                SettingRow("网关", gateway, field: true), SettingRow("anime-skip Client ID（可选）", _animeSkip, field: true),
                Note("填入后启用 anime-skip 片头源；AniSkip 与 TheIntroDB 自动启用。"));
            Group("弹幕渲染", SettingRow("用内核渲染弹幕", _kernel),
                Note("关闭后使用 App 层渲染。改动从下一次播放开始生效。"));
            var details = Rows(SettingRow("字号（11–44 pt）", _font), SettingRow("不透明度（%）", _opacity),
                SettingRow("显示区域（%）", _area), SettingRow("屏蔽顶部弹幕", _top), SettingRow("屏蔽底部弹幕", _bottom),
                SettingRow("屏蔽滚动弹幕", _scroll), SettingRow("合并重复弹幕", _merge), SettingRow("允许弹幕重叠", _stack));
            Content.Children.Add(new Expander
            {
                Header = "显示与过滤", Content = details, HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch, CornerRadius = new CornerRadius(16)
            });
        }
        else
        {
            Group("", SettingRow("自动加载弹幕", _automatic), SettingRow("显示弹幕", _enabled));
            Group("弹幕网关", SettingRow("弹幕网关地址", _gateway, field: true),
                SettingRow("网关 API Key", _key, field: true), reset);
            Group("片头来源", SettingRow("anime-skip Client ID（可选）", _animeSkip, field: true));
            Group("弹幕渲染", SettingRow("用内核渲染弹幕", _kernel),
                Note("关闭后使用 App 层渲染。改动从下一次播放开始生效。"));
            Group("显示样式", SettingRow("字号（11–44 pt）", _font),
                SettingRow("不透明度（%）", _opacity), SettingRow("显示区域（%）", _area));
            Group("弹幕过滤", SettingRow("屏蔽顶部弹幕", _top), SettingRow("屏蔽底部弹幕", _bottom),
                SettingRow("屏蔽滚动弹幕", _scroll), SettingRow("合并重复弹幕", _merge), SettingRow("允许弹幕重叠", _stack));
        }
    }

    private void Group(string title, params UIElement[] items)
    {
        var section = Stack(8);
        if (title.Length > 0) section.Children.Add(Caption(title, 13));
        section.Children.Add(new Border { Child = Rows(items), Style = (Style)Application.Current.Resources["SettingsCardStyle"] });
        if (title == "弹幕网关") section.Children.Add(Caption("Bangumi 登录与弹幕共用此网关。留空使用默认网关；自定义网关需填写自己的 API Key。"));
        if (title == "片头来源") section.Children.Add(Caption("填入后启用 anime-skip 片头源；AniSkip 与 TheIntroDB 自动启用。"));
        Content.Children.Add(section);
    }

    private static StackPanel Rows(params UIElement[] items)
    {
        var rows = Stack(0);
        for (var i = 0; i < items.Length; i++)
        {
            if (i > 0 && items[i] is not TextBlock)
                rows.Children.Add(new Border { Style = (Style)Application.Current.Resources["SettingsDividerStyle"] });
            rows.Children.Add(items[i]);
        }
        return rows;
    }

    private async void ShowGatewayDialog(FrameworkElement anchor)
    {
        if (_gatewayDialog is not null) return;
        var address = new TextBox { Header = "网关地址", Text = _gateway.Text, PlaceholderText = DanmakuPreferences.DefaultGateway };
        AutomationProperties.SetName(address, "弹幕网关地址");
        var key = new PasswordBox { Header = "API Key", Password = _key.Password, PlaceholderText = "留空使用默认 Key" };
        var fields = Stack(12);
        fields.Children.Add(address); fields.Children.Add(key);
        fields.Children.Add(Caption("Bangumi 登录与弹幕共用此网关。自定义网关需填写自己的 API Key。"));
        var reset = new Button { Content = "恢复默认网关" };
        reset.Click += (_, _) => { address.Text = ""; key.Password = ""; };
        fields.Children.Add(reset);
        var error = Caption(""); fields.Children.Add(error);
        var dialog = _gatewayDialog = new ContentDialog
        {
            Title = "弹幕网关", XamlRoot = anchor.XamlRoot, Content = fields,
            PrimaryButtonText = "保存", CloseButtonText = "取消"
        };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            try
            {
                var saved = ((_settings?.Current ?? _original) with { GatewayUrl = address.Text, ApiKey = key.Password }).Validated();
                _settings?.Save(saved);
                _gateway.Text = saved.GatewayUrl; _key.Password = saved.ApiKey;
                _gatewayValue!.Text = saved.EffectiveUrl;
                _showStatus?.Invoke("弹幕网关已保存。");
            }
            catch (Exception ex) { args.Cancel = true; error.Text = ex.Message; }
        };
        void CloseOnLeave(object sender, RoutedEventArgs args) => dialog.Hide();
        anchor.Unloaded += CloseOnLeave;
        try { await dialog.ShowAsync(); }
        catch (Exception ex) { _showStatus?.Invoke(ex.Message); }
        finally { anchor.Unloaded -= CloseOnLeave; _gatewayDialog = null; }
    }

    private static TextBlock Note(string text)
    {
        var note = Caption(text);
        note.Margin = new Thickness(0, 2, 0, 10);
        return note;
    }

    internal static TextBlock Caption(string text, double size = 12) => new()
    {
        Text = text, FontSize = size, Style = (Style)Application.Current.Resources["SettingsCaptionStyle"]
    };

    private static Grid SettingRow(string title, FrameworkElement control, bool field = false)
    {
        AutomationProperties.SetName(control, title);
        var row = new Grid { MinHeight = 42, ColumnSpacing = 16, Padding = new Thickness(0, 4, 0, 4) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = Text(title, 13);
        label.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(label);
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        row.Children.Add(control);
        if (field)
        {
            // Leave room for a wrapping label in the player dialog and narrow windows.
            control.Width = 260;
            row.SizeChanged += (_, _) => control.Width = Math.Min(260, Math.Max(120, row.ActualWidth * .48));
        }
        return row;
    }

    private static ToggleSwitch Toggle(string title, bool value)
    {
        var control = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "", MinWidth = 0 };
        AutomationProperties.SetName(control, title);
        return control;
    }
    private static NumberBox Number(string title, double value, double min, double max, double step)
    {
        var control = new NumberBox { Width = 120, Value = value, Minimum = min, Maximum = max, SmallChange = step,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        AutomationProperties.SetName(control, title);
        return control;
    }

    // The standalone settings page saves switches immediately. The player's
    // settings dialog keeps explicit Save/Cancel behavior by not enabling this.
    public void EnableToggleAutoSave(DanmakuSettings settings, Action<string> showStatus)
    {
        _settings = settings;
        _showStatus = showStatus;
        Bind(_automatic, (p, enabled) => p with { AutoLoad = enabled });
        Bind(_enabled, (p, enabled) => p with { Enabled = enabled });
        Bind(_kernel, (p, enabled) => p with { UseKernelRenderer = enabled });
        Bind(_top, (p, enabled) => p with { BlockTop = enabled });
        Bind(_bottom, (p, enabled) => p with { BlockBottom = enabled });
        Bind(_scroll, (p, enabled) => p with { BlockScroll = enabled });
        Bind(_merge, (p, enabled) => p with { MergeDuplicates = enabled });
        Bind(_stack, (p, enabled) => p with { AllowStacking = enabled });
        if (_settingsPage)
        {
            _animeSkip.LostFocus += (_, _) => SaveField(p => p with { AnimeSkipClientId = _animeSkip.Text }, () => _animeSkip.Text = settings.Current.AnimeSkipClientId);
            _font.LostFocus += (_, _) => SaveField(p => p with { FontSize = _font.Value }, () => _font.Value = settings.Current.FontSize);
            _opacity.LostFocus += (_, _) => SaveField(p => p with { Opacity = _opacity.Value / 100 }, () => _opacity.Value = settings.Current.Opacity * 100);
            _area.LostFocus += (_, _) => SaveField(p => p with { DisplayArea = _area.Value / 100 }, () => _area.Value = settings.Current.DisplayArea * 100);
        }

        void SaveField(Func<DanmakuPreferences, DanmakuPreferences> update, Action restore)
        {
            try
            {
                var preferences = update(settings.Current).Validated();
                if (preferences == settings.Current) return;
                settings.Save(preferences); showStatus("弹幕设置已保存。");
            }
            catch (Exception ex) { restore(); showStatus(ex.Message); }
        }

        void Bind(ToggleSwitch toggle, Func<DanmakuPreferences, bool, DanmakuPreferences> update)
        {
            var reverting = false;
            toggle.Toggled += (_, _) =>
            {
                if (reverting) return;
                try
                {
                    // Save just this switch against the latest preferences;
                    // unrelated text fields may still contain unfinished input.
                    settings.Save(update(settings.Current, toggle.IsOn));
                    showStatus("弹幕设置已保存。");
                }
                catch (Exception ex)
                {
                    reverting = true;
                    try { toggle.IsOn = !toggle.IsOn; }
                    finally { reverting = false; }
                    showStatus(ex.Message);
                }
            };
        }
    }

    public DanmakuPreferences Read() => (_original with
    {
        GatewayUrl = _gateway.Text, ApiKey = _key.Password, AutoLoad = _automatic.IsOn, Enabled = _enabled.IsOn,
        FontSize = _font.Value, Opacity = _opacity.Value / 100, DisplayArea = _area.Value / 100,
        BlockTop = _top.IsOn, BlockBottom = _bottom.IsOn, BlockScroll = _scroll.IsOn, MergeDuplicates = _merge.IsOn, AllowStacking = _stack.IsOn,
        UseKernelRenderer = _kernel.IsOn, AnimeSkipClientId = _animeSkip.Text
    }).Validated();
}
