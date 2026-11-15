#if DEBUG
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.Preview;

// Runs in a real WinUI dispatcher/compositor, so it catches animations that
// compile successfully but never interpolate or leave the content hidden.
internal sealed class PageTransitionVerification : Window
{
    public PageTransitionVerification(string output)
    {
        Title = "OcPlayer · Transition verification";
        var host = new Grid();
        Content = host;
        host.Loaded += async (_, _) =>
        {
            var assertions = new List<string>();
            var samples = new List<object>();
            using var transitions = new PageTransitionController(host);
            void Check(bool passed, string label)
            {
                if (!passed) throw new InvalidOperationException(label);
                assertions.Add(label);
            }
            Grid Page(string title) => new() { Children = { new TextBlock { Text = title } } };
            void Sample(string stage, UIElement oldPage, UIElement newPage) => samples.Add(new { stage, outgoing = oldPage.Opacity, incoming = newPage.Opacity });
            try
            {
                var heroWheel = new DetailWheelGesture(false);
                Check(heroWheel.Handle(-120, true, 1000) == DetailWheelAction.Flip, "one downward wheel tick opens the detail body");
                var bodyWheel = new DetailWheelGesture(true);
                Check(bodyWheel.Handle(120, true, 1000) == DetailWheelAction.Flip, "one upward wheel tick at the body top returns to the hero");
                Check(bodyWheel.Handle(-120, true, 1020) == DetailWheelAction.Scroll, "downward input keeps native body scrolling");
                Check(bodyWheel.Handle(120, false, 1040) == DetailWheelAction.Scroll, "upward input below the body top keeps native scrolling");
                var smoothWheel = new DetailWheelGesture(true);
                Check(smoothWheel.Handle(10, false, 1000) == DetailWheelAction.Scroll
                    && smoothWheel.Handle(20, true, 1016) == DetailWheelAction.Consume, "a continuous smooth gesture reaching the top does not flip");
                Check(smoothWheel.Handle(10, true, 1200) == DetailWheelAction.Consume
                    && smoothWheel.Handle(10, true, 1216) == DetailWheelAction.Flip, "a new phase-free smooth gesture at the top can return");
                var first = Page("Home"); var second = Page("Settings");
                transitions.Show(first, PageTransitionKind.None);
                transitions.Show(second, PageTransitionKind.Section);
                await Task.Delay(100);
                Sample("section-midpoint", first, second);
                Check(first.Opacity is > 0 and < 1 && second.Opacity is > 0 and < 1, "section crossfade interpolates both pages");
                await Task.Delay(200);
                Check(host.Children.Count == 1 && second.Opacity == 1 && second.IsHitTestVisible && !transitions.IsTransitioning, "section removes the old page and restores input");

                var third = Page("Settings subpage");
                transitions.Show(third, PageTransitionKind.Route);
                await Task.Delay(220);
                Sample("route-exit", second, third);
                Check(second.Opacity is > 0 and < 1 && third.Opacity == 0, "route keeps new content hidden during exit");
                await Task.Delay(420);
                Sample("route-entry", second, third);
                Check(second.Opacity == 0 && third.Opacity is > 0 and < 1, "route fades in after the outgoing page disappears");
                await Task.Delay(400);
                Check(host.Children.Count == 1 && third.Opacity == 1 && !transitions.IsTransitioning, "route finishes without a hidden or duplicate page");

                var refreshed = Page("Server data arrived");
                transitions.Show(second, PageTransitionKind.Route);
                await Task.Delay(100);
                transitions.Show(refreshed, PageTransitionKind.None);
                Check(transitions.IsTransitioning, "same-route server refresh preserves the active transition");
                await Task.Delay(950);
                Check(ReferenceEquals(transitions.Content, refreshed) && host.Children.Count == 1 && refreshed.Opacity == 1, "server refresh lands after the route animation");
                third = refreshed;

                var fourth = Page("Detail body");
                transitions.Show(fourth, PageTransitionKind.DetailFlip);
                await Task.Delay(520);
                Sample("detail-background-only", third, fourth);
                Check(third.Opacity == 0 && fourth.Opacity == 0, "detail leaves a foreground-free interval for mask expansion");
                await Task.Delay(260);
                Sample("detail-reveal", third, fourth);
                Check(fourth.Opacity is > 0 and < 1 && !fourth.IsHitTestVisible, "detail body fades in while repeated input is blocked");
                await Task.Delay(300);
                Check(host.Children.Count == 1 && fourth.Opacity == 1 && fourth.IsHitTestVisible, "detail restores input after reveal");

                transitions.Show(first, PageTransitionKind.Route);
                await Task.Delay(100);
                transitions.Show(second, PageTransitionKind.Section);
                await Task.Delay(300);
                Check(ReferenceEquals(transitions.Content, second) && host.Children.Count == 1 && second.Opacity == 1, "a new navigation cancels stale animation completion");
                transitions.Show(third, PageTransitionKind.DetailFlip);
                await Task.Delay(100);
                transitions.SetAnimationsEnabled(false);
                Check(!transitions.IsTransitioning && host.Children.Count == 1 && third.Opacity == 1 && third.IsHitTestVisible, "disabling system animations settles active transitions");
                transitions.Show(first, PageTransitionKind.Route);
                Check(!transitions.IsTransitioning && host.Children.Count == 1 && first.Opacity == 1, "reduced motion navigates immediately");
                File.WriteAllText(output, JsonSerializer.Serialize(new { passed = true, assertions, samples }, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch (Exception error)
            {
                File.WriteAllText(output, JsonSerializer.Serialize(new { passed = false, error = error.ToString(), assertions, samples }, new JsonSerializerOptions { WriteIndented = true }));
            }
            finally { Close(); }
        };
    }
}
#endif
