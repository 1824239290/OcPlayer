using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.ViewModels;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed class DemoSettings(DemoViewModel model, PageLayout pageLayout, Action<string> navigate, Action<bool> themeChanged)
{
    public static readonly (string Title, string[] Pages)[] Groups =
    [ ("服务", ["媒体服务器", "Bangumi", "MoviePilot", "TMDB 元数据补全", "网络"]),
      ("播放与界面", ["播放", "弹幕", "首页栏目"]), ("应用", ["维护", "关于"]) ];
    public UIElement Hub()
    {
        var page = Stack(36); page.Width = 680; page.MaxWidth = 680; page.HorizontalAlignment = HorizontalAlignment.Center;
        foreach (var group in Groups)
        {
            var section = Stack(8); section.Children.Add(Muted(group.Title, 11));
            var rows = Stack(0);
            foreach (var title in group.Pages)
            {
                var value = title switch { "媒体服务器" => "jumusu", "Bangumi" => model.BangumiEnabled ? "橘木苏（镜像）" : "已停用", "MoviePilot" => model.MoviePilotEnabled ? "已登录" : "已停用", "TMDB 元数据补全" => "已启用（镜像）", "网络" => "默认 UA", "播放" => "liberika", "弹幕" => "自动加载", "首页栏目" => $"显示 {model.HomeSections.Count-model.HiddenSections.Count} 栏", "关于" => "v0.3.0 · Demo", _ => "" };
                if (!model.DemoMode) value = title switch { "媒体服务器" => App.Core?.Server?.Profile.Kind ?? "未连接", "Bangumi" or "MoviePilot" or "TMDB 元数据补全" => "未配置", "网络" => "默认", "播放" => "Erika · D3D11 / WASAPI", "弹幕" => "本地文件", "关于" => $"Core {App.Core?.Version}", _ => "" };
                var row = SettingsLine(title, Text(value, 13), () => navigate("settings:"+title), true);
                rows.Children.Add(row);
                if (title != group.Pages[^1]) rows.Children.Add(Divider());
            }
            section.Children.Add(Panel(rows, new Thickness(16,5,16,5))); page.Children.Add(section);
        }
        var footer = Muted("TMDB\nThis product uses the TMDB API but is not endorsed or certified by TMDB.",11);
        footer.TextAlignment = TextAlignment.Center; page.Children.Add(footer);
        var scroll=pageLayout.Scroll(page, new Thickness(24,16,24,32)); scroll.SizeChanged+=(_,_)=>page.Width=Math.Min(680,Math.Max(0,scroll.ActualWidth-48)); return scroll;
    }
    public UIElement Subpage(string name)
    {
        if (name == "媒体服务器" || !model.DemoMode && name != "首页栏目") return RuntimeSubpage(name);
        var page=Stack(28); page.Width=680; page.MaxWidth=680; page.HorizontalAlignment=HorizontalAlignment.Center;
        void Group(string heading, params UIElement[] rows)
        {
            var section=Stack(8); if(heading.Length>0)section.Children.Add(Muted(heading,11));
            var content=Stack(0); for(var i=0;i<rows.Length;i++){content.Children.Add(rows[i]);if(i<rows.Length-1)content.Children.Add(Divider());}
            section.Children.Add(Panel(content,new Thickness(16,5,16,5))); page.Children.Add(section);
        }
        switch(name)
        {
            case "媒体服务器":
                Group("当前服务器", SettingsLine("名称",Text("jumusu")),SettingsLine("地址",Text("Jellyfin · 离线演示")),
                    Note("共 2 个地址：自动选择最快的；可在「管理服务器」里添加、删除或固定地址。"),
                    Select("启动时默认服务器",["jumusu · Jellyfin","不自动连接"],"jumusu · Jellyfin"),Note("打开 App 时优先连接这台。"),
                    Link("管理服务器…","服务器管理"),Link("连接其它服务器…","连接服务器"),Link("退出 Jellyfin","退出确认")); break;
            case "Bangumi":
                Group("",Toggle("启用 Bangumi",model.BangumiEnabled,v=>model.BangumiEnabled=v),SettingsLine("账号",Text("橘木苏")),Link("退出 Bangumi","退出确认"));
                Group("镜像源",Toggle("使用镜像源",true),Edit("镜像根域","bangumi.lat"),SettingsLine("当前 API",Muted("api.bangumi.lat")),SettingsLine("当前图片",Muted("lain.bangumi.lat")),Note("填入示例 bangumi.lat"),Link("恢复官方直连","恢复确认")); break;
            case "MoviePilot":
                Group("",Toggle("启用 MoviePilot",model.MoviePilotEnabled,v=>model.MoviePilotEnabled=v),SettingsLine("状态",Text("已登录")),SettingsLine("账号",Text("jumusu")),Link("管理连接…","MoviePilot 连接"),Link("退出 MoviePilot","退出确认")); break;
            case "TMDB 元数据补全":
                Group("",Toggle("启用 TMDB",true),Edit("API Key","",true),Select("语言",["简体中文","English"],"简体中文"),Note("在 TMDB 创建 API Key 后，补全简介、演员和海报。"));
                Group("镜像源",Toggle("使用镜像源",true),Edit("API 地址",""),Edit("图片地址",""),Link("恢复官方直连","恢复确认")); break;
            case "网络":
                Group("",Edit("User-Agent",""),Note("部分服务启用了播放器白名单，会拒绝非播放器客户端的请求。填入合适的 User-Agent；留空使用默认值。")); break;
            case "播放":
                Group("网络缓冲",Select("网络预读缓冲",["默认（2 MiB）","8 MiB","16 MiB","32 MiB"],"默认（2 MiB）"),Note("数值越大越能抗带宽抖动，内存占用相应增加。内核用持久流预取。"),Select("回退缓冲",["默认（16 MiB）","32 MiB","64 MiB"],"默认（16 MiB）"),Note("已播内容保留在缓存里，回退落在这段内不发网络请求。"));
                Group("跳过片头与片尾",Toggle("跳过片头",true),Toggle("跳过片尾",true),Select("片尾保留",["不保留","5 秒","10 秒","15 秒"],"10 秒"),Note("播放到片头/片尾时出现「跳过」按钮；片尾保留指跳过后停在片尾结束前多久。"));
                Group("字幕",Select("默认字幕语言",["中文优先（简体）","中文优先（繁体）","English","片源默认"],"中文优先（简体）"),Note("打开新片源时按这里的偏好挑字幕轨。在播放器里自己选过之后，本片不再自动改动。"));
                Group("字幕外观",Select("位置",["不设置","底部","顶部"],"不设置"),Select("字体大小",["不设置","100%","125%","150%"],"不设置"),Select("字幕颜色",["不设置","白色","黄色"],"不设置"),Select("描边颜色",["不设置","黑色"],"不设置"),Toggle("加粗",false),Toggle("覆盖字幕自带样式",false),Note("关闭时以上设置只用于填补字幕没指定的部分，片源自带的排版与特效字体原样保留。"));
                Group("播放内核",SettingsLine("内核",Text("liberika v0.3.6")),Select("画质增强",["关闭","2×"],"关闭"));
                Group("外观",Toggle("深色外观",model.DarkTheme,v=>{model.DarkTheme=v;themeChanged(v);})); break;
            case "弹幕":
                Group("",Toggle("自动加载弹幕",true),SettingsLine("网关",Button("配置",()=>navigate("settings:弹幕网关"))),Edit("anime-skip Client ID（可选）",""),Note("填入后启用 anime-skip 跳过片头源。TheIntroDB 免密钥自动启用。"));
                Group("弹幕渲染",Toggle("用内核渲染弹幕",false),Note("开 = 内核内置渲染器；关 = App 层渲染。改动从下一次播放开始生效。")); break;
            case "首页栏目":
                var list=Stack(0);
                foreach(var title in model.HomeSections.ToArray())
                {
                    var tools=Row(4);
                    tools.Children.Add(Button("⌃",()=>Move(title,-1)));tools.Children.Add(Button("⌄",()=>Move(title,1)));
                    var toggle=new ToggleSwitch{IsOn=!model.HiddenSections.Contains(title),OnContent="",OffContent="",MinWidth=0};
                    toggle.Toggled+=(_,_)=>{if(toggle.IsOn)model.HiddenSections.Remove(title);else model.HiddenSections.Add(title);};tools.Children.Add(toggle);
                    list.Children.Add(SettingsLine(title,tools)); if(title!=model.HomeSections[^1])list.Children.Add(Divider());
                }
                page.Children.Add(Panel(list,new Thickness(16,5,16,5))); page.Children.Add(Note("上下按钮调整顺序；开关只控制首页是否显示。关闭栏目会保留设置，随时可以再打开。")); break;
            case "维护":
                Group("缓存",SettingsLine("图片缓存",Text("140.8 MB / 536.9 MB")),Link("清空图片缓存","缓存清理"),SettingsLine("媒体元数据缓存",Text("8.3 MB")),Link("清空媒体元数据缓存","缓存清理"));
                Group("配置备份与多端同步",Link("导出配置文件…","配置导出"),Link("从文件恢复配置…","配置恢复"),Note("把播放偏好等设置导出成一个文件，供其他设备恢复。"));
                Group("日志与诊断",Toggle("详细日志",true),Note("打开后记录 debug 级链路细节；改动从下一次播放生效。"),SettingsLine("日志文件",Muted("diagnostics-demo.jsonl")),SettingsLine("记录数 / 大小",Muted("20 条 · 5 KB")),Link("导出诊断包…","诊断导出"),Link("清空日志","日志清理"),Toggle("弹幕诊断日志",false)); break;
            case "关于":
                Group("",SettingsLine("OcPlayer",Text("v0.3.0 · Windows Demo")),Note("原生媒体播放与媒体库管理"),Link("开源许可证","开源许可证"),Link("项目主页","项目主页"));
                page.Children.Add(Note("This product uses the TMDB API but is not endorsed or certified by TMDB."));break;
            default:
                Group(name,Note("离线演示：此操作不会修改 macOS 配置或连接真实服务。"),Button("返回",()=>navigate("settings")));break;
        }
        var scroll=pageLayout.Scroll(page, new Thickness(24,16,24,32));scroll.SizeChanged+=(_,_)=>page.Width=Math.Min(680,Math.Max(0,scroll.ActualWidth-48)); return scroll;
    }
    private UIElement RuntimeSubpage(string name)
    {
        var page = Stack(18); page.Width = 680; page.MaxWidth = 680; page.HorizontalAlignment = HorizontalAlignment.Center;
        if (name == "媒体服务器")
        {
            var profile = model.DemoMode ? null : App.Core?.Server?.Profile;
            page.Children.Add(SettingsLine("当前服务器", Text(profile?.DisplayName ?? "未连接")));
            if (profile is not null) page.Children.Add(SettingsLine("类型", Text(profile.DisplayKind + " " + profile.ServerVersion)));
            if (profile is not null) page.Children.Add(SettingsLine("地址", Text(profile.BaseUrl)));
            if (profile is not null) page.Children.Add(SettingsLine("账号", Text(profile.UserName ?? profile.UserId ?? "")));
            page.Children.Add(Link(profile is null ? "连接服务器…" : "连接其它服务器…", "连接服务器"));
            if (profile is not null) page.Children.Add(Link("断开连接", "退出确认"));
            page.Children.Add(Note("登录成功后自动连接这台服务器。登录令牌保存在 Windows 凭据保险箱中。"));
            if (model.DemoMode) page.Children.Add(Note("连接成功后会切换到真实媒体库，可以直接测试浏览和播放。"));
        }
        else if (name == "关于")
        {
            page.Children.Add(SettingsLine("OcPlayer", Text("Windows")));
            page.Children.Add(SettingsLine("共享核心", Text(App.Core?.Version ?? "不可用")));
            page.Children.Add(SettingsLine("播放内核", Text("Erika · Windows HDR 修复版本")));
        }
        else if (name == "播放")
        {
            page.Children.Add(SettingsLine("播放内核", Text("Erika · D3D11 / WASAPI")));
            page.Children.Add(Note("在播放器里调整音量、倍速、音轨和字幕。观看进度会自动保存，下次打开时继续播放。"));
            page.Children.Add(Toggle("深色外观", model.DarkTheme, v => { model.DarkTheme = v; themeChanged(v); }));
        }
        else if (name == "弹幕") page.Children.Add(Note("在播放器的弹幕菜单里加载本地 XML 或 JSON 弹幕文件。"));
        else if (name == "维护")
        {
            page.Children.Add(SettingsLine("观看进度", Text("自动保存")));
            page.Children.Add(SettingsLine("数据目录", Text(App.Core?.DataDirectory ?? "不可用")));
        }
        else page.Children.Add(Note("此项设置将在后续版本开放。"));
        var scroll = pageLayout.Scroll(page, new Thickness(24,16,24,32)); scroll.SizeChanged += (_, _) => page.Width = Math.Min(680, Math.Max(0, scroll.ActualWidth - 48)); return scroll;
    }
    void Move(string title,int delta){var index=model.HomeSections.IndexOf(title);var dest=Math.Clamp(index+delta,0,model.HomeSections.Count-1);model.HomeSections.RemoveAt(index);model.HomeSections.Insert(dest,title);navigate("settings:首页栏目");}
    UIElement Link(string title,string route)=>SettingsLine(title,Text("›"),()=>navigate("settings:"+route));
    UIElement Edit(string title,string initial,bool secret=false)
    {
        var key=title;var value=model.Preferences.TryGetValue(key,out var saved)?saved.ToString()!:initial;
        if(secret){var box=new PasswordBox{Width=240,Password=value};box.PasswordChanged+=(_,_)=>model.Preferences[key]=box.Password;return SettingsLine(title,box);}
        var field=new TextBox{Width=240,Text=value,PlaceholderText="留空使用默认值",CornerRadius=new CornerRadius(5)};field.TextChanged+=(_,_)=>model.Preferences[key]=field.Text;return SettingsLine(title,field);
    }
    UIElement Select(string title,string[] options,string initial)
    {
        var combo=new ComboBox{ItemsSource=options,SelectedItem=model.Preferences.TryGetValue(title,out var value)?value:initial,MinWidth=130};combo.SelectionChanged+=(_,_)=>{if(combo.SelectedItem!=null)model.Preferences[title]=combo.SelectedItem;};return SettingsLine(title,combo);
    }
    UIElement Toggle(string title,bool initial,Action<bool>? changed=null)
    {
        var toggle=new ToggleSwitch{IsOn=model.Preferences.TryGetValue(title,out var value)?(bool)value:initial,OnContent="",OffContent="",MinWidth=0};toggle.Toggled+=(_,_)=>{model.Preferences[title]=toggle.IsOn;changed?.Invoke(toggle.IsOn);};return SettingsLine(title,toggle);
    }
    static UIElement Note(string text){var note=Muted(text,11);note.Margin=new Thickness(12,6,12,12);note.LineHeight=17;return note;}
    static Border Divider()=>new(){Height=1,Margin=new Thickness(24,0,0,0),Background=new SolidColorBrush(global::Windows.UI.Color.FromArgb(18,255,255,255))};
    static UIElement SettingsLine(string title,UIElement value,Action? action=null,bool icon=false)
    {
        var row=new Grid{MinHeight=42,ColumnSpacing=10,Padding=new Thickness(0,4,0,4)};
        row.ColumnDefinitions.Add(new ColumnDefinition{Width=new GridLength(1,GridUnitType.Star)});row.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
        var leading=Row(10);leading.VerticalAlignment=VerticalAlignment.Center;
        if(icon){var glyph=title switch {"媒体服务器"=>"\uE968","Bangumi"=>"\uE714","MoviePilot"=>"\uE8B7","TMDB 元数据补全"=>"\uE8B9","网络"=>"\uE774","播放"=>"\uE768","弹幕"=>"\uE8F2","首页栏目"=>"\uE80A","维护"=>"\uE90F",_=>"\uE946"};leading.Children.Add(new FontIcon{Glyph=glyph,FontSize=15,Width=18});}
        var label=Text(title,13);label.VerticalAlignment=VerticalAlignment.Center;leading.Children.Add(label);row.Children.Add(leading);
        var tail=Row(12);tail.VerticalAlignment=VerticalAlignment.Center;tail.Children.Add(value);if(action!=null&&icon)tail.Children.Add(Muted("›"));Grid.SetColumn(tail,1);row.Children.Add(tail);
        if(action==null)return row;
        var button=new Button{Content=row,HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch,Background=new SolidColorBrush(Microsoft.UI.Colors.Transparent),BorderThickness=new Thickness(0),Padding=new Thickness(0)};button.Click+=(_,_)=>action();return button;
    }
}
