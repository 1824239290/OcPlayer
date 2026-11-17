using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Animation;

namespace OcPlayer.Windows.Services;

// Keep the scrim and controls in one transition, but stop accepting input as
// soon as hiding starts. The caller owns idle timing and interaction policy.
internal sealed class PlayerHudVisibilityController : IDisposable
{
    private readonly FrameworkElement _hud;
    private readonly global::Windows.UI.ViewManagement.UISettings _uiSettings = new();
    private Action? _onVisibilityChanged;
    private Storyboard? _storyboard;
    private bool _disposed;

    public bool IsVisible { get; private set; } = true;

    public PlayerHudVisibilityController(FrameworkElement hud, Action onVisibilityChanged)
    {
        _hud = hud;
        _onVisibilityChanged = onVisibilityChanged;
        _hud.Opacity = 1;
        _hud.Visibility = Visibility.Visible;
        _hud.IsHitTestVisible = true;
    }

    public void Show() => SetVisible(true);
    public void Hide() => SetVisible(false);

    private void SetVisible(bool visible)
    {
        if (_disposed || IsVisible == visible) return;

        // Read the animated value before stopping, so reversing never jumps
        // back to the base opacity of the previous transition.
        var from = _hud.Opacity;
        StopAnimation();
        IsVisible = visible;
        var target = visible ? 1d : 0d;
        if (!_uiSettings.AnimationsEnabled || Math.Abs(from - target) < .001)
        {
            _hud.Opacity = target;
            SetPresentation(visible ? Visibility.Visible : Visibility.Collapsed, visible);
            return;
        }

        _hud.Opacity = from;
        SetPresentation(Visibility.Visible, visible);
        if (_disposed || IsVisible != visible) return;

        var animation = new DoubleAnimation
        {
            From = from,
            To = target,
            Duration = new Duration(TimeSpan.FromMilliseconds(200)),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        Storyboard.SetTarget(animation, _hud);
        Storyboard.SetTargetProperty(animation, "Opacity");
        var storyboard = new Storyboard();
        storyboard.Children.Add(animation);
        storyboard.Completed += FadeCompleted;
        _storyboard = storyboard;
        storyboard.Begin();
    }

    private void FadeCompleted(object? sender, object args)
    {
        if (_disposed || !ReferenceEquals(sender, _storyboard)) return;
        StopAnimation();
        _hud.Opacity = IsVisible ? 1 : 0;
        SetPresentation(IsVisible ? Visibility.Visible : Visibility.Collapsed, IsVisible);
    }

    private void SetPresentation(Visibility visibility, bool hitTestVisible)
    {
        var changed = _hud.Visibility != visibility || _hud.IsHitTestVisible != hitTestVisible;
        _hud.Visibility = visibility;
        _hud.IsHitTestVisible = hitTestVisible;
        if (changed && !_disposed) _onVisibilityChanged?.Invoke();
    }

    private void StopAnimation()
    {
        var storyboard = _storyboard;
        _storyboard = null;
        if (storyboard is null) return;
        storyboard.Completed -= FadeCompleted;
        storyboard.Stop();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _onVisibilityChanged = null;
        StopAnimation();
        _hud.Opacity = IsVisible ? 1 : 0;
        SetPresentation(IsVisible ? Visibility.Visible : Visibility.Collapsed, IsVisible);
    }
}
