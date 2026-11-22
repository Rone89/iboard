# Agent Note: iOS 键盘左上角 `timelapse` 图标与 Liquid Glass 候选胶囊及弹簧动效精修

Status: implemented

## Problem

1. **键盘左上角功能图标视觉风格需要与原生工具栏统一**：[KeyboardBrandMarkButton.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardBrandMarkButton.swift) 此前曾先后使用旧版水杉折线和自绘 `iB` 键帽，在 24pt 尺寸下与旁边线性 SF Symbols / 单色工具栏图标存在视觉风格割裂，用户明确要求改为系统 SF Symbol `timelapse`。
2. **原生皮肤候选首选块与按钮松手动画尚未完全统一**：工具栏激活态、一键粘贴、撤销删除和滑行实时预览均已采用 `0.5pt` `calloutBorder` 描边胶囊，但原生皮肤首选候选词块仍是无描边小圆角；按钮松手复原仍采用生硬的线性 60ms 过渡。

## Decision

1. **工具栏左上角图标切换为 SF Symbol `timelapse`（[KeyboardBrandMarkButton.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardBrandMarkButton.swift)）**：
   - 使用 `UIImage(systemName: "timelapse")`（`.medium` 字重），常态取 `skin.secondary`、展开功能菜单激活态取 `skin.accent` 并叠加与 `KeyboardToolbarButton` 同构的 `toolbarActiveBackground` + `0.5pt` `calloutBorder` Liquid Glass 胶囊底托，在亮/暗模式与各皮肤下自然融入工具栏。
   - 保持 `UIButton` 满格透明占位图与 `imageView?.transform == .identity` 契约，不破坏系统键盘命中区域与既有 `NineKeyKeyboardTests` / `MorePanelFoldTests` 断言。
2. **原生皮肤首选候选 Liquid Glass 胶囊（[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)）**：
   - 在 `updateCandidateButton` 中仅针对 `skin.isNative` 且使用键盘自带配色时的首选/转换中词块，应用 `15pt` 胶囊圆角与 `0.5pt` `skin.calloutBorder` 高光描边；非原生皮肤与桌面调色板保持原样。
3. **按钮松手阻尼弹簧回弹（[KeyboardKeyButton.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardKeyButton.swift)）**：
   - 保持按下瞬间 `duration == 0` 零延迟不变；松手复原（`scale == 1 && duration > 0`）改用临界阻尼弹簧动画（`duration >= 0.14s`、`damping = 0.86`、`initialSpringVelocity = 0.4`），继续遵守系统「减弱动态效果」开关。

## Alternatives considered

- **继续在工具栏保留微型 `iB` 键帽图形**：24pt 尺寸下微型键帽与其余工具栏线性图标风格不够统一，按用户要求改用系统 `timelapse` 符号更利落耐看。

## Consequences

- **收益**：工具栏左上角图标、原生皮肤候选胶囊与按钮回弹动效在明暗模式下与系统 Liquid Glass 视觉语言一致。
- **验证**：由 `KeyboardKitParityEnhancementTests`、`NineKeyKeyboardTests` 工具栏点击区用例、`pnpm run verify-notes` 及真机 `RCe2027` 构建安装覆盖验证。
