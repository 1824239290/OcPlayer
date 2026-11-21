using System.Text.Json;
using System.Text.Json.Nodes;
using OcPlayer.CoreAdapter;

namespace OcPlayer.Windows.Services;

internal sealed record PreparedSettingsBackup(RuntimePreferences Playback, DanmakuPreferences Danmaku, TmdbPreferences Tmdb,
    string[]? HomeSections, string[]? HiddenSections, string? Theme, string Preview, JsonElement? IntegrationPreferences = null, bool? EpisodesDescending = null);

internal static class SettingsBackup
{
    public static string Export(CoreRuntime core, string[] sections, string[] hidden, string theme, bool episodesDescending = false)
    {
        var p = RuntimeSettings.Current; var d = core.Danmaku.Settings.Current; var t = core.Tmdb.Settings.Current;
        uint? Color(string? value) => value is null ? null : Convert.ToUInt32(value[1..], 16);
        var value = new
        {
            formatVersion = 1, exportedAt = DateTimeOffset.UtcNow.ToString("O"), appVersion = AppReleaseService.DisplayVersion, deviceName = Environment.MachineName,
            tmdb = new { apiKey = t.ApiKey, language = t.Language, preferText = t.PreferText, replaceImages = t.ReplaceImages, showPlaceholders = t.ShowMissingEpisodes, cacheDays = 30 },
            playback = new { skipIntro = p.SkipIntro, skipOutro = p.SkipOutro, outroRetentionSeconds = p.OutroRetainSeconds,
                subtitleLanguage = p.SubtitleLanguage == "default" ? "followSource" : p.SubtitleLanguage,
                lumaUpscaler = p.QualityEnhancement switch { "artcnn-f16" => "artCnnC4F16", "artcnn-f32" => "artCnnC4F32", "artcnn-f16-denoise" => "artCnnC4F16Ds", _ => "off" },
                subtitleStyleOverrides = p.OverrideSubtitleStyles, subtitleAlignment = p.SubtitlePosition switch { "bottom-center" => 2, "bottom-left" => 1, "bottom-right" => 3, "top-center" => 8, _ => (int?)null },
                subtitleMarginVertical = p.SubtitleMargin, subtitlePrimaryColor = Color(p.SubtitleColor), subtitleOutlineColor = Color(p.SubtitleOutlineColor), subtitleOutlineWidth = (double)p.SubtitleOutlineWidth, subtitleBold = p.SubtitleBold,
                httpReadAheadMiB = p.NetworkBufferMiB == 2 ? 0 : p.NetworkBufferMiB, httpBackBufferMiB = p.BackBufferMiB == 16 ? 0 : p.BackBufferMiB },
            danmaku = new { danmakuEnabled = d.Enabled, opacity = d.Opacity, displayArea = d.DisplayArea, blockTop = d.BlockTop, blockBottom = d.BlockBottom, blockScroll = d.BlockScroll,
                fontSize = d.FontSize, autoLoad = d.AutoLoad, dandanplayGatewayURL = d.GatewayUrl, outlineWidth = d.OutlineWidth, shadowStyle = d.ShadowStyle },
            general = new { bangumiEnabled = core.Integrations.IsEnabled("bangumi"), moviepilotEnabled = core.Integrations.IsEnabled("moviepilot"),
                homeSections = EncodeHome(sections, hidden), episodeSortAscending = !episodesDescending },
            mirror = new { bangumiEnabled = core.Integrations.MirrorEnabled, bangumiRootDomain = core.Integrations.MirrorRoot, tmdbEnabled = t.UseMirror, tmdbAPIBaseURL = t.ApiMirror, tmdbImageBaseURL = t.ImageMirror },
            windows = new { playback = p, danmaku = d, homeSections = sections, hiddenSections = hidden, theme, integrations = core.Integrations.ExportPreferences() }
        };
        var json = JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true });
        PlaybackSession.Require(core.Client.Call("settings.backup.decode", new { inputBase64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(json)) }));
        return json;
    }
    public static PreparedSettingsBackup Prepare(CoreRuntime core, string json)
    {
        if (json.Length > 4 * 1024 * 1024) throw new InvalidOperationException("配置文件过大。");
        var data = PlaybackSession.Require(core.Client.Call("settings.backup.decode", new { inputBase64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(json)) }));
        using var canonical = JsonDocument.Parse(Json.Text(data, "backupJSON")); var root = canonical.RootElement;
        using var original = JsonDocument.Parse(json); var windows = Json.Get(original.RootElement, "windows");
        var p = RuntimeSettings.Current; var d = core.Danmaku.Settings.Current; var t = core.Tmdb.Settings.Current;
        var playback = Json.Get(root, "playback"); var danmaku = Json.Get(root, "danmaku"); var tmdb = Json.Get(root, "tmdb"); var mirror = Json.Get(root, "mirror");
        static bool Bool(JsonElement node, string key, bool fallback) => Json.Get(node, key).ValueKind is JsonValueKind.True or JsonValueKind.False ? Json.Get(node, key).GetBoolean() : fallback;
        static string Text(JsonElement node, string key, string fallback) => Json.Get(node, key).ValueKind == JsonValueKind.String ? Json.Text(node, key) : fallback;
        static double Number(JsonElement node, string key, double fallback) => Json.Get(node, key).ValueKind == JsonValueKind.Number ? Json.Number(node, key) : fallback;
        static string? Color(JsonElement node, string key) => Json.Get(node, key) is { ValueKind: JsonValueKind.Number } number && number.TryGetUInt32(out var color) ? "#" + color.ToString("X8") : null;
        if (playback.ValueKind == JsonValueKind.Object) p = p with
        {
            SkipIntro = Bool(playback, "skipIntro", p.SkipIntro), SkipOutro = Bool(playback, "skipOutro", p.SkipOutro), OutroRetainSeconds = (int)Number(playback, "outroRetentionSeconds", p.OutroRetainSeconds),
            SubtitleLanguage = Text(playback, "subtitleLanguage", p.SubtitleLanguage) is var language && language == "followSource" ? "default" : language,
            QualityEnhancement = Text(playback, "lumaUpscaler", "off") switch { "artCnnC4F16" => "artcnn-f16", "artCnnC4F32" => "artcnn-f32", "artCnnC4F16Ds" => "artcnn-f16-denoise", _ => "off" },
            SubtitlePosition = Number(playback, "subtitleAlignment", 0) switch { 1 => "bottom-left", 2 => "bottom-center", 3 => "bottom-right", 8 => "top-center", _ => "unset" },
            SubtitleMargin = (int)Number(playback, "subtitleMarginVertical", 0), SubtitleOutlineWidth = (int)Number(playback, "subtitleOutlineWidth", 0),
            SubtitleColor = Color(playback, "subtitlePrimaryColor"), SubtitleOutlineColor = Color(playback, "subtitleOutlineColor"),
            SubtitleBold = Json.Get(playback, "subtitleBold").ValueKind is JsonValueKind.True or JsonValueKind.False ? Json.Get(playback, "subtitleBold").GetBoolean() : null,
            OverrideSubtitleStyles = Bool(playback, "subtitleStyleOverrides", false),
            NetworkBufferMiB = (int)Number(playback, "httpReadAheadMiB", 0) is var ahead && ahead == 0 ? 2 : ahead,
            BackBufferMiB = (int)Number(playback, "httpBackBufferMiB", 0) is var back && back == 0 ? 16 : back
        };
        if (danmaku.ValueKind == JsonValueKind.Object) d = d with { Enabled = Bool(danmaku, "danmakuEnabled", d.Enabled), AutoLoad = Bool(danmaku, "autoLoad", d.AutoLoad),
            FontSize = Number(danmaku, "fontSize", d.FontSize), Opacity = Number(danmaku, "opacity", d.Opacity), DisplayArea = Number(danmaku, "displayArea", d.DisplayArea),
            OutlineWidth = Number(danmaku, "outlineWidth", d.OutlineWidth), ShadowStyle = (int)Number(danmaku, "shadowStyle", d.ShadowStyle),
            BlockTop = Bool(danmaku, "blockTop", d.BlockTop), BlockBottom = Bool(danmaku, "blockBottom", d.BlockBottom), BlockScroll = Bool(danmaku, "blockScroll", d.BlockScroll), GatewayUrl = Text(danmaku, "dandanplayGatewayURL", d.GatewayUrl) };
        if (tmdb.ValueKind == JsonValueKind.Object) t = t with { ApiKey = Text(tmdb, "apiKey", t.ApiKey), Language = Text(tmdb, "language", t.Language),
            PreferText = Bool(tmdb, "preferText", t.PreferText), ReplaceImages = Bool(tmdb, "replaceImages", t.ReplaceImages), ShowMissingEpisodes = Bool(tmdb, "showPlaceholders", t.ShowMissingEpisodes) };
        if (mirror.ValueKind == JsonValueKind.Object) t = t with { UseMirror = Bool(mirror, "tmdbEnabled", t.UseMirror), ApiMirror = Text(mirror, "tmdbAPIBaseURL", t.ApiMirror), ImageMirror = Text(mirror, "tmdbImageBaseURL", t.ImageMirror) };
        string[]? sections = null, hidden = null; string? theme = null;
        var general = Json.Get(root, "general");
        if (Json.Get(general, "homeSections").ValueKind == JsonValueKind.String) (sections, hidden) = DecodeHome(Json.Text(general, "homeSections"));
        var integrations = core.Integrations.ExportPreferences();
        if (general.ValueKind == JsonValueKind.Object) { integrations["bangumi.enabled"] = Bool(general, "bangumiEnabled", true) ? "true" : "false"; integrations["moviepilot.enabled"] = Bool(general, "moviepilotEnabled", true) ? "true" : "false"; }
        if (mirror.ValueKind == JsonValueKind.Object) { integrations["bangumi.mirror.enabled"] = Bool(mirror, "bangumiEnabled", false) ? "true" : "false"; integrations["bangumi.mirror.root"] = Text(mirror, "bangumiRootDomain", ""); }
        if (windows.ValueKind == JsonValueKind.Object)
        {
            if (Json.Get(windows, "playback").ValueKind == JsonValueKind.Object) p = JsonSerializer.Deserialize<RuntimePreferences>(Json.Get(windows, "playback").GetRawText()) ?? p;
            if (Json.Get(windows, "danmaku").ValueKind == JsonValueKind.Object) d = JsonSerializer.Deserialize<DanmakuPreferences>(Json.Get(windows, "danmaku").GetRawText()) ?? d;
            if (Json.Get(windows, "homeSections").ValueKind == JsonValueKind.Array) sections = JsonSerializer.Deserialize<string[]>(Json.Get(windows, "homeSections").GetRawText());
            if (Json.Get(windows, "hiddenSections").ValueKind == JsonValueKind.Array) hidden = JsonSerializer.Deserialize<string[]>(Json.Get(windows, "hiddenSections").GetRawText());
            theme = Text(windows, "theme", "system"); if (theme is not ("system" or "light" or "dark")) throw new ArgumentException("外观设置无效。");
            if (Json.Get(windows, "integrations").ValueKind == JsonValueKind.Object) integrations = JsonSerializer.Deserialize<Dictionary<string, string>>(Json.Get(windows, "integrations").GetRawText()) ?? integrations;
        }
        if (integrations.GetValueOrDefault("bangumi.mirror.enabled") == "true") BangumiDomains.Parse(integrations.GetValueOrDefault("bangumi.mirror.root") ?? "");
        p = p.Validated(); d = d.Validated(); t = t.Validated();
        var keyTail = t.ApiKey.Length == 0 ? "未配置" : "••••" + t.ApiKey[^Math.Min(4, t.ApiKey.Length)..];
        var preview = $"导出时间：{Json.Text(root, "exportedAt")}\n来源设备：{Json.Text(root, "deviceName")}\n版本：{Json.Text(root, "appVersion")}\n\n"
            + $"TMDB：{keyTail} · {t.Language} · 文本优先 {t.PreferText} · 替换图片 {t.ReplaceImages} · 占位 {t.ShowMissingEpisodes}\n"
            + $"网络缓冲：{p.NetworkBufferMiB} / {p.BackBufferMiB} MiB\n跳过片头/尾：{p.SkipIntro}/{p.SkipOutro} · 保留 {p.OutroRetainSeconds}s\n字幕：{p.SubtitleLanguage} · {p.SubtitlePosition} · 边距 {p.SubtitleMargin} · 颜色 {p.SubtitleColor ?? "不设置"} / {p.SubtitleOutlineColor ?? "不设置"} · 描边 {p.SubtitleOutlineWidth} · 加粗 {p.SubtitleBold?.ToString() ?? "不设置"} · 覆盖 {p.OverrideSubtitleStyles}\n画质：{p.QualityEnhancement}\n"
            + $"弹幕：自动 {d.AutoLoad} · 显示 {d.Enabled} · {d.FontSize}pt · 不透明度 {d.Opacity:P0} · 区域 {d.DisplayArea:P0} · 描边 {d.OutlineWidth} · 阴影 {d.ShadowStyle} · 内核 {d.UseKernelRenderer}\n镜像：{t.ApiBase}\n{t.ImageBase}\n"
            + $"首页栏目：{(sections is null ? "保留当前" : string.Join("、", sections))}\n隐藏栏目：{(hidden is null ? "保留当前" : string.Join("、", hidden))}\n外观：{theme ?? "保留当前"}\nBangumi 镜像：{integrations.GetValueOrDefault("bangumi.mirror.root", "官方")}\n集成偏好：{integrations.Count} 项\n不会恢复服务器账号、密码或登录令牌。";
        return new(p, d, t, sections, hidden, theme, preview, JsonSerializer.SerializeToElement(integrations), general.ValueKind == JsonValueKind.Object ? !Bool(general, "episodeSortAscending", true) : null);
    }
    public static void Restore(CoreRuntime core, PreparedSettingsBackup backup)
    {
        // Validate every module before the first write. A save failure is surfaced; it is never reported as success.
        var p = backup.Playback.Validated(); var d = backup.Danmaku.Validated(); var t = backup.Tmdb.Validated();
        core.Tmdb.Settings.Save(t); core.Danmaku.Settings.Save(d); RuntimeSettings.Save(p);
        if (backup.IntegrationPreferences is { } integration) core.Integrations.RestorePreferences(JsonSerializer.Deserialize<Dictionary<string, string>>(integration.GetRawText()) ?? []);
        AppDiagnostics.Write("info", "已从配置文件恢复设置。");
    }
    private static readonly Dictionary<string, string> HomeNames = new() { ["resume"] = "继续观看", ["nextUp"] = "接下来看", ["latest"] = "最近添加", ["libraries"] = "媒体库" };
    internal static string EncodeHome(string[] sections, string[] hidden) => string.Join(",", sections.Where(x => HomeNames.ContainsValue(x)).Select(x => (hidden.Contains(x) ? "-" : "") + HomeNames.First(p => p.Value == x).Key));
    internal static (string[] Sections, string[] Hidden) DecodeHome(string raw)
    {
        if (raw.Trim().Length == 0) return (HomeNames.Values.ToArray(), HomeNames.Values.ToArray());
        var sections = new List<string>(); var hidden = new List<string>();
        foreach (var token in raw.Split(',').Select(x => x.Trim()))
        {
            var key = token.TrimStart('-'); if (!HomeNames.TryGetValue(key, out var title) || sections.Contains(title)) continue;
            sections.Add(title); if (token.StartsWith('-')) hidden.Add(title);
        }
        if (sections.Count == 0) return (HomeNames.Values.ToArray(), []);
        foreach (var title in HomeNames.Values.Where(x => !sections.Contains(x))) { sections.Add(title); hidden.Add(title); }
        return (sections.ToArray(), hidden.ToArray());
    }
}
