using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32;

namespace OcPlayer.Windows.Services;

/// Unpackaged Windows protocol activation: the short-lived callback process
/// forwards only to the current user's live, state-specific authorization pipe.
internal static class BangumiOAuthBrowser
{
    public const string CallbackArgument = "--bangumi-oauth-callback";
    public const string RegisterArgument = "--register-bangumi-protocol";
    private static string PipeName(string state)
    {
        if (state.Length != 32 || !state.All(char.IsAsciiHexDigit)) throw new InvalidOperationException("无效授权状态。");
        var sid = WindowsIdentity.GetCurrent().User!.Value;
        return "OcPlayer.BangumiOAuth." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sid)))[..16] + "." + state;
    }
    public static async Task<string> Authorize(Uri authorizationUrl, string state, CancellationToken token, Action? browserOpened = null)
    {
        RegisterProtocol();
        return await Receive(state, () =>
        {
            try
            {
                OpenBrowser(authorizationUrl);
                browserOpened?.Invoke();
            }
            catch (System.ComponentModel.Win32Exception ex)
            { throw new InvalidOperationException("无法启动默认浏览器，请检查浏览器安装后重试。", ex); }
        }, token);
    }
    internal static void OpenBrowser(Uri url)
    {
        using var browser = Process.Start(DefaultBrowserStartInfo(url));
    }
    internal static ProcessStartInfo DefaultBrowserStartInfo(Uri url)
    {
        if (!url.IsAbsoluteUri || url.Scheme is not ("https" or "http")) throw new ArgumentException("浏览器地址无效。");
        return new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true };
    }
    internal static async Task<string> Receive(string state, Action openBrowser, CancellationToken token)
    {
        using var pipe = new NamedPipeServerStream(PipeName(state), PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        // Listen before opening the browser, including immediate already-authorized redirects.
        var connection = pipe.WaitForConnectionAsync(token);
        openBrowser();
        await connection;
        using var reader = new StreamReader(pipe, Encoding.UTF8, false, 1024, leaveOpen: true);
        var buffer = new char[1]; var callback = new StringBuilder();
        while (callback.Length <= 8192)
        {
            if (await reader.ReadAsync(buffer.AsMemory(), token) == 0) throw new InvalidOperationException("授权回调连接中断。");
            if (buffer[0] == '\n') break;
            callback.Append(buffer[0]);
        }
        var value = callback.ToString();
        if (BangumiOAuthCallback.Parse(value).State != state) throw new InvalidOperationException("授权状态不匹配。");
        await pipe.WriteAsync(new byte[] { 1 }, token); await pipe.FlushAsync(token);
        return value;
    }
    public static async Task Forward(string callback, CancellationToken token)
    {
        var parsed = BangumiOAuthCallback.Parse(callback);
        using var pipe = new NamedPipeClientStream(".", PipeName(parsed.State), PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(3000, token);
        var bytes = Encoding.UTF8.GetBytes(callback + "\n");
        await pipe.WriteAsync(bytes, token); await pipe.FlushAsync(token);
        var ack = new byte[1];
        if (await pipe.ReadAsync(ack, token) != 1 || ack[0] != 1) throw new InvalidOperationException("授权回调未被接收。");
    }
    internal static string ProtocolCommand(string applicationDirectory, string? dotnetHost)
    {
        applicationDirectory = Path.GetFullPath(applicationDirectory);
        var appHost = Path.Combine(applicationDirectory, "OcPlayer.Windows.exe");
        if (File.Exists(Path.Combine(applicationDirectory, "coreclr.dll")) || !File.Exists(dotnetHost))
            return $"\"{appHost}\" {CallbackArgument} \"%1\"";

        var consoleHost = Path.Combine(Environment.SystemDirectory, "conhost.exe");
        var assembly = Path.Combine(applicationDirectory, "OcPlayer.Windows.dll");
        return $"\"{consoleHost}\" --headless \"{Path.GetFullPath(dotnetHost)}\" \"{assembly}\" {CallbackArgument} \"%1\"";
    }
    internal static void RegisterProtocol()
    {
        var dotnetHost = Environment.ProcessPath;
        if (!string.Equals(Path.GetFileName(dotnetHost), "dotnet.exe", StringComparison.OrdinalIgnoreCase))
        {
            var runtime = Environment.GetEnvironmentVariable("DOTNET_ROOT_" + RuntimeInformation.ProcessArchitecture.ToString().ToUpperInvariant())
                ?? Environment.GetEnvironmentVariable("DOTNET_ROOT");
            dotnetHost = runtime is null ? null : Path.Combine(runtime, "dotnet.exe");
        }
        var command = ProtocolCommand(AppContext.BaseDirectory, dotnetHost);
        RegisterProtocol(Registry.CurrentUser, @"Software\Classes\ocplayer", command);
    }
    internal static void RegisterProtocol(RegistryKey root, string path, string command)
    {
        try
        {
            // Launchers prepare registration before starting the UI. Reusing the
            // current handler also avoids unnecessary registry writes on each login.
            using (var current = root.OpenSubKey(path))
            using (var open = current?.OpenSubKey(@"shell\open\command"))
                if (current?.GetValue("URL Protocol") is string && Equals(open?.GetValue(""), command)) return;
            using var key = root.CreateSubKey(path, true);
            key.SetValue("", "URL:OcPlayer OAuth"); key.SetValue("URL Protocol", "");
            using var handler = key.CreateSubKey(@"shell\open\command", true); handler.SetValue("", command);
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException)
        {
            throw new InvalidOperationException("无法注册 Bangumi 登录回调，请通过启动脚本打开 OcPlayer 后重试。", ex);
        }
    }
}
