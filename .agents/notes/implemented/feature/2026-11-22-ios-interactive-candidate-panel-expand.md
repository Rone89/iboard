# Agent Note: iOS 候选栏下拉 1:1 交互式展开与空格键无字化

Status: implemented

## Problem

1. **候选栏下拉展开缺少跟手过渡**：此前 `CandidateStripVerticalSwipeRecognizer` 在下滑超过 `6pt` 后直接触发一次性离散展开，手指慢拉时没有 1:1 渐显反馈；同时 `KeyboardCandidatePanelView` 在复用候选格时每次移除并重建 `UIAction` 与无障碍动作，展开瞬间有一定主线程开销。
2. **空格键显示方案字样显得冗余**：底行左下角已有独立的语言/方案切换键，空格键上再印「手写」或方案名属于重复信息，在紧凑布局下视觉较杂。

## Decision

- **候选栏下拉交互式渐显（[CandidateStripRow.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/CandidateStripRow.swift)、[KeyboardCandidatePanelView.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardCandidatePanelView.swift)、[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)）**：
  - 将 `CandidateStripVerticalSwipeRecognizer.activationDistance` 降至 `4pt`，新增 `interactiveDownward` 标志与 `translationY` / `velocityY` 跟踪：开启时下滑进入 `.began` -> `.changed` -> `.ended`，通过 `KeyboardCandidatePanelView.applyInteractiveExpandProgress(_:)`（`CALayer` 裁剪遮罩 + 透明度与轻微位移）和 `setKeyRowsInteractiveExpandProgress(_:)` 让面板与键面 1:1 跟随手指；抬手时满足 `progress >= 0.22 || velocityY >= 200` 则弹簧补全展开，否则回弹收起。
  - 注意 UIKit 中 `UIGestureRecognizer.State.recognized` 与 `.ended` 原始值相同（均为 `3`）：`handleCandidateStripVerticalSwipe` 在 `.ended, .cancelled` 分支里当 `candidatePanel == nil` 且 `state == .ended` 时直接调用 `showCandidatePanel()`，保证快滑直接松手和非交互识别器均能可靠展开。
  - 候选格复用改用 `CandidateGridButton.hasSelectAction` 一次性绑定选择动作与长按手势，减少展开排布时的重复闭包分配。
- **空格键默认无文字（[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)）**：
  - 空格键在常规中/英文、手写与符号层均不显示文字，仅在开启「长按空格语音输入」时显示麦克风图标，以及在拖动移光标期间临时展示状态提示。

## Alternatives considered

- **用 `UIViewPropertyAnimator` 驱动整块键盘缩放**：候选面板和键面分属不同层级且随时可能被外部状态关闭，直接由手势进度更新遮罩与透明度、抬手再用短弹簧收敛，状态机更简单且不易卡在半开状态。

## Consequences

- **收益**：候选栏下拉展开更跟手流畅，快滑与慢拉皆可自然触发；底行空格键视觉更干净。
- **代价与测试同步**：`HandwritingTests` 与 `SpaceVoicePanelTests` 中原本断言空格键文字不为空或等于「手写」的旧用例已同步更新为校验空标题与麦克风图标状态。
- **验证**：由 `pnpm run verify-notes`、`CandidateStripRowTests`、`HandwritingTests`、`SpaceVoicePanelTests` 及全套 `MSIMEKeyboardTests` 在 iOS 模拟器上覆盖验证。
