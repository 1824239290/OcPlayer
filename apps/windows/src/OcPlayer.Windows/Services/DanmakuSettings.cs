using System.Text.Json;

namespace OcPlayer.Windows.Services;

internal sealed record DanmakuPreferences(
    string GatewayUrl = "", string ApiKey = "", bool AutoLoad = true, bool Enabled = true,
    double FontSize = 22, double Opacity = .85, double DisplayArea = .75,
    bool BlockTop = false, bool BlockBottom = false, bool BlockScroll = false,
    bool MergeDuplicates = false, bool AllowStacking = false, bool UseKernelRenderer = false, string AnimeSkipClientId = "")
{
    // Public, app-distributed gateway credentials, shared with OcPlayer's DandanplaySettingsStore.
    public const string DefaultGateway = "https://dandanplay.3841625.xyz";
    private const string PublicApiKey = "ocp_-zNBxWgtukt0JD7sjQQgzcNk99MUrERqGlg6rABKFQQ";
    public string EffectiveUrl => NormalizeGateway(GatewayUrl);
    // A custom host must never silently receive credentials meant for the default gateway.
    public string EffectiveKey => !string.IsNullOrWhiteSpace(ApiKey) ? ApiKey.Trim()
        : EffectiveUrl == DefaultGateway ? PublicApiKey : "";
    public object Gateway => new { base_url = EffectiveUrl, api_key = EffectiveKey, user_agent = "OcPlay/0.3.0 (Windows)" };
    public object Renderer => new { enabled = Enabled, fontSize = FontSize, opacity = Opacity, displayArea = DisplayArea,
        blockTop = BlockTop, blockBottom = BlockBottom, blockScroll = BlockScroll, mergeDuplicates = MergeDuplicates, allowStacking = AllowStacking };

    public DanmakuPreferences Validated()
    {
        if (GatewayUrl is null || ApiKey is null || AnimeSkipClientId is null) throw new ArgumentException("弹幕网关设置无效，请重新保存配置。");
        _ = EffectiveUrl;
        if (EffectiveKey.Length == 0) throw new ArgumentException("请填写自定义弹幕网关的 API Key。");
        if (ApiKey.Contains('\r') || ApiKey.Contains('\n')) throw new ArgumentException("API Key 不能包含换行。");
        if (AnimeSkipClientId.Any(char.IsControl)) throw new ArgumentException("anime-skip Client ID 不能包含控制字符。");
        if (!double.IsFinite(FontSize) || FontSize is < 11 or > 44
            || !double.IsFinite(Opacity) || Opacity is < .25 or > 1
            || !double.IsFinite(DisplayArea) || DisplayArea is < .25 or > 1)
            throw new ArgumentException("弹幕字号应为 11–44，不透明度和显示区域应为 25%–100%。");
        return this with { GatewayUrl = GatewayUrl.Trim(), ApiKey = ApiKey.Trim(), AnimeSkipClientId = AnimeSkipClientId.Trim() };
    }

    public static string NormalizeGateway(string raw)
    {
        raw = raw.Trim();
        if (raw.Length == 0) return DefaultGateway;
        if (!raw.Contains("://", StringComparison.Ordinal)) raw = "https://" + raw;
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)
            || !(uri.Scheme == "https" || uri.Scheme == "http" && uri.IsLoopback)
            || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
            throw new ArgumentException("请输入 HTTPS 网关地址，不包含账号、查询参数或片段。");
        return uri.AbsoluteUri.TrimEnd('/');
    }
}

/// One atomic credential replacement keeps both preferences and private API keys out of plain-text files.
internal sealed class DanmakuSettings
{
    private readonly Action<string> _write;
    public DanmakuPreferences Current { get; private set; }
    public string? LoadWarning { get; private set; }
    public event Action<DanmakuPreferences>? Changed;

    public DanmakuSettings(string resource) : this(() => ReadCredential(resource), json =>
        new global::Windows.Security.Credentials.PasswordVault().Add(
            new global::Windows.Security.Credentials.PasswordCredential(resource, "danmaku-settings", json))) { }

    internal DanmakuSettings(Func<string?> read, Action<string> write)
    {
        _write = write;
        try
        {
            var json = read();
            Current = (json is null ? new DanmakuPreferences()
                : JsonSerializer.Deserialize<DanmakuPreferences>(json) ?? throw new JsonException("Missing danmaku settings")).Validated();
        }
        catch (Exception ex) when (ex is JsonException or ArgumentException or System.Runtime.InteropServices.COMException)
        {
            Current = new(AutoLoad: false);
            LoadWarning = "未能读取已保存的弹幕设置。自动加载已暂停，请检查配置后保存。";
        }
    }

    public void Save(DanmakuPreferences preferences)
    {
        preferences = preferences.Validated();
        _write(JsonSerializer.Serialize(preferences));
        Current = preferences;
        LoadWarning = null;
        Changed?.Invoke(preferences);
    }

    private static string? ReadCredential(string resource)
    {
        try
        {
            var item = new global::Windows.Security.Credentials.PasswordVault().Retrieve(resource, "danmaku-settings");
            item.RetrievePassword(); return item.Password;
        }
        catch (System.Runtime.InteropServices.COMException ex) when (ex.HResult == unchecked((int)0x80070490)) { return null; }
    }
}
