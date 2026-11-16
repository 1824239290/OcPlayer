using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.Features;

internal sealed class DanmakuSettingsEditor
{
    private readonly DanmakuPreferences _original;
    private readonly TextBox _gateway, _animeSkip;
    private readonly PasswordBox _key;
    private readonly ToggleSwitch _automatic, _enabled, _top, _bottom, _scroll, _merge, _stack, _kernel;
    private readonly NumberBox _font, _opacity, _area;
    public StackPanel Content { get; } = new() { Spacing = 14 };

    public DanmakuSettingsEditor(DanmakuPreferences preferences)
    {
        _original = preferences;
        _automatic = Toggle("自动加载弹幕", preferences.AutoLoad);
        _enabled = Toggle("显示弹幕", preferences.Enabled);
        _gateway = new TextBox { Header = "弹幕网关地址", Text = preferences.GatewayUrl, PlaceholderText = DanmakuPreferences.DefaultGateway };
        _key = new PasswordBox { Header = "网关 API Key", Password = preferences.ApiKey, PlaceholderText = "默认网关留空使用公共额度" };
        Content.Children.Add(_gateway); Content.Children.Add(_key);
        Content.Children.Add(new TextBlock { Text = "默认与 OcPlayer 共用弹幕网关。自定义网关需填写自己的 API Key。", TextWrapping = TextWrapping.Wrap, Opacity = .65 });
        var reset = new Button { Content = "恢复默认网关" };
        reset.Click += (_, _) => { _gateway.Text = ""; _key.Password = ""; };
        Content.Children.Add(reset);
        _animeSkip = new TextBox { Header = "anime-skip Client ID（可选）", Text = preferences.AnimeSkipClientId };
        Content.Children.Add(_animeSkip);
        Content.Children.Add(new TextBlock { Text = "填入后启用 anime-skip 片头源；AniSkip 与 TheIntroDB 自动启用。", TextWrapping = TextWrapping.Wrap, Opacity = .65 });
        _kernel = Toggle("用内核渲染弹幕", preferences.UseKernelRenderer);
        Content.Children.Add(new TextBlock { Text = "关闭后使用 App 层渲染。渲染路线从下次播放开始生效。", TextWrapping = TextWrapping.Wrap, Opacity = .65 });
        _font = Number("字号（11–44 pt）", preferences.FontSize, 11, 44, 2.2);
        _opacity = Number("不透明度（%）", preferences.Opacity * 100, 25, 100, 5);
        _area = Number("显示区域（%）", preferences.DisplayArea * 100, 25, 100, 5);
        _top = Toggle("屏蔽顶部弹幕", preferences.BlockTop);
        _bottom = Toggle("屏蔽底部弹幕", preferences.BlockBottom);
        _scroll = Toggle("屏蔽滚动弹幕", preferences.BlockScroll);
        _merge = Toggle("合并重复弹幕", preferences.MergeDuplicates);
        _stack = Toggle("允许弹幕重叠", preferences.AllowStacking);
    }
    private ToggleSwitch Toggle(string title, bool value)
    {
        var control = new ToggleSwitch { Header = title, IsOn = value, OnContent = "开启", OffContent = "关闭" };
        Content.Children.Add(control); return control;
    }
    private NumberBox Number(string title, double value, double min, double max, double step)
    {
        var control = new NumberBox { Header = title, Value = value, Minimum = min, Maximum = max, SmallChange = step,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        Content.Children.Add(control); return control;
    }
    public DanmakuPreferences Read() => (_original with
    {
        GatewayUrl = _gateway.Text, ApiKey = _key.Password, AutoLoad = _automatic.IsOn, Enabled = _enabled.IsOn,
        FontSize = _font.Value, Opacity = _opacity.Value / 100, DisplayArea = _area.Value / 100,
        BlockTop = _top.IsOn, BlockBottom = _bottom.IsOn, BlockScroll = _scroll.IsOn, MergeDuplicates = _merge.IsOn, AllowStacking = _stack.IsOn,
        UseKernelRenderer = _kernel.IsOn, AnimeSkipClientId = _animeSkip.Text
    }).Validated();
}
