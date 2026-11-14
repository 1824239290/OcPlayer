#if DEBUG
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;

namespace OcPlayer.Windows.Preview;

// Explicit Debug-only capture mode for repeatable Windows visual acceptance over SSH.
internal static class DemoCapture
{
    public static void Attach(Window window)
    {
        var path=Environment.GetCommandLineArgs().FirstOrDefault(x=>x.StartsWith("--demo-capture="))?.Split('=',2)[1];
        if(path is null)return;
        var root=(FrameworkElement)window.Content;
        var timer=new DispatcherTimer{Interval=TimeSpan.FromSeconds(3)};
        timer.Tick+=async (_,_)=>
        {
            timer.Stop();
            try
            {
                var bitmap=new RenderTargetBitmap();await bitmap.RenderAsync(root);
                var pixels=await bitmap.GetPixelsAsync();
                using var stream=File.Create(path);using var random=stream.AsRandomAccessStream();
                var encoder=await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId,random);
                encoder.SetPixelData(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,(uint)bitmap.PixelWidth,(uint)bitmap.PixelHeight,96,96,pixels.ToArray());
                await encoder.FlushAsync();
                File.WriteAllText(path+".txt",$"Captured {bitmap.PixelWidth}x{bitmap.PixelHeight}");
            }
            catch(Exception ex){File.WriteAllText(path+".error.txt",ex.ToString());}
            finally{window.Close();Application.Current.Exit();}
        };
        root.Loaded+=(_,_)=>timer.Start();
    }
}
#endif
