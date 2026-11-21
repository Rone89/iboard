# Agent Note: iOS 滑行输入二维起滑、异步多读音解码与拐角平滑

Status: implemented

## Problem

在完成 `GlideBeamEngine` 与 `SwipeTrailGeometry` 移植后，真机滑行手感仍存在四处明显短板：

1. **纯横向起滑门槛（`abs(dx) >= 0.4 * width`）导致上下排直滑失灵**：`e→d`、`r→f`、`u→j`、`i→k` 等竖向或小斜角跨排滑行常停在 `.possible`，抬手后误触发单击。
2. **主线程同步解码风险**：`GlideBeamEngine.isReady` 与 `decodeReading` 通过 `queue.sync` 阻塞主线程，若后台词典加载尚未结束，首笔滑行会卡住主线程。
3. **GlideBeam `limit = 1` 单读音瓶颈**：仅取第 0 名读音逐字母喂入水杉会话，遇到 `xian`/`xiang`、`shi`/`si` 等相似读音首位误判时无法回退到备选读音。
4. **折线尖角与起滑触感缺失**：急转弯折线棱角较硬，从点按切入滑行瞬间缺少触感提示。

## Decision

- **二维距离起滑与角标手势共存（[GlideTyping.swift](../../../../platforms/ios/KeyboardExtension/Sources/input/GlideTyping.swift)、[GlideTypingGesture.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/GlideTypingGesture.swift)）**：`startsGlide` 默认改为二维欧氏距离 `hypot(dx, dy) >= width * 0.4`；当按下键带有 `cornerHint` 且开启了同向纵滑输入符号时，`allowsVerticalGlide` 对该方向收紧为横向 `0.4 * width` 或跨行 `0.85 * height`，反向与无角标方向直接放行二维起滑。
- **无锁就绪检测与异步多读音解码（[GlideBeamEngine.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/GlideBeamEngine.swift)、[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)）**：`isReady` 改用独立 `NSLock` 读取 `loadedReady`，避免主线程在后台加载期间等待串行队列；新增 `decodeReadingsAsync(limit: 5)` 在后台队列解出至多 5 条去重读音，带 `glideDecodeGeneration` 代次防串台，主线程按序喂入水杉会话并在无有效候选时自动尝试下一条读音，全部失败或引擎未就绪时回退 `session.glide`。
- **拐角平滑与起滑触感（[SwipeTrailGeometry.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/SwipeTrailGeometry.swift)）**：保留 `SwipeTrailGeometry.path()` 1:1 直线构造契约不变，新增 `SwipeTrailGeometry.smoothed(_:)`（Chaikin 切角，首尾端点不动）供 `GlideTrailView.draw` 渲染使用；在 `glideGesture.onBegan` 触发一次轻强度触感反馈。

## Alternatives considered

- **直接修改 `SwipeTrailGeometry.path()` 用 `addQuadCurve` 绘制**：会破坏既有的 1:1 几何单测与端点法线契约，在绘制前对输入点集做纯函数平滑更安全且可独立测试。

## Consequences

- **收益**：上下排字母直滑顺畅起滑、首笔不卡主线程、GlideBeam 多读音容错显著提升、急转弯轨迹更顺滑。
- **验证**：由 `pnpm run verify-notes`、`GlideTypingTests`、`SwipeTrailGeometryTests`、`GlideEngineTests` 与真机 `RCe2027` 装机实测覆盖验证。
