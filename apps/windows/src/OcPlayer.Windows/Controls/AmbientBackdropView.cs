using System.Numerics;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Services;
using Windows.Foundation;
using Windows.UI;

namespace OcPlayer.Windows.Controls;

// Fixed window background. Each scene fades as one group, including its image,
// blur and scrims. Detail's sharp/blurred brushes share one decoded surface.
public sealed class AmbientBackdropView : Grid, IDisposable
{
    private sealed class Scene(Compositor compositor) : IDisposable
    {
        public ContainerVisual Root { get; } = compositor.CreateContainerVisual();
        public SpriteVisual Sharp { get; } = compositor.CreateSpriteVisual();
        public SpriteVisual Blurred { get; } = compositor.CreateSpriteVisual();
        public SpriteVisual Veil { get; } = compositor.CreateSpriteVisual();
        public SpriteVisual Scrim { get; } = compositor.CreateSpriteVisual();
        public SpriteVisual Bottom { get; } = compositor.CreateSpriteVisual();
        public SpriteVisual Expanded { get; } = compositor.CreateSpriteVisual();
        public List<CompositionBrush> Brushes { get; } = [];
        public CompositionSurfaceBrush? BlurSource;
        public CompositionEffectBrush? Effect;
        public CompositionLinearGradientBrush? Mask;
        public CompositionColorBrush? VeilColor;
        public string? Key;
        public bool Detail;
        public IEnumerable<SpriteVisual> Visuals => [Sharp, Blurred, Veil, Scrim, Bottom, Expanded];
        public void Clear()
        {
            Root.StopAnimation("Opacity"); Root.Opacity = 0;
            Expanded.StopAnimation("Opacity"); Expanded.Opacity = 0;
            foreach (var visual in Visuals) visual.Brush = null;
            foreach (var brush in Brushes) brush.Dispose();
            Brushes.Clear(); BlurSource = null; Effect = null; Mask = null; VeilColor = null; Key = null;
        }
        public void Dispose() { Clear(); foreach (var visual in Visuals) visual.Dispose(); Root.Dispose(); }
    }

    private readonly Dictionary<string, (LoadedImageSurface Surface, Task<bool> Ready)> _cache = [];
    private readonly Scene[] _scenes;
    private readonly ContainerVisual _container;
    private readonly Compositor _compositor;
    private readonly CompositionEffectFactory? _blur;
    private int _front;
    private bool _dark = true, _expanded, _animations = true, _disposed;

    public AmbientBackdropView()
    {
        IsHitTestVisible = false;
        _compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
        _container = _compositor.CreateContainerVisual();
        _container.Clip = _compositor.CreateInsetClip();
        ElementCompositionPreview.SetElementChildVisual(this, _container);
        if (new CompositionCapabilities().AreEffectsSupported())
        {
            _blur = _compositor.CreateEffectFactory(new SaturationEffect
            {
                Name = "Saturation", Saturation = 1,
                Source = new GaussianBlurEffect { Name = "Blur", BlurAmount = 14, BorderMode = EffectBorderMode.Hard,
                    Source = new CompositionEffectSourceParameter("Image") }
            }, ["Blur.BlurAmount", "Saturation.Saturation"]);
        }
        _scenes = [new Scene(_compositor), new Scene(_compositor)];
        foreach (var scene in _scenes)
        {
            scene.Root.Opacity = 0;
            foreach (var visual in scene.Visuals) scene.Root.Children.InsertAtTop(visual);
            _container.Children.InsertAtTop(scene.Root);
        }
        SizeChanged += (_, _) => Resize();
    }

    private void Resize()
    {
        _container.Size = new Vector2((float)ActualWidth, (float)ActualHeight);
        foreach (var scene in _scenes)
        {
            scene.Root.Size = _container.Size;
            foreach (var visual in scene.Visuals) visual.Size = _container.Size;
            if (scene.BlurSource is not null)
                scene.BlurSource.TransformMatrix = Matrix3x2.CreateScale(scene.Detail ? 1.15f : 1.12f, _container.Size / 2);
            if (scene.Mask is not null) UpdateMask(scene, false);
        }
    }

    public void SetStyle(bool dark, bool expanded = false)
    {
        if (_disposed) return;
        var changedPage = _expanded != expanded;
        var changedTheme = _dark != dark;
        if (!changedPage && !changedTheme) return;
        _dark = dark; _expanded = expanded;
        foreach (var scene in _scenes)
        {
            if (scene.Key is null) continue;
            if (changedTheme) StyleScene(scene);
            // Header/data refreshes can apply the same style during a flip.
            // Only a page change should replace the running mask animation.
            if (scene.Detail && changedPage) UpdateMask(scene, _animations);
        }
    }

    public static Color PageColor(bool dark) => dark ? Color.FromArgb(255, 32, 34, 33) : Color.FromArgb(255, 245, 244, 242);
    private static Color Alpha(Color color, double opacity) => Color.FromArgb((byte)Math.Round(opacity * 255), color.R, color.G, color.B);

    private CompositionLinearGradientBrush Gradient(Scene scene, Vector2 end, params (float Offset, Color Color)[] stops)
    {
        var brush = _compositor.CreateLinearGradientBrush();
        brush.EndPoint = end;
        foreach (var stop in stops) brush.ColorStops.Add(_compositor.CreateColorGradientStop(stop.Offset, stop.Color));
        scene.Brushes.Add(brush);
        return brush;
    }

    private void StyleScene(Scene scene)
    {
        var tint = _dark ? Microsoft.UI.Colors.Black : Microsoft.UI.Colors.White;
        scene.Effect?.Properties.InsertScalar("Blur.BlurAmount", scene.Detail ? 30 : _dark ? 14 : 20);
        scene.Effect?.Properties.InsertScalar("Saturation.Saturation", scene.Detail ? 1.02f : 1);
        // Replace only tint brushes; image/mask references stay unchanged on theme changes.
        Replace(scene, scene.Scrim, scene.Detail
            ? Gradient(scene, new Vector2(1, 0), (0, Alpha(tint, _dark ? .58 : .62)), (.36f, Alpha(tint, .30)), (.66f, Alpha(tint, .06)), (1, Alpha(tint, 0)))
            : Gradient(scene, new Vector2(0, 1), (0, Alpha(tint, _dark ? .10 : .25)), (.12f, Alpha(tint, _dark ? .48 : .66)), (.85f, Alpha(PageColor(_dark), .88)), (1, PageColor(_dark))));
        Replace(scene, scene.Bottom, scene.Detail ? Gradient(scene, new Vector2(0, 1), (0, Alpha(tint, 0)), (.70f, Alpha(tint, 0)), (1, Alpha(tint, .42))) : null);
        var expandedTint = _compositor.CreateColorBrush(Alpha(tint, _dark ? .30 : .34));
        scene.Brushes.Add(expandedTint); Replace(scene, scene.Expanded, expandedTint);
        // A separate masked veil follows the blurred region, matching DetailPageArt.
        if (scene.Detail && scene.Mask is not null)
        {
            if (scene.VeilColor is null)
            {
                scene.VeilColor = _compositor.CreateColorBrush(); scene.Brushes.Add(scene.VeilColor);
                var veil = _compositor.CreateMaskBrush(); veil.Source = scene.VeilColor; veil.Mask = scene.Mask;
                scene.Brushes.Add(veil); scene.Veil.Brush = veil;
            }
            scene.VeilColor.Color = Alpha(tint, _dark ? .24 : .22);
        }
    }

    private static void Replace(Scene scene, SpriteVisual visual, CompositionBrush? brush)
    {
        var previous = visual.Brush;
        visual.Brush = brush;
        if (previous is not null) { scene.Brushes.Remove(previous); previous.Dispose(); }
    }

    private void UpdateMask(Scene scene, bool animate)
    {
        if (scene.Mask is null) return;
        var expanded = _expanded ? 1f : 0f;
        scene.Expanded.StopAnimation("Opacity");
        if (animate)
        {
            var tint = _compositor.CreateScalarKeyFrameAnimation();
            tint.Duration = PageMotion.DetailMask;
            tint.DelayTime = PageMotion.DetailMaskDelay(_expanded);
            tint.InsertKeyFrame(1, expanded, MaskEasing());
            scene.Expanded.StartAnimation("Opacity", tint);
        }
        else scene.Expanded.Opacity = expanded;
        var solid = _container.Size.X * (_expanded ? 1.75f : .34f);
        var start = new Vector2(solid, 0);
        var end = new Vector2(solid + _container.Size.X * .34f, 0);
        scene.Mask.StopAnimation("StartPoint"); scene.Mask.StopAnimation("EndPoint");
        if (animate)
        {
            AnimatePoint(scene.Mask, "StartPoint", start);
            AnimatePoint(scene.Mask, "EndPoint", end);
        }
        else { scene.Mask.StartPoint = start; scene.Mask.EndPoint = end; }
    }

    private void AnimatePoint(CompositionObject target, string property, Vector2 value)
    {
        var animation = _compositor.CreateVector2KeyFrameAnimation();
        animation.Duration = PageMotion.DetailMask;
        animation.DelayTime = PageMotion.DetailMaskDelay(_expanded);
        animation.InsertKeyFrame(1, value, MaskEasing());
        target.StartAnimation(property, animation);
    }

    private CompositionEasingFunction MaskEasing() =>
        _compositor.CreateCubicBezierEasingFunction(new Vector2(.42f, 0), new Vector2(.58f, 1));

    private static string Key(string source, bool detail) => (detail ? "1920:" : "512:") + source;

    public async Task<bool> WarmAsync(string source, CancellationToken token, bool detail = false)
    {
        if (_disposed || _blur is null || string.IsNullOrWhiteSpace(source)) return false;
        var key = Key(source, detail);
        if (!_cache.TryGetValue(key, out var entry))
        {
            if (!Uri.TryCreate(source, UriKind.Absolute, out var uri)) return false;
            // Eight pool images, an entry image and a bounded number of detail surfaces.
            if (_cache.Count >= 12)
            {
                var victim = _cache.OrderBy(x => x.Key.StartsWith("1920:") ? 0 : 1)
                    .FirstOrDefault(x => !_scenes.Any(s => s.Key == x.Key) && x.Value.Ready.IsCompleted);
                if (victim.Key is null) return false;
                victim.Value.Surface.Dispose(); _cache.Remove(victim.Key);
            }
            var pixels = detail ? 1920 : 512;
            var surface = LoadedImageSurface.StartLoadFromUri(uri, new Size(pixels, pixels));
            var ready = new TaskCompletionSource<bool>();
            surface.LoadCompleted += (_, args) => ready.TrySetResult(args.Status == LoadedImageSourceLoadStatus.Success);
            entry = (surface, ready.Task); _cache.Add(key, entry);
        }
        try { return await entry.Ready.WaitAsync(TimeSpan.FromSeconds(20), token); }
        catch (TimeoutException) { return false; }
    }

    public async Task<bool> ShowAsync(string source, bool animate, CancellationToken token, bool detail = false)
    {
        if (!await WarmAsync(source, token, detail)) return false;
        token.ThrowIfCancellationRequested();
        if (_disposed) return false;
        var key = Key(source, detail);
        if (_scenes[_front].Key == key) return true;
        var previous = _scenes[_front];
        _front = 1 - _front;
        var scene = _scenes[_front]; scene.Clear(); scene.Detail = detail; scene.Key = key;
        foreach (var current in _scenes) current.Root.StopAnimation("Opacity");
        var surface = _cache[key].Surface;
        CompositionSurfaceBrush ImageBrush()
        {
            var brush = _compositor.CreateSurfaceBrush(surface); brush.Stretch = CompositionStretch.UniformToFill;
            scene.Brushes.Add(brush); return brush;
        }
        scene.BlurSource = ImageBrush();
        scene.Effect = _blur!.CreateBrush(); scene.Effect.SetSourceParameter("Image", scene.BlurSource); scene.Brushes.Add(scene.Effect);
        if (detail)
        {
            scene.Sharp.Brush = ImageBrush();
            scene.Mask = Gradient(scene, new Vector2(1, 0), (0, Microsoft.UI.Colors.White), (1, Microsoft.UI.Colors.Transparent));
            scene.Mask.MappingMode = CompositionMappingMode.Absolute;
            var masked = _compositor.CreateMaskBrush(); masked.Source = scene.Effect; masked.Mask = scene.Mask;
            scene.Brushes.Add(masked); scene.Blurred.Brush = masked;
        }
        else scene.Blurred.Brush = scene.Effect;
        Resize(); StyleScene(scene);
        _container.Children.Remove(scene.Root); _container.Children.InsertAtTop(scene.Root);
        Visibility = Visibility.Visible;
        if (animate && previous.Key is not null)
        {
            scene.Root.Opacity = 1;
            var fade = _compositor.CreateScalarKeyFrameAnimation();
            fade.Duration = TimeSpan.FromSeconds(detail ? .35 : 1.6);
            fade.InsertKeyFrame(0, 0);
            fade.InsertKeyFrame(1, 1, _compositor.CreateCubicBezierEasingFunction(new Vector2(.42f, 0), new Vector2(.58f, 1)));
            scene.Root.StartAnimation("Opacity", fade);
        }
        else { previous.Root.Opacity = 0; scene.Root.Opacity = 1; }
        return true;
    }

    public Task<bool> ShowCachedAsync(string source, CancellationToken token)
        => _cache.TryGetValue(Key(source, false), out var entry) && entry.Ready.IsCompletedSuccessfully && entry.Ready.Result
            ? ShowAsync(source, false, token) : Task.FromResult(false);

    public void Hide(bool clearCache = false)
    {
        Visibility = Visibility.Collapsed;
        foreach (var scene in _scenes) scene.Clear();
        if (!clearCache) return;
        foreach (var entry in _cache.Values) entry.Surface.Dispose(); _cache.Clear();
    }

    public void SetAnimationsEnabled(bool enabled)
    {
        _animations = enabled;
        if (enabled) return;
        foreach (var scene in _scenes) { scene.Root.StopAnimation("Opacity"); if (scene.Detail) UpdateMask(scene, false); }
        _scenes[_front].Root.Opacity = 1; _scenes[1 - _front].Root.Opacity = 0;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; Hide(true);
        foreach (var scene in _scenes) scene.Dispose();
        _container.Dispose(); _blur?.Dispose();
    }
}
