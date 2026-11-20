# Agent Note: 触屏拼音组字的按音节回删开关

Status: implemented

## Problem

滑行输入一笔解出多音节读音（一笔滑出 `meiyou`），想改最后一个字时单次 ⌫ 一次只删一个字母，要按四次才回到 `mei`；长按 ⌫ 连删倒是按音节缩，但轻点永远逐字母退，滑行打完的长读音改起来很费劲。[GlideBeam 的上游 GlideKeyboard](../../../../../../Desktop/GlideKeyboard) 对滑行产生的读音就是按音节回删的（`nihao` 一次退格丢 `hao`），本仓没有对应能力。

## Decision

共享偏好新增 `touch_backspace_by_syllable`（`crates/client-core/src/preferences.rs` 的 `Preferences`），默认关：关着单次 ⌫ 照旧一次删一个字母，老用户手感不变。打开后 iOS 的全拼 26 键与双拼 26 键在组字中的单次 ⌫ 走既有的 `SegmentCommand::Backspace`（command 12）按音节缩：`meiyou` 退一格变 `mei`，删掉整个 `you` 而不是字母 `y`。滑行与逐键打的字母同粒度——iBoard 的组字真源在 Rust 会话里且不记字母来源，开关打开的人要的是按音节删，不再分来源。九键、14/18 键和五笔等没有字母音节的方案不受影响，与长按 ⌫ 的适用范围（`ChineseInputScheme.editsBySyllable` 且非 `typesLetterGrid`）完全一致。

按音节删除的机制早已存在：长按 ⌫ 的 `repeatBackspace` 一直在调 `session.segmentBackspace()`，引擎侧按 `segment_raw_boundaries` 找边界循环退格并处理悬挂 `'` 分隔符。这次只把单次 ⌫ 在开关打开时路由到同一条命令：`KeyboardViewController.handleBackspace` 里 `TouchBackspaceSyllablePreference.isEnabled && editsCompositionBySyllable` 时调 `segmentBackspace`，快照未处理（组字删空或无可删）照旧回落 `deleteOwnBackward` 删正文；长按路径的语义不变，只是条件抽成两处共用的谓词 `editsCompositionBySyllable`。

持久层沿用触屏偏好的文档优先模式：共享文档键 `touch_backspace_by_syllable` 是权威来源（serde 默认关、缺键按关），App Group `backspaceBySyllable` 是键盘每次按键读的镜像（`platforms/ios/SharedUI/preferences/TouchBackspaceSyllablePreference.swift`，照 `TouchShuangpinLayoutPreference` 的读法与「先写文档成功才写镜像」）；「重置所有设置」时镜像键随文档恢复一起清掉。设置行放在「键盘 › 键盘」的手势组，紧挨滑行输入那一组开关。

## Alternatives considered

**照搬 GlideKeyboard 的来源区分（只有滑行尾段按音节删，逐键字母照旧删一个）。** 它最强的理由是逐键打字的手感完全不变：打字的人删字母是肌肉记忆，整音节退格对他们是一次行为突变。没采用是因为 iBoard 与它的组字架构不同：GlideKeyboard 的组字是 Swift 本地的 `PinyinComposition`，每个读音片段自带 `origin`（typed/glide）；iBoard 的组字真源在 Rust 会话且 `raw` 不记来源，照搬要么给引擎加一张与 `raw` 平行的来源表——`character`、`glide`、backspace、`edit_at_caret`、顶字上屏每一条改组字的路径都要维护它，要么在 Swift 侧近似跟踪「尾段来自滑行」的标志——组字被引擎自行改动（顶字、候选选择）时容易跟丢，跟丢的后果是把错的粒度删给用户。另外两种粒度交替出现（滑行尾删音节、紧接着打的字母删字母）本身是用户猜不到的隐藏行为，开关默认关、打开的人明确要按音节删，两种来源同粒度更可预期。

**在 Rust 侧实现（runtime 按偏好把单次 `Command::Backspace` 升格为按音节删除）。** 它最强的理由是业务规则进共享 Rust：Android、HarmonyOS 自动受益，宿主零改动。没采用是因为 runtime 不读 `Preferences`（宿主读），要新穿一条偏好进引擎的管道，为一个宿主行为先动会话层不划算；而 iOS 侧长按 ⌫ 本来就在 Swift 里选择 `segmentBackspace`，单次 ⌫ 在 Swift 路由与现有架构一致。共享键已经放进 `Preferences`，其他触屏端之后把同一条件接进各自的退格路径即可，不需要迁移。

## Consequences

- 收益：单次与长按的组字删除语义统一成同一粒度，实现只增加一处路由和一层偏好；文档键让 Android、鸿蒙以后可以无迁移接入。
- 代价：开关打开后逐键打字的组字回删也变整音节，这是用户自选的行为；`repeatBackspace` 的条件抽成了谓词，长按路径行为不变但代码位置变了，改动那段时两处要一起看。
- 桌面宿主（macOS、Windows、Linux）不消费这个键，文档里原样保留；触摸端接入前它只是随文档同步的休眠设置。

## Testing

- Rust：`preferences::tests::touch_backspace_by_syllable_defaults_off_and_round_trips_through_the_store` 钉默认关、缺键的旧文档不改写、显式开经 PreferencesStore 往返。
- iOS 行为：`KeyboardTests/input/BackspaceSyllableTests.swift` 用控制器驱动——开关开时组字 `meiyou` 单次 ⌫ 到 `mei`（断言行内预编辑的标记文本），关时到 `meiyo`，无组字时照旧删正文；桥级按音节缩由 `CompositionCaretTests` 既有用例覆盖。
- iOS 设置：`KeyboardTests/settings/BackspaceSyllableSettingsTests.swift` 钉「先写文档成功才写镜像」、镜像与宽松读取的口径。
