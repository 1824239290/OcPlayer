# 共享片头来源服务

启用 OcPlayerCore 后，AniSkip、AnimeSkip、TheIntroDB 和 AniList 客户端为每个
客户端保留一个 Core 实例，通过 Core 的连接池发送可取消 HTTP 请求。前三个来源
的请求组装、响应解析、OP 区间转换和时间戳选择也使用 Rust 实现。

客户端仍接受注入的 URLSession。含自定义 URLProtocol 的配置使用原版传输，方便
测试；默认生产配置使用 Core。每次 Core exchange 只发送一次请求，AniSkip 在
原有 RetryPolicy 中处理传输超时/断网，HTTP 状态和响应解析保持在循环外。
因此 HTTP 429/5xx 不会新增重试；AniSkip 404 返回 nil，TheIntroDB 404 保持抛错。

新增 baseURL 参数允许 AnimeSkip、TheIntroDB 和内部 AniList 客户端连接本地
HTTP fixture 或带路径前缀的代理。默认地址和 GraphQL 的字符串变量沿用原版。
原版解析函数保留为独立测试对照，覆盖首个标注、季号优先级、等时间戳顺序、
重复 JSON 键、Unicode 编码、坏字段及 Int64 边界。

RustIntroProviderTests 使用 Fixtures/intro_provider_server.py 验证全部四个
客户端的真实 HTTP 调用、连接复用、错误类型、超时重试和取消。这个 fixture
与 OcPlayer-Core 中的副本逐字节校验。完整 API 合约和原始验证日志保存在
OcPlayer-Core 的 docs/intro-provider-contract.md 和对应 validation 目录。

AniList 身份解析/ID 缓存、完整共享加载编排，以及 URLSession 的独立空闲/资源
截止时间仍需迁入 Core。当前桥接以较小的 request/resource timeout 作为整次请求
截止时间，尚未完成整个传输层的等价验收。
