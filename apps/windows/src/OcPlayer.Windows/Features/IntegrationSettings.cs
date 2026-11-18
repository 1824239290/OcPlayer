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
        if (bangumi) return BangumiSettings();
        var page = new Page(); const string name = "MoviePilot", key = "moviepilot";
        var account = Service.MoviePilot;
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
                if (!await Confirm(page, "退出 " + name, "清除登录令牌、记住的密码和账号会话；保留服务器地址以便重新连接。")) return;
                await Service.Logout(key); navigate("settings:" + name);
            }));
            return Show(page);
        }
        else if (account is not null) page.Body.Children.Add(Muted("登录已失效，请重新登录。"));
        var address = new TextBox { Header = "服务器地址", Text = account?.BaseUrl ?? "", PlaceholderText = "https://…" };
        page.Body.Children.Add(address);
        var username = new TextBox { Header = "用户名", Text = account?.UserName ?? "" };
        var secret = new PasswordBox { Header = "密码" };
        var remember = new ToggleSwitch { Header = "记住密码（令牌过期后免重输）", IsOn = account?.RememberPassword ?? Service.Preference("moviepilot.rememberPassword") == "true" };
        page.Body.Children.Add(username); page.Body.Children.Add(remember);
        remember.Toggled += (_, _) => Service.RememberMoviePilotPassword(remember.IsOn);
        page.Body.Children.Add(secret);
        page.Body.Children.Add(page.Action("验证并保存连接", async () =>
        {
            await Service.ConnectMoviePilot(address.Text, username.Text, secret.Password, page.Token, remember.IsOn);
            Service.Enable(key, enabled.IsOn); secret.Password = ""; navigate("settings:" + name);
        }));
        return Show(page);
    }
}
