using Microsoft.UI.Windowing;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;
using Windows.Graphics;

namespace OcPlayer.Windows;

public sealed partial class MainWindow
{
    private CancellationTokenSource? _playPrepare;
    private DemoMedia? _playingMedia;
    private PlaybackSource? _playingSource;
    private int _playingEpisode, _sourceAttempt;
    private SizeInt32? _sizeBeforePlayback;
    private sealed record NextEpisodeResult((DemoMedia Media, int Episode)? Next, bool Failed = false);
    private Task<NextEpisodeResult>? _nextEpisode;
    private async Task PrepareServerPlayback(DemoMedia media, int episode, MediaServer server, bool retry = false, bool alternate = false)
    {
        var resume = retry ? _player?.PositionSeconds ?? 0 : 0;
        _playPrepare?.Cancel(); _playPrepare?.Dispose(); _playPrepare = new CancellationTokenSource(); var token = _playPrepare.Token;
        if (!retry) { _sourceAttempt = 0; _nextEpisode = null; }
        if (alternate) _sourceAttempt++;
        if (_player is null) PresentPlayer(media);
        else { _player.CancelPreparation(); _player.ShowPreparation(media.Title); }
        _playingMedia = media; _playingEpisode = episode;
        var observed = _player;
        try
        {
            if (media.Kind is "episode" or "season" || media.Kind == "series" && media.Episodes is null)
            { media = await server.Detail(media, token); episode = media.InitialEpisodeNumber; }
            var source = await server.Resolve(media, episode, token, _sourceAttempt);
            token.ThrowIfCancellationRequested(); if (_player != observed || _closing) return;
            if (retry && resume > 0) source = source with { ResumeSeconds = resume };
            if (media.Episodes?.FirstOrDefault(x => x.Number == episode) is { } selected)
                media = media with { EpisodeLabel = $"S{selected.SeasonNumber}E{selected.Number}", EpisodeNumber = selected.Number, SeasonNumber = selected.SeasonNumber, Progress = selected.Progress, DurationSeconds = selected.DurationSeconds };
            _playingMedia = media; _playingEpisode = episode; _playingSource = source;
            _player!.SetMedia(media, source);
            _nextEpisode = PrefetchNext(server, media, episode, token);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (_player == observed && !token.IsCancellationRequested) { _player?.ShowPreparationFailure(ex.Message); AppDiagnostics.Write("error", ex.Message); } }
    }
    private static async Task<NextEpisodeResult> PrefetchNext(MediaServer server, DemoMedia media, int episode, CancellationToken token)
    {
        try { return new(await server.NextEpisode(media, episode, token)); }
        catch (OperationCanceledException) { return new(null, true); }
        catch (Exception ex) { AppDiagnostics.Write("warning", "下一集预取失败：" + ex.Message); return new(null, true); }
    }
    private async void Player_RetryRequested(object? sender, EventArgs args)
    {
        if (_playingMedia is not { } media || _player is null) return;
        if (media.SourceUri is null && App.Core?.Server is { } server) { _sourceAttempt = 0; await PrepareServerPlayback(media, _playingEpisode, server, true); }
        else _player.RetryPlayback(_playingSource is { } source ? source with { ResumeSeconds = _player.PositionSeconds } : null);
    }
    private async void Player_PlaybackFailed(PlaybackFailure failure)
    {
        if (_sourceAttempt >= 2 || !failure.CanTryAlternateSource || _playingMedia is not { SourceUri: null } media || App.Core?.Server is not { } server) return;
        await PrepareServerPlayback(media, _playingEpisode, server, true, true);
    }
    private async void Player_PlaybackEnded(object? sender, EventArgs args)
    {
        var player = _player; var media = _playingMedia; if (player is null || media is null || App.DemoMode) return;
        var episode = _playingEpisode;
        var preparation = _playPrepare;
        var source = _playingSource;
        bool Current() => _player == player && ReferenceEquals(_playingSource, source) && ReferenceEquals(_playPrepare, preparation) && !_closing;
        if (App.Core is { } core && media.Kind == "series")
        {
            var sync = core.Integrations.MarkLinkedEpisodeWatched(ViewingHistory.Source(core.Server), media, episode, CancellationToken.None);
            core.TrackReports(SafeSync(sync));
        }
        var result = _nextEpisode is { } pending ? await pending : new NextEpisodeResult(null);
        if (!Current()) return;
        if (result.Failed && App.Core?.Server is { } retryServer && preparation is not null)
            result = await PrefetchNext(retryServer, media, episode, preparation.Token);
        if (!Current()) return;
        if (result.Failed)
        {
            player.ShowPreparationFailure("当前集已播放完，暂时无法查询下一集。可以重试当前集，或返回剧集页选择下一集。");
            return;
        }
        var next = result.Next;
        if (next is { } candidate && App.Core?.Server is { } server)
        { _model.SelectedMedia = candidate.Media; _model.SelectedEpisode = candidate.Episode; await PrepareServerPlayback(candidate.Media, candidate.Episode, server); }
        else DismissPlayer();
    }
    private static async Task SafeSync(Task task) { try { await task; } catch (Exception ex) { AppDiagnostics.Write("warning", "Bangumi 章节同步失败：" + ex.Message); } }
    private void Player_VideoDimensionsAvailable(uint width, uint height)
    {
        if (width == 0 || height == 0 || _player is null || AppWindow.Presenter is not OverlappedPresenter { State: OverlappedPresenterState.Restored } presenter) return;
        _player.UpdateLayout();
        var scale = _player.XamlRoot?.RasterizationScale ?? 1;
        var viewportWidth = (int)Math.Round(_player.ActualWidth * scale);
        var viewportHeight = (int)Math.Round(_player.ActualHeight * scale);
        if (viewportWidth <= 0 || viewportHeight <= 0) return;
        var borderWidth = Math.Max(0, AppWindow.Size.Width - viewportWidth);
        var borderHeight = Math.Max(0, AppWindow.Size.Height - viewportHeight);
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var aspect = (double)width / height;
        var targetWidth = Math.Min(Math.Max(Math.Max(720, 360 * aspect), viewportWidth), Math.Max(1, area.Width * .9 - borderWidth));
        var targetHeight = targetWidth / aspect;
        var maxHeight = Math.Max(1, area.Height * .9 - borderHeight);
        if (targetHeight > maxHeight) { targetHeight = maxHeight; targetWidth = targetHeight * aspect; }
        var desiredWidth = Math.Max(1, (int)Math.Round(targetWidth)) + borderWidth;
        var desiredHeight = Math.Max(1, (int)Math.Round(targetHeight)) + borderHeight;
        if (presenter.PreferredMinimumHeight > desiredHeight) presenter.PreferredMinimumHeight = desiredHeight;
        if (presenter.PreferredMinimumWidth > desiredWidth) presenter.PreferredMinimumWidth = desiredWidth;
        AppWindow.Resize(new SizeInt32(desiredWidth, desiredHeight));
    }
}
