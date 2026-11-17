using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows;

public sealed partial class PlayerView
{
    private Button _skipButton = null!;
    private PlaybackSkipMark? _currentSkipMark;
    private readonly Dictionary<string, PlaybackSkipMark> _skipMarks = [];
    private readonly HashSet<string> _skippedKinds = [];
    private CancellationTokenSource? _segmentCancellation;
    private double _skipChaptersDuration = -1;
    private PlaybackChapter[]? _skipChaptersSnapshot;
    private bool _performingSkip;
    private bool _introLearningOpened;
    private long _lastLearnedAnime;
    private CancellationTokenSource? _introHintCancellation;
    private bool _introHintStarted;
    private DanmakuEpisode? _introMatch;
    private void InitializeSkipPrompts()
    {
        _skipButton = new Button { Content = "跳过片头", HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(24, 24, 28, 200), Visibility = Visibility.Collapsed };
        _skipButton.Click += (_, _) => PerformSkip();
        PlayerRoot.Children.Add(_skipButton);
    }
    private void ResetSkipPrompts()
    {
        _segmentCancellation?.Cancel(); _segmentCancellation = null;
        _skipMarks.Clear(); _skippedKinds.Clear(); _skipChaptersDuration = -1; _skipChaptersSnapshot = null;
        _lastLearnedAnime = 0;
        _introHintCancellation?.Cancel(); _introHintCancellation = null; _introHintStarted = false; _introMatch = null;
        _skipButton.Visibility = Visibility.Collapsed;
        if (!_demoMode && _source?.Report is not null) LoadSkipSegments();
    }
    private async void LoadSkipSegments()
    {
        if (App.Core is not { } core || _source?.Report is not { } report) return;
        var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(25)); _segmentCancellation = cancel;
        try
        {
            var marks = await PlaybackSkipMarks.LoadSegmentsAsync(core.Client, report, cancel.Token);
            if (_closed || cancel != _segmentCancellation) return;
            foreach (var mark in marks) MergeSkipMark(mark);
        }
        catch (OperationCanceledException) { }
        catch { /* MediaSegments is optional on older servers; chapter and community sources remain active. */ }
        finally { if (cancel == _segmentCancellation) _segmentCancellation = null; cancel.Dispose(); }
    }
    private void MergeSkipMark(PlaybackSkipMark mark)
    {
        if (!double.IsFinite(mark.Start) || !double.IsFinite(mark.End) || mark.Start < 0 || mark.End <= mark.Start + .5) return;
        if (_skipMarks.TryGetValue(mark.Kind, out var existing) && existing.Rank > mark.Rank) return;
        _skipMarks[mark.Kind] = mark;
    }
    private void ApplyExternalIntroHint(JsonElement? hint)
    {
        if (hint is not { ValueKind: JsonValueKind.Object } value || !value.TryGetProperty("endSeconds", out var ending) || ending.ValueKind != JsonValueKind.Number || !ending.TryGetDouble(out var end)) return;
        var start = value.TryGetProperty("startSeconds", out var beginning) && beginning.ValueKind == JsonValueKind.Number && beginning.TryGetDouble(out var number) ? number : 0;
        var source = value.TryGetProperty("source", out var origin) && origin.ValueKind == JsonValueKind.String ? origin.GetString() ?? "danmaku" : "danmaku";
        MergeSkipMark(new($"{source}-opening-{start:0.###}", "opening", source, start, end));
    }
    private void TickSkipPrompt()
    {
        if (!_introHintStarted && !_demoMode && _danmakuContext is not null && RuntimeSettings.Current.SkipIntro && App.Core?.Danmaku.Settings.Current.AutoLoad == false)
            LoadIndependentIntroHint();
        LoadLearnedIntroHint();
        var duration = _session?.DurationSeconds ?? (_demoMode ? Timeline.Maximum : 0);
        if (duration != _skipChaptersDuration || !ReferenceEquals(_chapters, _skipChaptersSnapshot))
        {
            _skipChaptersDuration = duration; _skipChaptersSnapshot = _chapters;
            foreach (var candidate in PlaybackSkipMarks.FromChapters(_chapters, duration, _source?.Metadata?.IsMovie ?? _media.Kind == "movie")) MergeSkipMark(candidate);
        }
        _currentSkipMark = null;
        if (_playing && duration > 0 && !PlaybackError.IsOpen && !_preparing)
        {
            var position = PositionSeconds;
            var settings = RuntimeSettings.Current;
            _currentSkipMark = _skipMarks.Values.FirstOrDefault(m => !_skippedKinds.Contains(m.Kind)
                && (m.Kind == "opening" ? settings.SkipIntro : settings.SkipOutro) && position >= m.Start && position < m.End);
            if (_currentSkipMark is null && settings.SkipOutro && !_skippedKinds.Contains("credits") && duration - position <= 90 && duration - position > Math.Max(1, settings.OutroRetainSeconds))
                _currentSkipMark = new("fallback-credits", "credits", "fallback", position, duration);
        }
        _skipButton.Visibility = _currentSkipMark is null ? Visibility.Collapsed : Visibility.Visible;
        if (_currentSkipMark is { } mark) { _skipButton.Content = mark.Label; Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_skipButton, mark.Label); }
        _skipButton.Margin = new Thickness(24, 24, 28, _hudVisibility.IsVisible ? 200 : 38);
    }
    private void PerformSkip()
    {
        if (_currentSkipMark is not { } mark) return;
        var duration = _session?.DurationSeconds ?? Timeline.Maximum;
        var target = mark.Kind == "credits" ? Math.Max(PositionSeconds, Math.Min(mark.End, duration - RuntimeSettings.Current.OutroRetainSeconds)) : mark.End;
        _skippedKinds.Add(mark.Kind); _performingSkip = true;
        try { Run(() => SetPosition(target)); } finally { _performingSkip = false; }
        TickSkipPrompt();
    }
    private void LearnIntroFromSeek(double from, double to)
    {
        if (_performingSkip || _preparing) return;
        RecordDanmakuIntroSeek(from, to);
    }
    private void EnsureIntroLearning()
    {
        if (_introLearningOpened || App.Core is not { } core) return;
        OcPlayer.CoreAdapter.PlaybackSession.Require(core.Client.Call("introLearning.open", new { directory = Path.GetFullPath(Path.Combine(core.DataDirectory, "Danmaku")) }));
        _introLearningOpened = true;
    }
    private void LoadLearnedIntroHint()
    {
        if ((_danmaku?.CurrentMatch ?? _introMatch) is not { AnimeId: > 0 } match || match.AnimeId == _lastLearnedAnime || App.Core is not { } core) return;
        _lastLearnedAnime = match.AnimeId;
        try
        {
            EnsureIntroLearning();
            var result = OcPlayer.CoreAdapter.PlaybackSession.Require(core.Client.Call("introLearning.promotedHint", new { animeID = match.AnimeId }));
            if (result.TryGetProperty("payloadJSON", out var json) && json.ValueKind == JsonValueKind.String)
            { using var doc = JsonDocument.Parse(json.GetString()!); ApplyExternalIntroHint(doc.RootElement); }
        }
        catch { LogPlaybackDiagnostic("intro learning read failed"); }
    }
    private void RecordDanmakuIntroSeek(double from, double to)
    {
        if ((_danmaku?.CurrentMatch ?? _introMatch) is not { } match || App.Core is not { } core || to - from < 5 || to < 30 || to > 360) return;
        try
        {
            EnsureIntroLearning();
            var input = new { @match = new { episodeID = match.EpisodeId, animeID = match.AnimeId, shiftSeconds = (long)Math.Round(_danmakuShift), animeTitle = match.AnimeTitle, episodeTitle = match.EpisodeTitle }, from, to };
            var result = OcPlayer.CoreAdapter.PlaybackSession.Require(core.Client.Call("introLearning.applySeek", new { payloadJSON = JsonSerializer.Serialize(input) }));
            if (result.TryGetProperty("payloadJSON", out var json) && json.ValueKind == JsonValueKind.String)
            {
                using var document = JsonDocument.Parse(json.GetString()!);
                if (document.RootElement.TryGetProperty("hint", out var hint)) ApplyExternalIntroHint(hint);
            }
        }
        catch { LogPlaybackDiagnostic("intro learning save failed"); }
    }
    private async void LoadIndependentIntroHint()
    {
        if (_danmakuContext is not { } context || App.Core is not { } core) return;
        _introHintStarted = true;
        var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(60)); _introHintCancellation = cancel;
        try
        {
            var payload = await core.Danmaku.Load(context, false, null, cancel.Token);
            if (_closed || cancel != _introHintCancellation) return;
            _introMatch = payload.Match;
            ApplyExternalIntroHint(payload.IntroHint);
        }
        catch (OperationCanceledException) { }
        catch { LogPlaybackDiagnostic("independent intro hint unavailable"); }
        finally { if (cancel == _introHintCancellation) _introHintCancellation = null; cancel.Dispose(); }
    }
    private void DisposeSkipPrompts() { _segmentCancellation?.Cancel(); _segmentCancellation = null; _introHintCancellation?.Cancel(); _introHintCancellation = null; }
}
