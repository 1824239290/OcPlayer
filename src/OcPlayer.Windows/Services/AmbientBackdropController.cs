using Microsoft.UI.Xaml;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.ViewModels;

namespace OcPlayer.Windows.Services;

// One session-owned pool for the entire window, independent of the current page.
// A detail image temporarily overrides it; leaving detail restores the same pool.
internal sealed class AmbientBackdropController : IDisposable
{
    private readonly AmbientBackdropView _view;
    private readonly DemoViewModel _model;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(12) };
    private CancellationTokenSource? _poolLoad, _displayLoad;
    private MediaServer? _server;
    private bool _demo, _hasSession, _loadingPool, _active = true, _animations = true, _rotating, _disposed;
    private string _detailSource = "";
    private string[] _pool = [];
    private int _index, _generation;

    public AmbientBackdropController(AmbientBackdropView view, DemoViewModel model)
    {
        _view = view; _model = model;
        _timer.Tick += Rotate;
    }

    public void Update(bool retryEmptyPool = false)
    {
        if (_disposed) return;
        var server = _model.DemoMode ? null : App.Core?.Server;
        var changedSession = !_hasSession || !ReferenceEquals(server, _server) || _demo != _model.DemoMode;
        var detail = _model.Route is "detail" or "detail-info";
        var source = detail && _model.SelectedMedia.BackdropArtwork.Length > 0
            ? MediaServer.DetailImage(DemoMedia.AssetPath(_model.SelectedMedia.BackdropArtwork)) : "";
        _view.SetStyle(_model.DarkTheme, _model.Route == "detail-info");
        if (changedSession)
        {
            _poolLoad?.Cancel(); _poolLoad?.Dispose();
            _displayLoad?.Cancel(); _displayLoad?.Dispose(); _displayLoad = null;
            _timer.Stop(); _pool = []; _index = 0; ++_generation;
            _view.Hide(true);
            _server = server; _demo = _model.DemoMode; _hasSession = true;
        }
        if (changedSession || source != _detailSource || detail != _inDetail)
        {
            _displayLoad?.Cancel(); _displayLoad?.Dispose(); _displayLoad = new CancellationTokenSource();
            _detailSource = source; _inDetail = detail;
            if (detail) _ = PrepareDetailAsync(source, _displayLoad.Token);
            else if (_pool.Length > 0) _ = DisplayAsync(_pool[_index], false, _displayLoad.Token);
            else if (!detail) _view.Hide();
            // A detail with no artwork keeps the blurred entry snapshot, never a
            // clear frame from a different film, and never the live carousel.
        }
        // Retry a failed cold-start pool when home data arrives. Successful pools
        // survive refreshes and page rebuilds without re-querying or reshuffling.
        if (changedSession || retryEmptyPool && !_loadingPool && _pool.Length == 0)
        {
            _poolLoad?.Cancel(); _poolLoad?.Dispose(); _poolLoad = new CancellationTokenSource();
            _loadingPool = true;
            _ = LoadPoolAsync(server, _demo, _generation, _poolLoad.Token);
        }
    }

    private bool _inDetail;

    private async Task LoadPoolAsync(MediaServer? server, bool demo, int generation, CancellationToken token)
    {
        try
        {
            IEnumerable<DemoMedia> candidates = demo ? DemoCatalog.All : [];
            if (server is not null)
            {
                try { candidates = await server.RandomBackdrops(token); }
                catch (ServerConnectionException) { /* Fall back to the loaded home catalog. */ }
                if (!candidates.Any(x => x.BackdropArtwork.Length > 0)) candidates = server.Latest.Concat(server.Resume).Concat(server.NextUp);
            }
            token.ThrowIfCancellationRequested();
            var picked = candidates.Where(x => x.BackdropArtwork.Length > 0).DistinctBy(x => x.Id).ToArray();
            Random.Shared.Shuffle(picked);
            var sources = picked.Take(8).Select(x => MediaServer.AmbientImage(DemoMedia.AssetPath(x.BackdropArtwork))).Distinct().ToArray();
            var ready = new List<string>();
            foreach (var source in sources)
            {
                if (!await _view.WarmAsync(source, token)) continue;
                ready.Add(source);
                if (ready.Count == 1)
                {
                    _pool = ready.ToArray();
                    if (!_inDetail) await _view.ShowAsync(source, false, token);
                }
            }
            token.ThrowIfCancellationRequested();
            _pool = ready.ToArray();
            ResumeTimer();
        }
        catch (OperationCanceledException) { }
        catch (Exception) { /* Decorative image failures must not interrupt browsing. */ }
        finally { if (generation == _generation) _loadingPool = false; }
    }

    private async Task DisplayAsync(string source, bool detail, CancellationToken token)
    {
        try { await _view.ShowAsync(source, _animations, token, detail); }
        catch (OperationCanceledException) { }
        catch (Exception) { /* Keep the fixed entry image on failure. */ }
    }

    private async Task PrepareDetailAsync(string source, CancellationToken token)
    {
        try
        {
            // Capture only pixels already in the pool cache; don't start a second
            // network request for an entry image. It remains fixed until exit.
            if (_pool.Length == 0 || !await _view.ShowCachedAsync(_pool[_index], token)) _view.Hide();
            if (source.Length > 0) await _view.ShowAsync(source, _animations, token, true);
        }
        catch (OperationCanceledException) { }
        catch (Exception) { }
    }

    private async void Rotate(object? sender, object e)
    {
        if (_rotating || _pool.Length < 2 || _disposed) return;
        _index = (_index + 1) % _pool.Length;
        if (_inDetail) return;
        _rotating = true;
        try { await _view.ShowAsync(_pool[_index], _animations, _displayLoad?.Token ?? CancellationToken.None); }
        catch (OperationCanceledException) { }
        catch (Exception) { }
        finally { _rotating = false; }
    }

    public void SetActivity(bool active, bool animations)
    {
        if (_disposed) return;
        _active = active; _animations = animations;
        _view.SetAnimationsEnabled(animations);
        ResumeTimer();
    }

    private void ResumeTimer()
    {
        if (_active && _animations && _pool.Length > 1) { if (!_timer.IsEnabled) _timer.Start(); }
        else _timer.Stop();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; ++_generation;
        _timer.Stop(); _timer.Tick -= Rotate;
        _poolLoad?.Cancel(); _poolLoad?.Dispose(); _displayLoad?.Cancel(); _displayLoad?.Dispose();
        _view.Dispose();
    }
}
