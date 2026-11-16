using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace OcPlayer.Windows.Services;

internal static class DanmakuFingerprint
{
    internal const int HeadBytes = 16 * 1024 * 1024;
    private static readonly HttpClient Client = new(new HttpClientHandler { AllowAutoRedirect = false, AutomaticDecompression = DecompressionMethods.None })
    { Timeout = Timeout.InfiniteTimeSpan };

    // Inspect headers before reading the body; a server ignoring Range must not cause a movie-sized allocation/download.
    public static async Task<string?> ReadRemote(string url, IReadOnlyDictionary<string, string>? headers, long? expectedSize,
        CancellationToken token, HttpClient? client = null)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var original) || original.Scheme is not ("http" or "https")) return null;
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(12));
        try
        {
            var current = original;
            for (var redirects = 0; redirects <= 5; redirects++)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, current);
                // Authentication belongs only to the original media origin, never to a redirected CDN.
                if (current.GetLeftPart(UriPartial.Authority) == original.GetLeftPart(UriPartial.Authority) && headers is not null)
                    foreach (var (name, value) in headers)
                        if (!name.Equals("Range", StringComparison.OrdinalIgnoreCase) && !name.Equals("Accept-Encoding", StringComparison.OrdinalIgnoreCase))
                            request.Headers.TryAddWithoutValidation(name, value);
                request.Headers.Range = new RangeHeaderValue(0, HeadBytes - 1);
                request.Headers.AcceptEncoding.ParseAdd("identity");
                using var response = await (client ?? Client).SendAsync(request, HttpCompletionOption.ResponseHeadersRead, budget.Token).ConfigureAwait(false);
                if (response.StatusCode is HttpStatusCode.MovedPermanently or HttpStatusCode.Redirect or HttpStatusCode.SeeOther or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect)
                {
                    if (response.Headers.Location is not { } location) return null;
                    current = new Uri(current, location);
                    if (current.Scheme is not ("https" or "http") || original.Scheme == "https" && current.Scheme != "https" || current.UserInfo.Length > 0) return null;
                    continue;
                }
                if (response.Content.Headers.ContentEncoding.Any(x => x != "identity")) return null;
                long expected;
                if (response.StatusCode == HttpStatusCode.PartialContent)
                {
                    var range = response.Content.Headers.ContentRange;
                    if (range is null || range.Unit != "bytes" || range.From != 0 || range.To is null) return null;
                    if (range.Length is { } total && (total <= 0 || expectedSize is { } known && total != known)) return null;
                    expected = Math.Min(HeadBytes, range.Length ?? expectedSize ?? HeadBytes);
                    if (expected <= 0 || range.To != expected - 1) return null;
                }
                else if (response.StatusCode == HttpStatusCode.OK)
                {
                    expected = response.Content.Headers.ContentLength ?? expectedSize ?? -1;
                    if (expected is < 1 or > HeadBytes || expectedSize is { } known && expected != known) return null;
                }
                else return null;
                if (response.Content.Headers.ContentLength is { } length && length != expected) return null;
                await using var stream = await response.Content.ReadAsStreamAsync(budget.Token).ConfigureAwait(false);
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
                var buffer = new byte[64 * 1024];
                for (long read = 0; read < expected;)
                {
                    var count = await stream.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, expected - read)), budget.Token).ConfigureAwait(false);
                    if (count == 0) return null;
                    hash.AppendData(buffer, 0, count); read += count;
                }
                // Reject a body longer than the promised range, without buffering it.
                if (await stream.ReadAsync(buffer.AsMemory(0, 1), budget.Token).ConfigureAwait(false) != 0) return null;
                return Convert.ToHexStringLower(hash.GetHashAndReset());
            }
            return null;
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { return null; }
        catch (Exception ex) when (ex is HttpRequestException or IOException) { return null; }
    }
}
