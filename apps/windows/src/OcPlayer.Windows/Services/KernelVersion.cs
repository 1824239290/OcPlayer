using System.Text.Json;

namespace OcPlayer.Windows.Services;

internal static class KernelVersion
{
    private static string? _cached;
    public static string Read()
    {
        if (_cached is not null) return _cached;
        var path = Path.Combine(AppContext.BaseDirectory, "erika_capi.dll");
        try
        {
            var receiptPath = Path.Combine(AppContext.BaseDirectory, "build-receipt.json");
            if (File.Exists(path) && File.Exists(receiptPath))
            {
                using var receipt = JsonDocument.Parse(File.ReadAllText(receiptPath));
                var expected = Json.Text(receipt.RootElement, "erikaSha256"); var version = Json.Text(receipt.RootElement, "kernelVersion");
                using var dll = File.OpenRead(path);
                if (version.Length > 0 && expected.Equals(Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(dll)), StringComparison.OrdinalIgnoreCase)) return _cached = version;
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { }
        {
            var version = File.Exists(path) ? System.Diagnostics.FileVersionInfo.GetVersionInfo(path).ProductVersion : null;
            return _cached = string.IsNullOrWhiteSpace(version) ? "当前内核未提供版本信息" : version;
        }
    }
}
