namespace OcPlayer.CoreAdapter;

public sealed record PlaybackFailure(string Category, string Message, bool Retryable, bool CanTryAlternateSource)
{
    public string Title => Category switch
    {
        "network" => "网络连接失败", "unsupported" => "片源格式不受支持", "auth" => "服务器认证失败",
        "server" => "服务器暂时不可用", "cancelled" => "已取消播放", "timeout" => "打开片源超时", _ => "播放失败"
    };

    public static PlaybackFailure Classify(string message)
    {
        var text = message.ToLowerInvariant();
        bool Has(params string[] terms) => terms.Any(text.Contains);
        var category = Has("cancelled", "canceled", "已取消") ? "cancelled"
            : Has("401", "403", "unauthorized", "forbidden", "认证", "鉴权") ? "auth"
            : Has("timed out", "timeout", "超时") ? "timeout"
            : Has("unsupported", "not supported", "decoder not found", "invalid data", "不支持", "codec") ? "unsupported"
            : Has("500", "502", "503", "504", "server error") ? "server"
            : Has("network", "connection", "dns", "resolve host", "http", "socket", "网络") ? "network" : "unknown";
        return new(category, message, category != "cancelled", category is "network" or "timeout" or "unsupported" or "server" or "unknown");
    }
}
