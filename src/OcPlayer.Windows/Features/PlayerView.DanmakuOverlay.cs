using System.Text.Json;
using System.Xml.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows;

public sealed partial class PlayerView
{
    private sealed record OverlayComment(double Time, int Mode, uint Color, string Text);
    private sealed record ScheduledComment(int Id, OverlayComment Comment, int Lane, double Width);
    private Canvas? _danmakuCanvas;
    private readonly DispatcherTimer _danmakuFrame = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private readonly List<OverlayComment> _overlayComments = [];
    private readonly List<ScheduledComment> _overlaySchedule = [];
    private readonly Dictionary<int, TextBlock> _overlayVisible = [];
    private bool _useKernelDanmaku = true;
    private double _overlayWidth, _overlayHeight;
    private const double OverlayLifetime = 8;

    private void InitializeDanmakuOverlay()
    {
        _danmakuCanvas = new Canvas { IsHitTestVisible = false };
        PlayerRoot.Children.Insert(PlayerRoot.Children.IndexOf(VideoPanel) + 1, _danmakuCanvas);
        _danmakuFrame.Tick += (_, _) => DrawDanmakuOverlay();
        _danmakuFrame.Start();
    }
    private void ClearDanmakuContent()
    {
        _session?.ClearDanmaku(); _overlayComments.Clear(); _overlaySchedule.Clear(); _overlayVisible.Clear(); _danmakuCanvas?.Children.Clear();
    }
    private void ApplyDanmakuContent(string json)
    {
        if (_useKernelDanmaku) { _session!.LoadDanmakuJson(json); return; }
        _session?.ClearDanmaku();
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var entries = root.ValueKind == JsonValueKind.Array ? root : root.TryGetProperty("comments", out var comments) ? comments : default;
        _overlayComments.Clear();
        if (entries.ValueKind != JsonValueKind.Array) throw new InvalidOperationException("弹幕 JSON 必须包含 comments 数组。");
        foreach (var value in entries.EnumerateArray())
        {
            var time = Json.Number(value, "time"); var mode = (int)Json.Number(value, "type"); var color = (uint)Json.Number(value, "color");
            var content = Json.First(value, "content", "text");
            if (time >= 0 && double.IsFinite(time) && mode is 1 or 4 or 5 && content.Length > 0)
                _overlayComments.Add(new(time, mode, color & 0xffffff, content));
        }
        _overlayComments.Sort((a, b) => a.Time.CompareTo(b.Time)); RebuildDanmakuOverlay();
    }
    private void ImportLocalDanmaku(string path)
    {
        if (_useKernelDanmaku) { _session!.LoadDanmaku(path); return; }
        if (Path.GetExtension(path).Equals(".xml", StringComparison.OrdinalIgnoreCase))
        {
            using var input = System.Xml.XmlReader.Create(path, new System.Xml.XmlReaderSettings { DtdProcessing = System.Xml.DtdProcessing.Prohibit, MaxCharactersInDocument = 64 * 1024 * 1024 });
            var document = XDocument.Load(input);
            var comments = document.Descendants("d").Select(x => (Parts: ((string?)x.Attribute("p") ?? "").Split(','), Text: x.Value))
                .Where(x => x.Parts.Length >= 4)
                .Select(x => new { time = double.TryParse(x.Parts[0], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var t) ? t : -1,
                    type = int.TryParse(x.Parts[1], out var mode) ? mode : 0, color = uint.TryParse(x.Parts[3], out var c) ? c : 0xffffff, content = x.Text });
            ApplyDanmakuContent(JsonSerializer.Serialize(new { comments }));
        }
        else ApplyDanmakuContent(File.ReadAllText(path));
    }
    private void RebuildDanmakuOverlay()
    {
        _overlaySchedule.Clear(); _overlayVisible.Clear(); _danmakuCanvas?.Children.Clear();
        if (_useKernelDanmaku || _danmakuCanvas is null) return;
        var p = CurrentDanmakuPreferences; _overlayWidth = PlayerRoot.ActualWidth; _overlayHeight = PlayerRoot.ActualHeight;
        _danmakuCanvas.Clip = new RectangleGeometry { Rect = new global::Windows.Foundation.Rect(0, 0, Math.Max(0, _overlayWidth), Math.Max(0, _overlayHeight)) };
        var rows = Math.Max(1, (int)(_overlayHeight * p.DisplayArea / (p.FontSize * 1.5)));
        var scroll = new double[rows]; var top = new double[rows]; var bottom = new double[rows]; var seen = new Dictionary<string, double>();
        var count = 0;
        foreach (var comment in _overlayComments)
        {
            if (comment.Mode == 1 && p.BlockScroll || comment.Mode == 5 && p.BlockTop || comment.Mode == 4 && p.BlockBottom) continue;
            if (p.MergeDuplicates && seen.TryGetValue(comment.Text, out var previous) && comment.Time - previous < OverlayLifetime) continue;
            seen[comment.Text] = comment.Time;
            var measure = new TextBlock { Text = comment.Text, FontSize = p.FontSize }; measure.Measure(new(double.PositiveInfinity, double.PositiveInfinity));
            var width = measure.DesiredSize.Width;
            var lanes = comment.Mode == 1 ? scroll : comment.Mode == 5 ? top : bottom;
            var lane = Array.FindIndex(lanes, time => time <= comment.Time);
            if (lane < 0) { if (!p.AllowStacking) continue; lane = count % rows; }
            // Scrolling comments reserve until their tail clears the launch edge, with a minimum gap.
            lanes[lane] = comment.Time + (comment.Mode == 1 ? Math.Max(1.2, OverlayLifetime * (width + 32) / Math.Max(1, _overlayWidth + width)) : OverlayLifetime);
            _overlaySchedule.Add(new(count++, comment, lane, width));
        }
    }
    private void DrawDanmakuOverlay()
    {
        if (_closed || _useKernelDanmaku || _danmakuCanvas is null || _session is null) return;
        var p = CurrentDanmakuPreferences; _danmakuCanvas.Visibility = p.Enabled ? Visibility.Visible : Visibility.Collapsed; _danmakuCanvas.Opacity = p.Opacity;
        if (!p.Enabled) return;
        if (Math.Abs(_overlayWidth - PlayerRoot.ActualWidth) > 1 || Math.Abs(_overlayHeight - PlayerRoot.ActualHeight) > 1) RebuildDanmakuOverlay();
        var position = _session.PositionSeconds - _danmakuShift - _danmakuOffset;
        // Binary seek gives the same output after a seek, pause or rate change, without a second clock.
        var low = 0; var high = _overlaySchedule.Count;
        while (low < high) { var mid = (low + high) / 2; if (_overlaySchedule[mid].Comment.Time < position - OverlayLifetime) low = mid + 1; else high = mid; }
        var active = new HashSet<int>();
        for (var i = low; i < _overlaySchedule.Count && _overlaySchedule[i].Comment.Time <= position && active.Count < 400; i++)
        {
            var scheduled = _overlaySchedule[i]; var item = scheduled.Comment; active.Add(scheduled.Id);
            if (!_overlayVisible.TryGetValue(scheduled.Id, out var text))
            {
                var c = item.Color; text = new TextBlock { Text = item.Text, FontSize = p.FontSize, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Foreground = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, (byte)(c >> 16), (byte)(c >> 8), (byte)c)),
                    IsHitTestVisible = false };
                _overlayVisible[scheduled.Id] = text; _danmakuCanvas.Children.Add(text);
            }
            var x = item.Mode == 1 ? _overlayWidth - (position - item.Time) / OverlayLifetime * (_overlayWidth + scheduled.Width) : (_overlayWidth - scheduled.Width) / 2;
            var y = item.Mode == 4 ? _overlayHeight * p.DisplayArea - (scheduled.Lane + 1) * p.FontSize * 1.5 : scheduled.Lane * p.FontSize * 1.5;
            Canvas.SetLeft(text, x); Canvas.SetTop(text, Math.Max(0, y));
        }
        foreach (var id in _overlayVisible.Keys.Where(id => !active.Contains(id)).ToArray()) { _danmakuCanvas.Children.Remove(_overlayVisible[id]); _overlayVisible.Remove(id); }
    }
}
