# Agent Note: iOS 键盘对齐 KeyboardKit 按键气泡轮廓、外周边距命中与 Liquid Glass 按压配色

Status: implemented

## Problem

继[四档设备键高与 26 键布局参数](2026-11-20-ios-keyboardkit-device-tier-metrics.md)对齐 `KeyboardKit 11.2.4`（`liquidGlass: true`）后，原生键盘在手感和深色 Liquid Glass 视觉反馈上仍有四处脱节：

1. **窄行距导致屏幕边缘按键外侧出现盲区**：默认行距可下调至 `4pt`，此时 `KeyAreaStackView` 由间距算出的 `baseReach` 只有 `3pt`；大屏竖屏或手机横屏 `3pt` 边距尚可覆盖，但标准竖屏 `6pt` 左右边距或底行下方 `4pt` 边缘的触摸会落出 `baseReach` 之外，导致 `Q`/`P`/底行边键外缘漏按。
2. **松手容差沿用系统按钮约 `70pt` 默认值**：按下一个字母后手指滑出两行远再松开，仍容易误触发原先按下的键，缺少输入法级别的误滑取消距离。
3. **按键弹出气泡仍是上下分离几何且缺柔和投影与深色对比度**：`KeyPressPreviewView` 此前未采用统一的 `topRadius = 10` / `bottomRadius = 9` / `8×15` 颈部曲线，且浅暗投影与纯色背景在深色半透明 `17%` 白键帽（[原生皮肤](2026-10-09-ios-native-keyboard-skin.md)）下气泡混叠在 `#434344` 近似灰底上，不够突出。
4. **深色 Liquid Glass 按下反而变暗、主动作蓝色未对齐新规范**：`KeyboardKeyButton.setPressShade` 固定叠一层 `0.14` 黑遮罩，使深色半透明白底按键按下时几乎看不见反馈甚至发暗；`SystemKeyboardTokens.actionBackground` 仍停在旧系统蓝 `#007AFF` / `#0A84FF`。

## Decision

继续保持无闭源依赖的纯 UIKit/Swift 原生实现，从交互命中、气泡轮廓和 Liquid Glass 着色三方面补齐一致性：

- **外周边距与底缘路由扩展**（[KeyGapRouting.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyGapRouting.swift)、[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)）：
  - 原先 `keyboardRoot`（`KeyAreaStackView`）通过 `keyboardPaddingConstraints` 在 `keyboardFrameGuide` 内缩进左/右 `6pt`（大屏或横屏 `3pt`）与底边 `4pt`，落在外框内边距上的触摸根本进不了 `KeyAreaStackView.hitTest`。现为 `KeyAreaStackView` 增加 `outerHitInsets`（由 `applyKeyboardMetrics` 同步左/右/下三边内边距，顶边保持 `0` 避开候选栏），在 `point(inside:with:)` 接收该外周环带；若未路由到任何键，当落点在自身 `bounds` 外时不吞吐事件直接返回 `nil`。
  - 配合新增 `KeyGapRouting.outerEdgeReach(at:in:baseReach:edgePadding:)`（`edgePadding = max(12, maxOuterHitInset + 2)`），当触摸落在可见键包围盒之外的左/右外边距或底边距时将 `reach` 扩展至至少 `12pt`。
  - 键区包围盒内部的行距、键距、分隔键盘中缝、候选条侧边以及第一行上方区域仍严格保持 `baseReach`，避免候选栏、抬高键盘外部留白与分体中缝误触。
- **滑出按键的松手容差收紧至 `24pt`**（[KeyboardKeyButton.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardKeyButton.swift)）：
  - 在 `KeyboardKeyButton` 增加 `releaseOutsideTolerance: CGFloat = 24` 与 `acceptsRelease(at:)`；`endTouches` 在真实触摸集合包含落点且超出 `bounds.insetBy(dx: -24, dy: -24)` 时转走 `touchesCancelled` 取消输入。从 `6pt` 外周边距起手落进边缘键的点按、九键滑动（`nineKeySwipe`）、角标滑动及无触摸对象的合成事件不受影响。
- **一体化气泡轮廓与轻盈阴影**（`KeyPressPreviewView`）：
  - 参数对齐 `KeyboardKit.KeyboardCalloutStyle.standard`：`topRadius = 10`、`bottomRadius = 9`、`curveSize = CGSize(width: 8, height: 15)`、`shadowOpacity = 0.14`、`shadowRadius = 5`、`shadowOffset = CGSize(width: 0, height: 2)`。
  - `show(_:key:wide:fill:border:text:monospaced:)` 与 `path(for:)` 通过左右 S 形三次贝塞尔曲线把放大头部与底部 `9pt` 按键底座连成单一连续轮廓，同时保持 `KeyPressPreviewView.geometry(key:in:wide:)` 几何契约不变。
- **自适应按压遮罩与深色气泡 / Liquid Glass 动作蓝**：
  - `KeyboardKeyButton.pressShadeFillColor` 将键帽背景（`SkinKeySurfaceView.fillColor` 或 `configuration?.background.backgroundColor`）先与当前 `KeyboardTheme.current.background` 做 alpha 预混后计算感知亮度：亮度 `< 0.45` 时切为 `UIColor.white`（在深色 `0.17` 白叠层上按 `keyPressShade = 0.14` 叠出约 `0.286` 的提亮按压感，对齐 KeyboardKit 的 `0.30` 深色按钮反馈且保持既定 `shade.opacity` 常量测试不破），其余浅色键保持 `UIColor.black`；每次 `setPressShade` 激活时实时重算，响应运行期浅深色与换肤切换。
  - [KeyboardTheme.swift](../../../../platforms/ios/SharedUI/keyboard/KeyboardTheme.swift) 新增 `calloutBackground` 与 `calloutBorder`，保留 `opaqueKeyBackground` 深色预混结果（`#434344`）不动；原生皮肤深色下 `calloutBackground` 取 `#6B6B6B`（`rgb(107, 107, 107)`）、浅色与非原生主题沿用 `opaqueKeyBackground`，描边分别使用暗底 `white @ 0.16`、亮底 `black @ 0.12` 与非原生主题 `hairline`。
  - [GlobalTheme.swift](../../../../platforms/ios/SharedUI/core/GlobalTheme.swift) 将 `SystemKeyboardTokens.actionBackground` 从 `0x007AFF / 0x0A84FF` 更新为 Liquid Glass 规范下的 `0x0088FF / 0x0091FF`。

## Alternatives considered

- **直接放大所有边缘键按钮自身的 `hitTest` 边界或外边距**：做法更直观，但会迫使每个边缘按钮单独维护边距感知状态，且可能抢占上方候选栏衔接带或与分体键盘中缝逻辑重复；统一收口在 `KeyGapRouting.outerEdgeReach` 后只需键包围盒即可一次性覆盖左/右/下三侧盲区。
- **直接修改 `KeyboardTheme.opaqueKeyBackground` 的深色返回值或为按键加 `UIVisualEffectView` 实现按压玻璃态**：`opaqueKeyBackground` 在已有静态颜色契约测试中被锚定为预混值 `#434344`；而每个按键挂独立 `UIVisualEffectView` 会带来键盘扩展内存与合成开销（见[原生皮肤](2026-10-09-ios-native-keyboard-skin.md)）。拆出 `calloutBackground` 并复用现有 `CAShapeLayer` 仅按亮度切黑/白，风险最小且性能开销为零。
- **把 `releaseOutsideTolerance` 再缩小到 `8~12pt`**：更能防误滑，但手指在竖高仅 `43pt` 的矮键上轻微上仰或斜点极易丢键；`24pt` 约为半个标准键高加上少量宽容量，刚好放过原地微抖而拦截跨行误滑。

## Consequences

- **收益**：窄行距下的外周边界盲区消失、跨行远滑取消更干净；深色原生键盘的按键按压与气泡对比度显著提升；弹出气泡轮廓与主动作蓝在浅/深色下同 `KeyboardKit 11.2.4` 保持视觉一致。
- **代价**：`KeyGapRouting.outerEdgeReach` 默认按 `12pt` 外扩，若未来在键盘最左/右/最底边缘新增非键盘交互控件且直接挂在 `KeyAreaStackView` 下，需记得加入 `gapRoutingExclusions`；`KeyboardSkinTests` 需同步更新 `actionBackground` 期望十六进制颜色与新增的 `calloutBackground` 断言。
- **验证**：由 `pnpm run verify-notes`、`MSIMEApp` 模拟器构建，以及 `KeyGapRoutingTests`、`NineKeyKeyboardTests`、`KeyboardFormFactorTests`、`KeyLayoutStyleTests` 和 `KeyboardSkinTests/testNativeSkinDefinesTokenValuesAndLogoContrast` 覆盖验证。
