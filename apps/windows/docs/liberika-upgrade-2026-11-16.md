# liberika 0.3.7 升级交付

2026-11-16，Windows x64 Release 的实际播放 DLL 已从 Erika 0.1.7 升级到官方
[AimesSoft/liberika v0.3.7](https://github.com/AimesSoft/liberika/releases/tag/v0.3.7)。
官方 `releases/latest` 在本次交付检查中指向 v0.3.7。

## 版本与构建

- 上游提交：`a4f829999fe8df0c35561fe1bdf0f5ad0df0c3a5`。
- 版本固定文件：`Config/Kernel.version.json`。
- 准备入口：`Scripts/prepare-kernel.ps1`；构建入口：`Scripts/build-windows.ps1`。
- 本地适配：`Scripts/patches/liberika-v0.3.7-windows.patch`。
- 原生特性：`libass,embedded-fallback-font,artcnn-r8f64`，Windows 使用 D3D11。
- 原生依赖：FFmpeg 8.1.2、dav1d 1.5.1、libass 0.17.5。
- C ABI 和 DLL 名仍为 `erika_*` / `erika_capi.dll`。
- “关于”页面通过核对随包 DLL 的 SHA256 读取 receipt，显示 liberika 0.3.7；
  许可证目录根据实际源码及平台依赖生成，共 197 项。

原有 D3D11 SDR 截图、暂停时外挂字幕导入/切换、字幕 overlay 刷新以及同步删除字幕
已迁移到新版接口。HDR 截图根据独立的 SDR 输出目标配置视频和字幕；色域 LUT
生成完成后正确绑定，等待生成期间关闭 LUT 采样并使用快速色域转换。
截图保持原有 HDR 播放 surface 和视频 uniforms。

网络回退缓冲及 HDR / Dolby Vision 元数据接口使用新版上游实现，构建不再应用
0.1.7 的旧补丁。

## 验证结果

以下验证全部使用完成 HDR LUT 修复后的源码或 DLL：

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 原生 D3D11 | 22 项通过，含 HDR 截图 LUT 等待/完成两条路径的像素检查 | `artifacts/liberika-v0.3.7-hdr-fixed-native-tests.log` |
| 暂停字幕与 AV1 | 5 项通过，含 AV1 8/10-bit 实际解码 | `artifacts/liberika-v0.3.7-hdr-fixed-other-native-tests.log` |
| 全量集成 | 原有 341 项通过 | `reports/liberika-v0.3.7-hdr-fixed-integration-20261116/results.json` |
| 真实 WinUI | 29 项通过 | `reports/liberika-v0.3.7-hdr-fixed-native-ui-20261116/results.json` |
| 随包 DLL 交付验证 | 64 项通过，含新增 3 项 C# 截图接口检查 | `reports/liberika-v0.3.7-hdr-fixed-delivery-smoke-20261116/results.json` |
| Windows Release 构建 | 0 个警告、0 个错误；原生上游另有 3 个编译警告 | `artifacts/liberika-v0.3.7-release-hdr-fixed-build.log` |

全量集成及交付验证核对测试宿主加载的 DLL 与实际 Release DLL 的 SHA256 相同。
截图交付验证检查 RGBA 长度、不透明 alpha、可见视频像素以及暂停时钟保持；
输出示例是交付验证目录中的 `captured-frame.png`。WinUI 关于页面截图也已人工查看。
最终哈希、版本、各验证结果及启动信息记录在 `reports/liberika-v0.3.7-delivery.json`。

## 试用入口与保留的功能

运行 `Scripts/start-release.cmd`。它会定位 .NET，并使用 `artifacts/app-data` 保存应用数据。
实际程序位于：

```text
src/OcPlayer.Windows/bin/x64/Release/net10.0-windows10.0.26100.0/OcPlayer.Windows.exe
```

弹幕默认网关为 `https://dandanplay.3841625.xyz`，默认使用原 OcPlayer 内置公共 key，
自动加载及 liberika 原生渲染默认开启。Core 负责匹配、下载及轨道 JSON，播放适配器
将其送入 liberika 渲染。用户仍可在设置中选择应用层弹幕渲染。
详情页已移除手动匹配 TMDB 和在 TMDB 打开两个按钮，自动元数据补全继续工作。
