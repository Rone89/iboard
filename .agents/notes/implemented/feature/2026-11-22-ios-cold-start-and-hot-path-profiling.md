# Agent Note: iOS 键盘冷启动首帧、剪贴板 XPC 短路与热路径键位几何缓存优化

Status: implemented

## Problem

在完成 26 键全拼空间触点、CoreHaptics 分键震动与一键粘贴胶囊等新能力后，剖析 `viewDidLoad` / `viewWillAppear` / 逐键热路径发现四处真实开销：

1. **冷启动与明暗切换双重全树换装**：`traitCollectionDidChange` 与 iOS 17+ `registerForTraitChanges` -> `refreshTraits(_:)` 并存，出现或切换深浅色时会触发两遍 `KeyboardTheme.reload(..., force: true)` + `applyKeyboardSkin` + `updateKeyboardLayout`。
2. **首次按键 CoreHaptics 同步冷启动毛刺**：`CHHapticEngine.start()` 与首个 `CHHapticPatternPlayer` 编译发生在第一下按键 `touchDown` 主线程上，真机首次按键延迟偏高。
3. **`viewWillAppear` 同步剪贴板 XPC 查询**：即使 `changeCount == 0` 或同一条剪贴板已处理，每次拉起键盘都会调用 `UIPasteboard.general.hasStrings` / `hasImages` 触发跨进程 `pasted` 查询。
4. **逐键重复量测 26 枚字母键布局矩形**：26 键双拼与全拼每次敲字母都会通过 `currentKeyLayout` 遍历 26 个视图做坐标变换并分配临时数组。

## Decision

1. **合并明暗变更路径（[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)）**：移除重复的 `traitCollectionDidChange` 覆写，由 `registerForTraitChanges` -> `refreshTraits(_:)` 统一单次完成 `KeyboardTheme.reload(..., force: true)`、`applyKeyboardSkin(onlyIfChanged: false)` 与 `view.setNeedsDisplay()`。
2. **首帧后异步预热 CoreHaptics（[KeyboardHapticsEngine.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardHapticsEngine.swift)）**：新增 `warmUp(strength:)`，在 `viewDidAppear` 之后排到下一轮主线程运行循环预启动引擎并预编译高频播放器（`.key(.standard)`、`.key(.space)`、`.key(.backspace)`、`.cursorTick`），不拖慢首帧且消除首键冷启延迟。
3. **剪贴板 `changeCount` 轻量前置短路（[QuickPasteToolbar.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/QuickPasteToolbar.swift)）**：新增 `QuickPasteToolbarPolicy.isUnhandled(changeCount:)`，仅在检测到未处理的新 `changeCount` 且尚未命中本地预览缓存时才访问 `hasStrings`/`hasImages`。
4. **键位几何布局缓存（[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)）**：以 `(root.bounds.size, oneHandedMode, keyboardPlacement, inputScheme, semicolonHidden, firstLetterFrame)` 为键缓存 `TouchPointPolicy.Layout`，布局不变时热路径 `O(1)` 复用，旋转/单手/方案切换/微软 `;` 显隐变化立即失效重算。

## Alternatives considered

- **把 `CHHapticEngine` 启动提前到 `viewDidLoad`**：会直接增加冷启动首帧出图时间，且用户尚未看到键盘；延后到 `viewDidAppear` 下一帧运行循环兼顾首帧速度和首键跟手性。

## Consequences

- **收益**：首帧减少双重全树换装与无谓剪贴板 XPC；首键 CoreHaptics 预编译命中缓存；26 键全拼/双拼逐键键位几何读取从全量 26 键遍历降至单键校验 + 缓存命中。
- **验证**：由 `KeystrokeLatencyTests`、`TouchPointTests`、`KeyboardMemoryTests`、`KeyboardKitParityEnhancementTests`、`KeyboardSkinTests`、`pnpm run verify-notes` 及真机 `RCe2027` Release 构建安装覆盖验证。
