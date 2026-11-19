# 文件媒体库实施进度

日期：2026-11-19。分支：`codex/media-library-single-source`。实施依据：[V3 方案](/Users/jumusu/Documents/project/OcPlayer/docs/MEDIA-LIBRARY-IMPLEMENTATION-V3.md)。原分析报告和 V2/V3 完整保留。

本批交付是 M1 的基础代码与调用合同。**尚未完成用户可操作的媒体库功能**，不能把底层测试通过当作三端应用、SMB/WebDAV 或自动刮削已经可用。

## 本批已实现

- 新增 `ocp-library` crate，独立 `Library.sqlite` 及版本化迁移。清理服务器缓存不影响其索引、观看事实与匹配快照；数据库损坏时保留原文件并报错。
- 文件源、分类库、条目和资产采用持久 UUID。一个来源可添加互不重叠的电影／电视剧子目录；所有目录查询、详情、播放资源和进度都有来源范围。
- 本地目录后台扫描、持久目录检查点、暂停／取消／恢复、扫描代次和错误状态。目录失败、权限失效、取消不标记文件删除；旧扫描不能覆盖新代次。
- 电影数字片名保护；明确的 S/E、2x03、季目录分集解析；电视剧按剧→季→集→视频资产组织；S0 保留，同一结构内的同集版本共用分集。不同目录的同名剧不按标题直接合并。
- `tmdb.access.validate` 实际请求鉴权配置端点并检查响应结构。建库需要 Core 签发的短期验证与目录凭证；Key、端点或配置代次改变时撤销旧凭证，迟到验证不能重新放行。
- 本地播放地址准备、资产归属／真实路径检查、永久进度写入，旧时间戳不覆盖新记录。自然完成／已看由调用者明确传入，不按 stop 或剩余时长自行推断。
- Swift/C# 文件库 SDK、公开命令清单和 [Core 调用合同](/Users/jumusu/Documents/project/OcPlayer/core/docs/file-library-contract.md)。新接口不依赖原服务器业务的迁移开关。

## 后续尚需实现

| 范围 | 尚需接通 |
|---|---|
| Apple / Windows 添加流程 | TMDB 配置／校验页、系统目录选择器、书签／授权租约持久化、目录与类型选择、草稿及库管理 |
| 单一来源切换 | 宿主 activeSource、来源选择器、文件 catalog 接入现有首页／搜索／详情、浏览回包隔离、切换时原播放收尾 |
| 在线刮削 | 持久匹配／元数据任务、电影／电视剧 TMDB 请求、分季数据、人工匹配界面、NFO 解析、图片与离线海报 |
| 播放接入 | SDK 地址实际送入现有播放器、文件库身份与周期进度、字幕、连播、同片电影版本分组 |
| WebDAV | PROPFIND／路径与 XML、凭据、真实 Range／重定向合同、直连播放／字幕／图片 |
| SMB | libsmb2 三端依赖与 IO、共享目录、本机 HTTP Range 桥接、句柄及播放租约 |
| 发行／平台验收 | Core 实际打包、macOS/iOS/Windows 应用构建、系统权限及播放器真机验证 |

能力接口明确返回 `tmdbScraping: false`、`remoteProviders: false`，来源仅放行 `localFolder`，聚合为 false。应用接入阶段应依据真实能力判断可用范围；首版最终仍只做来源切换，不做多来源聚合。

## 已执行的验证

- `cargo test -p ocp-library -p ocp-core -p ocp-tmdb`：82 个用例通过，其中包含临时目录及本机 HTTP 鉴权／创建／扫描／查询／播放准备闭环。
- `cargo build -p ocp-ffi`：macOS 动态库／静态库构建成功。
- 使用本次构建的 `libocp_ffi.dylib` 运行 Swift `OcpFileLibraryTests`：3 个用例通过；实际验证能力检测、目录凭证、无有效 TMDB 凭证不能创建以及 64 位字段。
- 同一动态库运行 `tests/public_command_contract.py`：6 个合同用例通过，覆盖 390 个公开命令的输入与请求归属边界。
- Clippy 完成，仍有两个新 Store 方法的参数数量提示，以及原 settings backup／测试模块位置提示；没有自动重写无关代码。
- 本机没有 .NET 10 SDK，C# SDK 尚未编译或运行 Windows 验证。本批未测试应用 UI、真实视频解码、用户实际目录／NAS 或 TMDB 账户。
