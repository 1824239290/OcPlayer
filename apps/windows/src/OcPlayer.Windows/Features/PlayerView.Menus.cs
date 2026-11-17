using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace OcPlayer.Windows;

public sealed partial class PlayerView
{
    private bool _danmakuEnabled = true;

    private void ResetMenuState()
    {
        _danmakuEnabled = _demoMode || App.Core?.Danmaku.Settings.Current.Enabled != false;
        UpdateMenuIndicators();
    }

    private void UpdateMenuIndicators()
    {
        AudioButton.Opacity = _demoMode || CurrentTracks(false).Length > 0 ? 1 : .45;
        DanmakuButton.Opacity = _danmakuEnabled ? 1 : .45;
        ToolTipService.SetToolTip(DanmakuButton, _danmakuEnabled ? "弹幕" : "弹幕 · 已关闭");
        if (!_demoMode) DanmakuChanged();
    }

    private void Menu(object sender, params (string Label, Action Action)[] items)
    {
        var menu = new MenuFlyout();
        foreach (var (label, action) in items) menu.Items.Add(MenuAction(label, action));
        ShowMenu(sender, menu);
    }

    private MenuFlyoutItem MenuAction(string label, Action action)
    {
        var item = new MenuFlyoutItem { Text = label };
        item.Click += (_, _) => RunMenuAction(() => { action(); ShowHud(); });
        return item;
    }

    private void RunMenuAction(Action action)
    {
        try { action(); }
        catch (Exception ex) { ShowMoreNotice(ex.Message, InfoBarSeverity.Error); }
    }

    private async void PickOverlay(bool danmaku)
    {
        var generation = _mediaGeneration;
        BeginModalInteraction();
        try
        {
            var picker = new global::Windows.Storage.Pickers.FileOpenPicker();
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(_window));
            foreach (var extension in danmaku ? new[] { ".xml", ".json" } : new[] { ".ass", ".ssa", ".srt", ".vtt" })
                picker.FileTypeFilter.Add(extension);
            var file = await picker.PickSingleFileAsync();
            if (file is null || _closed || generation != _mediaGeneration) return;
            if (danmaku) _danmaku?.LoadLocal(file.Path, path =>
            {
                ImportLocalDanmaku(path); _danmakuShift = 0;
                _session?.SetDanmakuOffset(_danmakuOffset);
            });
            else if (_demoMode)
            {
                var id = _demoExternalSubtitles.Count + 2;
                _demoExternalSubtitles[id] = Path.GetFileNameWithoutExtension(file.Name);
                SelectDemoSubtitle(id);
                _subtitleSelectionRevision++;
                _subtitleChosenByUser = true;
            }
            else if (_session is not null)
            {
                var id = _session.LoadSubtitle(file.Path);
                RegisterExternalSubtitle(id, Path.GetFileNameWithoutExtension(file.Name));
                _subtitleSelectionRevision++;
                _subtitleChosenByUser = true;
            }
            UpdateMenuIndicators();
        }
        catch (Exception ex) { if (!_closed && generation == _mediaGeneration) { if (danmaku) ShowDanmakuError(ex.Message); else ShowMoreNotice(ex.Message, InfoBarSeverity.Error); } }
        finally { EndModalInteraction(); }
    }

    private void Rate_Click(object sender, RoutedEventArgs e) => ShowMoreMenu(sender);
}
