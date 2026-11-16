# Windows 安装包与数据目录

## 生成安装包

Windows 使用按当前用户安装的 MSI。默认安装到
`%LOCALAPPDATA%\Programs\OcPlayer`，创建开始菜单快捷方式并注册
`ocplayer://` 的 Bangumi 回调。安装、升级和卸载均不要求管理员权限。
MSI 内置 .NET、Windows App SDK 和 Visual C++ release CRT，目标电脑无需
预先安装这些运行库，也不需要 SDK 或 Core 源码仓库。

```powershell
./Scripts/package-windows.ps1 -Version 1.0.0
```

构建机需要 .NET SDK 10.0.4xx、同级 Core SDK，以及
`native/OcPlayerCore/x64` 内匹配的 Release DLL 和 build receipt。
脚本下载固定版本 WiX 6.0.2 到 `artifacts/tools`，不全局安装工具。
Visual C++ CRT 默认取自本机 Visual Studio 的 release redist；没有 Visual
Studio 时，用 `-VcRuntimeDirectory` 指向官方 `Microsoft.VC143.CRT` 目录。
脚本检查 DLL hash、运行时完整性和 native Release 配置，先完整 publish，
再替换发行目录，防止旧文件混入新安装包。
发布过程也复制应用自身的 PRI/XBF 资源；只验证 DLL 初始化无法发现
窗口 XAML 缺失，因此运行时验收还会创建实际主窗口。

程序、窗口/任务栏、开始菜单和安装界面使用 macOS 项目现有的 OcPlayer
猫咪播放图标。Windows ICO 直接封装原来的多尺寸 PNG，macOS 资源不变。

产物位于 `artifacts/release/<Version>/<Platform>/`，包含 MSI、自包含的
`app` 目录和记录 hash、Core/kernel 提交、运行库版本与签名状态的
`release.json`。`-Platform ARM64` 必须配套 ARM64 native DLL 与 CRT；
当前验收范围是 Windows x64，ARM64 仍需实机验证。

发行签名使用用户已持有的代码签名证书：

```powershell
./Scripts/package-windows.ps1 -Version 1.0.0 -CertificateThumbprint '<证书 SHA1 thumbprint>'
```

脚本会对 apphost 和 MSI 进行 SHA256 签名与时间戳。未提供证书时生成
可测试的未签名安装包，并在 `release.json` 中明确写入 `signed: false`。

## 数据与升级

所有 Windows 服务通过 `AppPaths` 解析同一个默认目录：
`%LOCALAPPDATA%\OcPlayer\Windows`。安装文件和用户数据分离；MSI 不拥有
数据目录内的文件，升级与卸载保留设置、数据库、播放记录与系统凭据。
账号和私有 API key 继续使用原来的 PasswordVault resource，安装版不改变
应用身份，也不转存成明文。

开发启动脚本现在使用相同的默认目录。第一次通过新启动脚本运行时，
会导入旧 `artifacts/app-data` 中尚未存在的设置、观看历史、集成偏好和
数据库。SQLite 使用在线 backup API 读取一致性快照，包含 WAL 中已提交
的记录；不直接复制活动数据库及 WAL/SHM。原目录保留，新目录已有数据
优先，一次性 marker 防止之后被用户删除的设置重新出现。图片与弹幕缓存不参与
持久数据迁移。

`-DataDirectory` / `OCP_DATA_DIRECTORY` 仍支持独立测试目录；应用拒绝
相对路径、磁盘根目录和安装目录内的数据路径。手动导入另一个旧目录：

```powershell
$env:OCP_DATA_DIRECTORY = "$env:LOCALAPPDATA\OcPlayer\Windows"
& "$env:LOCALAPPDATA\Programs\OcPlayer\OcPlayer.Windows.exe" '--migrate-data=D:\old\OcPlayer-data'
```

## 缓存政策

| 内容 | 目录 | 磁盘上限 | 清理时保留 |
| --- | --- | --- | --- |
| 图片 | `Images` | 512 MiB | 设置与记录 |
| 浏览元数据 | `browser-cache/<服务器 hash>/<账号 hash>` | 128 MiB | 其它服务器缓存 |
| 服务器字幕 | `SubtitleCache` | 128 MiB | 已加载的字幕和播放设置 |
| 弹幕内容 | `Danmaku/comments-*.json` | 256 MiB | 手动匹配、片头标记与偏好 |
| TMDB 内容 | `Tmdb/<hash>.json` | 64 MiB | 关联文件和批量进度 |
| Bangumi 快照 | `Integrations/<resource>/Bangumi` | 每个 resource 64 MiB | 账号、偏好和媒体关联 |

限额在启动和写入时执行，浏览、字幕、TMDB 和 Bangumi 快照还会淘汰超过
30 天的文件。一天前遗留的临时下载文件会清理。持久记录不计入可淘汰
缓存，日志保留自己的轮转策略。

维护页显示缓存占用，提供图片、当前服务器元数据、字幕、弹幕和日志的
清理入口。当前服务器的元数据清理同时处理前端磁盘缓存、旧 server-only
数据库 tenant 和当前 `server:account` tenant。浏览请求用代次校验阻止旧
响应写回；图片清理等待下载退出；字幕清理使旧下载失效；弹幕清理取消
并等待已有请求结束，再清除磁盘与内存中的内容。清理失败会显示错误。

## 验证

```powershell
dotnet run --project tests/OcPlayer.Integration/OcPlayer.Integration.csproj `
  -c Release -p:Platform=x64 -- --storage-only 'D:\new-storage-verification'

./Scripts/verify-installer.ps1 -Installer 'D:\release\OcPlayer-1.0.0-x64.msi' `
  -UpgradeInstaller 'D:\release\OcPlayer-1.0.1-x64.msi' `
  -OutputDirectory 'D:\new-installer-verification'
```

安装验证使用独立安装与数据目录，检查实际 apphost/Core/Erika 初始化、
app-local .NET/WinUI/CRT 加载、协议注册、major upgrade 和卸载数据保留，
最后卸载测试产品并恢复原有协议处理器。它不会替代用户在 Windows 10
最低版本、ARM64 和干净虚拟机上的验收。

2026-11-17 的 x64 验收结果：Release 自包含发布与 Debug 构建成功，
独立发布目录的首页和图片资源已实际检查，存储/设置/浏览/字幕集成
验证通过 120 项断言。MSI 1.0.0 安装、1.0.1 升级与卸载验证通过
29 项断言，包括应用窗口创建、运行库加载位置、图标和协议、版本替换，
以及升级/卸载前后 Core 数据库 SHA256 不变。结果保存在
`artifacts/storage-verification-20261117-final/results.json` 和
`artifacts/installer-verification-final/results.json`。测试产品已卸载；
用户的默认数据目录未用于本次安装验收。当前生成的 MSI 未签名。

Core 提交 `7e3968e` 仅新增可选 `commentsDiskCapacityBytes` 和
`clearComments` / `pruneComments`。未提供磁盘限额的 Apple 客户端保留
原行为；没有修改 macOS/Swift 源码、FFI header 或 ABI。macOS 更新 Core
后可回归自动匹配、手动纠正、重启恢复和离线复用。
