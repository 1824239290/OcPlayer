import ErikaKit
import PlaybackKit

/// **整个 App 里唯一 import 具体内核适配器的地方。**
///
/// 加一个内核 = 在下面加一行 `register`。删一个内核 = 删那一行 + 删对应的
/// `Packages/<XxxKit>` 目录 + 清 `Scripts/package-macos.sh` 的许可证条目和
/// `OpenSourceLicensesView` 的组件清单。App 层其它文件、`PlaybackKit`、
/// 以及另一个适配器都不用动。
///
/// 注册顺序 = 设置页显示顺序 = 没有显式选择时的默认（第一个）。
///
/// 用户选的内核存在 UserDefaults 里，在 `PlaybackController.prepareEngine()`
/// （懒创建）时读取，所以**切换在下一次播放生效**，不用重启。
/// 存的 id 找不到时 `PlaybackEngineRegistry` 会静默回退到第一个可用内核——
/// 一条失效的偏好不能让播放器打不开。
///
/// ⚠️ **不是所有内核都能共存**：libmpv 的预编译包（MPVKit）里 libdovi 是 Rust 写的，
/// 和同样是 Rust 的 Erika 各带一份 Rust std，`_rust_eh_personality` 在静态链接期
/// 重复定义（`ld: 1 duplicate symbols`），两者只能二选一。若将来要加第二个内核，
/// 优先选不含 Rust 的（libVLC 是 C/C++，不会有这个问题）。
enum PlaybackEngineAssembly {
    @MainActor
    static func registerAll() {
        PlaybackEngineRegistry.register(ErikaEngine.descriptor) { try ErikaEngine() }
    }
}
