# 本地、SMB、WebDAV 媒体库的 TMDB 配置前置要求

日期：2026-11-19。

本文件补充 [媒体库扩展分析报告](/Users/jumusu/Documents/project/OcPlayer/docs/MEDIA-LIBRARY-EXPANSION-PLAN.md)，记录用户确认的产品方向。原分析报告完整保留；其中允许未配置 TMDB 凭据也创建文件源媒体库的建议，由本文件替代。此处为设计要求，尚未实现。

## 1. 创建媒体库之前必须配置 TMDB

对于本地文件夹、SMB、WebDAV 三种文件源，用户必须先填写并验证有效的 TMDB 凭据，之后才能创建媒体库并启动首次扫描、匹配和刮削。媒体库定位为自动整理电影、剧集和海报的入口，TMDB 配置因此成为创建步骤中的必填项。

支持现有的两种凭据形态：TMDB v3 API Key、API Read Access Token。三种文件源共用全局配置，无需每个媒体库分别填写。

Emby/Jellyfin 的服务器媒体库继续使用服务器提供的元数据；在 OcPlayer 中进行额外的 TMDB 补全时使用上述全局配置。

## 2. 添加流程

1. 用户选择添加本地、SMB 或 WebDAV 媒体库。
2. 如果没有 TMDB 凭据，添加流程引导用户填写，并保留已输入的数据源信息。
3. 发起轻量且需要鉴权的 TMDB API 请求验证凭据；不能仅用“字符串非空”作为验证成功。
4. 验证通过后，完成文件夹授权或 SMB/WebDAV 连接验证、选择扫描目录及媒体类型。
5. 创建媒体库，启动目录扫描、条目合成和后台 TMDB 匹配。界面分别显示扫描和刮削进度。

401 等鉴权失败应提示凭据无效。网络超时、429 限流和服务端故障应分别提示原因并允许重试，不应误判为 Key 错误。验证未成功时保留添加草稿，暂不创建新媒体库。

“已填写凭据”和“验证通过”应分别记录；凭据修改后旧验证结果失效，不能继续拿旧结果放行新的创建流程。

## 3. 首次验证与离线使用

TMDB 凭据要求适用于创建媒体库和开启在线刮削。已创建的媒体库从本地索引和已保存元数据恢复，日常启动不要求成功访问 TMDB 后才能进入。

断网时仍可浏览已保存的海报、详情和观看进度。播放是否可用取决于实际文件源：本地文件可读即可播放，SMB/WebDAV 文件仍需能连接到对应服务。

凭据被删除或失效后，提示重新配置，暂停在线匹配和刷新；保留已有索引、元数据和播放进度。重新配置成功后允许继续处理未完成的任务。

首次创建要求有效 Key，不代表所有文件都会匹配成功。无法识别的文件应保留条目，展示文件名或占位封面，并提供手动匹配入口；同目录 NFO 与图片可以作为辅助输入。扫描完成后先生成可浏览条目、再异步补全的流水线仍适用。

## 4. 当前代码需要调整的边界

- [TMDbSettings.swift](/Users/jumusu/Documents/project/OcPlayer/apps/apple/Packages/MetadataKit/Sources/MetadataKit/TMDb/TMDbSettings.swift:31) 当前将空凭据返回为 nil，需要在新增媒体库流程中增加验证步骤和配置引导。
- [TMDbClient.swift](/Users/jumusu/Documents/project/OcPlayer/apps/apple/Packages/MetadataKit/Sources/MetadataKit/TMDb/TMDbClient.swift:100) 的 `isConfigured` 当前只判断凭据是否存在。创建前的有效性验证应采用独立状态，避免把现有非空检查误当作网络验证。
- [TMDbEnricher.swift](/Users/jumusu/Documents/project/OcPlayer/apps/apple/Packages/MetadataKit/Sources/MetadataKit/TMDb/TMDbEnricher.swift:63) 当前读取缓存 overlay 也要求已配置凭据。新增文件源媒体库需要允许已保存的元数据独立于在线凭据展示，确保删除 Key 后不会让已建媒体库的海报和详情消失。
- Apple 与 Windows 的新增媒体库入口应遵守相同的创建规则、错误分类和离线恢复规则；验证策略应由共享 Core 承担，宿主负责配置界面与凭据保存。

## 5. 验收要求

- 未配置 TMDB 时，三种文件源均进入配置步骤，不能直接创建媒体库。
- 有效 Key 或 Read Access Token 验证通过后可以继续添加；无效凭据提示明确且保留草稿。
- 配置一次即可用于多个本地、SMB、WebDAV 媒体库。
- 初次创建验证失败与已有库离线启动采用不同处理方式；已有库不被联网验证阻塞。
- Key 删除或过期后，已有库内容保留，在线刮削停止；重新配置后任务可继续。
- 匹配失败只影响对应文件的元数据补全，不使整个媒体库不可用。
