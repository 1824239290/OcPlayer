using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows;

public sealed partial class PlayerView
{
    private CancellationTokenSource? _serverSubtitleCancellation;
    private long _serverSubtitleGeneration;
    private bool _serverSubtitlesStarted, _serverSubtitlesLoading, _serverSubtitlesFailed;
    private int _serverSubtitleSourceRevision;
    private string _serverSubtitleStatus = "等待加载服务器字幕";
    private string? _serverSubtitleError;
    private readonly Dictionary<string, (long Id, string? Language)> _loadedServerSubtitles = [];
    private readonly HashSet<string> _removedServerSubtitles = [];

    private void ResetServerSubtitles()
    {
        _serverSubtitleGeneration++;
        _serverSubtitleCancellation?.Cancel();
        _serverSubtitleCancellation = null;
        _serverSubtitlesStarted = _serverSubtitlesLoading = _serverSubtitlesFailed = false;
        _serverSubtitleSourceRevision = _subtitleSelectionRevision;
        _serverSubtitleStatus = "等待加载服务器字幕";
        _serverSubtitleError = null;
        _loadedServerSubtitles.Clear();
        _removedServerSubtitles.Clear();
    }

    private void DisposeServerSubtitles()
    {
        _serverSubtitleGeneration++;
        _serverSubtitleCancellation?.Cancel();
        _serverSubtitleCancellation = null;
    }

    private void StartServerSubtitlesIfReady()
    {
        if (!_closed && !_demoMode && !_serverSubtitlesStarted && _source?.Report is not null && _session?.Ready == true)
            LoadServerSubtitles();
    }

    private long SelectedSubtitleId()
    {
        var selected = CurrentTracks(true).FirstOrDefault(TrackSelected);
        return selected.ValueKind == System.Text.Json.JsonValueKind.Object ? selected.GetProperty("id").GetInt64() : -1;
    }

    private async void LoadServerSubtitles()
    {
        if (_closed || _demoMode || _serverSubtitlesLoading || _session is not { Ready: true } session
            || _source?.Report is not { } report || App.Core is not { } core) return;
        _serverSubtitlesStarted = _serverSubtitlesLoading = true;
        _serverSubtitlesFailed = false;
        _serverSubtitleError = null;
        _serverSubtitleStatus = "正在加载服务器字幕…";
        var cancellation = new CancellationTokenSource();
        _serverSubtitleCancellation = cancellation;
        var generation = _serverSubtitleGeneration;
        var revision = _subtitleSelectionRevision;
        var initiallyUnselected = SelectedSubtitleId() < 0;
        bool Current() => !_closed && generation == _serverSubtitleGeneration
            && ReferenceEquals(_serverSubtitleCancellation, cancellation) && ReferenceEquals(_session, session);
        RefreshSubtitleTracksMenu();
        try
        {
            var service = new ServerSubtitleService(core.Client, report, core.DataDirectory);
            var subtitles = await service.ListAsync(cancellation.Token);
            if (!Current()) return;
            // Downloads overlap (at most four); native track mutations remain on the UI thread
            // in server order so default selection and track ordering remain deterministic.
            using var slots = new SemaphoreSlim(4);
            var downloads = subtitles.Select(async subtitle =>
            {
                if (_loadedServerSubtitles.ContainsKey(subtitle.Key) || _removedServerSubtitles.Contains(subtitle.Key))
                    return (Subtitle: subtitle, Path: (string?)null, Error: (Exception?)null);
                await slots.WaitAsync(cancellation.Token);
                try { return (Subtitle: subtitle, Path: (string?)await service.DownloadAsync(subtitle, cancellation.Token), Error: (Exception?)null); }
                catch (Exception ex) { return (Subtitle: subtitle, Path: (string?)null, Error: ex); }
                finally { slots.Release(); }
            }).ToArray();
            var downloaded = await Task.WhenAll(downloads);
            var failures = 0;
            foreach (var result in downloaded)
            {
                var subtitle = result.Subtitle;
                cancellation.Token.ThrowIfCancellationRequested();
                if (!Current()) return;
                if (_removedServerSubtitles.Contains(subtitle.Key)) continue;
                if (_loadedServerSubtitles.TryGetValue(subtitle.Key, out var existing))
                {
                    RegisterExternalSubtitle(existing.Id, subtitle.DisplayName);
                    continue;
                }
                try
                {
                    if (result.Error is not null) throw result.Error;
                    var path = result.Path!;
                    if (!Current()) return;
                    cancellation.Token.ThrowIfCancellationRequested();
                    // Downloads yield to user input. Preserve the selection immediately before each native add,
                    // because this Erika build selects the newly added track automatically.
                    var selected = SelectedSubtitleId();
                    try
                    {
                        var id = session.LoadSubtitle(path);
                        _loadedServerSubtitles[subtitle.Key] = (id, subtitle.Language);
                        RegisterExternalSubtitle(id, subtitle.DisplayName);
                    }
                    finally
                    {
                        try { session.SelectTrack(selected, true); }
                        catch
                        {
                            // A broken restoration must stop the batch; later imports must not keep changing selection.
                            throw new SubtitleSelectionRestoreException();
                        }
                    }
                    _serverSubtitleStatus = $"正在加载服务器字幕 · 已加载 {_loadedServerSubtitles.Count} 条";
                    RefreshSubtitleTracksMenu();
                }
                catch (OperationCanceledException) { throw; }
                catch (SubtitleSelectionRestoreException) { throw; }
                catch (Exception ex)
                {
                    failures++;
                    _serverSubtitleError = ex is ServerSubtitleException ? ex.Message : "部分服务器字幕无法加载，请重试。";
                }
            }
            if (!Current()) return;
            ApplyPreferredSubtitle(true);
            _serverSubtitlesFailed = failures > 0;
            _serverSubtitleStatus = failures > 0 ? $"已加载 {_loadedServerSubtitles.Count} 条字幕，{failures} 条加载失败"
                : _loadedServerSubtitles.Count > 0 ? $"已加载 {_loadedServerSubtitles.Count} 条服务器字幕" : "服务器没有外挂字幕";
        }
        catch (OperationCanceledException)
        {
            if (Current())
            {
                _serverSubtitlesFailed = true;
                _serverSubtitleStatus = "服务器字幕加载超时";
                _serverSubtitleError = "加载服务器字幕超时，请重试。";
            }
        }
        catch (Exception ex)
        {
            if (Current())
            {
                _serverSubtitlesFailed = true;
                _serverSubtitleStatus = "服务器字幕加载失败";
                _serverSubtitleError = ex switch
                {
                    ServerSubtitleException => ex.Message,
                    SubtitleSelectionRestoreException => "恢复原字幕选择失败，请重新选择字幕后重试。",
                    _ => "服务器字幕暂时无法加载，请重试。"
                };
            }
        }
        finally
        {
            if (Current())
            {
                _serverSubtitlesLoading = false;
                _serverSubtitleCancellation = null;
                RefreshSubtitleTracksMenu();
                UpdateMenuIndicators();
            }
            cancellation.Dispose();
        }
    }

    private void AddServerSubtitleMenuItems(MenuFlyoutSubItem menu)
    {
        if (_demoMode || _source?.Report is null) return;
        menu.Items.Add(new MenuFlyoutSeparator());
        var status = new MenuFlyoutItem { Text = _serverSubtitleStatus, IsEnabled = false };
        if (_serverSubtitleError is not null) ToolTipService.SetToolTip(status, _serverSubtitleError);
        menu.Items.Add(status);
        if (_serverSubtitlesFailed && !_serverSubtitlesLoading)
        {
            var retry = new MenuFlyoutItem { Text = "重试加载服务器字幕", IsEnabled = _session?.Ready == true };
            retry.Click += (_, _) => { LoadServerSubtitles(); ShowHud(); };
            menu.Items.Add(retry);
        }
    }

    private static bool IsChineseSubtitle(string? language) => language is not null
        && (language.Contains("zh", StringComparison.OrdinalIgnoreCase) || language.Contains("chi", StringComparison.OrdinalIgnoreCase));
    private sealed class SubtitleSelectionRestoreException : Exception { }
}
