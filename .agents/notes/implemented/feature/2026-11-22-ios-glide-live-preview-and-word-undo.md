# Agent Note: iOS 滑行实时候选预览与滑后退格一键撤整词

Status: implemented

## Problem

滑行输入在接入二维起滑与异步多读音解码之后，仍有两处交互断层：

1. **手指滑动期间顶栏完全静止**：必须等到抬手才能看到解码出的读音与候选词，滑长词时无法边滑边确认是否滑偏。
2. **滑错词后退格成本高**：未上屏的滑行组字（如 5 字母 `nihao`）或刚通过空格/候选上屏的滑行多字词，误滑后轻点 ⌫ 仍只删 1 个字母/1 个字，必须连按多次才能重滑。

## Decision

1. **新增独立模块 [GlideLivePreviewAndUndo.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/GlideLivePreviewAndUndo.swift) 与只读原子桥接预览**：
   - **节流门控（`GlideLivePreviewPolicy`）**：在 `glideGesture.onMoved` 中限制最小间隔 `85ms`、最少 `4` 采样、总弧长 `>= 24pt`、距上次预览位移 `>= 14pt`（尾键停顿 `>= 180ms` 允许补刷新一次）且同一时刻至多 1 个在途预览，确保 120Hz 轨迹渲染不掉帧。
   - **零残态原子查询（[MetasequoiaInputSessionBridge.swift](../../../../platforms/ios/SharedUI/core/MetasequoiaInputSessionBridge.swift)）**：新增 `previewGlideAsync` 与 `previewCharactersAsync`，在 `MSIMEInputThread` 单一异步闭包内原子执行「试解码 -> 读前 4 候选与读音 -> 立刻 `cancel`」，不触碰宿主输入框、不残留临时组字，且仅在起滑前会话无正式组字时启用；连续多词滑行（已有未提交组字）时退化为无状态 `GlideBeamEngine` 读音预览或键序预览，绝不打断原组字。
   - **零抖动顶栏覆盖预览条（`GlideLivePreviewBar`）**：覆盖在 `compositionContainer` 顶栏内，采用 Liquid Glass 首选胶囊 + 次选列表，不改变键盘高度；抬手或取消时随代次递增即时丢弃过期回调并隐藏。
2. **滑后退格一键撤整词（`GlideUndoTracker`）**：
   - **未上屏阶段**：滑行解出组字后，在用户未敲单字母或移动拼音光标之前，轻点一次 ⌫ 直接清空整段滑行组字并播放 `.swipeDelete` 震动。
   - **刚上屏阶段**：滑行组字整词上屏（长度 `>= 2`）后，若紧接着的下一个动作是轻点 ⌫，在校验文档身份和光标前后缀一致后一次退掉整个词，并同步放入工具栏「撤销删除」胶囊防止误撤。任何新输入、光标移动、外部改动或键盘收起立即清掉跟踪态。

## Alternatives considered

- **直接在 `onMoved` 中调用 `session.glide` 并渲染进正式候选栏与行内预编辑**：每 85ms 往宿主 App 发送 `setMarkedText` 会制造大量跨进程 IPC 闪烁，且连续多词滑行时无法安全回滚旧组字，因此改为独立只读覆盖条与原子试算。
- **把实时预览做成新设置开关默认关闭**：实时预览仅在已开启滑行输入的手指拖动瞬间显示，不影响非滑行用户，也不改变抬手后的最终上屏行为，无需新增配置负担。

## Consequences

- **收益**：滑行过程边滑边看候选词，滑偏可在抬手前及时修正，滑错后无论上屏与否都能一键 ⌫ 撤回整词且可再撤销。
- **验证**：由 [GlideLivePreviewAndUndoTests.swift](../../../../platforms/ios/KeyboardTests/input/GlideLivePreviewAndUndoTests.swift)、[GlideTypingTests.swift](../../../../platforms/ios/KeyboardTests/input/GlideTypingTests.swift)、[GlideEngineTests.swift](../../../../platforms/ios/KeyboardTests/input/GlideEngineTests.swift)、[BackspaceSyllableTests.swift](../../../../platforms/ios/KeyboardTests/input/BackspaceSyllableTests.swift) 与 `pnpm run verify-notes` 覆盖验证。
