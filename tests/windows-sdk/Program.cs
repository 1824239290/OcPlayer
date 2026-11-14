using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using OcPlayer.Core;
using OcPlayer.CoreAdapter;

static class Fixture
{
    const string Name = "ocp_fixture";
    [DllImport(Name, CallingConvention = CallingConvention.Cdecl)] public static extern int fixture_created();
    [DllImport(Name, CallingConvention = CallingConvention.Cdecl)] public static extern int fixture_destroyed();
    [DllImport(Name, CallingConvention = CallingConvention.Cdecl)] public static extern int fixture_allocated();
    [DllImport(Name, CallingConvention = CallingConvention.Cdecl)] public static extern int fixture_freed();
    [DllImport(Name, CallingConvention = CallingConvention.Cdecl)] public static extern int fixture_active();
    [DllImport(Name, CallingConvention = CallingConvention.Cdecl)] public static extern int fixture_uaf();
    [DllImport(Name, CallingConvention = CallingConvention.Cdecl)] public static extern int fixture_cancelled();
    [DllImport(Name, CallingConvention = CallingConvention.Cdecl)] public static extern void fixture_release();
    [DllImport(Name, CallingConvention = CallingConvention.Cdecl)] public static extern void fixture_reset_release();
}
static class Contracts
{
    static int checks;
    static readonly List<string> passed = [];
    static void Check(bool value, string message) { if (!value) throw new Exception(message); checks++; }
    static void Throws<T>(Action action) where T : Exception
    {
        try { action(); } catch (T) { checks++; return; }
        throw new Exception($"Expected {typeof(T).Name}");
    }
    static async Task ThrowsAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action(); } catch (T) { checks++; return; }
        throw new Exception($"Expected {typeof(T).Name}");
    }
    static async Task Active()
    {
        var watch=Stopwatch.StartNew();
        while (Fixture.fixture_active()==0) { if(watch.ElapsedMilliseconds>2000) throw new Exception("Native call never started"); await Task.Delay(5); }
    }
    static void Balance()
    {
        Check(Fixture.fixture_allocated()==Fixture.fixture_freed(),"Native strings leaked");
        Check(Fixture.fixture_uaf()==0,"Core was touched/destroyed during an active call");
    }
    [MethodImpl(MethodImplOptions.NoInlining)]
    static WeakReference Abandoned()
    {
        var core=new OcpCore();_ = core.Call("echo");return new WeakReference(core);
    }
    static async Task Mock()
    {
        using(var client=new OcpCoreClient())
        {
            var exact=client.Call("echo","{\"id\":9223372036854775807,\"negative\":-9223372036854775808,\"text\":\"雪✓🧪\"}");
            Check(exact.Data.GetProperty("id").GetInt64()==long.MaxValue,"Integer lost precision");
            Check(exact.Data.GetProperty("negative").GetInt64()==long.MinValue,"Negative integer lost precision");
            Check(exact.Data.GetProperty("text").GetString()=="雪✓🧪","UTF-8 changed");
            var asyncExact=await client.CallJSONAsync("echo","{\"id\":9007199254740993.0}");
            Check(asyncExact.Data.GetProperty("id").GetRawText()=="9007199254740993.0","Async JSON numbers changed");
            Check(client.Ping().Data.ValueKind==JsonValueKind.Object,"Ping serialized JSON as a string");
            Check(client.Call("echo",new {value=7}).Data.GetProperty("value").GetInt32()==7,"Typed object path failed");
        }
        passed.Add("raw/typed JSON and exact UTF-8/integer projections");Balance();
        OcpResponse saved;OcpEvent retained;JsonDocument snapshot;
        using(var core=new OcpCoreClient())
        {
            saved=core.Call("echo",new {id=long.MaxValue});
            Check(core.TryPollEvent(out var entry),"Ready event absent");retained=entry!;
            Check(!core.TryPollEvent(out _),"Empty queue not recognized");snapshot=core.Snapshot();
        }
        Check(saved.Data.GetProperty("id").GetInt64()==long.MaxValue,"Response died with client");
        Check(retained.Sequence==ulong.MaxValue && retained.Data.GetProperty("id").GetInt64()==long.MaxValue,"Event lost precision/lifetime");
        Check(snapshot.RootElement.GetProperty("id").GetInt64()==long.MaxValue,"Snapshot died with client");snapshot.Dispose();
        passed.Add("independently owned response/event/snapshot data");Balance();
        using(var core=new OcpCoreClient())
        {
            Throws<JsonException>(()=>core.Call("malformed"));
            Throws<InvalidOperationException>(()=>core.Call("null"));
            Throws<ArgumentException>(()=>core.Call("echo","[]"));
            Throws<ArgumentException>(()=>core.Call("echo\0suffix"));
            Throws<ArgumentOutOfRangeException>(()=>core.ResizeSurface(10,10,double.NaN));
        }
        passed.Add("parser/error/input failures still free every native string");Balance();
        var disposed=new OcpCoreClient();disposed.Dispose();disposed.Dispose();
        Throws<ObjectDisposedException>(()=>disposed.Call("echo"));
        Throws<ObjectDisposedException>(()=>disposed.Snapshot());
        Throws<ObjectDisposedException>(()=>disposed.TryPollEvent(out _));
        Throws<ObjectDisposedException>(()=>disposed.AttachSurface(1,10,10,1));
        Throws<ObjectDisposedException>(()=>disposed.ResizeSurface(10,10,1));
        Throws<ObjectDisposedException>(()=>disposed.DetachSurface());
        Throws<ObjectDisposedException>(()=>disposed.RenderTick(1));
        await ThrowsAsync<ObjectDisposedException>(async()=>await disposed.CallAsync("echo"));
        passed.Add("every entry rejects use after disposal");Balance();
        Fixture.fixture_reset_release();
        var synchronous=new OcpCoreClient();var before=Fixture.fixture_destroyed();
        var block=Task.Run(()=>synchronous.Call("block"));await Active();synchronous.Dispose();
        Check(Fixture.fixture_destroyed()==before,"Dispose freed a synchronously borrowed Core");
        Fixture.fixture_release();await block;
        Check(Fixture.fixture_destroyed()==before+1,"Borrowed Core was never released");
        passed.Add("SafeHandle defers destruction during blocking native calls");Balance();
        Fixture.fixture_reset_release();
        using(var core=new OcpCoreClient())
        using(var cancel=new CancellationTokenSource())
        {
            var timer=Stopwatch.StartNew();var task=core.CallAsync("block",new {requestId="cancelled-request"},cancel.Token);
            await Active();cancel.Cancel();await ThrowsAsync<OperationCanceledException>(async()=>await task);
            Check(timer.ElapsedMilliseconds<2000,"Cancel blocked behind the native command");
            Check(Fixture.fixture_cancelled()>0,"No native cancel control was sent");
        }
        passed.Add("native cancellation remains concurrent with network work");Balance();
        Fixture.fixture_reset_release();
        var retiring=new OcpCoreClient();var pending=retiring.CallAsync("block");await Active();retiring.Dispose();
        await ThrowsAsync<OperationCanceledException>(async()=>await pending);
        passed.Add("Dispose cancels and retains in-flight asynchronous work");Balance();
        Fixture.fixture_reset_release();
        using(var core=new OcpCoreClient())
        {
            var first=core.CallAsync("block",new {requestId="duplicate"});await Active();
            await ThrowsAsync<InvalidOperationException>(async()=>await core.CallAsync("echo",new {requestId="duplicate"}));
            Fixture.fixture_release();await first;
            Check((await core.CallAsync("echo",new {requestId="duplicate"})).Ok,"Completed request ID not reusable");
            using var cancelled=new CancellationTokenSource();cancelled.Cancel();
            await ThrowsAsync<OperationCanceledException>(async()=>await core.CallAsync("echo",cancellationToken:cancelled.Token));
        }
        passed.Add("duplicate/pre-cancelled/resolved request ownership");Balance();
        var count=Fixture.fixture_destroyed();var weak=Abandoned();
        for(var i=0;i<10 && weak.IsAlive;i++) {GC.Collect();GC.WaitForPendingFinalizers();GC.Collect();await Task.Delay(10);}
        Check(!weak.IsAlive && Fixture.fixture_destroyed()==count+1,"SafeHandle finalization leaked Core");
        passed.Add("un-disposed Core is finalized safely");Balance();
        for(var i=0;i<25;i++)
        {
            Fixture.fixture_reset_release();var core=new OcpCoreClient();var running=Task.Run(()=>core.Call("block"));await Active();
            await Task.Run(core.Dispose);Fixture.fixture_release();await running;
        }
        Check(Fixture.fixture_created()==Fixture.fixture_destroyed(),"Core handles leaked");
        passed.Add("repeated cross-thread dispose/native-call races");Balance();
    }
    static async Task Real(string endpoint)
    {
        using var core=new OcpCoreClient();
        Check(OcpCoreClient.AbiVersion==1 && core.Ping().Ok,"Real Core unavailable");
        Check(core.TryPollEvent(out var ready) && ready!.Kind=="core.ready","Real event channel failed");
        var backup="{\"formatVersion\":1,\"exportedAt\":\"2026-11-14T00:00:00Z\",\"appVersion\":\"fixture\",\"tmdb\":{\"apiKey\":\"key\",\"language\":\"zh-CN\",\"preferText\":true,\"replaceImages\":false,\"showPlaceholders\":true,\"cacheDays\":9007199254740993.0}}";
        var projected=core.Call("settings.backup.decode",new{inputBase64=Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(backup))});
        Check(projected.Ok,"Real backup decode failed");
        var effect=projected.Data.GetProperty("effects").EnumerateArray().First(x=>x.GetProperty("field").GetString()=="tmdb.cacheDays");
        Check(long.Parse(effect.GetProperty("valueJSON").GetString()!)==9007199254740993,"Real Core lost integer precision");
        for(int i=0;i<2;i++)Check((await core.CallAsync("ping",new{requestId="reused"})).Ok,"Real request reservation leaked");
        using var cancel=new CancellationTokenSource(300);
        var timer=Stopwatch.StartNew();
        await ThrowsAsync<OperationCanceledException>(async()=>await core.CallAsync("endpoint.probe",new{url=endpoint+"/slow"},cancel.Token));
        Check(timer.ElapsedMilliseconds<2000,"Real HTTP cancellation too slow");
        Check(core.Ping().Ok,"Core not usable after cancelled HTTP");
        Check(core.Call("settings.backup.capabilities").Ok,"Settings backup unavailable");
        Check(core.Call("diag.exportFile.capabilities").Ok,"File diagnostics unavailable");
        core.AttachSurface(1,1280,720,1.5);core.ResizeSurface(640,360,2);core.RenderTick(1);core.DetachSurface();
        using var snapshot=core.Snapshot();var typed=snapshot.Deserialize<OcpSnapshot>()!;Check(typed.Ready && typed.AbiVersion==1 && !typed.SurfaceAttached,"Typed snapshot schema mismatch");
        passed.Add("real macOS Core: business API, exact integers, cancellation, reused IDs, events and surface lifecycle");
    }
    public static async Task Main(string[] args)
    {
        NativeLibrary.SetDllImportResolver(typeof(Contracts).Assembly,(name,_,_)=>name=="ocp_fixture"?NativeLibrary.Load(Environment.GetEnvironmentVariable("OCP_CORE_LIBRARY_PATH")!):IntPtr.Zero);
        if(args[0]=="mock")await Mock();
        else if(args[0]=="real")await Real(args[1]);
        else if(args[0]=="missing") {Throws<EntryPointNotFoundException>(()=>new OcpCore());passed.Add("missing ABI exports rejected before creating Core");}
        Console.WriteLine(JsonSerializer.Serialize(new {checks,contracts=passed.Count,passed,windowsRuntimeTested=false}));
    }
}
