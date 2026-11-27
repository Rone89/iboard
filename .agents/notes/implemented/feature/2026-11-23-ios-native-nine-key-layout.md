# Agent Note: iOS 九键新增「iOS 原生」十键布局样式

Status: implemented

## Problem

既有九键布局（`standard`、`comma_period`、`emoji`、`tall_return`）均采用 14% 左侧标点/拼音条 + 中间 3×3 九宫格 + 14% 右列 + 底行的框架。基于 Xcode 27 模拟器（`iPhone 18 Pro Max` `440 × 956 pt @3x`）对系统原生「简体中文 · 拼音（十键）」的实测，原生十键为 **5 等宽列（每列 20%，80 pt）× 4 等高行（49 pt，列距 6 pt，行距 7 pt，连续圆角 9 pt）**，左下 `ABC` 与右下 `↵` 各跨两行，中间底行为 `选拼音`（1 列）+ `空格`（2 列），全键使用统一键面底色，2–9 键面居中无右上角数字角标。现有样式无法在保留老用户习惯的同时还原这套原生对称手感。

## Decision

1. **共享偏好新增枚举项与平台缺省值（[preferences.rs](../../../../crates/client-core/src/preferences.rs)、[TouchKeyLayoutStylePreference.swift](../../../../platforms/ios/SharedUI/preferences/TouchKeyLayoutStylePreference.swift)）**：
   - 经维护者明确确认，采用与 `TouchNumberPadSpace` 一致的 `PlatformDefault` 模式：在 `TouchNineKeyStyle` 中以 `PlatformDefault`（`"platform_default"`，缺键省略）为共享缺省值，并新增 `IosNative`（`"ios_native"`，iOS 显示名 `"iOS 原生"`）。
   - iOS 在文档缺键或写 `"platform_default"` 时默认按 `.iosNative`（`TouchNineKeyStyle.platformDefault`）绘制；Android 与鸿蒙仍按原有 `standard` 处理。iOS 用户在设置里显式切回「标准」时，`"standard"` 会正常落盘并同步，不会回弹到 `ios_native`。
   - 设置页「键盘 › 按键布局」与皮肤实时预览（[KeyboardKeyLayoutSettingsView.swift](../../../../platforms/ios/App/Sources/keyboard/KeyboardKeyLayoutSettingsView.swift)、[KeyboardSkinPreview.swift](../../../../platforms/ios/App/Sources/keyboard/KeyboardSkinPreview.swift)）为 `.iosNative` 渲染对应的 5 等宽列 × 4 等高行 + 左右双高键预览。
2. **独立视图实现与实拍细节对齐（[IOSNativeNineKeyView.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/IOSNativeNineKeyView.swift)、[NineKeyStripSpellingBar.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/NineKeyStripSpellingBar.swift)）**：
   - 不往巨型 `KeyboardViewController.swift` 堆叠逻辑，新建独立 `IOSNativeNineKeyView` 与 `NineKeyStripSpellingBar`，按实测比例实现 5 等宽列 × 4 等高行、9 pt 连续圆角、统一键面底色（回车在组字确认或主动作态时仍由 `styleReturnKey` 着强调色）、`1` 键空态 `,。?!` / 组字态 `分词`、右中键空态 `^_^` / 组字态 `重输`、`选拼音` 保持全不透明实体键帽并在组字时直接打开候选面板、双宽空格键显示 `空格`、搜索框下右下双高回车显示原生放大镜图标（`magnifyingglass`），并完整保留 1–9 长按与上滑数字手势、滑行输入、空格光标拖动及无障碍标识。
   - **九键展开候选面板布局（选拼音在候选栏、候选词在候选面板）**：全拼九键点按「选拼音」、顶栏 `∨` 或下拉候选栏打开候选面板时，顶部候选栏切换为横向可滚动的 `NineKeyStripSpellingBar` 展示拼音/首字母/数字选项，全部候选词（自第 1 条起，不再把首屏候选留在顶栏）展示在下方候选面板，默认隐藏面板左栏把 15% 宽度还给候选网格；切入「笔画」筛选时左栏再按需显示笔画键，收起后恢复普通候选栏与九键键盘。
   - 在 [KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift) 做懒构造与最小化切换接线，并在 `viewWillAppear` 先从 App Group 镜像刷新 `keyLayoutStyle` 以确保在设置 App 切换样式后回键盘首帧即刻生效；仅作用于拼音九键字母层，切到数字层（`123`）仍复用原生 4×3 数字键盘，笔画与九键双拼继续使用既有外框。

## Alternatives considered

- **直接改造现有的「右侧大回车（`tall_return`）」样式**：会改变已有用户的左栏标点/拼音条和底行键位习惯；新增独立 `ios_native` 枚举项零破坏既有样式，且可在设置页直接对比预览。

## Consequences

- **收益**：用户可在「设置 › 键盘 › 按键布局 › 9 键」一键选用 1:1 复刻的「iOS 原生」十键布局，同时不影响其他四种九键样式和现有九键单测。
- **代价**：当前仅 iOS 原生宿主实现该样式视图，Android / 鸿蒙读到 `ios_native` 时按 `standard` 或既有兼容分支处理，后续需要时再按同一共享键值扩展。
- **验证**：由 `cargo test -p msime-client-core touch_nine_key_style`、`pnpm run verify-notes`、iOS `KeyLayoutStyleTests`（含真键盘几何与组字交互断言）及 `RCe2027` 真机构建安装覆盖验证。
