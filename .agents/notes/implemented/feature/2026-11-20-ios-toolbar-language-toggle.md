# Agent Note: iOS 工具栏新增中英文切换按钮

Status: implemented

## Problem

部分用户在单手或紧凑布局下习惯从顶栏工具栏直接切换中/英文，而不是点按底行左下角的方案语言键。此前 `TouchToolbarPreference` 仅包含共享 `touch_toolbar` 的开关（`layout`、`emoji`、`skin`、`clipboard`、`ai`、`character_set`、`fullwidth`、`punctuation`、`undo`、`redo`），`TouchToolbarLocalPreference` 也只管理了 `phrases`、`scheme` 与 `hidden`。

## Decision

- **存储位置放在 `TouchToolbarLocalPreference`（[TouchToolbarPreference.swift](../../../../platforms/ios/SharedUI/preferences/TouchToolbarPreference.swift)）**：共享文档 `touch_toolbar` 校验器会丢弃未识别字段，因此本按钮归入 `TouchToolbarLocalPreference.language`（键名 `keyboard.toolbar.language`，并加入 `TouchToolbarLocalPreference.keys`），默认关闭以保证 `320pt` 窄屏默认工具栏不溢出（`NineKeyKeyboardTests.testToolbarIsTheDesignsEqualGridOfTools`），用户可在「键盘工具栏」设置页或长按任意工具栏按钮打开开关。
- **预览与设置页同步（[KeyboardToolbarSettingsView.swift](../../../../platforms/ios/App/Sources/keyboard/KeyboardToolbarSettingsView.swift)）**：`KeyboardPreviewToolbarItem` 新增 `.language`（字符 `"中"`），`KeyboardToolbarPreviewRow.items` 增加 `language: Bool = false` 参数并在末尾追加；设置页「按钮」分组追加「中英文切换」开关。
- **键盘扩展工具栏接入（[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)、[KeyboardToolbarButton.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardToolbarButton.swift)）**：新增 `languageShortcut`（无障碍标识 `languageShortcut`）并加入 `optionalShortcuts`，点击调用 `countKeyPress(TypingKeyID.language)` 与 `toggleInputMode()`；通过 `KeyboardToolbarButton.badgeImage(text:)` 绘制与其他 26pt 工具栏描边图标同线宽、同圆角和 `skin.secondary` 着色的方框文字图标，随 `isChineseMode` 在当前方案字样（如 `中`/`粤`/`注`/`日`/`한`）与 `A` 之间实时同步。

## Alternatives considered

- **把开关放进共享 `touch_toolbar` 并默认开启**：会修改跨六端共享的 Rust 偏好契约，且在 `320pt` 宽度下默认工具栏 7 个等宽按钮（`7 * 40 + 6 * 8 = 328pt`）会超出容器宽度。

## Consequences

- **收益**：用户可在工具栏一栏完成中英文快速切换，且不破坏现有默认工具栏布局及跨端共享配置校验。
- **验证**：由 `pnpm run verify-notes`、`TouchToolbarPreferenceTests`、`KeyLayoutStyleTests`、`NineKeyKeyboardTests` 与 `KeyboardKitParityEnhancementTests.testToolbarLanguageShortcutTogglesChineseAndEnglish` 覆盖验证。
