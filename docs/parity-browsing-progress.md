# 浏览、服务器与详情补齐进度

当前统一构建与验证结果见 [补齐收尾报告](parity-completion-2026-11-16.md)。原先失败的选集倒序 UI 用例已在真实 WinUI Dispatcher 中重跑通过。

对应固定基线审计的 82 项。实现与验证分开记录；未使用真实账号执行删除、订阅、配对或观看状态写回。系统文件关联注册不在此次请求范围，已实现文件/协议激活与裸路径参数处理。

| 编号 | 审计功能 | 实现入口 | 验证状态 |
|---|---|---|---|
| R-001 | Quick Connect 入口 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-002 | 独立 HTTP / HTTPS 协议选择 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-003 | 先探测服务器再登录 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-004 | 保存多台服务器及免重输切换 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-005 | 登录页的已保存服务器入口 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-006 | 删除指定服务器档案 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-007 | 服务器档案状态 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-008 | 同一服务器多个地址 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-009 | 删除单个地址 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-010 | 地址重新检测与延迟状态 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-011 | 固定当前地址 / 恢复自动选择 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-012 | 自动择优与故障换地址 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-013 | 不可达地址仍然添加 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-014 | 媒体服务器登录过期处理 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-015 | 真实账号头像 | MainWindow.Browsing.cs / MainWindow.xaml.cs / ServerProfiles.cs / MediaServer.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-016 | 首页冷启动缓存与离线浏览 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-017 | 部分栏目失败保留旧内容 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-018 | 旧内容提示及缓存更新时间 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-019 | 首页加载骨架与刷新忙碌状态 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-020 | 隐藏没有内容的栏目 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-021 | 首页栏目全关后的设置入口 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-022 | 服务器无内容 / 媒体库加载失败专用状态 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-023 | 继续观看与接下来看去重 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-024 | 续播卡片剧集标题与分集信息 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-025 | 首页横卡副标题空值与时长格式 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-026 | 媒体库分页及自动加载下一页 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-027 | “加载更多”及翻页失败重试 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-028 | 已加载数量 / 总数量 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-029 | 按媒体库类型选择条目种类 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-030 | 媒体库磁盘缓存恢复 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-031 | 库页加载/失败/空结果的区分 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-032 | 刷新当前媒体库 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-033 | 首页输入即搜索 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-034 | 全库搜索分页 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-035 | 搜索范围不随回车变为全库 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-036 | 搜索无结果的具体说明 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-037 | 直接采纳服务端搜索结果 | MediaServer.cs / BrowserCache.cs / DemoPages.cs / DemoViewModel.cs / MediaLibraryGrid.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-038 | 评分与内容分级 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-039 | 展开全文 / 收起简介 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-040 | 第二屏随当前分集改变简介 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-041 | 切季后显示该季简介 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-042 | 选集正序 / 倒序 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-043 | 长篇按 30 集分区 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-044 | 智能默认季 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-045 | 智能默认集 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-046 | 切季保留各季所选分集 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-047 | 真实缺集占位与播出状态 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-048 | 分集缩略图与悬停简介 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-049 | 电影“正片”选集卡 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-050 | 真实演职员列表 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-051 | 真正的类似推荐 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-052 | 合集详情与成员导航 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-053 | 缓存详情与失败后继续查看 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-054 | 分集加载失败的区内重试 | DemoPages.cs / DemoPages.Detail.cs / EpisodePicker.cs / MediaServer.cs / TmdbService.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-055 | 视频：分辨率 / 宽高比 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-056 | 视频：编码与 Profile | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-057 | 视频：码率 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-058 | 视频：帧率 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-059 | 视频：动态范围 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-060 | 视频：色彩 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-061 | 视频：位深 / 隔行扫描 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-062 | 音频：逐音轨资料 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-063 | 字幕：逐字幕轨资料 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-064 | 文件：容器 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-065 | 文件：大小 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-066 | 文件：文件名 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-067 | 媒体源版本数量及按集刷新 | DemoPages.Detail.cs → media.fileInfo | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-068 | TMDB 自动识别与文本补全 | TmdbService.cs / DemoPages.Detail.cs / MediaLibraryGrid.cs / IntegrationPersistence.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-069 | TMDB 图片补全 | TmdbService.cs / DemoPages.Detail.cs / MediaLibraryGrid.cs / IntegrationPersistence.cs | 已实现；本地协议/持久化测试覆盖，整套结果见最终报告 |
| R-070 | 合集的 TMDB 封面补全 | TmdbService.cs / DemoPages.Detail.cs / MediaLibraryGrid.cs / IntegrationPersistence.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-071 | “手动匹配 TMDB 条目”按钮 | DemoPages.Detail.cs | 按用户要求移除详情页入口（2026-11-16） |
| R-072 | TMDB 匹配搜索与候选核对 | TmdbService.cs / IntegrationPersistence.cs | 随详情页手动匹配入口移除对话框；自动补全服务保留 |
| R-073 | 确认关联 / 解除当前匹配 | TmdbService.cs / IntegrationPersistence.cs | 随详情页手动匹配入口移除对话框；已有匹配和服务保留 |
| R-074 | 在 TMDB 打开 | DemoPages.Detail.cs | 按用户要求移除详情页入口（2026-11-16） |
| R-075 | 在 Bangumi 打开（媒体详情头部） | TmdbService.cs / DemoPages.Detail.cs / MediaLibraryGrid.cs / IntegrationPersistence.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-076 | 打开文件 / 直连链接键盘入口 | MainWindow.Browsing.cs / MainWindow.xaml.cs / App.xaml.cs / RuntimeSettingsPages.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-077 | 文件选择器媒体类型范围 | MainWindow.Browsing.cs / MainWindow.xaml.cs / App.xaml.cs / RuntimeSettingsPages.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-078 | 直连链接 AccessToken | MainWindow.Browsing.cs / MainWindow.xaml.cs / App.xaml.cs / RuntimeSettingsPages.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-079 | 直连对话框输入本地路径 | MainWindow.Browsing.cs / MainWindow.xaml.cs / App.xaml.cs / RuntimeSettingsPages.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |
| R-080 | 外部打开事件处理 | MainWindow.Browsing.cs / MainWindow.xaml.cs / App.xaml.cs / RuntimeSettingsPages.cs | 已实现入口；安装后默认应用关联未声明、未冒充验证 |
| R-081 | 首次欢迎 / 登录海报墙 | MainWindow.Browsing.cs / MainWindow.xaml.cs / App.xaml.cs / RuntimeSettingsPages.cs | 已实现欢迎海报墙/连接/已存档案入口（展示项） |
| R-082 | 跟随系统浅色 / 深色外观 | MainWindow.Browsing.cs / MainWindow.xaml.cs / App.xaml.cs / RuntimeSettingsPages.cs | 已实现；源码调用链核对，界面/真实服务验证范围见最终报告 |

本地协议测试：tests/OcPlayer.Integration/BrowsingParityVerification.cs。界面测试：tests/OcPlayer.Ui/BrowsingParityVerification.cs。构建/测试结果在 reports/ 下，失败重跑记录保留，最终以汇总报告列出的通过文件为准。
