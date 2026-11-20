# Agent Note: iOS 长按/反滑气泡单指横滑直选与 26 键角标斜滑消歧

Status: implemented

## Problem

在完成[按键弹出气泡轮廓与 Liquid Glass 配色](2026-11-20-ios-keyboardkit-callout-and-liquid-glass.md)后，iOS 键盘在多选气泡和滑动角标两处手势与 `KeyboardKit 11.2.4`（及本仓 Android 侧规则）仍有体验缺口：

1. **九键长按 / 反滑弹出字母与 14/18 键长按仍只能松手再点**：[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift) 的 `showKeyHoldOptions` 使用 `skin.background` 配 `accent` 细框（在深色 Liquid Glass 下与键盘底色混叠），且仅在 `.began` / `.letters` 弹出浮层——用户按住或反方向滑出选项后继续横向滑动并不能高亮或松手直接上屏（即[九键滑动输入数字](2026-10-29-nine-key-swipe-digits.md)中留给后续的 iOS 缺口）。
2. **`SwipeHintPolicy.swiped` 缺少纵横位移比较**：同文件的 `swipedEitherWay`（长空格逗号）要求纵向位移严格大于横向位移，而 26 键字母角标的 `SwipeHintPolicy.swiped(direction:downY:currentY:)` 只判断纵向差值 `> 14pt`，导致快打斜滑或横滑跨键时偶尔误出角标符号。

## Decision

- **统一多选气泡与单指横滑直选状态机**（`KeyActionCalloutView`，位于 [KeyboardKeyButton.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardKeyButton.swift)）：
  - 外观对齐 `KeyboardKit.KeyboardCalloutStyle.standard`：底色 `skin.calloutBackground`（原生深色 `#6B6B6B` / 浅色 `#FDFEFF`）、描边 `0.5pt` `skin.calloutBorder`、圆角 `10pt`（`KeyPressPreviewView.topRadius`）、投影 `shadowOpacity = 0.14` / `shadowRadius = 5` / `shadowOffset = (0, 2)`，当前高亮选项以 `skin.accent` 圆角胶囊配 `skin.onAccent` 文字突出，并保留原有 `nineKeyHoldBackdrop` / `nineKeyHoldOptions` / `nineKeyHoldOption-*` 无障碍标识。
  - `showKeyHoldOptions(from:options:)` 在视图顶部增加 `topAnchor >= view.topAnchor + 2` 约束避免贴近顶栏时上沿裁切，约束激活后立即 `view.layoutIfNeeded()` 使首帧拖选锚点即可对齐选项坐标。
  - `KeyActionCalloutView.dragSelection(at:itemFrames:calloutBounds:triggerKeyFrame:dragAnchor:hasEntered:)`：原地轻按（未进入气泡矩形且相对锚点横向位移 `< 8pt`）抬手时 `hasEntered` 保持 `false`，气泡留停等待点击或点外关闭，不破坏既有点选和无障碍流程；进入气泡或横向滑动 `>= 8pt` 后进入拖选，按 X 列高亮对应选项、松手即调 `commitNineKeyHoldOption` 上屏，若拖出活性容差框（水平覆盖气泡与触发键外延 `±28pt`、顶 `-32pt`、底 `triggerKey.maxY + 24pt`）再松手则取消高亮并静默关闭。
  - 九键长按（`handleNineKeyHold`）、14/18 键长按（`handleFourteenKeyHold`）共用 `trackKeyHoldLongPress` 分发 `.began` / `.changed` / `.ended` / `.cancelled`；九键反方向滑动（`KeyboardKeyButton.touchesMoved` / `endTouches` / `touchesCancelled`）通过 `onNineKeySwipeDrag` 与 `onNineKeySwipeDragCancelled` 复用同一条 `trackKeyHoldOptions` 通道，在 `Gesture.letters` 判出后继续传递移动和松手。
- **26 键角标斜滑消歧**（[LetterHintTable.swift](../../../../platforms/ios/KeyboardExtension/Sources/input/LetterHintTable.swift)）：
  - `SwipeHintPolicy` 新增 `swiped(direction:down:current:)`（要求 `distance > threshold && distance > abs(current.x - down.x)`），`KeyboardKeyButton.cornerHintSwiped(_:)` 改传完整窗口坐标 `CGPoint`；保留原有 `downY:currentY:` 重载兼容既有纯纵向单测；九键上下滑 `NineKeySwipePolicy` 仍保持「只看纵向位移」的三端约定不变。

## Alternatives considered

- **26 键长按字母改造成多候选变音符菜单**：iOS 英文键盘通常长按字母弹出重音/变音符，但本仓 26 键在中文和英文模式下均将长按固定分配给右上角快捷符号（`LetterHintTable`，由 `LetterCornerHintTests` 与三端对齐契约钉住），直接替掉会破坏老用户的长按角标手感，故保留 26 键单角标行为，将 `KeyActionCalloutView` 优先落在多选项气泡入口（九键 1–9、九键反滑与 14/18 键）。
- **继续沿用 `UIMenu` 或每次手势改在触摸外层全屏幕加覆盖层拦截**：`UIMenu` 必须先长按触发后再点二次，不支持单指顺滑扫选；而全屏手势拦截会与九键滑动、光标横滑和 `KeyboardViewController` 现有触摸分配耦合。直接在现有 `UILongPressGestureRecognizer` 与 `KeyboardKeyButton` `touchesMoved`/`endTouches` 回调上复用位置跟踪，改动最局部。

## Consequences

- **收益**：九键长按、九键反滑弹出与 14/18 键长按全部补齐「按住直接横滑选中松手上屏、滑出取消、原地松手可点选」的连贯交互，气泡对比度与深浅色质感同主键盘气泡统一；26 键斜滑不再误触角标。
- **代价**：若未来为 26 键英文或标点键（如独立 `.` 键）新增多选长按，需在按钮配置期避开与已有 `cornerHint` 长按共存的键位冲突；同页单测需确保弹窗添加到带 `UIWindow` 或完成布局后再注入拖动坐标。
- **验证**：由 `pnpm run verify-notes`、`MSIMEApp` 模拟器与真机（`RCe2027`，iPhone 18 Pro Max）构建装机实测，以及 `LetterCornerHintTests`（含真实按钮斜滑消歧）、`NineKeySwipeDigitsTests`（含九键反滑与长按拖选）、`FourteenKeyKeyboardTests`（含 14 键长按拖选）、`KeyPressFeedbackTests`、`BackspaceSyllableTests`、`KeyGapRoutingTests`、`TouchPointTests` 与 `NineKeyKeyboardTests` / `EighteenKeyKeyboardTests`（跳过已知基线偏差项 `testKeyLayoutsKeepNineKeyHeight`、`testTheThreeRowsShareTheSameLeftAndRightEdges`）覆盖验证。
