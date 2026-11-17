# 开发与构建

从仓库根运行下列命令。根入口会切换到正确组件目录，支持带空格或中文的检出路径；原组件入口也继续保留。

PowerShell 根入口在切换目录前解析显式传入的本地输入/输出路径，因此 `-OutputDirectory artifacts/verification/windows-msi` 位于调用目录，而不是 Windows 组件目录。Unix Shell 脚本通过根 `.gitattributes` 保持 LF，不对其他历史文件批量改写换行符。

## 通用校验

```text
python scripts/verify-monorepo.py --output artifacts/verification/layout.json
cargo test --manifest-path core/Cargo.toml --workspace --locked
```

布局检查需要完整 Git 历史；CI checkout 使用 `fetch-depth: 0`。它验证源提交可达、导入时文件/模式一致、单一 Swift SDK、依赖路径和 ignore 规则。`--migration` 还要求当前候选的 Apple Swift 源码和内核钉点保持基线；常规检查使用清单中冻结的迁移验收提交验证历史证据，不阻止日后正常更新业务、SDK 或内核。

## Windows

需要 .NET 10 SDK、Visual Studio C++ x64/ARM64 工具链、Python、Rust/MSVC 与含 `libclang.dll` 的 LLVM。根 `global.json` 沿用 `10.0.100` / `latestFeature`。内核依赖构建还需要 CMake、Ninja 和准备脚本使用的原生工具；详见 [组件文档](../apps/windows/docs/core-integration.md)。

```powershell
.\scripts\prepare-kernel.ps1
.\scripts\build-windows.ps1 -Configuration Release -LibClangPath 'C:\path\to\LLVM\bin'
.\scripts\verify-core.ps1 -Configuration release
.\scripts\start-windows.ps1 -Configuration Release -Demo
.\scripts\package-windows.ps1 -Version 1.0.0
```

默认内核位于 `apps/windows/artifacts/liberika-v0.3.7`；`-KernelRoot`、`-NativeArchiveCache`、`-KernelCargoHome`、`-CoreRoot` 和 MSBuild `-p:OcpCoreRoot=` 仍可显式覆盖。默认 Core 必须来自本仓库 `core`，不能用旧工作区 DLL 代替本次构建验证。

Windows 集成测试入口：

```powershell
dotnet run --project apps/windows/tests/OcPlayer.Integration -c Release -p:Platform=x64
```

按 [现有集成测试参数](../apps/windows/tests/OcPlayer.Integration/Program.cs) 选择验证场景，并传入隔离数据目录/产物目录。原生 DLL 默认从 `apps/windows/native/OcPlayerCore/x64` 进入构建输出。

MSI 参数仍是纯数值版本，例如 `1.0.0`；不能直接传入 `windows/v1.0.0`。CI 先去掉标签前缀。测试 MSI 不等于授权覆盖本机已安装的正式应用。

## macOS / iOS

需要 Xcode、SwiftPM、Python 与 Rust。先准备本地配置：

```bash
./apps/apple/Scripts/bootstrap.sh
./scripts/build-macos.sh debug
./scripts/package-macos.sh v0.3.0
./scripts/package-ios.sh v0.3.0
```

打包保留已有签名、内核下载与构建缓存参数，见 [Apple 组件文档](../apps/apple/README.md)。普通打包不自动变成 Core-enabled 分发。

Core-enabled macOS 的完整接入检查：

```bash
./scripts/verify-macos-core.sh
```

该入口构建 Core dylib、设置 `OCP_CORE_ENABLED=1` 和实际库路径、运行 ABI/HTTP/领域合同及 Swift 包/AppTests，并在签名前嵌入 Core。缺库跳过的测试不能算激活成功；每个领域还要断言实际选路。iOS 的源码绑定编译与启用静态 XCFramework 是不同验收路径，保留原分发策略。

## 输出与发行

- 公共验证：`artifacts/verification`；Core 缓存：`core/target`。
- Windows 产物：`apps/windows/artifacts`、`apps/windows/native/OcPlayerCore`；Apple 产物：`apps/apple/.local-build`、`apps/apple/dist`。
- 公共 Swift 绑定只在 `core/bindings/apple/OcPlayerCore` 修改；禁止重新复制到 Apple Packages。
- Apple 使用 `v*`、Windows 使用 `windows/v*`；发行检查与打包始终检出同一标签提交。
- Windows 更新器默认读取 GitHub 同仓库的稳定 `windows/v*` 发行，保留 `OCP_UPDATE_FEED` 和旧单对象响应；不会要求 GitHub runner 访问内网 Gitea 来发布安装包。
- GitHub 的 `latest` 保留给 Apple `v*`，以兼容现有 Apple 更新器。Windows 发行创建和重发均使用 `--latest=false`；将来独立发布 Core SDK 也必须设置 `make_latest=false`。
- 提交代码和标签同步到 Gitea/GitHub 后核对对象 ID。旧仓库在验收与切换完成前不归档。
