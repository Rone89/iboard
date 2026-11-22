# Agent Note: 引擎按需懒建全拼双拼字典与 iOS 键盘异步恢复会话

Status: implemented

## Problem

iOS 键盘在每次收起时为防止 App Group 词库租约锁随进程挂起触发 `0xdead10cc`（见 [只在可见期间持有引擎会话](2026-11-02-ios-keyboard-session-only-while-shown.md)），都会销毁引擎会话并在下一次 `viewWillAppear` 同步重建。在实测唤醒路径时，发现三个叠加在首帧前的阻塞源：

1. **每次重建会话都同时打开两份拼音词库**：`ProviderRegistry::new` 对包含全拼与双拼的方案集同时构造 `QuanpinEngine` 与 `ShuangpinEngine`，两者各自打开 `msime-pinyin.db`（约 76 MB）、执行 `database.warm_up()` 与粗俗词表读取，哪怕用户只使用其中一种方案。
2. **`viewWillAppear` 主线程同步阻塞等待 `msime_client_create` + `focus`**：此前 [低端机功耗](2026-10-27-ios-keyboard-low-end-power.md) 暂缓了异步建会话，导致每次弹起键盘的首帧动画都被引擎初始化挡住。
3. **`viewWillAppear` 主线程同步扫描按需资源包**：`InputSchemePreference.refreshResourceAvailability()` 每次出现都跨 C ABI 调用 `IOSResourcePacks.list()`；完整版扩展已随包携带日文与全部语言词库，白白在主线程做目录扫描与 JSON 编解码。

## Decision

1. **Rust 侧按需懒建全拼/双拼引擎**：`ProviderRegistry::new` 不再预先构造 `QuanpinEngine` 和 `ShuangpinEngine`，改为仅记录 `paths` 与 `profile`，在 `activate(SchemeType::Quanpin | Shuangpin)` 或首次查询/扩展/缓存动态候选对应方案时通过 `ensure_quanpin` / `ensure_shuangpin` 按需构造。启用单一拼音方案时不再重复打开第二条 `msime-pinyin.db` 连接；仅激活五笔时也不提前构造全拼引擎，待首次混拼查询时再按需创建。
2. **iOS 扩展异步恢复引擎会话**：
   - `MetasequoiaInputSessionBridge` 新增 `resumeDictionarySessionAsync`，在常驻串行 `MSIMEInputThread` 上直接调用 `*Raw` C ABI 完成创建、聚焦与网格/全角/标点/AI 凭据/隐私标记重放，主线程立即返回渲染键盘首帧。
   - 异步恢复期间若用户抢跑敲击 26 键字母或九键数字，`enqueueCharacter` / `enqueueCharacters` 与 `setKeyGeometry` 将任务排在同一 FIFO `MSIMEInputThread` 的恢复任务之后顺序执行，通过带代次（`epoch`）的 `AsyncResumeState` 复用刚建出的句柄，不丢字也不阻塞主线程。
   - 任何需要同步读取句柄的调用先经 `flushPendingResumeIfNeeded()` 结算；`suspendDictionarySession()` 在恢复未结算时递增代次取消、同步排空 `MSIMEInputThread` 并立即销毁已建出的孤儿句柄，确保收起或 `releaseLocksBeforeSuspension()` 返回时绝不持有任何 App Group 锁；`holdsSession` 在恢复进行期间返回 `true`，保证 `AppGroupLockActivity` 不会提前结束。
   - `KeyboardViewController.viewWillAppear` 先把本机上下文、方案和学习偏好记入挂起桥（零 FFI），再发起异步恢复；通过 `resumesSessionAsynchronously` 控制（真实 `.appex` 扩展默认开启，单测宿主默认同步以保住既有紧邻 `viewWillAppear` 的锁断言，异步行为由专门用例显式开启验证）。
3. **资源包可用性检查移出主线程**：`InputSchemePreference` 在全部可选语言包已随包内置时跳过 `IOSResourcePacks.list()`；否则由 `refreshResourceAvailabilityAsync` 在后台队列扫描并仅在变化时回到主线程同步方案。

## Alternatives considered

- **收起时保留引擎会话、仅释放文件锁**：能彻底免去重建开销，但词库连接分散在各 provider 与 store 中，改造跨多个 crate 且一旦漏放即导致 `0xdead10cc`（同 [低端机功耗](2026-10-27-ios-keyboard-low-end-power.md) 中的评估），风险远高于按需懒建加异步恢复。
- **在 `viewWillAppear` 中把单测默认也切为异步恢复**：无需区分扩展与单测宿主，但仓库现有 170 余处控制器单测中有多条在 `viewWillAppear(false)` 后不转动 `RunLoop` 就直接同步断言锁状态，强改会破坏既有回归测试前置条件；遵循仓库已有的 `asynchronousInputEnabled`（按 `.appex` 区分、单测显式开关）更稳妥。

## Consequences

- **收益**：每次重建全拼或双拼会话减少一半主词库打开与预热开销；iOS 真机键盘 `viewWillAppear` 不再同步等待引擎创建与资源包扫描，首帧滑出更跟手，且恢复窗口内抢跑输入顺序不丢、快速收起零锁泄漏。
- **代价**：首次在运行中的同一会话内从全拼切到双拼（或五笔首次触发混拼）时，对应方案的 `msime-pinyin.db` 打开与 `warm_up()` 推迟到那次切换/查询时发生；`MetasequoiaInputSessionBridge` 增加了代次取消状态机，后续改动会话生命周期须保持 `MSIMEInputThread` 单线程 FIFO 与 `suspendDictionarySession()` 零持锁不变量。

## Verification

- Rust 单测：`cargo test -p msime-engine --lib ime::registry`（更新 `providers_follow_the_enabled_schemes` 覆盖全拼/双拼/五笔懒初始化）与 `session::tests` 全部通过。
- iOS 单测：在 `NineKeyKeyboardTests` 新增 `testAsyncResumeComposesQueuedEarlyKeystrokesAndReleasesLocksOnDismiss` 与 `testAsyncResumeCancelledByImmediateDismissLeavesNoLockHeld`，验证抢跑首键组字、正常持锁与恢复途中立即收起零锁泄漏；并跑通原有 `NineKeyKeyboardTests` 锁生命周期用例。
- 真机验收：重新编译 arm64 静态库与 Release App，签名安装到真机核实冷/热唤醒体验与基本输入。
