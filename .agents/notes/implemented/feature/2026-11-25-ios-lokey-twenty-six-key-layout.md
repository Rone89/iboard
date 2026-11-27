# Agent Note: iOS 26 键新增并默认启用 Lokey 布局样式

Status: implemented

## Problem

在对比逆向实测的 `Lokey 0.9.5` 键盘扩展与 iBoard 现有 26 键布局后，两者在紧凑几何、小屏分档与防误触热区上存在明显差异：现有 26 键在手机竖屏采用 `3pt/6pt` 外边距、`9pt` 圆角、`9.5pt` 第三排间隙、`5` 键标准底行（含独立 `中/英` 与 `，`），缺少 `<390pt` mini 档与 iOS 26 `hostTopPadding` 扣减，中文 `123` 第三排为 5 标点且缺少半角 `.`，同时顶栏与第一排之间未做防吞直通、第三排与底排上沿未做组字态边缘防误触重映射。维护者要求先以独立样式完整复刻这套 26 键布局并设为 iOS 默认，同时保留原有四种样式随时切回。

## Decision

1. **共享偏好采用 `PlatformDefault` + `Lokey` 模式（[preferences.rs](../../../../crates/client-core/src/preferences.rs)、[TouchKeyLayoutStylePreference.swift](../../../../platforms/ios/SharedUI/preferences/TouchKeyLayoutStylePreference.swift)）**：
   - 沿用九键 `iosNative` 已验证的 `PlatformDefault` 跨端缺省模式：`TouchTwentySixKeyStyle` 以 `PlatformDefault`（`"platform_default"`，缺键不写）作为共享默认，新增 `Lokey`（`"lokey"`，设置页名 `"Lokey"`）。
   - iOS 缺键或读到 `"platform_default"` 时默认按 `.lokey`（`TouchTwentySixKeyStyle.platformDefault`）绘制；Android 与鸿蒙仍按原有 `standard` 处理。iOS 用户显式切换回「标准」时 `"standard"` 正常落盘并同步。
2. **新增独立几何与符号层模块（[LokeyLayoutMetrics.swift](../../../../platforms/ios/SharedUI/keyboard/LokeyLayoutMetrics.swift)、[KeyboardLayoutTables.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardLayoutTables.swift)）**：
   - 复刻 Lokey 7 档屏幕分类与总高表（`375pt` mini `239pt`、`393pt` compact `250pt`、`430pt` Pro Max `268.5pt`、横屏 `197.5pt`、折叠屏外屏/展开竖横屏）以及 iOS 26 `hostTopPadding`（上限 `17pt`，顶栏保底 `31pt`，横屏不扣）动态扣减。
   - 复刻竖屏 `6.5pt` 外边距、`6.25pt` 水平键距、`10.5/11pt` 垂直排距、`7.0pt` 连续圆角、第三排 `sideW = max(keyW * 1.348, 42)`（Pro Max 两侧约 `14.9pt` 宽缓冲）与严格左右对称 4 键底行（`123 | ☺ | 空格 | 换行`，隐藏独立中/英键；带地球键时 `123 / 🌐 / ☺` 与单颗字母同宽）。
   - 复刻 `123` / `#+=` 6 标点符号层（中文 `123` 含半角 `.`、中文 `#+=` 首排全角 `【 】 ｛ ｝`、`#+=` 与 `⌫` 内侧各追加 `5pt` 缓冲，底行保持同款对称 4 键）。
3. **新增独立触控热区路由模块（[LokeyTouchHitRouter.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/LokeyTouchHitRouter.swift)、[KeyGapRouting.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyGapRouting.swift)）**：
   - 在 `KeyAreaStackView.hitTest` 挂接 `LokeyTouchHitRouter`：在保留 iBoard 原有顶栏（工具栏与候选条）的前提下，将顶栏与首排缝隙以及顶栏底沿非交互空白处透传给水平最近的 `Q–P`（绝不抢夺工具栏/候选按钮及候选条中上部滚动手势）；
   - 按 Lokey 组字态与空闲态双阈值对 `Shift`（→ `A`/`Z`）、`⌫` 外部空隙（→ `L`/`M`，直接点在 `⌫` 键帽内绝不抢夺）及底排上沿（`Z..M` 横向范围内 → 最近 `Z..M`）执行防误触重映射。
4. **设置页预览与最小化接线（[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)、[KeyboardKeyLayoutSettingsView.swift](../../../../platforms/ios/App/Sources/keyboard/KeyboardKeyLayoutSettingsView.swift)、[KeyboardSkinPreview.swift](../../../../platforms/ios/App/Sources/keyboard/KeyboardSkinPreview.swift)）**：
   - 仅在 `KeyboardViewController.swift` 做最小化接线（密码/纯数字输入框退回 `.standard`），并在「按键布局」设置页与皮肤预览同步渲染 Lokey 26 键预览。

## Alternatives considered

- **直接原地覆写 `.standard` 样式参数**：会破坏现有老用户带独立 `中/英` 键与 `，` 键的 5 键底行习惯且无法在设置页一键切回；新增独立 `.lokey` 样式并采用 `PlatformDefault` 既让 iOS 默认即得 Lokey 手感，又保持其余四种样式与跨端行为零回归。

## Consequences

- **收益**：iOS 中文 26 键默认具备 Lokey 0.9.5 的对称布局、7 档高度与 `hostTopPadding` 补偿、6 标点符号层及防吞点/边缘防误触手感，同时保留 iBoard 原有顶栏工具生态，并可在设置页随时切回原样式。
- **代价**：当前仅 iOS 原生宿主实现 `.lokey` 几何与热区路由，Android 与鸿蒙读到 `lokey` 或 `platform_default` 时按既有 `standard` 处理。
- **验证**：由 `cargo test -p msime-client-core`、`cargo test -p msime-client-services`、`pnpm run verify-notes` 及 iOS Simulator `xcodebuild test`（覆盖 `LokeyLayoutTests`、`KeyLayoutStyleTests`、`KeyboardKitParityEnhancementTests`、`TypingStatisticsTests`）验证。
