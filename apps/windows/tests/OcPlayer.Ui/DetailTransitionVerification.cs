#if DEBUG
using System.Text.Json;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows;

public sealed partial class MainWindow
{
    // Exercise Navigate itself: both the route and integration header refresh
    // update the backdrop, which the isolated foreground test does not cover.
    private void AttachDetailTransitionVerification()
    {
        var output = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--demo-verify-detail-transitions="))?.Split('=', 2)[1];
        if (output is null) return;
        WindowRoot.Loaded += async (_, _) =>
        {
            var assertions = new List<string>();
            var samples = new List<object>();
            void Check(bool passed, string label)
            {
                if (!passed) throw new InvalidOperationException(label);
                assertions.Add(label);
            }
            CompositionLinearGradientBrush? Mask()
            {
                var container = (ContainerVisual)ElementCompositionPreview.GetElementChildVisual(Ambience);
                return container.Children.OfType<ContainerVisual>().SelectMany(x => x.Children).OfType<SpriteVisual>()
                    .Select(x => x.Brush).OfType<CompositionMaskBrush>()
                    .Select(x => x.Mask).OfType<CompositionLinearGradientBrush>().FirstOrDefault();
            }
            CompositionScopedBatch BeginMaskBatch(out Task completion)
            {
                var finished = new TaskCompletionSource();
                var compositor = ElementCompositionPreview.GetElementChildVisual(Ambience).Compositor;
                var batch = compositor.CreateScopedBatch(CompositionBatchTypes.Animation);
                batch.Completed += (_, _) => finished.TrySetResult();
                completion = finished.Task;
                return batch;
            }
            void CheckMaskAnimation(Task completion, string stage)
            {
                samples.Add(new { stage, maskBatchCompleted = completion.IsCompleted });
                Check(!completion.IsCompleted, stage + " keeps the blur mask animation running");
            }
            async Task Settle()
            {
                for (var i = 0; i < 40 && _transitions.IsTransitioning; i++) await Task.Delay(50);
                Check(!_transitions.IsTransitioning, "detail foreground transition completes");
            }
            void CloseVerification()
            {
                // Release native composition objects while the window still
                // owns its compositor, before Window.Close destroys it.
                _closing = true;
                _exitReady = true;
                _ambient.Dispose();
                _transitions.Dispose();
                Close();
                Application.Current.Exit();
            }
            try
            {
                Check(_uiSettings.AnimationsEnabled, "Windows animations are enabled for the live regression");
                _model.SelectedMedia = DemoCatalog.All[4];
                _model.SelectedEpisode = _model.SelectedMedia.InitialEpisodeNumber;
                Navigate("detail");
                await Settle();
                for (var i = 0; i < 100 && Mask() is null; i++) await Task.Delay(50);
                Check(Mask() is not null, "real detail artwork and its composition mask load");

                var hero = _transitions.Content!;
                UIElement body;
                using (var batch = BeginMaskBatch(out var completion))
                {
                    Navigate("detail-info");
                    body = _transitions.Content!;
                    batch.End();
                    Check(Mask()!.StartPoint.X < Ambience.ActualWidth * 1.75 - 1,
                        "hero-to-body starts without snapping the mask to its expanded endpoint");
                    await Task.Delay(250);
                    CheckMaskAnimation(completion, "hero-to-body midpoint");
                    Check(hero.Opacity is > 0 and < 1 && body.Opacity == 0, "real detail flip fades the hero before revealing the body");
                    _ambient.Update();
                    await Task.Delay(50);
                    CheckMaskAnimation(completion, "same-route backdrop refresh");
                    Navigate("detail");
                    Check(_model.Route == "detail-info" && ReferenceEquals(_transitions.Content, body), "repeated flip input is blocked until reveal finishes");
                    await Settle();
                    await completion.WaitAsync(TimeSpan.FromSeconds(1));
                    Check(completion.IsCompletedSuccessfully, "expanded mask batch finishes normally");
                }
                Check(body.Opacity == 1 && body.IsHitTestVisible && PageHost.Children.Count == 1, "detail body finishes visible with input restored");

                using (var batch = BeginMaskBatch(out var completion))
                {
                    Navigate("detail");
                    batch.End();
                    Check(ReferenceEquals(_transitions.Content, hero), "return flip restores the cached hero");
                    await Task.Delay(300);
                    CheckMaskAnimation(completion, "body-to-hero midpoint");
                    Ambience.SetStyle(!_model.DarkTheme);
                    await Task.Delay(50);
                    CheckMaskAnimation(completion, "theme refresh during return");
                    await Settle();
                    await completion.WaitAsync(TimeSpan.FromSeconds(1));
                    Check(completion.IsCompletedSuccessfully, "collapsed mask batch finishes normally");
                }
                Check(hero.Opacity == 1 && hero.IsHitTestVisible && PageHost.Children.Count == 1, "hero return finishes visible with input restored");

                Navigate("detail-info");
                Ambience.SetAnimationsEnabled(false);
                _transitions.SetAnimationsEnabled(false);
                var mask = Mask()!;
                Check(Math.Abs(mask.StartPoint.X - Ambience.ActualWidth * 1.75) < 1,
                    "reduced motion settles the expanded mask immediately");
                Check(!_transitions.IsTransitioning && _transitions.Content!.Opacity == 1 && PageHost.Children.Count == 1,
                    "reduced motion settles the detail foreground immediately");
            }
            catch (Exception error)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
                File.WriteAllText(output, JsonSerializer.Serialize(new { passed = false, error = error.ToString(), assertions, samples }, new JsonSerializerOptions { WriteIndented = true }));
                CloseVerification();
                return;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
            File.WriteAllText(output, JsonSerializer.Serialize(new { passed = true, assertions, samples }, new JsonSerializerOptions { WriteIndented = true }));
            CloseVerification();
        };
    }
}
#endif
