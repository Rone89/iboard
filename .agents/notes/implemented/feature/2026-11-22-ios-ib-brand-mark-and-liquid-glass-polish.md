# Agent Note: iOS 键盘左上角 `iB` 图标统一与 Liquid Glass 候选胶囊及弹簧动效精修

Status: implemented

## Problem

1. **键盘左上角品牌图标与桌面 AppIcon 割裂**：AppIcon 已在 `cc45bf0626` 更新为液态玻璃键帽 + `iB` 字标（含亮/暗双色版本），但键盘工具栏左上角的 [KeyboardBrandMarkButton.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardBrandMarkButton.swift) 仍沿用旧版灰底绿边折线水杉标志，在原生液态玻璃键盘上显得突兀。
2. **原生皮肤候选首选块与按钮松手动画尚未完全统一**：工具栏激活态、一键粘贴、撤销删除和滑行实时预览均已采用 `0.5pt` `calloutBorder` 描边胶囊，但原生皮肤首选候选词块仍是无描边小圆角；按钮松手复原仍采用生硬的线性 60ms 过渡。

## Decision

1. **矢量重绘自适应 `iB` 液态玻璃键帽（[KeyboardBrandMarkButton.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardBrandMarkButton.swift)）**：
   - 新增 `IBoardBrandMarkRenderer`，用 CoreGraphics 绘制与 `AppIcon.png`（亮色磨砂蓝白键帽 + 深海蓝凹刻 `iB`）及 `AppIconDark.png`（暗色深灰蓝键帽 + 冰天蓝 `iB`）同源的微浮雕圆角键帽，包含顶部镜面高光、斜向玻璃折射带和柔和底影；功能菜单展开（`isActive == true`）时外沿高亮为皮肤强调色环。
   - 保持 `UIButton` 满格透明占位图与 `imageView?.transform == .identity` 契约，不破坏系统键盘命中区域与既有 `NineKeyKeyboardTests` / `MorePanelFoldTests` 断言。
2. **原生皮肤首选候选 Liquid Glass 胶囊（[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)）**：
   - 在 `updateCandidateButton` 中仅针对 `skin.isNative` 且使用键盘自带配色时的首选/转换中词块，应用 `15pt` 胶囊圆角与 `0.5pt` `skin.calloutBorder` 高光描边；非原生皮肤与桌面调色板保持原样。
3. **按钮松手阻尼弹簧回弹（[KeyboardKeyButton.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardKeyButton.swift)）**：
   - 保持按下瞬间 `duration == 0` 零延迟不变；松手复原（`scale == 1 && duration > 0`）改用临界阻尼弹簧动画（`duration >= 0.14s`、`damping = 0.86`、`initialSpringVelocity = 0.4`），继续遵守系统「减弱动态效果」开关。

## Alternatives considered

- **直接把 1024×1024 `AppIcon.png` 缩放到 24pt 放进工具栏**：`AppIcon` 含外围蓝色背景与虚化后排键，缩到 24pt 会糊成一团；用 CoreGraphics 抽出最核心的液态玻璃 `iB` 键帽矢量绘制，在 `@2x`/`@3x` 下字标和镜面边线都锐利清晰且零包体积增量。

## Consequences

- **收益**：桌面图标与键盘工具栏品牌标识、原生皮肤候选胶囊与按钮回弹动效在明暗模式下形成完整的 iBoard Liquid Glass 视觉统一。
- **验证**：由 `KeyboardKitParityEnhancementTests`、`KeyboardSkinTests`、`NineKeyKeyboardTests`、`MorePanelFoldTests` 与 `pnpm run verify-notes` 覆盖验证。
