# OcPlayer 单仓库迁移计划

日期：2026-11-17（Asia/Hong_Kong）

状态：执行中。用户已授权迁移；源备份与非 squash 历史导入已完成，依赖与 CI 正在适配。平台验收通过前不切换主分支、不归档旧仓库。实际结果见 `docs/migration/EXECUTION.md`。

## 1. 目标与主仓库

使用现有 `OcPlayer` 作为合仓后的仓库名称，以 Gitea 的 `jumusu/OcPlayer` 为开发主仓，GitHub 的 `1824239290/OcPlayer` 保留同一份 Git 历史并承载现有 GitHub Actions 和发行页面。

- Gitea：`http://192.168.5.107:8418/jumusu/OcPlayer`，原 `OcPlay`，仓库 ID 为 1。
- GitHub：`https://github.com/1824239290/OcPlayer`。
- 本地迁移与验收使用独立目录 `D:\OcPlayer-Monorepo`。
- 通过验收并完成两端同步后，原 Gitea `OcPlayer-Core`、`OcPlayer-Windows` 转为只读归档。

合仓的结果应满足：一次克隆取得匹配的 Core 和客户端源码；Core、绑定和客户端适配可以在一次提交中更新；Windows、macOS、iOS 保留自己的工具链与发行节奏。

本轮修改范围是目录、Git 历史导入、依赖引用、构建与发布路径、项目链接及分平台更新源、文档入口。产品核心业务规则、C ABI、应用标识、用户数据目录、数据库格式和 Core 启用策略沿用迁移前行为。

## 2. 已核对的基线

下表的工作区状态指新增本规划文档之前。

| 组件 | 本地目录 | 已提交基线 | 工作区状态 |
| --- | --- | --- | --- |
| Apple | `D:\OcPlayer\OcPlayer` | `888ccdd8a1098b4426166bb4b09b2f7dca3d8720` | 干净；本地、GitHub、Gitea 的 `main` 一致 |
| Core | `D:\OcPlayer-Core` | `7e3968e2c6106d87a5d0fa17602a6972905cf19f` | 只有未跟踪的 `tests/windows-video/extract_frame.c` |
| Windows | `D:\OcPlayer-Windows` | `49e9e21f24b1ba580580a1129d51a95306bde865` | 干净 |

已确认的迁移条件：

- Apple 的 `Packages/OcPlayerCore` 与 Core 的 `bindings/apple/OcPlayerCore` 在 `Package.swift`、`Sources`、`Tests` 范围内各有 22 个已跟踪文件，Git blob 完全一致。
- Apple 的 BangumiKit、DanmakuKit、JellyfinKit、MetadataKit、MoviePilotKit、PlaybackKit 六个包通过 `../OcPlayerCore` 引用复制的绑定；Xcode 工程也引用这份本地包。
- Windows 已直接编译 Core 仓库的 C# SDK，当前 `OcpCoreRoot` 和构建脚本默认指向同级 `OcPlayer-Core`。
- Apple 的 liberika 固定为 `v0.3.6`；Windows 固定为 `v0.3.7` / `a4f829999fe8df0c35561fe1bdf0f5ad0df0c3a5`。两端保留各自已验证的版本和补丁。
- Apple 与 Core 的 `LICENSE` 是同一个 Git blob，可以沿用现有 GPL-3.0 许可证文本。
- 本机 Git 为 `2.56.0.windows.4`，已有 `git subtree`。
- Gitea `OcPlayer` 有 15 个分支、13 个标签，其中 6 个分支仅存在于 Gitea，需要保留。

`extract_frame.c` 属于未提交的独立诊断工具。历史导入只读取已提交的 Git 对象，因此该文件保留在原 Core 工作区；它是否成为正式诊断工具应作为独立修改处理。

执行前重新核对远端引用、工作区状态及上述基线。若任一主分支已有新提交，更新基线和源清单后再导入。

## 3. 目标目录

```text
OcPlayer/
├─ .github/
│  ├─ actions/
│  └─ workflows/
├─ .agents/
├─ .gitignore
├─ global.json
├─ LICENSE
├─ README.md
├─ docs/
│  ├─ MONOREPO-MIGRATION-PLAN.md
│  ├─ ARCHITECTURE.md
│  ├─ DEVELOPMENT.md
│  └─ migration/
├─ scripts/
├─ core/
│  ├─ Cargo.toml
│  ├─ Cargo.lock
│  ├─ crates/
│  ├─ bindings/
│  │  ├─ apple/OcPlayerCore/
│  │  └─ windows/
│  ├─ include/
│  ├─ Scripts/
│  ├─ tests/
│  └─ docs/
└─ apps/
   ├─ apple/
   │  ├─ App/
   │  ├─ AppTests/
   │  ├─ Packages/
   │  ├─ OcPlayer.xcodeproj/
   │  ├─ Config/
   │  ├─ Scripts/
   │  └─ Docs/
   └─ windows/
      ├─ OcPlayer.sln
      ├─ Directory.Build.props
      ├─ src/
      ├─ tests/
      ├─ Config/
      ├─ Scripts/
      ├─ installer/
      ├─ licenses/
      └─ docs/
```

Cargo workspace 保留在 `core/Cargo.toml`，.NET solution 保留在 `apps/windows`，Xcode 工程保留在 `apps/apple`。根目录 `scripts` 提供统一开发入口，内部调用组件脚本并设置正确的工作目录。

Apple 现有 `.github` 必须留在仓库根目录，以维持 Actions 发现和本地 composite action 路径；现有 `.agents` 和相关技能锁文件也保留根目录。Apple 原 README 与组件文档放在 `apps/apple`，根 README 改为三端开发和下载入口。

保留组件内的 `Scripts`、`Config`、`Docs` 大小写。前缀目录避免 Apple `Docs` 与其他组件 `docs`、同名构建脚本在 Windows 上发生冲突。Core 的历史验证报告和已跟踪日志保留在 `core/docs/validation`。

## 4. Apple 旧 Swift 核心与 Rust Core 的边界

Swift 绑定去重不等于旧业务实现已经退出。Rust Core 与 Apple Swift 模块通过 C ABI 交互，源码并存本身不会自动产生重名或重复链接；需要分别检查包/链接引用和运行时业务归属。

### 代码分类

| 类别 | 代表内容 | 合仓处理 |
| --- | --- | --- |
| Apple 平台实现 | SwiftUI、ErikaKit、Metal/音视频与系统服务适配、DanmakuRenderKit | 保留，不属于 Rust 业务核心的重复品 |
| 原生模型与状态投影 | `CoreModel/MediaItem`、`PlaybackKit/PlayerState`、UI 观察与主线程状态 | 保留；名称包含 Core 不构成删除理由 |
| Core 门面与原生副作用 | `Rust*` 桥接、凭据保存、UserDefaults、平台通知与任务生命周期 | 保留必要适配；区分 Rust 决策和 Swift 执行的平台效果 |
| 仍可执行的 Swift 业务分支 | 缓存 SQL、Bangumi 数据操作、TMDb 请求/规则、弹幕缓存、播放偏好默认规则等 | 逐领域记录实际选路；本轮结构迁移保留现有行为 |
| 重复的公共 Swift 绑定 | Apple `Packages/OcPlayerCore` 与 Core `bindings/apple/OcPlayerCore` | 仅这一类已验证的复制品在阶段 4 收敛 |

不能把 Apple 的 `Packages`、`CoreModel` 或带 Core 名称的目录整体当成废弃核心删除。

### 基线下的实际选路抽查

下表路径相对迁移前的 Apple 仓库根；这是源码抽查，不是全应用运行时验收。

| 入口 | 已确认的行为 | 需要防止的误判 |
| --- | --- | --- |
| `Packages/OcPlayerCore/Sources/OcPlayerCore/OcpCoreClient.swift` 中的 `OcpCoreFeature.isEnabled` | 依次读取环境变量、UserDefaults、Info.plist；未配置时默认关闭 | 合仓或链接绑定并不会自动启用 Rust Core |
| `Packages/MetadataKit/Sources/MetadataKit/Store/MetadataStore.swift` | 初始化 Rust store 失败后保留 Swift GRDB 路径；`touchTenant`、`saveItemsAndRail` 在 Rust 分支完成后直接返回 | 设置启用开关不代表初始化成功；这些入口不是两套写入同时执行 |
| `Packages/BangumiKit/Sources/BangumiKit/Database/BangumiDatabaseOperator.swift` | Rust store 使用 `try?` 初始化；`usesCoreStore` 反映是否实际接入 | 加载失败可能不抛错，不能只凭构建成功判断已经迁移 |
| `Packages/DanmakuKit/Sources/DanmakuKit/DanmakuCache.swift` | 默认平台依赖下尝试加载 Rust cache；写入等入口在 Rust 分支返回，否则使用 Swift 缓存 | 注入的原生依赖、关闭或加载失败仍可能使用原实现 |
| `App/Shared/Features/Player/PlaybackPreferences.swift` | 实际激活依赖开关和可用的 Core client；解析无结果时仍有 Swift 默认规则，UserDefaults 存储继续原生执行 | 原生存储不是重复决策；策略兜底也不能直接当作死代码删除 |

TMDb、Jellyfin/Emby 门面、MoviePilot 登录/请求等也必须列入归属清单。原生 transport 或测试注入可能被有意保留；已经开始的原生登录/请求与 Core 请求的错误、重试和副作用归属需要逐入口检查，不能笼统规定所有加载或请求失败都自动换后端重放。

目前抽查的缓存写入口有提前返回，未发现这些入口同时执行 Rust 和 Swift 两套写入。但不同模块可能选择不同后端，旧 Swift 分支也仍然有用途；不能据此保证全部调用无重复写入、上报或规则漂移。

### 审计产物与删除条件

合仓前形成领域级归属清单，逐项记录：Swift 生产入口、Rust command/命名空间、保留的原生效果、实际后端判定、关闭/加载失败/注入依赖时的合同、macOS/iOS 调用方及对应测试。审计依据包括现有 `Docs/SHARED-CORE-COMPLETION.md`、Core `docs/completion-audit.md` 和 `docs/macos-parity.md`，但“Core 功能完成”不等于 Swift 旧实现已删除或每个发行包都已启用 Core。

拟删除的 Swift 业务实现还须完成逐函数调用审计，并满足：

- 没有仍依赖该实现的生产调用方、关闭模式或 iOS 分发路径；若要取消这些路径，先独立定义新的产品合同。
- 对应 Rust 行为、数据兼容性与原生副作用经过验证，不能只检查命令存在或 Core `ping` 成功。
- 同一次状态变更只有一个业务执行者，不重复写数据库、进度上报、缓存更新或请求重放；并行和错误路径也要覆盖。
- 必要的差分测试仍可比较原规则；仅用于对照的实现可独立保留在测试支持代码中，不混入生产路径。

本轮合仓只消除已确认相同的绑定副本，不同时删除旧 Swift 业务分支、强制所有发行包启用 Core 或改变加载失败策略。后续业务收敛使用独立提交与验收边界。

## 5. 六个迁移阶段

### 阶段 1：冻结基线与备份

1. 获取三个远端的最新主分支、分支和标签，记录引用对象 ID。
2. 保存三个仓库的独立镜像或 bundle，验证备份对象连通性。
3. 完成 Apple Swift/Rust 领域级归属与实际选路清单，标明必须保留的旧业务分支和平台适配，不以目录名称判断废弃代码。
4. 生成源清单，记录源仓库 URL、提交、文件 blob ID、导入前缀和需留在根目录的 Apple 文件。
5. 在独立目录准备迁移分支，建议名称 `codex/monorepo-migration`。

产物：三份完整 Git 备份、源清单、Apple 领域归属清单、迁移分支。源工作区里的未提交文件继续留在原位置。

### 阶段 2：导入历史与目录

以 Apple `main` 为迁移分支的祖先，先用 `git mv` 整理 Apple 文件，再使用不带 `--squash` 的 `git subtree add` 导入 Core 与 Windows：

```text
Apple 应用文件 → apps/apple/
Core 已提交树 → core/
Windows 已提交树 → apps/windows/
```

该方法保留源提交对象 ID，最终 `main` 可从当前 Apple 主分支正常快进或合并。历史 Core/Windows 提交仍呈现其原始根目录布局；查看历史文件时需要使用原路径，当前目录结构从导入提交开始存在。

历史引用处理：

- 保留现有 Apple/Gitea 分支和 `v*` 标签及其对象 ID。
- Core、Windows 的历史引用使用 `history/core/*`、`history/windows/*` 命名空间，避免同名分支或标签覆盖。
- 原 Core、Windows 的主分支基线必须在合仓后的提交图中可达。
- 旧布局分支保留用于查阅；后续功能开发从合仓主分支创建新分支。

导入提交产生后立即验证：Core 和 Windows 的前缀子树分别与源提交整棵树一致；Apple 文件按迁移映射逐项比较 blob ID；三个源基线都是迁移分支的祖先。后续路径适配另作提交。

### 阶段 3：修复依赖与构建路径

| 修改位置 | 迁移后的处理 |
| --- | --- |
| `apps/windows/Directory.Build.props` | 默认 `OcpCoreRoot` 改为相对 Windows 根的 `..\..\core\`；保留显式覆盖参数 |
| Windows `build-windows.ps1`、`package-windows.ps1` | 从组件 `Scripts` 出发的默认 Core 路径改为 `..\..\..\core` |
| Windows CoreAdapter | 继续编译唯一的 `core/bindings/windows` 源码；更新缺失 SDK 的错误提示 |
| Windows `global.json` | 移到仓库根，沿用现有 `10.0.100` / `latestFeature` 规则，使从根目录运行 dotnet 仍使用既定 SDK 选择策略 |
| 根目录开发脚本 | 明确组件工作目录、Core 根目录及输出位置，支持从仓库根和带空格/中文的路径运行 |
| Apple 构建脚本 | 保留脚本计算组件根的逻辑；调用方切到 `apps/apple`，修复依赖当前工作目录的相对路径 |
| Core 验证脚本 | Apple 参数指向 `apps/apple`；输出与缓存使用独立的、已忽略的目录 |
| 许可证与来源元数据 | 更新 Cargo 的仓库 URL；保留 `core/LICENSE`，确保许可证生成与 XCFramework 打包仍可找到它 |

建议根目录入口覆盖：Windows 构建/启动/打包、macOS 构建/打包、iOS 打包、Core 验证和 Apple Core 接入验证。组件脚本仍承担实际工作。

合并三份 ignore 规则时检查 `.NET bin/obj`、Rust `target`、原生 DLL、Apple `Vendor`、`.local-build`、发行产物与本地配置。已跟踪的生成许可证目录、Core 验证日志和报告继续保留；迁移不做全仓换行符重写或历史报告清理。

### 阶段 4：仅收敛 Swift 绑定

以 `core/bindings/apple/OcPlayerCore` 为唯一开发源码包，删除 `apps/apple/Packages/OcPlayerCore` 的复制品。

- 六个 SwiftPM 包的依赖改为 `../../../../core/bindings/apple/OcPlayerCore`，相对各自的 `Package.swift` 目录计算。
- Xcode 本地 Swift package 引用改为 `../../core/bindings/apple/OcPlayerCore`，相对 Apple 项目根计算。
- 更新 Core 的 `verify-macos.sh`，只运行一次公共绑定测试，修改引用被删除副本的 fixture 检查和包列表。
- 原 `check-apple-binding.sh` 的跨仓库复制品比较改为消费者引用及公共 fixture 检查。
- `build-apple-xcframework.sh` 继续从唯一源码包生成发行包；发行包里的源码副本属于构建输出。

22 个绑定文件已验证一致，删除复制品不应改变 SDK 行为。检查 SwiftPM/Xcode 都引用唯一绑定，避免重复声明包或重复链接原生 Core；Apple 原生模型、适配和仍生效的业务分支不在此次删除范围内。其余领域包中的 fixture 复用和代码整理留在独立修改中。

### 阶段 5：适配 CI 与发行流程

所有工作流仍放在根 `.github/workflows`。保留现有 macOS AppTests、iOS 模拟器 AppTests、SwiftPM 测试的职责划分，增加 Core 与 Windows 检查。

| 改动范围 | 必须触发的检查 |
| --- | --- |
| `core/**` | Rust、C ABI/SDK、Windows Core 接入、Apple Swift 包与 macOS/iOS 回归 |
| `apps/windows/**` | Windows 构建、相关集成测试；涉及打包时检查 MSI |
| `apps/apple/**` | Apple Swift 包、macOS AppTests、iOS 模拟器 AppTests；涉及打包时检查产物 |
| 根构建入口、公共 CI 配置 | 受影响平台；共享入口改动覆盖全部相关平台 |
| 纯文档 | 文档/路径检查，汇总门禁正常结束 |

路径分流采用始终运行的汇总门禁，避免必需的检查因整条 workflow 被跳过而一直 pending。平台构建分别使用 Windows、macOS runner，纯 Rust 检查可使用 Linux runner。

CI 需要一起修改 `working-directory`、`hashFiles`、上传产物和所有缓存路径。特别是 `setup-erika` composite action 的命令工作目录与缓存路径必须显式指向 `apps/apple`；调用方的默认工作目录不会自动替它修好这些路径。

为新布局使用新缓存键，区分 OS、架构、工具链、配置及依赖锁文件，保留各 Apple job 独立的 DerivedData 和 SwiftPM 缓存。Apple `Config/Erika.version` 与 Windows `Config/Kernel.version.json` 继续分别作为各平台内核钉点事实源。

发行标签建议：

| 组件 | 标签规则 | 版本来源 |
| --- | --- | --- |
| Apple | 继续使用 `v*`，保留历史兼容性 | `apps/apple/Config/App.xcconfig` |
| Windows | 新增 `windows/v*` | 传入现有 MSI 打包脚本的纯版本号 |
| Core SDK | 如需独立发行，使用 `core/v*` | `core/Cargo.toml` 与 SDK 包版本 |

Windows 标签前缀在调用打包脚本前剥离，保留 MSI 的数值版本校验。发行门禁、构建和打包必须检出同一标签对应的提交。Apple 的构建号、Git dirty 标记和 Windows/Core receipt 在单仓库下会读取整个仓库的 Git 信息，需明确记录这项语义，并保证 Apple 构建号高于上次发行值。

现有 Apple 更新器读取 GitHub `/releases/latest`，不改其 Swift 行为。Windows 发行创建和重发明确设置 `make_latest=false`，Core SDK 独立发行也遵守该规则；`latest` 只用于 Apple `v*`。Windows 更新器改用分页发行列表并筛选稳定 `windows/v*`，避免读取 Apple/Core 的发行。

Windows 更新器默认读取 GitHub 共享仓库 release 列表，与 Actions 的发行页面一致；只选择稳定 `windows/v*` 标签，按同源 Link 分页查找，不能把 Apple 的最新发行作为 Windows 更新。保留 `OCP_UPDATE_FEED` 覆盖和原单 release JSON 的兼容性。

Apple 当前普通打包脚本与 Core-enabled macOS 的构建/嵌入验证是两条路径。迁移需分别保留并验证这两条路径，确认 Core 嵌入发生在签名和最终封包之前。沿用现有 Core 启用策略；iOS 的 Core-enabled 分发不能仅靠拷入一个静态库推定成功，需按已有 XCFramework/直接 C 引用合同单独验收。

保留 receipt 字段兼容性，明确其中源码提交现在指向 monorepo 提交；迁移源清单保存原三仓库提交，必要时增加组件 tree ID 来定位源码。

### 阶段 6：验收、切换与归档

1. 从迁移分支做全新检出，按以下验收清单验证。
2. 在 Gitea 和 GitHub 同步迁移分支，获得针对同一提交的平台检查结果。
3. 用保留阶段提交的最终 merge commit 切换 `main`，记录该提交和第一父提交。
4. 核对两个远端的 `main`、发行标签和需保留的历史引用；更新根 README、开发入口和 IDE 工作目录。
5. 两端同步、构建与打包验收完成后，再归档原 Core、Windows 仓库。

远端切换使用普通推送，不重写原主分支历史。若远端基线在迁移期间前进，重新整合并验证新增提交。以后主仓变更同步到 GitHub 的提交与标签均需核对结果；从同一主分支维护一份源码。

## 6. 验收清单

### 历史与目录

- 三个源基线提交在最终提交图中可达；导入时的文件 blob/子树与源清单相符。
- Apple 历史标签及 Gitea 独有分支保留，Core/Windows 的历史引用可追溯。
- 仓库内只有一份 Swift 绑定开发源码，六个包与 Xcode 都能解析它。
- 从全新检出构建时，SDK 与 DLL 的实际输入来自 monorepo；现有旧工作区无需作为默认依赖。

### Core 与 Windows

```text
cargo test --manifest-path core/Cargo.toml --workspace --locked
.\core\Scripts\verify-windows.ps1 -Configuration release
```

使用已适配的根 Windows 入口完成真实 Core/liberika 原生构建、WinUI 构建、现有集成测试和 Release MSI 打包。可复用已有下载缓存与工具链，但 DLL、许可证和 receipt 必须对应本次源码与既定内核版本。

验收本地/HTTP 播放、暂停/跳转、服务器 fixture、续播与已覆盖的业务路径；使用独立数据目录和测试凭据。验证 MSI 的依赖、原生 DLL 哈希及既有数据迁移行为。

### Apple

在 Mac 或 GitHub macOS runner 执行适配后的接入检查：

```text
./core/Scripts/verify-macos.sh "$PWD/apps/apple" "$PWD/artifacts/verification/apple"
```

同时运行现有 macOS、iOS 模拟器 AppTests 和 SwiftPM 检查，验证 macOS 打包、iOS 编译/打包及相关 SDK 产物。GPU/实机播放检查与现有跳过项分别记录，不能用编译成功代替运行时或 HDR 验收。

Swift/Rust 归属验收还须覆盖：

- Core 关闭、启用且加载成功、启用但库缺失/不兼容、注入原生依赖等场景，分别符合迁移前合同；报告记录各领域实际选中的后端。
- Core-enabled job 不得把因缺少 `OCP_CORE_ENABLED` / `OCP_CORE_LIBRARY_PATH` 而跳过的激活测试视为接入验证成功；`ping` 成功也不能替代各领域的实际 Core 调用断言。
- 对缓存写入、同步/进度上报、登录重试等有副作用的路径检查执行次数和状态归属，确认不会同时调用旧 Swift 实现或失败后经另一后端重复执行。
- macOS 与 iOS 的原生模型、平台存储、UI 状态投影仍正常工作；保留的 Swift 分支与 Rust 路径在约定行为上没有因路径迁移而变化。

当前规划在 Windows 机器上完成，Mac 构建结果需要在执行阶段取得。

### 文档与来源

- 根 README 能明确定位三端开发、构建、测试和发行入口。
- 更新活动维护的构建与架构文档，保留历史验收报告的原始日期、来源和结论。
- 新版源码、配置和活动构建脚本默认路径不依赖旧分仓库布局。
- 两个远端主分支对象 ID 一致，开发者可从任一远端克隆同一份源码。

## 7. 回退与完成标准

切换前，原工作区和三个完整 Git 备份可直接用于恢复开发。

切换后的短期回退以最终迁移 merge commit 的第一父提交为基准，使用 `git revert -m 1` 恢复迁移前布局，再同步两个远端。这样保留已导入的 Git 历史，原 Core、Windows 仓库也仍有迁移前主分支。若切换后已有新功能提交，先核对其影响再制定回退提交。

满足历史校验、单一绑定源码、Swift/Rust 归属与实际选路核对、全新检出构建、平台测试与打包、双远端同步后，才视为本轮合仓完成。未取得 Apple 检查结果时，迁移仍处于待验收阶段。

后续可独立推进统一三端产品版本、进一步复用领域测试 fixture、内核版本对齐与文档精简；这些工作各自保留单独的验证与提交边界。
