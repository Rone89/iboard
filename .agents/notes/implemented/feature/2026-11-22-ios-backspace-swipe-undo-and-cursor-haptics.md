# Agent Note: iOS 退格左滑删除与撤销胶囊、空格光标 CoreHaptics 棘轮震动

Status: implemented

## Problem

iOS 键盘在文本编辑与长句修改上有两处明显的手感落差：

1. **删除整词或短句缺少手势入口与容错机制**：长按 ⌫ 在纯英文正文需连续 18 步后才进入按词删除，中文正文更是只能逐字删；误删一段文字后工具栏上也没有一键恢复入口。
2. **空格与全键盘轨道板移光标震动仍走单一系统反馈**：[KeyboardHapticsEngine.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardHapticsEngine.swift) 接入分键 CoreHaptics 后，光标逐格移动仍固定调用 `UISelectionFeedbackGenerator.selectionChanged()`，在「轻 / 中 / 强」震动档位下无法呈现清脆的棘轮刻度感。

## Decision

1. **新增独立模块 [BackspaceSwipeDelete.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/BackspaceSwipeDelete.swift)**：
   - **手势判别**：在 `makeDeleteKey()` 上挂单指 `UIPanGestureRecognizer`（`backspaceSwipeDelete`），要求水平向左速度 `<= -80pt/s` 且水平速度大于垂直速度的 `1.4` 倍，并在已进入长按连删、正在移动光标或手写板有笔迹时拒绝识别，避免干扰轻点与长按连删。
   - **安全切分与组字边界**：正在组字时左滑仅清空整段组字并标记本次手势止步，绝不跨边界误删已上屏正文；非组字状态下按英文词/中文短句（遇标点、空白、换行或 12 字上限截断）步进删除，每跨 `28pt` 再删一块（支持快速左甩 `>= 16pt` 且 `<= -320pt/s` 补删一块），并按原始从左到右文档顺序前置累积被删片段。
   - **工具栏「撤销删除」胶囊（`UndoDeleteToolbarButton`）**：非凭据输入框完成左滑删除后，在品牌键右侧露出与「一键粘贴」同构的 Liquid Glass 胶囊并附带前 4 字摘要（显示期间暂藏一键粘贴避免拥挤）；点按原样恢复文本，任意后续输入、普通退格、光标移动、切换输入框或键盘收起立即失效清除。凭据/密码输入框绝不缓存被删文本。
2. **扩展 [KeyboardHapticsEngine.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardHapticsEngine.swift) 的光标与编辑震动波形**：
   - 新增 `.cursorTick`（高锐度 `0.92–0.96` 细密刻度脉冲）、`.swipeDelete`（干脆双脉冲）与 `.undo`（上扬双脉冲）。
   - `handleSpaceCursorMovement`（空格拖动与全键盘横滑共用）进入轨道板时播 `.glideStart`，每次 `steps != 0` 播 `.cursorTick`；`.system` 档或不支持 CoreHaptics 的设备回退到原有 `UIImpactFeedbackGenerator` / `UISelectionFeedbackGenerator`。

## Alternatives considered

- **在 ⌫ 上改用上滑清空全框（类似 Android）**：iOS 用户在键盘右下角天然习惯从 ⌫ 向左滑删除（与 Gboard/系统习惯一致），上滑容易与键盘顶层字母 `L`/`P` 及滑行输入误触，因此选择左滑分块删除配合工具栏撤销胶囊。
- **把逻辑直接写进 `KeyboardViewController.swift`**：主控制器已超 1.1 万行，按仓库代码健康规则将切分策略、状态机与撤销胶囊全部收敛在独立的 `BackspaceSwipeDelete.swift`，控制器仅留最小接线。

## Consequences

- **收益**：用户可在中英文场景下通过 ⌫ 左滑流畅成块删词/删短句并一键撤销，空格与全键盘移光标获得随档位细腻可辨的 Taptic Engine 棘轮刻度感。
- **验证**：由 [BackspaceSwipeDeleteTests.swift](../../../../platforms/ios/KeyboardTests/input/BackspaceSwipeDeleteTests.swift)、[KeyboardCursorSwipeTests.swift](../../../../platforms/ios/KeyboardTests/input/KeyboardCursorSwipeTests.swift)、[BackspaceSyllableTests.swift](../../../../platforms/ios/KeyboardTests/input/BackspaceSyllableTests.swift)、[KeyboardKitParityEnhancementTests.swift](../../../../platforms/ios/KeyboardTests/input/KeyboardKitParityEnhancementTests.swift) 与 `pnpm run verify-notes` 覆盖验证。
