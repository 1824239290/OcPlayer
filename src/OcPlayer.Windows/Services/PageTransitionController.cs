using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace OcPlayer.Windows.Services;

internal enum PageTransitionKind { None, Section, Route, DetailFlip }

// Matches macOS AppDesignKit/Motion and DetailPagePager (888ccdd).
internal static class PageMotion
{
    public static readonly TimeSpan Standard = TimeSpan.FromSeconds(.2);
    public static readonly TimeSpan RouteFade = TimeSpan.FromSeconds(.45);
    public static readonly TimeSpan RestoreDelay = TimeSpan.FromSeconds(.05);
    public static readonly TimeSpan DetailRevealDelay = TimeSpan.FromSeconds(.6);
    public static readonly TimeSpan DetailReveal = TimeSpan.FromSeconds(.4);
    public static readonly TimeSpan DetailMask = TimeSpan.FromSeconds(.55);
    public static TimeSpan DetailMaskDelay(bool expanded) => TimeSpan.FromSeconds(expanded ? .05 : .2);
}

// Owns both foregrounds until the outgoing animation completes. The fixed
// window backdrop stays outside this host, so transparent pages never flash.
internal sealed class PageTransitionController(Grid host) : IDisposable
{
    private Storyboard? _storyboard;
    private UIElement? _pendingContent;
    private bool _animations = true;
    public UIElement? Content { get; private set; }
    public bool IsTransitioning => _storyboard is not null;

    public void Show(UIElement content, PageTransitionKind kind)
    {
        // A fast server response rebuilds the same route while its foreground
        // is still entering. Finish that transition before applying the refresh.
        if (kind == PageTransitionKind.None && IsTransitioning)
        {
            _pendingContent = content;
            return;
        }
        Complete();
        var outgoing = Content;
        Content = content;
        if (!_animations || kind == PageTransitionKind.None || outgoing is null || ReferenceEquals(content, outgoing))
        {
            host.Children.Clear();
            content.Opacity = 1;
            content.IsHitTestVisible = true;
            host.Children.Add(content);
            return;
        }

        content.Opacity = 0;
        content.IsHitTestVisible = false;
        outgoing.IsHitTestVisible = false;
        host.Children.Add(content);
        var storyboard = new Storyboard();
        var fade = kind == PageTransitionKind.Section ? PageMotion.Standard : PageMotion.RouteFade;
        var delay = kind switch
        {
            PageTransitionKind.Section => TimeSpan.Zero,
            PageTransitionKind.DetailFlip => PageMotion.DetailRevealDelay,
            _ => PageMotion.RouteFade + PageMotion.RestoreDelay
        };
        var reveal = kind switch
        {
            PageTransitionKind.Section => PageMotion.Standard,
            PageTransitionKind.DetailFlip => PageMotion.DetailReveal,
            _ => PageMotion.RouteFade
        };
        AddFade(storyboard, outgoing, 1, 0, fade, TimeSpan.Zero);
        AddFade(storyboard, content, 0, 1, reveal, delay);
        _storyboard = storyboard;
        storyboard.Completed += (_, _) => { if (ReferenceEquals(_storyboard, storyboard)) Complete(); };
        storyboard.Begin();
    }

    private static void AddFade(Storyboard storyboard, UIElement target, double from, double to, TimeSpan duration, TimeSpan delay)
    {
        var animation = new DoubleAnimation
        {
            From = from, To = to, Duration = new Duration(duration), BeginTime = delay,
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut }
        };
        Storyboard.SetTarget(animation, target);
        Storyboard.SetTargetProperty(animation, "Opacity");
        storyboard.Children.Add(animation);
    }

    public void SetAnimationsEnabled(bool enabled)
    {
        _animations = enabled;
        if (!enabled) Complete();
    }

    private void Complete()
    {
        var storyboard = _storyboard;
        _storyboard = null;
        storyboard?.Stop();
        if (_pendingContent is { } pending)
        {
            _pendingContent = null;
            Content = pending;
            host.Children.Add(pending);
        }
        foreach (var child in host.Children.ToArray())
        {
            child.Opacity = 1;
            child.IsHitTestVisible = true;
            if (!ReferenceEquals(child, Content)) host.Children.Remove(child);
        }
        if (Content is not null) { Content.Opacity = 1; Content.IsHitTestVisible = true; }
    }

    public void Dispose() => Complete();
}
