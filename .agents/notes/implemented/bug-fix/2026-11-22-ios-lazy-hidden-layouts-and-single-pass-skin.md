# Agent Note: iOS 键盘隐藏布局按需懒加载与冷启动单次全树换肤

Status: implemented

## Problem

在 [引擎按需懒建全拼双拼字典与 iOS 键盘异步恢复会话](2026-11-22-ios-async-session-resume-and-lazy-providers.md) 消除 `viewWillAppear` 同步引擎重建后，iOS 键盘扩展被系统回收后的冷启动首帧仍有两块明显的 UI 主线程开销：

1. `installKeyboard()` 在 `viewDidLoad()` 里一次性构造全部隐藏键区：九键/笔画内容与右侧大回车（约 26 键）、日文假名九键及侧边功能键（约 20 键）、旧十键符号层（30 键）、设计符号层（30 键）以及仅 iPad 单手使用的数字侧栏（12 键）。26 键用户冷启动首帧前要白白创建 110+ 个自定义按键与大量 Auto Layout 约束。
2. `viewDidLoad()` 在 `installKeyboard()` 刚按当前主题造完并装饰好按键后，立即离屏调用全树 `applyKeyboardSkin()` 重涂一遍全部按键，紧接着进窗前的 `viewIsAppearing()` 因 `keySkinNeedsWindowPass` 又完整重涂第二遍。

## Decision

1. **五组隐藏布局改为首次显示时按需懒加载**（沿用 [低端机功耗](2026-10-27-ios-keyboard-low-end-power.md) 里 `ensureAlternateLetterRows` 的模式）：
   - `nineKeyContainer` 先仅保留空 `UIStackView` 占位锚点，内部九宫格/笔画/侧栏/右侧大回车在 `nineKeyFrame` 首次为 true 时由 `ensureNineKeyLayout()` 构造，并补齐当前键距、行距、回车样式与阴影色。
   - `japaneseKeys` 在 `kana` 首次为 true 时由 `ensureJapaneseNineKeyLayout()` 构造并插入 `handwriting` 之前。
   - `symbolRowViews` 与 `symbolLayerRowViews` 分别在对应符号层首次需要显示时由 `ensureSymbolRows()` / `ensureSymbolLayerRows()` 构造、插入中缝（`installSplitGap`）与等高约束。
   - `oneHandSidePad` 延迟到 `applyOneHanded()` 判定 `padShown` 为 true 时再调用 `installOneHandSidePad()`，手机形态永远不构造这组 iPad 专用键。
   - `handwriting` 保持原位：其本身仅含画布、提示和按钮三个轻量视图，且不预先加载 MLKit 识别器（延到 `activate()`），保留它可满足既有 `HandwritingTests` 对隐藏面板的直接查找断言。
2. **消除 `viewDidLoad` 的离屏重复全树重涂**：`applyKeyboardSkin(onlyIfChanged:recolorBuiltKeys:)` 新增 `recolorBuiltKeys` 参数，`viewDidLoad()` 传 `false`，仅更新背景、顶栏底色、回车样式与皮肤/trait 标记（仍保持 `keySkinNeedsWindowPass = view.window == nil`），将唯一一次完整全树换肤留给进窗后 trait 已确定的 `viewIsAppearing()`，同时保持 `KeyboardSkinTests` 既有离屏/进窗换肤契约不变。

## Alternatives considered

- **把 `viewIsAppearing()` 改成只刷新阴影色、不再重涂按键**：可再省去离屏测试里的重涂，但既有回归用例 `KeyboardSkinTests.testReappearingWithAnUnchangedSkinLeavesTheKeysAlone` 显式断言窗口外初始化的控制器在 `viewIsAppearing` 会完整重涂按键底色；改为去掉 `viewDidLoad()` 中刚建完按键后的那一遍冗余重涂，既把冷启动全树遍历降为单次，又不改动既有测试前置条件。
- **连 `handwriting` 也改为懒创建**：仅省三个轻量视图，却会让既有 `HandwritingTests` 在未切入手写前查找 `handwritingInput` 失败，收益极小、得不偿失。

## Consequences

- **收益**：26 键冷启动 `viewDidLoad()` 少构造 110+ 个隐藏按钮、约 25 个容器栈与对应约束，且冷启动从两遍全树换肤降为单遍，明显缩短被 Jetsam 回收后重新拉起键盘的首帧耗时。
- **代价**：首次切到九键、日文假名九键、123/#+= 符号层或 iPad 单手数字侧栏时，对应那一组键的构造开销挪到第一次切换发生；后续切换直接复用已建视图。

## Verification

- `NineKeyKeyboardTests` 新增 `testTwentySixKeyColdStartDefersHiddenLayoutsUntilShown`，验证 26 键冷启动不构造九键/日文/符号层/单手侧栏，且切入 `123` 后按需创建。
- 跑通 `KeyboardSkinTests`、`NineKeyKeyboardTests`、`JapaneseNineKeyTests`、`LanguageSchemesTests`、`OneHandModeTests`、`HandwritingTests` 等模拟器单测，以及 `pnpm run verify-notes`。
- 真机 arm64 Release 编译签名并安装到真机核实冷热唤醒与各层切换。
