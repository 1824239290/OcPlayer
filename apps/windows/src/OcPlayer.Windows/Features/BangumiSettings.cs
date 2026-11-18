using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Controls;
using static OcPlayer.Windows.Controls.DemoUi;
using static OcPlayer.Windows.Features.DemoSettings;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    private static ToggleSwitch SettingsSwitch(string label, bool enabled)
    {
        var toggle = new ToggleSwitch { IsOn = enabled, OnContent = "", OffContent = "", MinWidth = 0 };
        BgmName(toggle, label);
        return toggle;
    }

    private static Button SettingsAction(Button button, bool destructive = false)
    {
        return SettingsUi.Action(button, destructive);
    }

    private UIElement BangumiSettings()
    {
        var page = new Page();
        page.Body.MaxWidth = 680;
        page.Body.Spacing = 28;
        SettingsUi.Status(page.Status);
        var rows = Stack(0);
        page.Body.Children.Add(SettingsUi.Card(rows));
        var enabled = SettingsSwitch("启用 Bangumi", Service.IsEnabled("bangumi"));
        rows.Children.Add(SettingsLine("启用 Bangumi", enabled));
        var accountRows = Stack(0);
        rows.Children.Add(accountRows);
        accountRows.Children.Add(Divider());
        if (Service.Bangumi is { AccessToken.Length: > 0 } account)
        {
            accountRows.Children.Add(SettingsLine("账号", Text(string.IsNullOrWhiteSpace(account.DisplayName) ? account.UserName : account.DisplayName)));
            accountRows.Children.Add(Divider());
            accountRows.Children.Add(SettingsAction(page.Action("退出 Bangumi", async () =>
            {
                if (!await Confirm(page, "退出 Bangumi？", "本机的授权登录会清除，远端收藏和观看记录仍会保留。")) return;
                await Service.Logout("bangumi");
                navigate("settings:Bangumi");
            }), destructive: true));
        }
        else AddBangumiLogin(page, accountRows);

        var disabledNote = SettingsUi.Caption("关闭后将隐藏顶栏与详情页的 Bangumi 入口，并保留账号和条目关联。");
        rows.Children.Add(disabledNote);
        var mirror = BangumiMirrorSettings();
        page.Body.Children.Add(mirror);
        void UpdateVisibility()
        {
            accountRows.Visibility = mirror.Visibility = enabled.IsOn ? Visibility.Visible : Visibility.Collapsed;
            disabledNote.Visibility = enabled.IsOn ? Visibility.Collapsed : Visibility.Visible;
        }
        enabled.Toggled += (_, _) => { Service.Enable("bangumi", enabled.IsOn); UpdateVisibility(); };
        UpdateVisibility();
        return Show(page);
    }

    private void AddBangumiLogin(Page page, StackPanel rows)
    {
        var login = new SplitButton { Content = "登录 Bangumi" };
        BgmName(login, "登录 Bangumi");
        rows.Children.Add(SettingsLine("账号", login));
        var status = Muted("");
        status.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) =>
            status.Visibility = status.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible);
        status.Text = Service.Bangumi is null ? "" : "登录已失效，请重新登录。";
        status.Visibility = status.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        rows.Children.Add(status);
        var cancel = Button("取消授权", Service.CancelBangumiOAuth);
        cancel.Visibility = Visibility.Collapsed;
        rows.Children.Add(cancel);
        login.Click += async (_, _) =>
        {
            login.IsEnabled = false;
            cancel.Visibility = Visibility.Visible;
            try
            {
                await page.Run(async () =>
                {
                    var gateway = App.Core!.Danmaku.Settings.Current;
                    status.Text = "正在连接登录网关…";
                    await Service.ConnectBangumiOAuth(Service.Domains.Api, gateway.EffectiveUrl, gateway.EffectiveKey, async (url, state, token) =>
                    {
                        var callback = await Services.BangumiOAuthBrowser.Authorize(url, state, token, () => status.Text = "请在浏览器中完成授权…");
                        activate?.Invoke();
                        status.Text = "正在验证账号…";
                        return callback;
                    }, page.Token);
                    navigate("settings:Bangumi");
                }, status);
            }
            finally { cancel.Visibility = Visibility.Collapsed; login.IsEnabled = true; }
        };
        var menu = new MenuFlyout();
        var manual = new MenuFlyoutItem { Text = "使用个人 Access Token" };
        manual.Click += async (_, _) => await page.Run(async () =>
        {
            var secret = new PasswordBox { Header = "个人 Access Token" };
            var dialog = new ContentDialog { XamlRoot = rows.XamlRoot, Title = "连接 Bangumi", Content = secret, PrimaryButtonText = "验证并登录", CloseButtonText = "取消" };
            using var registration = page.Token.Register(() => rows.DispatcherQueue.TryEnqueue(dialog.Hide));
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            await Service.ConnectBangumi(Service.Domains.Api, secret.Password, page.Token);
            navigate("settings:Bangumi");
        }, status);
        menu.Items.Add(manual);
        login.Flyout = menu;
    }

    private StackPanel BangumiMirrorSettings()
    {
        var section = Stack(8);
        section.Children.Add(SettingsUi.Caption("镜像源", 13));
        var rows = Stack(0);
        section.Children.Add(SettingsUi.Card(rows));
        var mirror = SettingsSwitch("使用镜像源", Service.MirrorEnabled);
        rows.Children.Add(SettingsLine("使用镜像源", mirror));
        var note = SettingsUi.Caption(""); note.Margin = new Thickness(0, 3, 0, 0);
        rows.Children.Add(note);
        var details = Stack(0);
        rows.Children.Add(details);
        var root = new TextBox { Text = Service.MirrorRoot, PlaceholderText = "例：bangumi.lat", Width = 180, TextAlignment = TextAlignment.Right };
        BgmName(root, "镜像根域");
        var api = Text("");
        var images = Text("");
        var error = Muted("");
        void AddRow(UIElement row) { details.Children.Add(Divider()); details.Children.Add(row); }
        AddRow(SettingsLine("镜像根域", root));
        details.Children.Add(error);
        AddRow(SettingsLine("当前 API", api));
        AddRow(SettingsLine("当前图床", images));
        AddRow(SettingsAction(Button("填入示例 bangumi.lat", () => root.Text = "bangumi.lat")));
        var resetting = false;
        AddRow(SettingsAction(Button("恢复官方直连", () =>
        {
            Service.ConfigureMirror(false, "", clear: true);
            resetting = true;
            try { mirror.IsOn = false; root.Text = ""; }
            finally { resetting = false; }
            Refresh();
        }), destructive: true));
        section.Children.Add(SettingsUi.Caption("只填根域，可带端口。API 使用 api.<根域>，图床使用 lain.<根域>，章节与收藏使用 next.<根域>，登录授权使用根域。调整镜像会保留登录状态。"));
        void Refresh(string problem = "")
        {
            note.Text = mirror.IsOn ? "条目、收藏、章节与封面使用镜像，登录授权页使用镜像主站。" : "当前直连官方域名。开启后可填写镜像根域。";
            details.Visibility = mirror.IsOn ? Visibility.Visible : Visibility.Collapsed;
            error.Text = problem;
            error.Visibility = problem.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            api.Text = new Uri(Service.Domains.Api).Authority;
            images.Text = new Uri(Service.Domains.Images).Authority;
        }
        void Apply()
        {
            if (resetting) return;
            try { Service.ConfigureMirror(mirror.IsOn, root.Text); Refresh(); }
            catch (ArgumentException ex) { Refresh(ex.Message); }
        }
        mirror.Toggled += (_, _) => Apply();
        root.TextChanged += (_, _) => Apply();
        Refresh();
        return section;
    }
}
