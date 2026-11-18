using System.Text.Json;
using System.Text.Json.Nodes;
using OcPlayer.CoreAdapter;

namespace OcPlayer.Windows.Services;

internal sealed record IntegrationAccount(string BaseUrl, string AccessToken, string UserName, string DisplayName, bool Enabled = true, string? Avatar = null,
    string? RefreshToken = null, DateTimeOffset? ExpiresAt = null, BangumiGateway? OAuthGateway = null,
    bool RememberPassword = false, string? Password = null);
internal sealed class IntegrationRequestException(int code) : InvalidOperationException(code switch
{
    1521 => "请求超时，请检查网络或系统代理后重试。",
    2001 or 2003 => "登录已失效，请重新连接账号。",
    _ => $"请求失败（{code}），请检查连接或重新登录。"
})
{ public int Code { get; } = code; }

/// Platform credentials and presentation adapters; all service traffic goes through Core.
internal sealed partial class ViewingIntegrations
{
    private readonly Func<string, string, CancellationToken, Task<OcpResponse>> _call;
    private readonly string _resource;
    public IntegrationAccount? Bangumi { get; private set; }
    public IntegrationAccount? MoviePilot { get; private set; }
    public event Action? Changed;

    public ViewingIntegrations(OcpCoreClient core, string resource)
        : this(core.CallJSONAsync, resource) { }
    internal ViewingIntegrations(Func<string, string, CancellationToken, Task<OcpResponse>> call, string resource)
    {
        _call = call; _resource = resource;
        Bangumi = Read("bangumi"); MoviePilot = Read("moviepilot"); InitializePreferences();
    }
    private IntegrationAccount? Read(string key)
    {
        try
        {
            var credential = new global::Windows.Security.Credentials.PasswordVault().Retrieve(_resource, key);
            credential.RetrievePassword();
            return JsonSerializer.Deserialize<IntegrationAccount>(credential.Password);
        }
        catch (System.Runtime.InteropServices.COMException) { return null; }
        catch (JsonException) { return null; }
    }
    private void Save(string key, IntegrationAccount account)
    {
        new global::Windows.Security.Credentials.PasswordVault().Add(
            new global::Windows.Security.Credentials.PasswordCredential(_resource, key, JsonSerializer.Serialize(account)));
        if (key == "bangumi") Bangumi = account; else MoviePilot = account;
        Changed?.Invoke();
    }
    public void Enable(string key, bool enabled)
    {
        SetPreference(key + ".enabled", enabled ? "true" : "false");
        if (key == "bangumi")
        {
            lock (_bangumiGate) { BeginBangumiOperation(); if (Bangumi is { } current) Save(key, current with { Enabled = enabled }); }
            return;
        }
        Interlocked.Increment(ref _moviePilotRevision);
        var account = key == "bangumi" ? Bangumi : MoviePilot;
        if (account is not null) Save(key, account with { Enabled = enabled });
    }
    public async Task Logout(string key)
    {
        if (key == "bangumi")
        {
            lock (_bangumiGate)
            {
                BeginBangumiOperation();
                var credentials = new global::Windows.Security.Credentials.PasswordVault();
                try { credentials.Remove(credentials.Retrieve(_resource, key)); }
                catch (System.Runtime.InteropServices.COMException ex) when (ex.HResult == unchecked((int)0x80070490)) { }
                Bangumi = null; Changed?.Invoke();
            }
            return;
        }
        Interlocked.Increment(ref _moviePilotRevision);
        var vault = new global::Windows.Security.Credentials.PasswordVault();
        try { vault.Remove(vault.Retrieve(_resource, key)); }
        catch (System.Runtime.InteropServices.COMException ex) when (ex.HResult == unchecked((int)0x80070490)) { }
        if (key == "bangumi") Bangumi = null;
        else if (MoviePilot is { } previous) Save("moviepilot", previous with { AccessToken = "", Password = null, RememberPassword = false, DisplayName = "" });
        Changed?.Invoke();
        if (key == "moviepilot") await Call("moviepilot.clearSessions", new { }, CancellationToken.None);
    }
    public async Task ConnectBangumi(string api, string accessToken, CancellationToken token)
    {
        var revision = BeginBangumiOperation();
        api = MediaServer.NormalizeAddress(api) + "/";
        if (string.IsNullOrWhiteSpace(accessToken)) throw new ArgumentException("请输入 Bangumi Access Token。");
        var candidate = new IntegrationAccount(api, accessToken.Trim(), "", "", IsEnabled("bangumi"));
        var response = await Request("bangumi.request", candidate, new { url = api + "v0/me", httpMethod = "GET" }, token);
        var user = DecodeBangumi(response);
        var username = Json.Text(user, "username");
        if (username.Length == 0) throw new InvalidOperationException("Bangumi 未返回有效账号。");
        token.ThrowIfCancellationRequested();
        CommitBangumi(candidate with { UserName = username, DisplayName = Json.First(user, "nickname", "username"), Avatar = Json.First(Json.Get(user, "avatar"), "large", "medium", "small") }, revision, token);
    }
    public async Task ConnectMoviePilot(string address, string username, string password, CancellationToken token, bool rememberPassword = false)
    {
        var revision = Interlocked.Increment(ref _moviePilotRevision);
        SetPreference("moviepilot.rememberPassword", rememberPassword ? "true" : "false");
        address = MediaServer.NormalizeAddress(address) + "/";
        if (string.IsNullOrWhiteSpace(username) || string.IsNullOrEmpty(password)) throw new ArgumentException("请输入账号和密码。");
        var data = await Call("moviepilot.login", new { baseURL = address, username = username.Trim(), password, validateUser = true }, token);
        var accessToken = Json.Text(data, "accessToken");
        if (accessToken.Length == 0) throw new InvalidOperationException("MoviePilot 未返回令牌。");
        token.ThrowIfCancellationRequested();
        if (revision != Interlocked.Read(ref _moviePilotRevision)) throw new OperationCanceledException("登录操作已被新的账号操作替代。", token);
        rememberPassword = Preference("moviepilot.rememberPassword") == "true";
        Save("moviepilot", new(address, accessToken, username.Trim(), Json.First(Json.Get(data, "user"), "name", "username"), IsEnabled("moviepilot"), RememberPassword: rememberPassword, Password: rememberPassword ? password : null));
    }
    public Task<JsonElement> Bgm(string method, object? args, CancellationToken token) => BangumiRequest(method, args, token);
    public Task<JsonElement> Mp(string method, object? args, CancellationToken token) => MoviePilotRequest(method, args, token);
    private static IntegrationAccount RequireAccount(IntegrationAccount? account, string name) =>
        account is { Enabled: true, AccessToken.Length: > 0 } ? account : throw new InvalidOperationException("请在设置中连接并启用 " + name + "。");
    private Task<JsonElement> Request(string method, IntegrationAccount account, object? args, CancellationToken token)
    {
        var node = JsonSerializer.SerializeToNode(args ?? new { })!.AsObject();
        node["baseURL"] = method is "bangumi.subject" or "bangumi.search" or "bangumi.episodes" or "bangumi.collections" or "bangumi.updateEpisode"
            ? BangumiDomains.NextApi(account.BaseUrl) : account.BaseUrl;
        node["accessToken"] = account.AccessToken;
        return Call(method, node, token);
    }
    private async Task<JsonElement> Call(string method, object args, CancellationToken token)
    {
        var response = await _call(method, JsonSerializer.Serialize(args), token);
        token.ThrowIfCancellationRequested();
        if (!response.Ok) throw new IntegrationRequestException(response.Code);
        return response.Data.Clone();
    }
    internal static JsonElement DecodeBangumi(JsonElement response)
    {
        var status = Json.Number(response, "status");
        if (status < 200 || status >= 300) throw new InvalidOperationException(status is 401 or 403 ? "Bangumi 令牌无效或已过期。" : $"Bangumi 请求失败（{status}）。");
        JsonElement payload;
        try { using var document = JsonDocument.Parse(Json.Text(response, "body")); payload = document.RootElement.Clone(); }
        catch (JsonException) { throw new InvalidOperationException($"Bangumi 未返回有效 JSON（HTTP {status}）。"); }
        // Bangumi's v0 service can return an API error with HTTP 200.
        var code = Json.Number(payload, "code");
        if (code is >= 400 and < 600) throw new InvalidOperationException($"Bangumi 请求失败（{code}）。");
        return payload;
    }
    public Task<JsonElement[]> Collections(int type, CancellationToken token, int subjectType = 2)
    {
        var revision = BangumiRevision;
        return Pages(offset => BangumiRequest("collections", new { collectionType = type, subjectType, limit = 100, offset }, token, revision), token);
    }
    public Task<JsonElement[]> Episodes(long id, CancellationToken token)
    {
        var revision = BangumiRevision;
        return Pages(offset => BangumiRequest("episodes", new { subjectId = id, limit = 100, offset }, token, revision), token);
    }
    internal static async Task<JsonElement[]> Pages(Func<int, Task<JsonElement>> fetch, CancellationToken token)
    {
        var items = new List<JsonElement>();
        for (var offset = 0; offset <= int.MaxValue - 100;)
        {
            var page = await fetch(offset); token.ThrowIfCancellationRequested();
            var batch = Json.Items(page); items.AddRange(batch); offset += batch.Length;
            var total = Json.Number(page, "total", -1);
            if (batch.Length == 0 || total >= 0 && offset >= total || total < 0 && batch.Length < 100) return items.ToArray();
        }
        throw new InvalidOperationException("分页偏移超过服务允许的范围，本次未完成读取。");
    }
}

internal static class Json
{
    public static JsonElement[] OptionalItems(JsonElement value) => value.ValueKind == JsonValueKind.Array ? value.EnumerateArray().Select(x => x.Clone()).ToArray() : [];
    public static JsonElement Get(JsonElement value, string key) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(key, out var found) ? found : default;
    public static string Text(JsonElement value, string key) => Get(value, key) is var item && item.ValueKind is JsonValueKind.String or JsonValueKind.Number ? item.ToString() : "";
    public static string First(JsonElement value, params string[] keys) => keys.Select(key => Text(value, key)).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? "";
    public static double Number(JsonElement value, string key, double fallback = 0) => double.TryParse(Text(value, key), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var n) && double.IsFinite(n) ? n : fallback;
    public static JsonElement[] Items(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Array) return value.EnumerateArray().Select(x => x.Clone()).ToArray();
        foreach (var key in new[] { "data", "items", "list" })
            if (Get(value, key) is { ValueKind: JsonValueKind.Array } array) return Items(array);
        throw new InvalidOperationException("服务返回了无法识别的列表，请刷新或检查服务版本。");
    }
    public static JsonElement Subject(JsonElement item) => Get(item, "subject").ValueKind == JsonValueKind.Object ? Get(item, "subject") : item;
    public static string Title(JsonElement item) => First(item, "name_cn", "nameCN", "title", "name", "media_title");
    public static string DownloadTitle(JsonElement item) => First(Get(item, "media"), "title") is { Length: > 0 } title ? title : First(item, "media_title", "title", "name");
}
