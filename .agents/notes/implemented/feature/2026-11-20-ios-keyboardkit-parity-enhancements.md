# Agent Note: iOS 键盘长按气泡扩展、回车语义着蓝、退格加速与 Liquid Glass 细节协调

Status: implemented

## Problem

在完成[设备分档尺寸](2026-11-20-ios-keyboardkit-device-tier-metrics.md)、[Liquid Glass 气泡配色](2026-11-20-ios-keyboardkit-callout-and-liquid-glass.md)与[多选气泡横滑直选](2026-11-20-ios-action-callout-and-swipe-disambiguation.md)之后，iOS 键盘与 `KeyboardKit 11.2.4` / 系统原生键盘之间还剩四处高感知体验缺口：

1. **26 键常用标点与符号层仍割裂使用系统 `UIMenu` 或无长按衍生项**：`quickPunctuationButton` 挂系统 `UIMenu` 必须抬手二次点选；符号层的 `0`/`-`/`/`/`$`/引号及 `.URL`/`.emailAddress` 语境的 `.` 键（`.com`/`.cn` 等）尚未接入 `KeyActionCalloutView` 横滑直选。
2. **原生皮肤回车键未区分「普通换行」与「主动作/确认」语义**：`styleReturnKey()` 与 `applyKeySkin()` 在原生皮肤下把 `.default` 换行也涂成 `actionBackground` 蓝；同时 `.URL`/`.emailAddress` 框下的手机底行没有顺手露出 `/`、`@` 与独立 `.` 键。
3. **长按退格固定速度、空格轨道板缺少视觉降噪与步进反馈**：`repeatBackspace()` 固定 `0.075s` 删长段英文偏慢；`handleSpaceCursorMovement` 只在 `.began` 震一次，周围键面未淡出提示轨道板激活。
4. **原生皮肤工具栏与功能磁贴激活态未采用 Liquid Glass 胶囊底托**：`KeyboardToolbarButton` 仍用 `40pt` / `12pt` 圆角方托，`KeyboardFunctionTileView` 开启项仅靠右下角小对勾标识。

## Decision

1. **统一长按气泡策略（[KeyHoldCalloutPolicy.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyHoldCalloutPolicy.swift)）**：
   - 将 `quickPunctuationButton`（非 `commaHoldsPeriod`/`handwritingQuestion` 场景）、`periodKey`（`.URL`/`.emailAddress` 域名后缀）与 `symbolLayerKeys`（数字/货币/破折号/引号等衍生）接入通用 `trackKeyHoldLongPress` + `KeyActionCalloutView`（`0.35s` 触发），移除 `quickPunctuationButton.menu`；弹出前调用 `KeyboardKeyButton.cancelPressPreview()` 避免双气泡重叠，`KeyActionCalloutView` 针对 `.com`/`https://` 等宽选项改用 `.fill` 分布与 `>= 36pt` 自适应宽度。
   - 保留 26 键字母键角标斜滑规则不变，不引入重音字母气泡；日文假名 `nineKeySymbolsButton` 的 `showsMenuAsPrimaryAction` 主动作菜单保持原样。
2. **回车语义着蓝与 URL/Email 语境底行（`ReturnKeyStylePolicy`、`KeyboardContextBottomPolicy`）**：
   - `ReturnKeyStylePolicy.usesActionAccent` 在原生皮肤下仅对组字确认或非 `.default` 的主动作（`.search`/`.send`/`.go` 等）使用 `actionBackground`，普通 `.default` 换行回归 `functionKeyBackground` + `keyForeground`；非原生皮肤保留设计稿全态强调色。
   - `KeyboardContextBottomPolicy` 在 `.URL`/`.emailAddress` 且未自定义常用标点时将底行常用标点切为 `/` 或 `@` 并展开独立 `.` 键，且把 `urlOrEmailContext` 纳入 `KeyboardLayoutInputs` 缓存键确保切换输入框即时刷新。
3. **长按退格分级加速/按词删除与空格轨道板反馈（[BackspaceRepeatPolicy.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/BackspaceRepeatPolicy.swift)）**：
   - 退格重复第 `16` 步起将间隔从 `0.075s` 提速到 `0.045s`；在无手写笔迹、无组字、非就地组字且非中文模式下，第 `18` 步起升级为按词删除（`wordDeleteCount(beforeCursor:)`）。
   - `handleSpaceCursorMovement` 进入拖拽后以 `0.12s` 动画将周边按键淡出至 `alpha = 0.28`（保留正在拖动的空格完全不透明），每次发生 `steps != 0` 位移时触发一次 `UISelectionFeedbackGenerator.selectionChanged()`。
4. **原生皮肤工具栏与功能磁贴 Liquid Glass 协调（[KeyboardToolbarButton.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardToolbarButton.swift)、[KeyboardFunctionTileView.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardFunctionTileView.swift)）**：
   - 原生皮肤下激活态 `KeyboardToolbarButton` 改用 `36pt` 胶囊底托（`side / 2` 圆角）配 `0.5pt` `calloutBorder`；激活态 `KeyboardFunctionTileView` 叠加 `skin.accentSoft` + `9pt` 圆角 + `0.5pt` `calloutBorder`，非原生皮肤保持原有外观。

## Alternatives considered

- **全部主题一起改 `.default` 回车为功能键底色**：非原生主题（如四季/自定义皮肤）的设计规范与 `KeyboardSkinTests` 约定回车在所有状态为强调色，仅原生皮肤对齐系统语义最为稳妥。
- **使用 SwiftUI `UIGlassEffect` 重写工具栏和次级面板**：主键盘与工具栏在扩展内深度依赖 UIKit 跨进程触摸修复与零动画复用，`UIView`/`CALayer` 胶囊底托与半像素描边足够稳定且不破坏现有皮肤系统。

## Consequences

- **收益**：26 键标点/符号/域名全面统一到「长按横滑直选」手感；原生回车、URL/Email 输入、长段英文删除、空格移光标与原生工具栏激活态整体更贴近 iOS 原生 Liquid Glass 体验。
- **代价与测试同步**：`KeyboardSkinTests.testNativeKeyboardDrawsLightAndDark` 同步更新为校验原生默认换行态的 `functionKeyBackground`；`QuickPunctuationSettingsTests` 与 `KeyLayoutStyleTests` 同步更新为校验 `quickPunctuationKey.menu == nil` 及 `KeyHoldCalloutPolicy` 选项。
- **验证**：由 `pnpm run verify-notes`、`KeyboardKitParityEnhancementTests`、`KeyboardSkinTests`、`QuickPunctuationSettingsTests`、`KeyLayoutStyleTests`、`LetterCornerHintTests`、`BackspaceSyllableTests` 与 `MSIMEApp` 模拟器构建覆盖验证。
