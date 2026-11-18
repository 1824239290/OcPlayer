using System.Diagnostics;
using Microsoft.Win32;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Services;

internal static partial class Program
{
    private static async Task VerifyBangumiOAuth(OcpCoreClient core)
    {
        VerifyBangumiProtocolRegistration();
        await VerifyBangumiEndpointSelection(core);
        using var fixture = new ViewingFixture();
        var resource = "OcPlayer.OAuthTest." + Guid.NewGuid().ToString("N");
        var service = new ViewingIntegrations(core, resource);
        string Callback(string state) => "ocplayer://oauth/callback?code=fixture-code&state=" + state;
        Task<string> Authorize(Uri uri, string state, CancellationToken token)
        {
            Assert(uri.Host == "bgm.tv" && BangumiOAuthCallback.Query(uri)["state"] == state, "gateway authorization URL retains a unique verified state");
            return Task.FromResult(Callback(state));
        }
        Task Login(Func<Uri, string, CancellationToken, Task<string>>? browser = null, CancellationToken token = default) =>
            service.ConnectBangumiOAuth(fixture.Url, fixture.Url + "configured/path", "fixture-gateway-key", browser ?? Authorize, token);
        try
        {
            await Login();
            Assert(service.Bangumi is { AccessToken: "oauth-access", RefreshToken: "oauth-refresh", UserName: "fixture", OAuthGateway: not null }, "OAuth exchanges code through the gateway and verifies p1 profile before commit");
            Assert(fixture.GatewayHeadersCorrect && fixture.OAuthTokenCalls == 1, "gateway uses X-API-Key and OcPlay user agent without leaking a Bangumi Bearer token");
            var restored = new ViewingIntegrations(core, resource);
            Assert(restored.Bangumi?.RefreshToken == "oauth-refresh" && restored.Bangumi.OAuthGateway?.ApiKey == "fixture-gateway-key", "OAuth refresh token and gateway credentials restore from PasswordVault");
            var previous = service.Bangumi; var calls = fixture.OAuthTokenCalls;
            foreach (var callback in new[] { Callback(new string('a', 32)), "ocplayer://oauth/other?code=x&state=" + new string('a', 32) })
            {
                try { await Login((_, _, _) => Task.FromResult(callback)); throw new Exception("Forged callback accepted"); }
                catch (InvalidOperationException) { Assert(ReferenceEquals(previous, service.Bangumi) && fixture.OAuthTokenCalls == calls, "invalid callbacks cannot exchange tokens or replace an existing account"); }
            }
            try { await Login((_, state, _) => Task.FromResult("ocplayer://oauth/callback?error=access_denied&state=" + state)); throw new Exception("Denied authorization accepted"); }
            catch (InvalidOperationException ex) { Assert(ex.Message.Contains("取消") && ReferenceEquals(previous, service.Bangumi), "user denial preserves the previous account and reports cancellation"); }
            fixture.FailOAuthProfile = true;
            try { await Login(); throw new Exception("Bad profile committed"); }
            catch (InvalidOperationException) { Assert(ReferenceEquals(previous, service.Bangumi), "failed profile verification never publishes new OAuth tokens"); }
            fixture.FailOAuthProfile = false;
            fixture.OAuthGatewayError = "SCOPE_REQUIRED";
            try { await Login(); throw new Exception("Missing scope accepted"); }
            catch (InvalidOperationException ex) { Assert(ex.Message.Contains("bgm:oauth"), "missing gateway scope has an actionable error"); }
            fixture.OAuthGatewayError = null;
            fixture.TokenEntered = new(TaskCreationOptions.RunContinuationsAsynchronously); fixture.TokenRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var pending = Login(); await fixture.TokenEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            service.CancelBangumiOAuth(); fixture.TokenRelease.TrySetResult();
            try { await pending; throw new Exception("Cancelled token committed"); }
            catch (OperationCanceledException) { Assert(ReferenceEquals(previous, service.Bangumi), "cancel during token exchange retires the pending response"); }
            fixture.TokenEntered = fixture.TokenRelease = null;
            var browserEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var oldCallback = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously); string? oldState = null;
            var oldLogin = Login((_, state, _) => { oldState = state; browserEntered.TrySetResult(); return oldCallback.Task; });
            await browserEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)); await Login(); previous = service.Bangumi;
            oldCallback.TrySetResult(Callback(oldState!));
            try { await oldLogin; throw new Exception("Old login replaced new login"); }
            catch (OperationCanceledException) { Assert(ReferenceEquals(previous, service.Bangumi), "a late browser callback cannot replace a newer successful login"); }
            fixture.RejectOldOAuthAccess = true; var before401 = fixture.OAuthRefreshCalls;
            await service.Bgm("episodes", new { subjectId = 1 }, default);
            Assert(fixture.OAuthRefreshCalls == before401 + 1 && service.Bangumi?.AccessToken == "oauth-renewed", "a server 401 refreshes once and retries with the renewed token");
            fixture.RejectOldOAuthAccess = false;
            fixture.OAuthExpires = 1; await Login();
            var refreshCalls = fixture.OAuthRefreshCalls;
            await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => service.Bgm("episodes", new { subjectId = 1, limit = 100, offset = 0 }, default)));
            Assert(fixture.OAuthRefreshCalls == refreshCalls + 1 && service.Bangumi?.AccessToken == "oauth-renewed" && service.Bangumi.RefreshToken == "oauth-refresh", "concurrent expired requests refresh once and preserve an unrotated refresh token");
            await Login(); fixture.FailOAuthRefresh = true; previous = service.Bangumi;
            try { await service.Bgm("episodes", new { subjectId = 1 }, default); throw new Exception("Gateway outage accepted"); }
            catch (InvalidOperationException) { Assert(ReferenceEquals(previous, service.Bangumi), "temporary gateway failure preserves saved login credentials"); }
            fixture.FailOAuthRefresh = false; fixture.RejectOAuthRefresh = true;
            try { await service.Bgm("episodes", new { subjectId = 1 }, default); throw new Exception("Revoked refresh accepted"); }
            catch (BangumiOAuthRejectedException) { Assert(service.Bangumi is { Enabled: false, AccessToken: "", RefreshToken: null, OAuthGateway: not null }, "revoked refresh invalidates credentials while keeping gateway configuration for relogin"); }
            fixture.RejectOAuthRefresh = false; await Login();
            fixture.RefreshEntered = new(TaskCreationOptions.RunContinuationsAsynchronously); fixture.RefreshRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var refresh = service.Bgm("episodes", new { subjectId = 1 }, default); await fixture.RefreshEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await service.Logout("bangumi"); fixture.RefreshRelease.TrySetResult();
            try { await refresh; throw new Exception("Refresh resurrected login"); }
            catch (OperationCanceledException) { Assert(service.Bangumi is null, "logout wins over an in-flight token refresh"); }
            var state = Guid.NewGuid().ToString("N");
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            Task? forwarded = null;
            var received = await BangumiOAuthBrowser.Receive(state, () => forwarded = BangumiOAuthBrowser.Forward(Callback(state), timeout.Token), timeout.Token);
            await forwarded!;
            Assert(received == Callback(state), "Windows per-user named pipe delivers and acknowledges the original callback");
            using var expired = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
            try { await BangumiOAuthBrowser.Forward(Callback(state), expired.Token); throw new Exception("Replayed callback delivered"); }
            catch (OperationCanceledException) { Assert(true, "consumed callback cannot reconnect to a retired authorization pipe"); }
            try { BangumiOAuthCallback.Parse(Callback(state) + "&state=" + state); throw new Exception("Duplicate state accepted"); }
            catch (InvalidOperationException) { Assert(true, "duplicate OAuth parameters are rejected"); }
        }
        finally
        {
            fixture.TokenRelease?.TrySetResult(); fixture.RefreshRelease?.TrySetResult();
            await service.Logout("bangumi");
        }
    }
    private static async Task VerifyBangumiEndpointSelection(OcpCoreClient core)
    {
        Assert(BangumiDomains.NextApi("http://127.0.0.1:1234/proxy") == "http://127.0.0.1:1234/proxy/",
            "custom Bangumi service roots retain their protocol, port and subpath");
        foreach (var (api, next) in new[] {
            ("https://api.bgm.tv/", "https://next.bgm.tv/"),
            ("https://api.bangumi.lat/", "https://next.bangumi.lat/"),
            ("https://api.mirror.example:8443/", "https://next.mirror.example:8443/") })
        {
            using var v0Service = new ViewingFixture { RejectP1 = true };
            using var nextService = new ViewingFixture();
            using var gateway = new ViewingFixture();
            var requests = new List<(string Method, string Base, string Url)>();
            Task<OcpResponse> Call(string method, string arguments, CancellationToken token)
            {
                var input = System.Text.Json.Nodes.JsonNode.Parse(arguments)!.AsObject();
                var serviceRoot = input["baseURL"]!.GetValue<string>();
                var url = input["url"]?.GetValue<string>() ?? "";
                requests.Add((method, serviceRoot, url));
                // Preserve the production host selection; route each separate
                // service to its own local HTTP fixture for the real Core.
                string Local(string original)
                {
                    var uri = new Uri(original);
                    if (uri.Authority == new Uri(api).Authority) return new Uri(new Uri(v0Service.Url), uri.PathAndQuery).AbsoluteUri;
                    if (uri.Authority == new Uri(next).Authority) return new Uri(new Uri(nextService.Url), uri.PathAndQuery).AbsoluteUri;
                    return original;
                }
                input["baseURL"] = Local(serviceRoot);
                if (url.Length > 0) input["url"] = Local(url);
                return core.CallJSONAsync(method, input.ToJsonString(), token);
            }
            var service = new ViewingIntegrations(Call, "OcPlayer.EndpointTest." + Guid.NewGuid().ToString("N"));
            Task Login() => service.ConnectBangumiOAuth(api, gateway.Url, "fixture-gateway-key",
                (_, state, _) => Task.FromResult("ocplayer://oauth/callback?code=fixture-code&state=" + state), default);
            try
            {
                await Login();
                Assert(service.Bangumi is { UserName: "fixture", DisplayName: "Fixture BGM", Avatar: "https://lain.bgm.tv/avatar.jpg" }
                    && service.Bangumi.BaseUrl == api && nextService.ProfileBearerCorrect,
                    $"OAuth verifies and saves the account through the distinct Next service for {api}");
                Assert(requests.Any(x => x.Url == next + "p1/me"), "OAuth profile request uses the exact Next URL with the selected mirror port");
                foreach (var (method, args) in new (string, object)[] {
                    ("subject", new { subjectId = 1 }), ("search", new { keyword = "Anime" }),
                    ("episodes", new { subjectId = 1 }), ("collections", new { limit = 1 }),
                    ("updateEpisode", new { episodeId = 12, collectionType = 2 }) })
                {
                    await service.Bgm(method, args, default);
                    Assert(requests.Last().Base == next, $"Bangumi {method} uses Next after login");
                }
                foreach (var (method, args) in new (string, object)[] {
                    ("calendar", new { }), ("updateSubject", new { subjectId = 1, body = new { type = 3 } }),
                    ("subjectCollection", new { subjectId = 1, username = "fixture" }) })
                {
                    await service.Bgm(method, args, default);
                    Assert(requests.Last().Base == api, $"Bangumi {method} retains the v0 API service");
                }
                var previous = service.Bangumi;
                nextService.RejectP1 = true;
                try { await Login(); throw new Exception("HTTP 200 API error was saved as an account"); }
                catch (InvalidOperationException ex)
                {
                    Assert(ex.Message.Contains("404") && ReferenceEquals(previous, service.Bangumi),
                        "HTTP 200 with Bangumi code=404 reports the API failure and preserves the previous account");
                }
                await service.ConnectBangumi(api, "fixture-manual-token", default);
                Assert(requests.Last().Url == api + "v0/me" && service.Bangumi?.UserName == "fixture",
                    "personal Access Token login continues to validate through v0/me");
            }
            finally { await service.Logout("bangumi"); }
        }
    }
    private static void VerifyBangumiProtocolRegistration()
    {
        var authorization = new Uri("https://bgm.tv/oauth/authorize?client_id=fixture&state=" + Guid.NewGuid().ToString("N"));
        var browser = BangumiOAuthBrowser.DefaultBrowserStartInfo(authorization);
        Assert(browser.UseShellExecute && browser.FileName == authorization.AbsoluteUri && browser.Verb != "runas",
            "OAuth opens the complete URL with the system default browser without requesting elevation");
        try { BangumiOAuthBrowser.DefaultBrowserStartInfo(new Uri("file:///C:/Windows/system32/cmd.exe")); throw new Exception("Non-web browser launch accepted"); }
        catch (ArgumentException) { Assert(true, "browser launch accepts only HTTP and HTTPS URLs"); }
        var path = @"Software\OcPlayer\OAuthProtocolTest." + Guid.NewGuid().ToString("N");
        var directory = Directory.CreateTempSubdirectory("OcPlayer OAuth ");
        try
        {
            var dotnetHost = Path.Combine(directory.FullName, "dotnet.exe");
            File.WriteAllBytes(dotnetHost, []);
            var assembly = Path.Combine(directory.FullName, "OcPlayer.Windows.dll");
            var consoleHost = Path.Combine(Environment.SystemDirectory, "conhost.exe");
            var command = BangumiOAuthBrowser.ProtocolCommand(directory.FullName, dotnetHost);
            Assert(command == $"\"{consoleHost}\" --headless \"{dotnetHost}\" \"{assembly}\" --bangumi-oauth-callback \"%1\"",
                "a private .NET runtime receives the quoted callback through a headless console");
            var appHost = Path.Combine(directory.FullName, "OcPlayer.Windows.exe");
            var directCommand = $"\"{appHost}\" --bangumi-oauth-callback \"%1\"";
            Assert(BangumiOAuthBrowser.ProtocolCommand(directory.FullName, null) == directCommand, "the system runtime uses the GUI apphost");
            File.WriteAllBytes(Path.Combine(directory.FullName, "coreclr.dll"), []);
            Assert(BangumiOAuthBrowser.ProtocolCommand(directory.FullName, dotnetHost) == directCommand, "self-contained installs always use the GUI apphost");
            using var root = Registry.CurrentUser.CreateSubKey(path, true);
            BangumiOAuthBrowser.RegisterProtocol(root, "ocplayer", $"\"{dotnetHost}\" \"{assembly}\" --bangumi-oauth-callback \"%1\"");
            BangumiOAuthBrowser.RegisterProtocol(root, "ocplayer", command);
            using (var handler = root.OpenSubKey(@"ocplayer\shell\open\command"))
                Assert(Equals(handler?.GetValue(""), command), "registration upgrades the old console handler before opening the browser");
            using var readOnly = Registry.CurrentUser.OpenSubKey(path, false)!;
            BangumiOAuthBrowser.RegisterProtocol(readOnly, "ocplayer", command);
            Assert(true, "an existing callback registration works with read-only registry access");
            try { BangumiOAuthBrowser.RegisterProtocol(readOnly, "ocplayer", command + " --new-version"); throw new Exception("Read-only registration was overwritten"); }
            catch (InvalidOperationException ex) { Assert(ex.Message.Contains("启动脚本"), "missing write access reports an actionable startup instruction"); }
            var movedCommand = BangumiOAuthBrowser.ProtocolCommand(Path.Combine(directory.FullName, "New Location"), null);
            BangumiOAuthBrowser.RegisterProtocol(root, "ocplayer", movedCommand);
            using (var handler = root.OpenSubKey(@"ocplayer\shell\open\command"))
                Assert(Equals(handler?.GetValue(""), movedCommand), "launching from a new install path updates the callback handler");
        }
        finally { Registry.CurrentUser.DeleteSubKeyTree(path, false); directory.Delete(true); }
    }
    private static async Task VerifyBangumiBrowserRoundTrip(OcpCoreClient core)
    {
        var assembly = Environment.GetEnvironmentVariable("OCP_OAUTH_APP_ASSEMBLY")
            ?? throw new InvalidOperationException("Set OCP_OAUTH_APP_ASSEMBLY to the built Windows application DLL.");
        var runtime = Environment.ProcessPath!;
        Assert(Path.GetFileName(runtime).Equals("dotnet.exe", StringComparison.OrdinalIgnoreCase), "live browser verification runs through the installed .NET host");
        using (var handler = Registry.CurrentUser.OpenSubKey(@"Software\Classes\ocplayer\shell\open\command"))
        {
            var command = handler?.GetValue("") as string ?? "";
            var directory = Path.GetDirectoryName(Path.GetFullPath(assembly))!;
            Assert(command.Equals(BangumiOAuthBrowser.ProtocolCommand(directory, runtime), StringComparison.OrdinalIgnoreCase)
                || command.Equals(BangumiOAuthBrowser.ProtocolCommand(directory, null), StringComparison.OrdinalIgnoreCase),
                "the installed ocplayer protocol targets the staged callback without opening a console window");
        }
        using var fixture = new ViewingFixture();
        var service = new ViewingIntegrations(core, "OcPlayer.BrowserRoundTrip." + Guid.NewGuid().ToString("N"));
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try
        {
            await service.ConnectBangumiOAuth(fixture.Url, fixture.Url, "fixture-gateway-key", async (_, state, token) =>
            {
                var probe = new Uri(fixture.Url + "browser-login-probe?state=" + state);
                var received = BangumiOAuthBrowser.Receive(state, () => BangumiOAuthBrowser.OpenBrowser(probe), token);
                var userAgent = await fixture.BrowserLoaded.Task.WaitAsync(token);
                Assert(userAgent.Contains("Mozilla/"), "the actual browser requests and loads the complete login probe HTML");
                Evidence.Add(new { stage = "browser-loaded", url = probe.AbsoluteUri, userAgent });
                var callbackUrl = "ocplayer://oauth/callback?code=fixture-code&state=" + state;
                using var child = Process.Start(new ProcessStartInfo(callbackUrl) { UseShellExecute = true });
                var value = await received;
                if (child is not null)
                {
                    await child.WaitForExitAsync(token);
                    Assert(child.ExitCode == 0, "the protocol callback process exits successfully after delivery");
                }
                Assert(value == callbackUrl, "shell protocol activation reaches the shipping callback and acknowledges the browser login state");
                return value;
            }, deadline.Token);
            Assert(service.Bangumi is { AccessToken: "oauth-access", UserName: "fixture" } && fixture.OAuthTokenCalls == 1,
                "browser launch and shipping callback complete code exchange and account validation through the real Core");
        }
        finally { await service.Logout("bangumi"); }
    }
}
