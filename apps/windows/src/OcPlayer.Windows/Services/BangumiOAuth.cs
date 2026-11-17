using System.Text.Json;

namespace OcPlayer.Windows.Services;

internal sealed record BangumiGateway(string BaseUrl, string ApiKey);
internal sealed class BangumiOAuthRejectedException() : InvalidOperationException("Bangumi 授权已失效，请重新登录。");

internal sealed partial class ViewingIntegrations
{
    private readonly object _bangumiGate = new();
    private readonly SemaphoreSlim _bangumiRefresh = new(1);
    private long _bangumiRevision;
    private CancellationTokenSource? _oauthCancellation;
    private long BangumiRevision { get { lock (_bangumiGate) return _bangumiRevision; } }
    private long BeginBangumiOperation()
    {
        lock (_bangumiGate) { _oauthCancellation?.Cancel(); return ++_bangumiRevision; }
    }
    public void CancelBangumiOAuth() => BeginBangumiOperation();
    private void CheckBangumi(long revision, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (revision != _bangumiRevision) throw new OperationCanceledException("登录操作已失效。", token);
    }
    private void CommitBangumi(IntegrationAccount account, long revision, CancellationToken token)
    {
        lock (_bangumiGate) { CheckBangumi(revision, token); Save("bangumi", account); ++_bangumiRevision; }
    }

    public async Task ConnectBangumiOAuth(string api, string gatewayAddress, string apiKey,
        Func<Uri, string, CancellationToken, Task<string>> authorize, CancellationToken token)
    {
        api = MediaServer.NormalizeAddress(api) + "/";
        var gateway = new BangumiGateway(MediaServer.NormalizeAddress(gatewayAddress), apiKey.Trim());
        if (gateway.ApiKey.Length == 0) throw new ArgumentException("请输入带 bgm:oauth 权限的网关 API Key。");
        var revision = BeginBangumiOperation();
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token);
        lifetime.CancelAfter(TimeSpan.FromMinutes(10));
        lock (_bangumiGate) { CheckBangumi(revision, token); _oauthCancellation = lifetime; }
        var state = Guid.NewGuid().ToString("N");
        try
        {
            var payload = await GatewayRequest(gateway, "authorize?state=" + state, null, lifetime.Token);
            var url = AuthorizationUrl(payload, api, state);
            var callback = await authorize(url, state, lifetime.Token);
            lock (_bangumiGate) CheckBangumi(revision, lifetime.Token);
            var query = BangumiOAuthCallback.Parse(callback);
            if (query.State != state) throw new InvalidOperationException("授权校验失败，请重新发起登录。");
            if (query.Error is not null) throw new InvalidOperationException(query.Error == "access_denied" ? "你已取消 Bangumi 授权。" : "Bangumi 授权失败，请重新登录。");
            // This attempt consumes exactly one callback. Token exchange is never retried by the host.
            var credentials = await GatewayRequest(gateway, "token", new { code = query.Code }, lifetime.Token);
            var candidate = TokenAccount(new(api, "", "", "", IsEnabled("bangumi"), OAuthGateway: gateway), credentials);
            var profile = DecodeBangumi(await Request("bangumi.request", candidate, new { url = BangumiDomains.NextApi(api) + "p1/me", httpMethod = "GET" }, lifetime.Token));
            var username = Json.Text(profile, "username");
            if (string.IsNullOrWhiteSpace(username)) throw new InvalidOperationException("Bangumi 未返回有效账号，原连接已保留。");
            CommitBangumi(candidate with { UserName = username, DisplayName = Json.First(profile, "nickname", "username"), Avatar = Json.First(Json.Get(profile, "avatar"), "large", "medium", "small") }, revision, lifetime.Token);
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested && revision == BangumiRevision)
        { throw new InvalidOperationException("授权等待已超时，请重新发起登录。"); }
        finally { lock (_bangumiGate) if (ReferenceEquals(_oauthCancellation, lifetime)) _oauthCancellation = null; }
    }
    internal static Uri AuthorizationUrl(JsonElement payload, string api, string state)
    {
        if (!Uri.TryCreate(Json.Text(payload, "authorize_url"), UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.UserInfo.Length > 0 || uri.Fragment.Length > 0)
            throw new InvalidOperationException("网关返回的授权地址无效。");
        var query = BangumiOAuthCallback.Query(uri);
        if (!query.TryGetValue("state", out var returnedState) || returnedState != state || uri.AbsolutePath != "/oauth/authorize" || !uri.IsDefaultPort || uri.Host is not ("bgm.tv" or "bangumi.tv" or "chii.in"))
            throw new InvalidOperationException("网关授权地址或 state 不匹配，请检查网关配置。");
        if (query.TryGetValue("redirect_uri", out var redirect) && redirect != BangumiOAuthCallback.RedirectUri)
            throw new InvalidOperationException("网关回调地址须配置为 ocplayer://oauth/callback。");
        // Same mirror rule as macOS: only the browser authorization host changes.
        var apiUri = new Uri(api); var apiHost = apiUri.Host;
        return apiHost.StartsWith("api.") && apiHost != "api.bgm.tv" ? new UriBuilder(uri) { Host = apiHost[4..], Scheme = apiUri.Scheme, Port = apiUri.Port }.Uri : uri;
    }
    private async Task<JsonElement> GatewayRequest(BangumiGateway gateway, string endpoint, object? body, CancellationToken token)
    {
        // Match macOS: gateway routes are rooted at /v1, independent of API mirror.
        var url = new Uri(new Uri(gateway.BaseUrl), "/v1/bangumi/oauth/" + endpoint).AbsoluteUri;
        var response = await Call("bangumi.request", new { baseURL = gateway.BaseUrl, url, httpMethod = body is null ? "GET" : "POST", body,
            headers = new Dictionary<string, string> { ["X-API-Key"] = gateway.ApiKey, ["User-Agent"] = "OcPlay/0.3 (Windows; Bangumi OAuth)" } }, token);
        var status = (int)Json.Number(response, "status");
        JsonElement payload;
        try { using var document = JsonDocument.Parse(Json.Text(response, "body")); payload = document.RootElement.Clone(); }
        catch (JsonException) { throw new InvalidOperationException($"网关未返回有效 JSON（HTTP {status}）。"); }
        var error = Json.Text(Json.Get(payload, "error"), "code");
        if (status is >= 200 and < 300 && Json.Get(payload, "success").ValueKind != JsonValueKind.False) return payload;
        throw error switch
        {
            "BANGUMI_OAUTH_REJECTED" => new BangumiOAuthRejectedException(),
            "SCOPE_REQUIRED" => new InvalidOperationException("网关 API Key 缺少 bgm:oauth 权限。"),
            "OCPLAY_USER_AGENT_REQUIRED" => new InvalidOperationException("网关拒绝了请求标识，请更新 App 后重试。"),
            "GATEWAY_NOT_CONFIGURED" => new InvalidOperationException("网关尚未配置 Bangumi 登录。"),
            _ => new InvalidOperationException(status == 401 ? "网关 API Key 无效，请检查设置。" : $"OAuth 网关请求失败（HTTP {status}），请稍后重试。")
        };
    }
    private static IntegrationAccount TokenAccount(IntegrationAccount account, JsonElement token)
    {
        var access = Json.Text(token, "access_token");
        var expires = Json.Number(token, "expires_in", 604800);
        if (string.IsNullOrWhiteSpace(access) || expires <= 0 || expires > 315360000)
            throw new InvalidOperationException("网关返回的登录令牌无效。");
        return account with { AccessToken = access, RefreshToken = Json.Text(token, "refresh_token") is { Length: > 0 } refresh ? refresh : account.RefreshToken,
            ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(expires) };
    }
    private async Task<IntegrationAccount> RefreshBangumi(long revision, IntegrationAccount observed, bool force, CancellationToken token)
    {
        await _bangumiRefresh.WaitAsync(token);
        try
        {
            IntegrationAccount account;
            lock (_bangumiGate) { CheckBangumi(revision, token); account = RequireAccount(Bangumi, "Bangumi"); }
            if (account.OAuthGateway is null || !ReferenceEquals(account, observed) || !force && account.ExpiresAt > DateTimeOffset.UtcNow.AddSeconds(60)) return account;
            JsonElement payload;
            try
            {
                if (string.IsNullOrEmpty(account.RefreshToken)) throw new BangumiOAuthRejectedException();
                payload = await GatewayRequest(account.OAuthGateway, "refresh", new { refresh_token = account.RefreshToken }, token);
            }
            catch (BangumiOAuthRejectedException)
            {
                lock (_bangumiGate)
                {
                    CheckBangumi(revision, token);
                    if (ReferenceEquals(Bangumi, account))
                    {
                        Save("bangumi", account with { AccessToken = "", RefreshToken = null, ExpiresAt = null, Enabled = false });
                        ++_bangumiRevision;
                    }
                }
                throw;
            }
            var renewed = TokenAccount(account, payload);
            lock (_bangumiGate)
            {
                CheckBangumi(revision, token);
                if (!ReferenceEquals(Bangumi, account)) throw new OperationCanceledException("登录账号已更换。", token);
                Save("bangumi", renewed);
            }
            return renewed;
        }
        finally { _bangumiRefresh.Release(); }
    }
    private async Task<JsonElement> BangumiRequest(string method, object? args, CancellationToken token, long? expectedRevision = null)
    {
        var revision = expectedRevision ?? BangumiRevision;
        IntegrationAccount account;
        lock (_bangumiGate) { CheckBangumi(revision, token); account = RequireAccount(Bangumi, "Bangumi"); }
        if (account.OAuthGateway is not null) account = await RefreshBangumi(revision, account, false, token);
        JsonElement result;
        try { result = await Request("bangumi." + method, account, args, token); }
        catch (IntegrationRequestException ex) when (ex.Code == 2001 && account.OAuthGateway is not null)
        {
            account = await RefreshBangumi(revision, account, true, token);
            result = await Request("bangumi." + method, account, args, token);
        }
        lock (_bangumiGate) CheckBangumi(revision, token);
        return result;
    }
}

internal sealed record BangumiOAuthCallback(string State, string? Code, string? Error)
{
    public const string RedirectUri = "ocplayer://oauth/callback";
    public static BangumiOAuthCallback Parse(string value)
    {
        if (value.Length > 8192 || !Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != "ocplayer" || uri.Host != "oauth" || uri.AbsolutePath != "/callback" || uri.UserInfo.Length > 0 || uri.Fragment.Length > 0 || !uri.IsDefaultPort)
            throw new InvalidOperationException("OAuth 回调地址无效。");
        var query = Query(uri);
        if (!query.TryGetValue("state", out var state) || state.Length != 32 || !state.All(char.IsAsciiHexDigit)) throw new InvalidOperationException("授权校验失败，请重新发起登录。");
        query.TryGetValue("code", out var code); query.TryGetValue("error", out var error);
        if ((string.IsNullOrWhiteSpace(code) && string.IsNullOrWhiteSpace(error)) || code is not null && error is not null) throw new InvalidOperationException("OAuth 回调缺少授权结果。");
        return new(state, code, error);
    }
    internal static Dictionary<string, string> Query(Uri uri)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var pair = part.Split('=', 2);
            var key = Uri.UnescapeDataString(pair[0].Replace('+', ' '));
            var value = pair.Length == 2 ? Uri.UnescapeDataString(pair[1].Replace('+', ' ')) : "";
            if (!result.TryAdd(key, value)) throw new InvalidOperationException("OAuth 回调包含重复参数。");
        }
        return result;
    }
}
