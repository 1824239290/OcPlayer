using OcPlayer.Windows.Preview;

// Execute the production controller without a compositor or WinUI message loop.
// These surfaces complete image loads immediately so lifecycle transitions are
// deterministic; network/login behavior remains covered by the real Core tests.
namespace Microsoft.UI.Xaml
{
    internal sealed class DispatcherTimer
    {
        public TimeSpan Interval { get; set; }
        public bool IsEnabled { get; private set; }
        public event EventHandler<object>? Tick { add { } remove { } }
        public void Start() => IsEnabled = true;
        public void Stop() => IsEnabled = false;
    }
}

namespace OcPlayer.Windows
{
    internal static class App
    {
        public static Services.CoreRuntime? Core => null;
    }
}

namespace OcPlayer.Windows.ViewModels
{
    internal sealed class DemoViewModel
    {
        public bool DemoMode { get; set; }
        public bool DarkTheme => true;
        public string Route { get; set; } = "home";
        public DemoMedia SelectedMedia => DemoCatalog.All[0];
    }
}

namespace OcPlayer.Windows.Controls
{
    internal sealed class AmbientBackdropView : IDisposable
    {
        public string? CurrentSource { get; private set; }
        public bool Disposed { get; private set; }
        public void SetStyle(bool dark, bool expanded = false) { }
        public void SetAnimationsEnabled(bool enabled) { }
        public Task<bool> WarmAsync(string source, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            return Task.FromResult(true);
        }
        public Task<bool> ShowAsync(string source, bool animate, CancellationToken token, bool detail = false)
        {
            token.ThrowIfCancellationRequested();
            CurrentSource = source;
            return Task.FromResult(true);
        }
        public Task<bool> ShowCachedAsync(string source, CancellationToken token)
            => ShowAsync(source, false, token);
        public void Hide(bool clearCache = false) => CurrentSource = null;
        public void Dispose() { Disposed = true; Hide(true); }
    }
}
