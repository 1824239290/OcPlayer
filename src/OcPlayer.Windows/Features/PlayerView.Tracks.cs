using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows;

public sealed partial class PlayerView
{
    private int _demoSubtitleTrack = -1, _demoAudioTrack;
    private int _subtitleSelectionRevision;
    private double _subtitleScale = 1;
    private bool _trackPreferencesLoaded;
    private bool _subtitleChosenByUser;
    private int _lastPreferredTracksRevision = -1;
    private readonly Dictionary<long, string> _externalSubtitleNames = [];
    private readonly Dictionary<int, string> _demoExternalSubtitles = [];
    private PlaybackChapter[] _chapters = [];
    private CancellationTokenSource? _chapterCancellation;
    private long _trackGeneration;
    private bool _chaptersLoading;
    private string? _chapterLoadError;
    private MenuFlyout? _chapterMenu;
    private readonly List<MenuFlyoutItem> _chapterItems = [];
    private MenuFlyoutSubItem? _subtitleScaleMenu;
    private MenuFlyoutSubItem? _subtitleTracksMenu;
    private int PlaybackChapterCount => _chapters.Length;

    private void ResetTrackMenus()
    {
        _trackGeneration++;
        _chapterCancellation?.Cancel();
        _chapterCancellation = null;
        _chapterMenu?.Hide();
        _chapterMenu = null;
        _chapterItems.Clear();
        _chapters = [];
        _chaptersLoading = false;
        _chapterLoadError = null;
        _demoSubtitleTrack = -1;
        _subtitleChosenByUser = false;
        _lastPreferredTracksRevision = -1;
        _demoAudioTrack = 0;
        _externalSubtitleNames.Clear();
        _demoExternalSubtitles.Clear();
        _subtitleScaleMenu = null;
        _subtitleTracksMenu = null;
        if (!_trackPreferencesLoaded)
        {
            _subtitleScale = !_demoMode && App.Core is { } core ? PlaybackPreferences.Load(core.DataDirectory).SubtitleScale : 1;
            _trackPreferencesLoaded = true;
        }
        SubtitlePreview.FontSize = 24 * _subtitleScale;
        SubtitlePreview.Visibility = Visibility.Collapsed;
        if (_demoMode) _chapters = PlaybackChapters.Demo(_media.DurationSeconds);
        else if (_source?.Report is not null) LoadChapters();
        UpdateMenuIndicators();
    }

    private void DisposeTrackMenus()
    {
        _trackGeneration++;
        _chapterCancellation?.Cancel();
        _chapterCancellation = null;
        _chapterMenu?.Hide();
        _chapterMenu = null;
        _chapterItems.Clear();
        _subtitleScaleMenu = null;
        _subtitleTracksMenu = null;
    }

    private void RegisterExternalSubtitle(long id, string displayName)
    {
        if (!string.IsNullOrWhiteSpace(displayName)) _externalSubtitleNames[id] = displayName.Trim();
        RefreshSubtitleTracksMenu();
        UpdateMenuIndicators();
    }

    private JsonElement[] CurrentTracks(bool subtitle) => _session?.Tracks is { ValueKind: JsonValueKind.Array } tracks
        ? tracks.EnumerateArray().Where(track => track.TryGetProperty("kind", out var kind)
            && kind.TryGetInt32(out var value) && value == (subtitle ? 2 : 1)).ToArray()
        : [];

    private static bool TrackSelected(JsonElement track) => track.TryGetProperty("selected", out var selected)
        && selected.ValueKind == JsonValueKind.True;

    private static string? TrackText(JsonElement track, string key) => track.TryGetProperty(key, out var value)
        && value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(value.GetString()) ? value.GetString()!.Trim() : null;

    private string TrackLabel(JsonElement track)
    {
        var id = track.GetProperty("id").GetInt64();
        var external = track.TryGetProperty("source", out var source) && source.TryGetInt32(out var origin) && origin == 1;
        var title = external && _externalSubtitleNames.TryGetValue(id, out var name) ? name : TrackText(track, "title");
        if (title is null)
        {
            var parts = new List<string>();
            if (TrackText(track, "language") is { } language) parts.Add(language);
            if (TrackText(track, "codec") is { } codec) parts.Add(codec);
            if (track.GetProperty("kind").GetInt32() == 1 && track.TryGetProperty("channels", out var channels)
                && channels.TryGetInt32(out var count) && count > 0) parts.Add($"{count}ch");
            title = parts.Count > 0 ? string.Join(" · ", parts) : $"轨道 {id}";
        }
        return external ? $"{title}（外挂）" : title;
    }

    private RadioMenuFlyoutItem TrackChoice(string label, string group, bool selected, Action action)
    {
        var item = new RadioMenuFlyoutItem { Text = label, GroupName = group, IsChecked = selected };
        item.Click += (_, _) => RunMenuAction(() =>
        {
            action();
            if (group == "SubtitleTrack") { _subtitleSelectionRevision++; _subtitleChosenByUser = true; }
            if (group == "SubtitleTrack") RefreshSubtitleTracksMenu();
            UpdateMenuIndicators(); ShowHud();
        });
        return item;
    }

    private void Audio_Click(object sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout();
        if (_demoMode)
        {
            menu.Items.Add(TrackChoice("中文 · 立体声", "AudioTrack", _demoAudioTrack == 0, () => _demoAudioTrack = 0));
            menu.Items.Add(TrackChoice("English · 5.1", "AudioTrack", _demoAudioTrack == 1, () => _demoAudioTrack = 1));
        }
        else
        {
            var tracks = CurrentTracks(false);
            foreach (var track in tracks)
            {
                var id = track.GetProperty("id").GetInt64();
                menu.Items.Add(TrackChoice(TrackLabel(track), "AudioTrack", TrackSelected(track), () => _session?.SelectTrack(id, false)));
            }
            if (tracks.Length == 0) menu.Items.Add(new MenuFlyoutItem { Text = "当前媒体无独立多音轨", IsEnabled = false });
        }
        UpdateMenuIndicators();
        ShowMenu(sender, menu);
    }

    private string CurrentSubtitleLabel()
    {
        if (_demoMode) return _demoSubtitleTrack switch
        {
            < 0 => "关闭",
            0 => "简体中文",
            1 => "English",
            _ => _demoExternalSubtitles.TryGetValue(_demoSubtitleTrack, out var name) ? $"{name}（外挂）" : "关闭"
        };
        var selected = CurrentTracks(true).FirstOrDefault(TrackSelected);
        return selected.ValueKind == JsonValueKind.Object ? TrackLabel(selected) : "关闭";
    }

    private void Subtitles_Click(object sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout();
        var tracksMenu = _subtitleTracksMenu = new MenuFlyoutSubItem { Icon = new SymbolIcon(Symbol.ClosedCaption) };
        PopulateSubtitleTracksMenu(tracksMenu);
        menu.Items.Add(tracksMenu);
        var import = MenuAction("打开外挂字幕…", () => PickOverlay(false));
        import.Icon = new SymbolIcon(Symbol.OpenFile);
        import.IsEnabled = _demoMode || _session?.Ready == true;
        menu.Items.Add(import);
        var scaleMenu = _subtitleScaleMenu = new MenuFlyoutSubItem();
        PopulateSubtitleScaleMenu(scaleMenu);
        menu.Items.Add(scaleMenu);
        menu.Closed += (_, _) =>
        {
            if (ReferenceEquals(_subtitleScaleMenu, scaleMenu)) _subtitleScaleMenu = null;
            if (ReferenceEquals(_subtitleTracksMenu, tracksMenu)) _subtitleTracksMenu = null;
        };
        ShowMenu(sender, menu);
    }

    private void RefreshSubtitleTracksMenu()
    {
        if (_subtitleTracksMenu is { } menu) PopulateSubtitleTracksMenu(menu);
    }

    private void PopulateSubtitleTracksMenu(MenuFlyoutSubItem tracksMenu)
    {
        tracksMenu.Text = $"字幕轨道 · {CurrentSubtitleLabel()}";
        ToolTipService.SetToolTip(tracksMenu, tracksMenu.Text);
        tracksMenu.Items.Clear();
        if (_demoMode)
        {
            tracksMenu.Items.Add(TrackChoice("关闭字幕", "SubtitleTrack", _demoSubtitleTrack < 0, () => SelectDemoSubtitle(-1)));
            tracksMenu.Items.Add(TrackChoice("简体中文", "SubtitleTrack", _demoSubtitleTrack == 0, () => SelectDemoSubtitle(0)));
            tracksMenu.Items.Add(TrackChoice("English", "SubtitleTrack", _demoSubtitleTrack == 1, () => SelectDemoSubtitle(1)));
            foreach (var (id, name) in _demoExternalSubtitles)
                tracksMenu.Items.Add(TrackChoice($"{name}（外挂）", "SubtitleTrack", _demoSubtitleTrack == id, () => SelectDemoSubtitle(id)));
        }
        else
        {
            var tracks = CurrentTracks(true);
            tracksMenu.Items.Add(TrackChoice("关闭字幕", "SubtitleTrack", !tracks.Any(TrackSelected), () => _session?.SelectTrack(-1, true)));
            foreach (var track in tracks)
            {
                var id = track.GetProperty("id").GetInt64();
                tracksMenu.Items.Add(TrackChoice(TrackLabel(track), "SubtitleTrack", TrackSelected(track), () => _session?.SelectTrack(id, true)));
                if (track.TryGetProperty("canRemove", out var removable) && removable.ValueKind == JsonValueKind.True)
                {
                    var remove = MenuAction($"删除 · {TrackLabel(track)}", () => RemoveExternalSubtitle(id));
                    remove.Icon = new SymbolIcon(Symbol.Delete);
                    tracksMenu.Items.Add(remove);
                }
            }
        }
        AddServerSubtitleMenuItems(tracksMenu);
        ConstrainPlayerMenuItems([tracksMenu]);
    }

    private void RemoveExternalSubtitle(long id)
    {
        var selected = SelectedSubtitleId() == id;
        _session?.RemoveSubtitle(id);
        _externalSubtitleNames.Remove(id);
        foreach (var key in _loadedServerSubtitles.Where(x => x.Value.Id == id).Select(x => x.Key).ToArray())
        { _loadedServerSubtitles.Remove(key); _removedServerSubtitles.Add(key); }
        if (selected) { _subtitleChosenByUser = false; ApplyPreferredSubtitle(true); }
        RefreshSubtitleTracksMenu(); UpdateMenuIndicators();
    }

    private void ApplyPreferredSubtitle(bool force = false)
    {
        if (_subtitleChosenByUser || _session is not { Ready: true } session || App.Core is not { } core) return;
        if (!force && _lastPreferredTracksRevision == session.TracksRevision) return;
        var tracks = CurrentTracks(true).Select(track => new
        {
            id = track.GetProperty("id").GetInt64(), kind = "subtitle",
            source = track.TryGetProperty("source", out var origin) && origin.GetInt32() == 1 ? "external" : "embedded",
            selected = TrackSelected(track), title = TrackText(track, "title"), language = TrackText(track, "language"),
            displayName = _externalSubtitleNames.GetValueOrDefault(track.GetProperty("id").GetInt64()),
            canRemove = track.TryGetProperty("canRemove", out var remove) && remove.ValueKind == JsonValueKind.True
        }).ToArray();
        var preference = RuntimeSettings.Current.SubtitleLanguage;
        var current = SelectedSubtitleId();
        var choice = OcPlayer.CoreAdapter.PlaybackSession.Require(core.Client.Call("playbackTracks.selection", new
        { tracks, preference = preference == "default" ? "followSource" : preference, current = current >= 0 ? (long?)current : null }));
        var action = choice.GetProperty("action").GetString();
        if (action == "disable") session.SelectTrack(-1, true);
        else if (action == "select") session.SelectTrack(choice.GetProperty("id").GetInt64(), true);
        _lastPreferredTracksRevision = session.TracksRevision;
    }

    private void PopulateSubtitleScaleMenu(MenuFlyoutSubItem menu)
    {
        menu.Text = $"字体大小 · {_subtitleScale * 100:0}%";
        menu.Items.Clear();
        var smaller = MenuAction("减小", () => SetSubtitleScale(_subtitleScale - .1));
        smaller.IsEnabled = _subtitleScale > .5;
        menu.Items.Add(smaller);
        if (Math.Abs(_subtitleScale - 1) > .01) menu.Items.Add(MenuAction("重置", () => SetSubtitleScale(1)));
        var larger = MenuAction("加大", () => SetSubtitleScale(_subtitleScale + .1));
        larger.IsEnabled = _subtitleScale < 3;
        menu.Items.Add(larger);
        ConstrainPlayerMenuItems([menu]);
    }

    private void SetSubtitleScale(double scale)
    {
        scale = Math.Clamp(Math.Round(scale, 1), .5, 3);
        _session?.SetSubtitleScale(scale);
        _subtitleScale = scale;
        SubtitlePreview.FontSize = 24 * scale;
        if (!_demoMode && App.Core is { } core)
            (PlaybackPreferences.Load(core.DataDirectory) with { SubtitleScale = scale }).Save(core.DataDirectory);
        if (_subtitleScaleMenu is { } menu) PopulateSubtitleScaleMenu(menu);
    }

    private void SelectDemoSubtitle(int track)
    {
        _demoSubtitleTrack = track;
        SubtitlePreview.Text = track == 1 ? "Subtitle preview"
            : _demoExternalSubtitles.TryGetValue(track, out var name) ? $"外挂字幕预览 · {name}" : "字幕预览";
        SubtitlePreview.Visibility = track < 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void LoadChapters()
    {
        if (_closed || _demoMode || App.Core is not { } core || _source?.Report is not { } report) return;
        _chapterCancellation?.Cancel();
        var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        _chapterCancellation = cancellation;
        var generation = _trackGeneration;
        bool Current() => !_closed && generation == _trackGeneration && ReferenceEquals(_chapterCancellation, cancellation);
        _chaptersLoading = true;
        _chapterLoadError = null;
        RefreshChapterMenu();
        try
        {
            var chapters = await PlaybackChapters.LoadAsync(core.Client, report, cancellation.Token);
            if (Current()) _chapters = chapters;
        }
        catch (OperationCanceledException)
        {
            if (Current()) _chapterLoadError = "加载章节超时，请重试。";
        }
        catch (Exception ex)
        {
            if (Current()) _chapterLoadError = ex.Message;
        }
        finally
        {
            if (Current())
            {
                _chaptersLoading = false;
                _chapterCancellation = null;
                RefreshChapterMenu();
            }
            cancellation.Dispose();
        }
    }

    private void Chapters_Click(object sender, RoutedEventArgs e)
    {
        var menu = _chapterMenu = new MenuFlyout();
        RefreshChapterMenu();
        menu.Closed += (_, _) =>
        {
            if (ReferenceEquals(_chapterMenu, menu)) { _chapterMenu = null; _chapterItems.Clear(); }
        };
        ShowMenu(sender, menu);
    }

    private void RefreshChapterMenu()
    {
        if (_chapterMenu is not { } menu) return;
        menu.Items.Clear();
        _chapterItems.Clear();
        if (_chaptersLoading) menu.Items.Add(new MenuFlyoutItem { Text = "正在加载章节…", IsEnabled = false });
        else if (_chapterLoadError is { } error)
        {
            var failed = new MenuFlyoutItem { Text = "章节加载失败", IsEnabled = false };
            ToolTipService.SetToolTip(failed, error);
            menu.Items.Add(failed);
            menu.Items.Add(MenuAction("重试", LoadChapters));
        }
        else if (_chapters.Length == 0) menu.Items.Add(new MenuFlyoutItem { Text = "当前片源没有章节信息", IsEnabled = false });
        else
        {
            foreach (var chapter in _chapters)
            {
                var item = MenuAction($"{TimeLabel(chapter.StartSeconds)}  {chapter.Name}", () => SetPosition(chapter.StartSeconds));
                item.IsEnabled = _demoMode || _session?.Ready == true;
                ToolTipService.SetToolTip(item, chapter.Name);
                _chapterItems.Add(item);
                menu.Items.Add(item);
            }
        }
        ConstrainPlayerMenuItems(menu.Items);
        UpdateChapterSelection();
    }

    private void UpdateChapterSelection()
    {
        if (_chapterMenu is null || _chapterItems.Count == 0) return;
        var current = PlaybackChapters.CurrentIndex(_chapters, Timeline.Value);
        for (var index = 0; index < _chapterItems.Count; index++)
        {
            var item = _chapterItems[index];
            var selected = index == current;
            item.FontWeight = selected ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
            if (selected && item.Icon is null) item.Icon = new FontIcon { Glyph = "\uE768", FontSize = 12 };
            else if (!selected) item.Icon = null;
            item.IsEnabled = _demoMode || _session?.Ready == true;
        }
    }
}
