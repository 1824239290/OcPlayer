#if DEBUG
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OcPlayer.Windows.Features;
using OcPlayer.Windows.Services;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;

namespace OcPlayer.Windows.Preview;

internal sealed class ServerConnectionVerification : Window
{
    public ServerConnectionVerification(string output)
    {
        Title = "服务器连接界面验证";
        AppWindow.ResizeClient(new(1130, 670));
        var root = new Grid(); Content = root;
        root.Loaded += async (_, _) =>
        {
            Directory.CreateDirectory(output); var assertions = new List<string>();
            void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); assertions.Add(message); }
            T Field<T>(ServerConnectionView view, string name) where T : FrameworkElement => (T)view.FindName(name);
            void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
            IEnumerable<DependencyObject> Walk(DependencyObject parent)
            { yield return parent; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) foreach (var child in Walk(VisualTreeHelper.GetChild(parent, i))) yield return child; }
            using var fixture = new ConnectionFixture();
            using var core = new CoreRuntime("OcPlayer.ConnectionUiTest." + Guid.NewGuid().ToString("N"));
            var created = new List<string>();
            async Task Capture(string name)
            {
                await Task.Delay(120); root.UpdateLayout();
                var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(root); var pixels = await bitmap.GetPixelsAsync();
                using var file = File.Create(Path.Combine(output, name + ".png")); using var stream = file.AsRandomAccessStream();
                var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
                encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels.ToArray()); await encoder.FlushAsync();
            }
            try
            {
                foreach (var kind in new[] { "jellyfin", "emby" })
                {
                    MediaServer? connected = null;
                    var view = new ServerConnectionView(core, server => { connected = server; return Task.CompletedTask; }, () => { });
                    root.Children.Clear(); root.Children.Add(view); root.RequestedTheme = ElementTheme.Light; await Task.Delay(150);
                    Check(Field<StackPanel>(view, "AccountFields").Visibility == Visibility.Collapsed, "initial form asks for a server address before credentials");
                    Check(!Field<Button>(view, "PrimaryAction").IsEnabled, "empty server address disables connection");
                    var address = Field<TextBox>(view, "AddressInput"); address.Text = "file:///invalid"; await view.Detect();
                    Check(Field<InfoBar>(view, "ErrorNotice").IsOpen && Field<StackPanel>(view, "AccountFields").Visibility == Visibility.Collapsed, "invalid server address stays on the first step with an error");
                    address.Text = fixture.Url + kind; await view.Detect();
                    Check(Field<StackPanel>(view, "AccountFields").Visibility == Visibility.Visible && Field<StackPanel>(view, "AddressFields").Visibility == Visibility.Collapsed, "public server detection advances to the account step");
                    Check(Field<ComboBox>(view, "ServerKind").SelectedIndex == (kind == "emby" ? 1 : 0), "server product detection selects the matching account type");
                    Check(Field<Expander>(view, "QuickConnect").Visibility == (kind == "emby" ? Visibility.Collapsed : Visibility.Visible), "Quick Connect is shown for Jellyfin");
                    Field<TextBox>(view, "UsernameInput").Text = "fixture"; Field<PasswordBox>(view, "PasswordInput").Password = "wrong";
                    await view.Login();
                    Check(connected is null && Field<InfoBar>(view, "ErrorNotice").IsOpen && Field<Button>(view, "PrimaryAction").IsEnabled, "rejected credentials leave the account step available for retry");
                    Field<PasswordBox>(view, "PasswordInput").Password = "fixture-password"; await view.Login();
                    Check(connected is not null && connected.Profile.Kind == kind && connected.Libraries.Count == 1, "two-step login reads a real Core media library through the reverse proxy root");
                    Check(Field<PasswordBox>(view, "PasswordInput").Password.Length == 0, "successful connection clears the password field");
                    core.Servers.Save(connected!.Profile); created.Add(connected.Profile.Id);
                    await Capture(kind + "-account");
                    Check(Field<ScrollViewer>(view, "Viewport").ScrollableHeight < 1, "default window shows the complete account form without scrolling");
                }
                MediaServer? restored = null; var localSelected = false;
                var savedView = new ServerConnectionView(core, server => { restored = server; return Task.CompletedTask; }, () => { localSelected = true; });
                root.Children.Clear(); root.Children.Add(savedView); await Task.Delay(150);
                Check(Field<StackPanel>(savedView, "SavedServers").Children.Count == 2, "saved Jellyfin and Emby accounts appear as individual connection cards");
                Invoke(Walk(Field<StackPanel>(savedView, "SavedServers")).OfType<Button>().First());
                for (var attempt = 0; attempt < 100 && restored is null; attempt++) await Task.Delay(50);
                Check(restored is { Libraries.Count: 1 } && restored.Profile.Token == "fixture-only", "saved-server connection validates its endpoint and library using retained credentials");
                Field<TextBox>(savedView, "AddressInput").Text = "https://example.invalid/proxy";
                await Task.Delay(50);
                Check(Field<Microsoft.UI.Xaml.Controls.Primitives.ToggleButton>(savedView, "HttpsButton").IsChecked == true, "full server URLs automatically select HTTPS");
                Field<TextBox>(savedView, "AddressInput").Text = "";
                await Capture("light-address");
                root.RequestedTheme = ElementTheme.Dark; await Capture("dark-address");
                AppWindow.ResizeClient(new(650, 720)); await Capture("compact-address");
                Check(Field<StackPanel>(savedView, "Introduction").Visibility == Visibility.Collapsed && Field<Border>(savedView, "FormCard").ActualWidth <= root.ActualWidth,
                    "narrow windows show a centered form without the introduction column");
                Invoke(Field<Button>(savedView, "LocalPlayer"));
                Check(localSelected, "local-player entry continues without a server login");
                File.WriteAllText(Path.Combine(output, "results.json"), JsonSerializer.Serialize(new { passed = true, assertions }, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch (Exception ex) { File.WriteAllText(Path.Combine(output, "results.json"), JsonSerializer.Serialize(new { passed = false, error = ex.ToString(), assertions })); }
            finally { foreach (var id in created) core.Servers.Delete(id); Close(); }
        };
    }
    private sealed class ConnectionFixture : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _stop = new();
        public string Url { get; }
        public ConnectionFixture() { _listener.Start(); Url = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}/"; _ = Listen(); }
        private async Task Listen()
        {
            while (!_stop.IsCancellationRequested)
                try { var client = await _listener.AcceptTcpClientAsync(_stop.Token); _ = Respond(client); }
                catch (OperationCanceledException) { break; }
        }
        private static async Task Respond(TcpClient client)
        {
            using (client) try
            {
                using var stream = client.GetStream(); using var reader = new StreamReader(stream, Encoding.UTF8, false, leaveOpen: true);
                var target = (await reader.ReadLineAsync())!.Split(' ')[1]; var path = target.Split('?')[0]; var length = 0;
                while (await reader.ReadLineAsync() is { Length: > 0 } header) if (header.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = int.Parse(header[15..]);
                var bodyChars = new char[length]; if (length > 0) await reader.ReadBlockAsync(bodyChars);
                var kind = path.StartsWith("/emby/") ? "Emby" : "Jellyfin";
                var status = new string(bodyChars).Contains("wrong") ? 401 : 200;
                object response = path.EndsWith("/System/Info/Public") ? new { Id = "fixture-" + kind, ServerName = "私人影院 · " + kind, ProductName = kind, Version = "10.11" }
                    : path.EndsWith("AuthenticateByName") ? new { AccessToken = "fixture-only", User = new { Id = "fixture", Name = "fixture" } }
                    : path.EndsWith("Views") ? new { Items = new[] { new { Id = "movies", Name = "电影", CollectionType = "movies" } } }
                    : new { Items = Array.Empty<object>(), TotalRecordCount = 0 };
                var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(response));
                await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {bytes.Length}\r\nConnection: close\r\n\r\n")); await stream.WriteAsync(bytes);
            }
            catch (Exception ex) when (ex is IOException or OperationCanceledException) { }
        }
        public void Dispose() { _stop.Cancel(); _listener.Stop(); _stop.Dispose(); }
    }
}
#endif
