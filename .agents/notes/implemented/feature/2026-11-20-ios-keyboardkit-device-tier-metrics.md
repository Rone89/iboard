# Agent Note: iOS 键盘按 KeyboardKit 公开参数对齐四档设备键高、圆角与 26 键布局几何

Status: implemented

## Problem

fork 的键盘形态此前仅按 `.phone` / `.tablet` 两档区分高度（手机竖屏 26 键固定 `45pt`、横屏 `34pt`，iPad 竖屏 `54pt`、横屏 `73pt`），Liquid Glass 键帽圆角停在 `8.5pt`（非原生主题 iPad 为 `7pt`），且手机 26 键水平与纵向布局参数（侧边距 `6.67pt`、第三排 `⇧`/`⌫` `max(42, 1.21 × keyWidth)`、默认行距 `11pt`、底行 `123`/`return` 权重 `1.45/2.35` 总重 `10.65`）与 `KeyboardKit 11.2.4` 在 `liquidGlass: true` 下的公开标准布局存在差距。

## Decision

不引入闭源商业二进制 `KeyboardKit`（与本仓 GPL-3.0-only 许可冲突，且会增加键盘扩展包体与内存负担），改为在纯 Swift 布局层吸收其公开四档键高、圆角以及手机 26 键横向/纵向布局比例，同时保留中文 `，`、`中/英` 与四套 26 键底行样式结构、九键 `52pt` 键高与 `5%` 字母中排缩进，并保留用户通过滑块与共享文档手动调节间距的能力：

- **四档屏幕分档判定**（`KeyboardFormFactor.isLargeScreen(idiom:screenSize:)`）：
  - 手机：短边 `>= 428pt` 或长边 `>= 926pt` 为大屏（Plus / Pro Max 系列），其余为标准/中屏。
  - 平板：短边 `>= 1024pt` 或长边 `>= 1366pt` 为大屏（12.9"/13" iPad Pro），其余为普通 iPad。
  - `KeyboardViewController` 读取 `screenSizeOverride ?? view.window?.windowScene?.screen.bounds.size ?? UIScreen.main.bounds.size`，`KeyboardFormFactor` 仍保持 `.phone` / `.tablet` 两个拓扑枚举值不变。
- **键高分档对齐**（`KeyboardFormFactor.keyHeight` 与 `KeyboardHeightPercent.portraitKeyHeight`）：
  - 手机竖屏 26 键及切出的数字/符号层：标准屏 `43pt`（对应 KeyboardKit `rowHeight 53 - 10`）、大屏 `46pt`（`56 - 10`）；九键/14/18 键/笔画/手写竖屏保留 `52pt`。
  - 手机横屏：`32pt`（`40 - 8`），手写横屏保留 `40pt` 以保证书写空间。
  - iPad 竖屏：普通 `54pt`（`64 - 10`）、大屏 `61pt`（`69 - 8`）；iPad 横屏：普通 `74pt`（`86 - 12`）、大屏 `78pt`（`88 - 10`）。
- **圆角统一为 `9pt`**：`SystemKeyboardTokens.cornerRadius`、`KeyboardTheme.cornerRadius`（非自定义皮肤、启用 Liquid Glass 时，见 [原生皮肤](2026-10-09-ios-native-keyboard-skin.md)）与内置「iOS 原生」「iOS 原生（深色）」模板统一设为 `9pt`；自定义皮肤设计仍使用自身的 `design.cornerRadius`。
- **手机侧边距分档**（`KeyboardFormFactor.padding(landscape:largeScreen:)`）：
  - 仅真实手机（`idiom == .phone`）的大屏竖屏及任意手机横屏把左右边距收紧为 `3pt`；标准手机竖屏及 iPad 浮动/窄屏形态保持 `6pt`（上下仍为 `2pt`/`4pt`，iPad 全宽保持 `6 / 8 / 4`）。
- **默认行距对齐**（`KeyboardLayoutPreference.rowSpacing` 与 `effectiveRowSpacing`）：
  - `KeyboardLayoutPreference.rowSpacing` 默认值与上限由 `11pt`（`4...11`）回调为 `10pt`（`4...10`，与 `KeyboardLayoutSettingsView` 滑块及 `MetasequoiaInputSessionBridge.geometryMapping` 一致，共享文档旧默认值 `110` 经夹紧后按 `10pt` 生效）；不修改跨端共享 Rust 默认值（[preferences.rs](../../../../crates/client-core/src/preferences.rs)）。
  - 手机横屏在行距仍处于默认 `10pt` 时自动收紧为 KeyboardKit 的 `8pt`，用户通过设置滑块或拖动调整到其它值后仍按用户值生效；`KeyboardLayoutInputs` 与 `applyLayoutPreferences` 跟踪方向及大屏变化以在旋转时实时刷新间距与边距。
- **手机 26 键第三排边缘键**（`KeyboardGeometry.phoneThirdRowEdgeLayout`）：
  - `⇧` 与 `⌫` 宽度对齐为可用键区宽度的 `13%`（`(keysWidth * 0.13).rounded(.toNearestOrEven)`，上限仍受 `1.5 * pitch - keySpacing` 约束，保证 `Z..M` 严格对齐 `S..K`）。
- **手机 26 键标准底行与英文底行比例**（`TouchBottomRowLayout`）：
  - 保留中文 `，`、`中/英` 与四套 `TouchTwentySixKeyStyle` 结构（`.commaPeriod` / `.longSpace` / `.emoji` 保留原有样式权重）。
  - 标准中文/英文 26 键以总重 `10.00` 对齐 KeyboardKit 占比：竖屏 `123` = `1.23`（`12.3%`）、`return` = `2.50`（`25%`）、中文空格 `4.32` / 英文空格 `5.27`；横屏 `123` = `0.95`（`9.5%`）、`return` = `1.95`（`19.5%`）、中文空格 `5.15` / 英文空格 `6.10`（`TouchBottomRowLayout.twentySixKey` 与 `englishTwentySixKey` 增加 `landscape: Bool = false` 参数并由 `KeyboardViewController.styleTableRow` 传入 `isLandscape`）。

## Alternatives considered

- **直接将 `KeyboardKit` 作为 SPM 依赖接入并读取 `KeyboardLayoutConfiguration`**：调用最省事，可自动随上游更新数值。但 `KeyboardKit 11.2.4` 为 `Closed Source License` 闭源二进制分发，与本仓 `GPL-3.0-only` 冲突，且强绑定 SwiftUI 框架与 `LicenseKit` 依赖，在 UIKit 主导且内存敏感的键盘扩展里得不偿失，放弃。
- **连同 `crates/client-core` 跨端默认 `touch_row_spacing_tenths` 与 iPad 键距 `10~14pt` 一并改造**：彻底抹平 iOS 与 `KeyboardKit` 的每项参数。但 `touch_row_spacing_tenths` 与 `touch_key_spacing_tenths`（`3~6pt`）由多个触屏平台共享且有既定滑块边界，未经单独产品授权不应在共享 Rust 核心侧静默翻转跨端默认值；在 iOS 偏好夹紧层与 `effectiveRowSpacing` 处理可保持各端兼容且避免重编 Rust 静态库，放弃。
- **在 `KeyboardFormFactor` 枚举里直接拆出 4 个 case**：类型上更显式。但全仓库测试与布局面板多处假设拓扑只有 `.phone` / `.tablet`（例如浮动 iPad 走 `.phone` 拓扑），拆成 4 个 case 会扩大无谓的枚举分派面；保持拓扑二元、用 `largeScreen` / `landscape` 正交参数传入更局部，放弃。

## Consequences

- **收益**：标准与大屏 iPhone、普通与大屏 iPad 的竖横屏键高、手机左右边距（`6pt`/`3pt`）、默认行距（`10pt`/`8pt`）、第三排边键（`13%`）及 26 键底行占比（`12.3%/25%` 与 `9.5%/19.5%`）均与原生 `KeyboardKit Liquid Glass` 保持一致，同时保留全部中文标点/中英键/四套样式/可调间距与九键规则，不引入闭源依赖。
- **代价**：`KeyboardFormFactorTests`、`KeyLayoutStyleTests`、`NineKeyKeyboardTests`、`FourteenKeyKeyboardTests`、`OneHandModeTests` 中涉及旧常量（`6.67pt`、`11pt`、`45pt`、`34pt`、`8.5pt`、`1.45/4.90/2.35`）或假定手机边距固定不随 `screenSize`/`landscape` 变化的用例需同步更新；在无 `UIWindow` 单元测试中，默认 `UIScreen.main` 会随所跑模拟器型号变化，需通过 `screenSizeOverride` 或与控制器同源的分档条件保证断言确定性。
- **验证**：见本笔记同步后运行的 `KeyboardFormFactorTests`、`MorePanelFoldTests`、`KeyLayoutStyleTests`、`FourteenKeyKeyboardTests`、`NineKeyKeyboardTests`、`OneHandModeTests`、`KeyboardGeometrySettingsTests`、`MSIMEApp` 模拟器构建以及 `pnpm run verify-notes` 结果。
