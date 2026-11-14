using System.Text.Json;
using System.Text.Json.Serialization;

namespace OcPlayer.CoreAdapter;

public sealed record OcpResponse(
    [property: JsonPropertyName("ok")] bool Ok,
    [property: JsonPropertyName("code")] int Code,
    [property: JsonPropertyName("retryable")] bool Retryable,
    [property: JsonPropertyName("message")] string Message,
    [property: JsonPropertyName("data")] JsonElement Data)
{
    public T? DecodeData<T>(JsonSerializerOptions? options = null) => Data.Deserialize<T>(options);
}
public sealed record OcpEvent(
    [property: JsonPropertyName("sequence")] ulong Sequence,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("data")] JsonElement Data)
{
    public T? DecodeData<T>(JsonSerializerOptions? options = null) => Data.Deserialize<T>(options);
}
public sealed record OcpSnapshot(
    [property: JsonPropertyName("abiVersion")] uint AbiVersion,
    [property: JsonPropertyName("coreVersion")] string CoreVersion,
    [property: JsonPropertyName("ready")] bool Ready,
    [property: JsonPropertyName("surfaceAttached")] bool SurfaceAttached);
