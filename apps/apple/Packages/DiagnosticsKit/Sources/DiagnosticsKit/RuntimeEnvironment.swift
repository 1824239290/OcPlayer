import Foundation

/// 运行环境探测：目前只有一件事实——**本进程是不是测试宿主**。
///
/// 为什么需要它：`OcPlayerTests` 用的是 `TEST_HOST` 模式，测试跑在**真实 App 进程**里
/// （见 `project.pbxproj` 的 `TEST_HOST = OcPlayer.app`）。于是 App 的启动路径会照常执行，
/// 包括那些只该在真实使用时发生的事：拉取更新、从磁盘恢复用户会话、连真实服务器。
///
/// 这不是理论问题，是实际发生过的：
/// - 一次全量 AppTests 会在真实日志目录留下 6 个会话文件，还会混进用户报障要发的诊断包；
/// - 「崩溃前 116 行残缺记录」也是「测试宿主 + App 共写同一文件」留下的；
/// - 凭据迁移一旦上线，跑一次测试就会在真实 Application Support 里建出
///   `credentials.json` —— 测试进程动了用户的真实凭据文件。
///
/// 所以判定收在这**一个**地方：散落的 `XCTestConfigurationFilePath` 字符串比较，
/// 漏一处就是一个静默的真实副作用。
public enum RuntimeEnvironment {

    /// 是否运行在测试里。
    ///
    /// 注意：这是**环境**判定而不是编译期判定——测试宿主编的是与生产完全相同的二进制，
    /// 所以不能靠 `#if DEBUG`（Debug 构建的 App 也可能被正常双击运行）。
    ///
    /// 要同时覆盖两种跑法，实测差异如下（本机 macOS 26 / Swift 6.2）：
    ///
    /// | 跑法 | `XCTestConfigurationFilePath` | XCTest 框架 |
    /// |---|---|---|
    /// | Xcode `xcodebuild test`（`TEST_HOST`，AppTests） | **有** | 已加载 |
    /// | `swift test`（SPM 包测试，走 `xctest` 可执行文件） | **没有** | 已加载 |
    ///
    /// 只看第一个环境变量会漏掉 SPM 那一路 —— 而漏掉的后果是**真实副作用**：
    /// 包测试会往真实日志目录写文件（`DiagnosticBackend` 靠这个判定改道临时目录）。
    /// 所以补上「XCTest 框架是否已加载」：生产二进制不链接它，`NSClassFromString` 返回 nil。
    public static let isRunningTests: Bool = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }()
}
