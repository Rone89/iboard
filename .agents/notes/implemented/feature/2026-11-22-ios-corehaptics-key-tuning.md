# Agent Note: iOS 键盘接入 CoreHaptics 分键型细腻震动调教

Status: implemented

## Problem

此前 iOS 键盘所有按键统一通过 `UIImpactFeedbackGenerator` 触发震动：字母键、空格、回车、退格与起滑的手感完全一致，只能粗略区分 `.light`/`.medium`/`.heavy` 与单一力度，缺乏类似机械键盘或原生细腻 Taptic Engine 的清脆度（`sharpness`）区分与段落层次感。

## Decision

- **新增独立引擎文件（[KeyboardHapticsEngine.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardHapticsEngine.swift)）**：
  - 保留既有 `KeyboardHapticStrength` 四档枚举（「跟随系统 / 轻 / 中 / 强」）及云同步契约不变：「跟随系统」仍走原生 `UIImpactFeedbackGenerator`；「轻 / 中 / 强」改由 `CHHapticEngine` 按键型（`standard`、`space`、`enter`、`backspace`、`glideStart`）分别调节 `intensity` 与 `sharpness`。
  - 「强」档普通字母键使用 `0ms` 高锐度主脉冲 + `12ms` 低沉触底回弹双脉冲模拟机械段落轴；空格与回车采用更高强度、更低锐度呈现厚实触底；退格与起滑采用短促高锐度轻触。
  - 预编译并缓存 `CHHapticPatternPlayer`（按键热路径零重建），加入 `12ms` 防抖冷却门控；设置 `playsHapticsOnly = true` 与 `isAutoShutdownEnabled = true` 避免打断背景音乐并省电；键盘收起与内存告警时调用 `stop()` 释放。
  - 硬件不支持 `CoreHaptics`（如模拟器）或引擎启动异常时返回 `false`，由 `KeyboardViewController` 无缝回退到 `UIImpactFeedbackGenerator`。

## Alternatives considered

- **新增独立的震动风格偏好键与设置项**：会增加跨端偏好和设置页复杂度；直接映射到现有「轻 / 中 / 强」三档并保留「跟随系统」为原生冲击反馈，老用户升级后零配置即可获得更细腻的分键手感。

## Consequences

- **收益**：真机上字母键清脆利落、空格/回车沉稳厚实、强档带清晰段落感，且不影响背景音频播放与按键主线程帧率。
- **代价**：需在键盘收起和内存告警时管理 `CHHapticEngine` 生命周期，首次按键会有一次轻量的引擎启动与播放器编译（随后全部命中缓存）。
- **验证**：由 `pnpm run verify-notes`、`KeyboardKitParityEnhancementTests.testCoreHapticsEngineProfilesAndCooldown`、`KeyPressFeedbackTests` 及真机 `RCe2027` 装机实测覆盖验证。
