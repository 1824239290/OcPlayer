using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using OcPlayer.Windows.Controls;
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
        var account = Service.MoviePilot; var fields = Stack(0); var address = new TextBox { Text = account?.BaseUrl ?? "" }; var username = new TextBox { Text = account?.UserName ?? "" }; var password = new PasswordBox(); var remember = SettingsSwitch("记住密码", account?.RememberPassword == true); var error = SettingsUi.Caption("");
        foreach (var (label, control) in new (string, FrameworkElement)[] { ("服务器地址", address), ("用户名", username), ("密码", password) }) SettingsUi.Add(fields, SettingsUi.Row(label, control, field: true));
        SettingsUi.Add(fields, SettingsUi.Row("记住密码", remember)); SettingsUi.Add(fields, SettingsUi.Caption("令牌过期后免重输密码。")); SettingsUi.Status(error); fields.Children.Add(error);
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
        page.Body.MaxWidth = 680; page.Body.Spacing = 28; SettingsUi.Status(page.Status);
        var rows = SettingsUi.Section(page.Body, "");
        var enabled = SettingsSwitch("启用 " + name, Service.IsEnabled(key));
        enabled.Toggled += async (_, _) => await page.Run(() => { Service.Enable(key, enabled.IsOn); return Task.CompletedTask; }); SettingsUi.Add(rows, SettingsUi.Row("启用 " + name, enabled));
        if (connectedAccount is not null)
        {
            SettingsUi.Add(rows, SettingsUi.Row("账号", SettingsUi.Value(string.IsNullOrWhiteSpace(connectedAccount.DisplayName) ? connectedAccount.UserName : connectedAccount.DisplayName)));
            SettingsUi.Add(rows, SettingsUi.Row("服务器地址", SettingsUi.Value(connectedAccount.BaseUrl)));
            SettingsUi.Add(rows, SettingsUi.Action(Button("打开 " + name, () => navigate("viewing:" + key))));
            SettingsUi.Add(rows, SettingsUi.Action(page.Action("退出 " + name, async () =>
            {
                if (!await Confirm(page, "退出 " + name, "清除登录令牌、记住的密码和账号会话；保留服务器地址以便重新连接。")) return;
                await Service.Logout(key); navigate("settings:" + name);
            }), destructive: true));
            return Show(page);
        }
        SettingsUi.Add(rows, SettingsUi.Row("状态", SettingsUi.Value(account is null ? "未连接" : "登录已失效")));
        var connection = SettingsUi.Section(page.Body, "连接服务器");
        var address = new TextBox { Text = account?.BaseUrl ?? "", PlaceholderText = "https://…", FontSize = 13 };
        var username = new TextBox { Text = account?.UserName ?? "", FontSize = 13 };
        var secret = new PasswordBox { FontSize = 13 };
        var remember = SettingsSwitch("记住密码", account?.RememberPassword ?? Service.Preference("moviepilot.rememberPassword") == "true");
        SettingsUi.Add(connection, SettingsUi.Row("服务器地址", address, field: true));
        SettingsUi.Add(connection, SettingsUi.Row("用户名", username, field: true));
        SettingsUi.Add(connection, SettingsUi.Row("密码", secret, field: true));
        SettingsUi.Add(connection, SettingsUi.Row("记住密码", remember));
        SettingsUi.Add(connection, SettingsUi.Caption("令牌过期后免重输密码。"));
        remember.Toggled += (_, _) => Service.RememberMoviePilotPassword(remember.IsOn);
        SettingsUi.Add(connection, SettingsUi.Action(page.Action("验证并保存连接", async () =>
        {
            await Service.ConnectMoviePilot(address.Text, username.Text, secret.Password, page.Token, remember.IsOn);
            Service.Enable(key, enabled.IsOn); secret.Password = ""; navigate("settings:" + name);
        })));
        return Show(page);
    }
}
