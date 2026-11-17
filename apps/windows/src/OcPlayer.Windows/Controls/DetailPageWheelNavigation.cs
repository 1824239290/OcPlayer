using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using OcPlayer.Windows.Services;
using Windows.System;
using Windows.UI.Core;

namespace OcPlayer.Windows.Controls;

internal static class DetailPageWheelNavigation
{
    public static void Attach(UIElement root, Action flip, ScrollViewer? body = null)
    {
        var gesture = new DetailWheelGesture(body is not null);
        // ScrollViewer handles PointerWheelChanged in its class handler. Observe
        // handled events on its parent, after the control has done its own work.
        root.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler((_, args) =>
        {
            var wheel = args.GetCurrentPoint(root).Properties;
            var shift = (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift) & CoreVirtualKeyStates.Down) != 0;
            if (wheel.IsHorizontalMouseWheel || shift || wheel.MouseWheelDelta == 0) return;
            var action = gesture.Handle(wheel.MouseWheelDelta, body is null || body.VerticalOffset <= 2, Environment.TickCount64);
            if (action != DetailWheelAction.Scroll) args.Handled = true;
            if (action == DetailWheelAction.Flip) flip();
        }), true);
    }
}
