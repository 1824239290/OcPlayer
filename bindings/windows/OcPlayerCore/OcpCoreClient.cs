using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OcPlayer.Core;

namespace OcPlayer.CoreAdapter;

/// Typed, byte-preserving projection of every shared Core command. Domain flow
/// receipts remain JSON so native adapters can execute their platform effects.
public sealed class OcpCoreClient : IDisposable
{
    private readonly OcpCore _core;
    public OcpCoreClient(string? configJson = null, string? libraryPath = null)
        => _core = new OcpCore(configJson ?? "{}", libraryPath);
    public static uint AbiVersion => OcpCore.AbiVersion;
    public OcpResponse Ping() => CallJSON("ping");
    public OcpResponse Call(string method, object? arguments = null)
        => CallJSON(method, arguments is null ? "{}" : JsonSerializer.Serialize(arguments));
    public OcpResponse Call(string method, string argumentsJson) => CallJSON(method, argumentsJson);
    public OcpResponse CallJSON(string method, string argumentsJson = "{}")
        => DecodeResponse(_core.Call(method, argumentsJson));
    public Task<OcpResponse> CallAsync(string method, object? arguments = null, CancellationToken cancellationToken = default)
        => CallJSONAsync(method, arguments is null ? "{}" : JsonSerializer.Serialize(arguments), cancellationToken);
    public Task<OcpResponse> CallAsync(string method, string argumentsJson, CancellationToken cancellationToken = default)
        => CallJSONAsync(method, argumentsJson, cancellationToken);
    public async Task<OcpResponse> CallJSONAsync(string method, string argumentsJson = "{}", CancellationToken cancellationToken = default)
        => DecodeResponse(await _core.CallAsync(method, argumentsJson, cancellationToken).ConfigureAwait(false));
    public OcpResponse CancelRequest(string requestId) => Call("request.cancel", new { requestId });
    public JsonDocument Snapshot(string kind = "core") => JsonDocument.Parse(_core.Snapshot(kind));
    public string SnapshotJSON(string kind = "core") => _core.Snapshot(kind);
    public bool TryPollEvent(out OcpEvent? value)
    {
        var json = _core.PollEvent();
        if (json is null) { value = null; return false; }
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        value = new OcpEvent(root.GetProperty("sequence").GetUInt64(), root.GetProperty("kind").GetString()!, root.GetProperty("data").Clone());
        return true;
    }
    public async IAsyncEnumerable<OcpEvent> ReadEventsAsync(
        TimeSpan? idleInterval = null,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var interval = idleInterval ?? TimeSpan.FromMilliseconds(16);
        if (interval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(idleInterval));
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (TryPollEvent(out var value)) yield return value!;
            else await Task.Delay(interval, cancellationToken).ConfigureAwait(false);
        }
    }
    public void AttachSurface(ulong nativeHandle, uint width, uint height, double scale, uint surfaceKind = 1)
        => _core.AttachSurface(nativeHandle, width, height, scale, surfaceKind);
    public void ResizeSurface(uint width, uint height, double scale) => _core.ResizeSurface(width, height, scale);
    public void DetachSurface() => _core.DetachSurface();
    public void RenderTick(double timeSeconds) => _core.RenderTick(timeSeconds);
    public void Dispose() => _core.Dispose();
    private static OcpResponse DecodeResponse(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        return new OcpResponse(root.GetProperty("ok").GetBoolean(), root.GetProperty("code").GetInt32(),
            root.GetProperty("retryable").GetBoolean(), root.GetProperty("message").GetString()!, root.GetProperty("data").Clone());
    }
}
