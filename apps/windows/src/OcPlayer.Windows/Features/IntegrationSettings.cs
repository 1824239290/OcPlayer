using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    private static void Submit(TextBox text, Page page, Func<Task> action) => text.KeyDown += async (_, e) => { if (e.Key == global::Windows.System.VirtualKey.Enter) { e.Handled = true; await page.Run(action); } };
    private static void Browse(string url) { if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https") System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); }
    private void Reconnect(Page page) => page.Body.Children.Add(page.Action("重新登录 MoviePilot", () => ReconnectMoviePilot(page)));
    private async Task ReconnectMoviePilot(Page page)
    {
        var account = Service.MoviePilot; var fields = Stack(10); var address = new TextBox { Header = "服务器地址", Text = account?.BaseUrl ?? "" }; var username = new TextBox { Header = "用户名", Text = account?.UserName ?? "" }; var password = new PasswordBox { Header = "密码" }; var remember = new ToggleSwitch { Header = "记住密码（令牌过期后免重输）", IsOn = account?.RememberPassword == true }; var error = Muted("");
        foreach (var item in new UIElement[] { address, username, password, remember, error }) fields.Children.Add(item);
        var dialog = new ContentDialog { XamlRoot = page.Body.XamlRoot, Title = "重新登录 MoviePilot", Content = fields, PrimaryButtonText = "登录", CloseButtonText = "取消" };
        remember.Toggled += (_, _) => Service.RememberMoviePilotPassword(remember.IsOn);
        dialog.PrimaryButtonClick += async (_, e) => { var deferral = e.GetDeferral(); e.Cancel = true; dialog.IsPrimaryButtonEnabled = false; try { await Service.ConnectMoviePilot(address.Text, username.Text, password.Password, page.Token, remember.IsOn); e.Cancel = false; } catch (Exception ex) { error.Text = ex.Message; } finally { dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); } };
        using var registration = page.Token.Register(() => page.Body.DispatcherQueue.TryEnqueue(dialog.Hide));
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) page.Status.Text = "登录成功，请重试刚才的操作。";
    }
    public UIElement Settings(bool bangumi)
    {
        var page = new Page(); var name = bangumi ? "Bangumi" : "MoviePilot"; var key = bangumi ? "bangumi" : "moviepilot";
        var account = bangumi ? Service.Bangumi : Service.MoviePilot;
        var connectedAccount = account is { AccessToken.Length: > 0 } ? account : null;
        page.Body.MaxWidth = 720; page.Body.Children.Add(Text(name, 22, true));
        var enabled = new ToggleSwitch { Header = "启用 " + name, IsOn = Service.IsEnabled(key) };
        enabled.Toggled += async (_, _) => await page.Run(() => { Service.Enable(key, enabled.IsOn); return Task.CompletedTask; }); page.Body.Children.Add(enabled);
        if (connectedAccount is not null)
        {
            page.Body.Children.Add(Text("当前账号：" + connectedAccount.DisplayName + " @" + connectedAccount.UserName));
            page.Body.Children.Add(Button("打开 " + name, () => navigate("viewing:" + key)));
            page.Body.Children.Add(page.Action("退出 " + name, async () =>
            {
                if (!await Confirm(page, "退出 " + name, bangumi ? "清除本机登录令牌；收藏和观看记录仍保留在 Bangumi。" : "清除登录令牌、记住的密码和账号会话；保留服务器地址以便重新连接。")) return;
                await Service.Logout(key); navigate("settings:" + name);
            }));
            if (!bangumi) return Show(page);
        }
        else if (account is not null) page.Body.Children.Add(Muted("登录已失效，请重新登录。"));
        var address = new TextBox { Header = bangumi ? "当前 API" : "服务器地址", Text = bangumi ? Service.Domains.Api : account?.BaseUrl ?? "", IsReadOnly = bangumi, PlaceholderText = "https://…" };
        if (bangumi)
        {
            var mirror = new ToggleSwitch { Header = "使用镜像源", IsOn = Service.MirrorEnabled };
            var root = new TextBox { Header = "镜像根域名", Text = Service.MirrorRoot, PlaceholderText = "例如 bangumi.lat；可带协议和端口" };
            var actual = Muted("");
            void Apply(bool clear = false)
            {
                try { Service.ConfigureMirror(mirror.IsOn, root.Text, clear); address.Text = Service.Domains.Api; actual.Text = "当前 API：" + Service.Domains.Api + "\n当前图床：" + Service.Domains.Images + "\n当前 Next：" + Service.Domains.Next + "\n主站及授权：" + Service.Domains.Main; }
                catch (ArgumentException ex) { actual.Text = ex.Message; }
            }
            mirror.Toggled += (_, _) => Apply(); root.TextChanged += (_, _) => Apply();
            page.Body.Children.Add(mirror); page.Body.Children.Add(root); page.Body.Children.Add(actual);
            var actions = Row(8); actions.Children.Add(Button("填入示例 bangumi.lat", () => root.Text = "bangumi.lat"));
            actions.Children.Add(Button("恢复官方直连", () => { mirror.IsOn = false; root.Text = ""; Apply(true); })); page.Body.Children.Add(actions);
            actual.Text = "当前 API：" + (account?.BaseUrl ?? Service.Domains.Api) + "\n当前图床：" + Service.Domains.Images + "\n当前 Next：" + Service.Domains.Next + "\n主站及授权：" + Service.Domains.Main;
        }
        page.Body.Children.Add(address);
        if (bangumi && connectedAccount is not null) return Show(page);
        if (bangumi)
        {
            var oauth = Stack(12); oauth.Children.Add(Text("浏览器授权登录", 18, true));
            oauth.Children.Add(Muted("登录共用弹幕设置中的网关，授权在系统浏览器完成并自动返回。"));
            var loginStatus = Muted("");
            var cancel = Button("取消授权", () => Service.CancelBangumiOAuth()); cancel.Visibility = Visibility.Collapsed;
            oauth.Children.Add(page.Action("使用浏览器登录 Bangumi", async () =>
            {
                var gateway = App.Core!.Danmaku.Settings.Current;
                loginStatus.Text = "正在连接登录网关…";
                cancel.Visibility = Visibility.Visible;
                try { await Service.ConnectBangumiOAuth(Service.Domains.Api, gateway.EffectiveUrl, gateway.EffectiveKey, async (url, state, token) => { loginStatus.Text = "正在打开浏览器…"; var callback = await BangumiOAuthBrowser.Authorize(url, state, token, () => loginStatus.Text = "请在浏览器中完成授权…"); activate?.Invoke(); loginStatus.Text = "正在完成登录并验证账号…"; return callback; }, page.Token); Service.Enable(key, enabled.IsOn); navigate("settings:Bangumi"); }
                finally { cancel.Visibility = Visibility.Collapsed; }
            }, loginStatus));
            oauth.Children.Add(cancel); oauth.Children.Add(loginStatus); page.Body.Children.Add(Panel(oauth));
        }
        var username = new TextBox { Header = "用户名", Text = account?.UserName ?? "" };
        var secret = new PasswordBox { Header = bangumi ? "Access Token" : "密码" };
        var remember = new ToggleSwitch { Header = "记住密码（令牌过期后免重输）", IsOn = account?.RememberPassword ?? Service.Preference("moviepilot.rememberPassword") == "true" };
        if (!bangumi)
        {
            page.Body.Children.Add(username); page.Body.Children.Add(remember);
            remember.Toggled += (_, _) => Service.RememberMoviePilotPassword(remember.IsOn);
        }
        else page.Body.Children.Add(Muted("也可使用个人 Access Token 手动连接。登录凭据只存储在 Windows 凭据管理器。"));
        page.Body.Children.Add(secret);
        page.Body.Children.Add(page.Action("验证并保存连接", async () =>
        {
            if (bangumi) await Service.ConnectBangumi(Service.Domains.Api, secret.Password, page.Token);
            else await Service.ConnectMoviePilot(address.Text, username.Text, secret.Password, page.Token, remember.IsOn);
            Service.Enable(key, enabled.IsOn); secret.Password = ""; navigate("settings:" + name);
        }));
        return Show(page);
    }
}
