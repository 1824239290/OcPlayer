using System.Text.Json;
using System.Text.Json.Serialization;

namespace OcPlayer.CoreAdapter;

public sealed record OcpResponse(
    [property: JsonPropertyName("ok")] bool Ok,
    [property: JsonPropertyName("code")] int Code,
    [property: JsonPropertyName("retryable")] bool Retryable,
    [property: JsonPropertyName("message")] string Message,
    [property: JsonPropertyName("data")] JsonElement Data);

public sealed record OcpEvent(
    [property: JsonPropertyName("sequence")] ulong Sequence,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("data")] JsonElement Data);

public sealed record OcpSnapshot(
    [property: JsonPropertyName("abi_version")] uint AbiVersion,
    [property: JsonPropertyName("core_version")] string CoreVersion,
    [property: JsonPropertyName("ready")] bool Ready,
    [property: JsonPropertyName("surface_attached")] bool SurfaceAttached);
