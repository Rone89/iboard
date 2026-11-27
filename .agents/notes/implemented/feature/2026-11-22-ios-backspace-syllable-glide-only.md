# Agent Note: iOS 按音节回删新增「仅滑行输入生效」子开关

Status: implemented

## Problem

在[触屏拼音组字的按音节回删开关](2026-11-20-backspace-by-syllable.md)落地后，打开「按音节回删」会让滑行和逐键点按共享同一回删粒度；但不少同时使用点按和滑行的用户希望**逐键点按仍保持单字母删除肌肉记忆，只有滑行输入的拼音内容才按音节回删**。同时，此前 `handleBackspace()` 中 `glideUndoTracker.consumeActiveGlideComposition()` 在所有情况下都抢先整段清空滑行组字，开启「按音节回删」后反而无法对滑行产出的多音节词（如 `meiyou`）逐音节退成 `mei`。

## Decision

1. **新增本机子开关（[TouchBackspaceSyllablePreference.swift](../../../../platforms/ios/SharedUI/preferences/TouchBackspaceSyllablePreference.swift)、[KeyboardLayoutSettingsView.swift](../../../../platforms/ios/App/Sources/keyboard/KeyboardLayoutSettingsView.swift)）**：
   - 在 `TouchBackspaceSyllablePreference` 中新增 App Group 键 `backspaceBySyllableGlideOnly`（`glideOnly`，默认 `false`，保持既有行为不变），并加入 `DeveloperOptionsView.resetLocalPreferences()` 重置清单。
   - 在「键盘 › 手势」分组的「按音节回删」下方新增子开关「仅滑行输入生效」（`appBackspaceBySyllableGlideOnlySwitch`），说明收进「?」，主开关关闭时置灰不可点。
2. **Swift 侧前缀/后缀对齐来源追踪（[GlideLivePreviewAndUndo.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/GlideLivePreviewAndUndo.swift)）**：
   - 新增纯值类型 `GlideCompositionOriginTracker`，在 `KeyboardViewController.render(_:compositionOrigin:)` 中按引擎最新 `editingText` 的公共前缀与公共后缀同步每个字母的来源（`.glide` / `.typed`）：滑行路径（`fallbackGlideToSession` 与 `submitGlideReadings`）传入 `.glide`，其余新增默认 `.typed`，退格与部分选词保留剩余字母的原来源；结合 `visibleCaretSpelling` 的 `|` 光标位置判断光标前待删字母是否来自滑行。
3. **与滑行一键清空整段的优先级协调（[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)）**：
   - `handleBackspace()` 先通过 `GlideCompositionOriginTracker.shouldUseSyllableBackspace(...)` 计算 `usesSyllableBackspace`。
   - 当 `usesSyllableBackspace` 为真时，跳过 `glideUndoTracker.consumeActiveGlideComposition()` 的整段清空并清掉该标记，交由 `session.segmentBackspace()` 逐音节回删；主开关关闭时保持既有滑后一键清整段与上屏整词撤回不变。

## Alternatives considered

- **在 Rust 引擎会话层为 `raw` 维护平行来源表**：改动横跨 `crates/engine`、`crates/input-runtime`、`crates/host-api` 和共享偏好文档，且仅 iOS 端需要该子选项；在 Swift 侧按每次快照的 `editingText` 前后缀对齐追踪，零引擎侵入、可覆盖混打与部分选词，且有独立纯值单测兜底。

## Consequences

- **收益**：兼顾点按逐字母修改与滑行按音节回删两类手感，同时修正了开启「按音节回删」时滑行多音节组字被一键整段清空的冲突。
- **代价**：子开关目前存在 iOS App Group 本机，不跨端同步；极端情况下若引擎在组字中段自动重写整串字母，未匹配前后缀的新字母会保守归类为 `.typed`。
- **验证**：由 `pnpm run verify-notes`、`BackspaceSyllableTests`、`BackspaceSyllableSettingsTests`、`GlideLivePreviewAndUndoTests` 在 iOS 模拟器上覆盖验证。
