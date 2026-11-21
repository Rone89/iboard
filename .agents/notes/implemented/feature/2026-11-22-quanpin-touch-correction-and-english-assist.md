# Agent Note: 26 键全拼空间触点容错纠错与 iOS 英文输入细节优化

Status: implemented

## Problem

1. **空间触点纠错此前仅对 26 键双拼开放**：Rust 引擎（`crates/engine/src/touch/`、`shuangpin/typo_edges.rs`）和 iOS 宿主（[TouchPointPolicy.swift](../../../../platforms/ios/KeyboardExtension/Sources/input/TouchPointPolicy.swift)）已经打通键位几何注册与按键落点上报，但全拼方案（`QuanpinScheme`、`QuanpinDictionary`）和 `TouchPointPolicy.sendsTouch` 直接丢弃触点，26 键全拼用户按偏键边缘时无法利用落点位置降低邻键纠错罚分。
2. **英文模式缺少三项原生高频细节**：连续双击空格不会自动转 `". "` 并触发句首大写；英文选词/空格边界自动附带尾空格后紧跟标点会留下多余前导空格；部分高频无歧义缩写缺少兜底撇号提示。

## Decision

1. **Rust 引擎接入 26 键全拼空间触点计价**：
   - [scheme.rs](../../../../crates/engine/src/quanpin/scheme.rs) 与 [mod.rs](../../../../crates/engine/src/ime/mod.rs)：让 `QuanpinScheme` 镜像双拼维护与按键逐字节对齐的 `touches` 与 `key_geometry`（桌面无触点时为空 `Vec`，零额外分配），退格与重置同步裁剪；`ImeSession::set_key_geometry`、`set_pending_touch` 同时分发给全拼和双拼。
   - [typo_edges.rs](../../../../crates/engine/src/quanpin/typo_edges.rs) 与 [dictionary.rs](../../../../crates/engine/src/quanpin/dictionary.rs) / [engine.rs](../../../../crates/engine/src/quanpin/engine.rs)：新增 `priced_quanpin_variants` 与 `collect_priced_quanpin_typo_edges`，对单音节邻键替换按 `KeyGeometry::penalty` 计算各向异性空间罚分并补入 `<= tuning.cut` 的真实布局邻键变体，复用既有的全局按罚分排序规划；触点签名并入 `series_slot` 与 `sentence_decode_cache`，防止不同落点命中旧缓存。
   - [TouchPointPolicy.swift](../../../../platforms/ios/KeyboardExtension/Sources/input/TouchPointPolicy.swift) 与 [KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)：`sendsTouch` 新增默认参数 `quanpinLetters: Bool = false`，对 26 键全拼小写字母同样注册几何并发送落点（不含微软双拼专属的 `;`）；同步更新 `session/tests.rs` 与 `TouchPointTests.swift` 中此前「全拼不收触点」的旧断言为正向验证。
2. **iOS 英文输入细节优化（[EnglishTypingAssistPolicy.swift](../../../../platforms/ios/KeyboardExtension/Sources/input/EnglishTypingAssistPolicy.swift)）**：
   - **双击空格变句号 + 一键退格还原**：英文非 URL/Email/凭据框内，单词后 450ms 内双击空格将末尾 `" "` 转为 `". "` 并触发自动大写；紧接着点 ⌫ 一键还原回单空格 `" "`。
   - **自动尾空格后标点回贴**：仅当紧前的空格由 `commitEnglishBoundary(" ")` 自动附带时，下一键点 `,`/`.`/`!`/`?`/`;`/`:` 自动吞掉多余前导空格，手动敲的空格绝不受影响。
   - **常见无歧义英文缩写撇号兜底**：引擎未给出改写时，对 `dont`/`cant`/`wont`/`im`/`ive`/`couldnt` 等高确定性缩写提供带撇号候选（排除 `its`/`were`/`well`/`hell`/`ill`/`wed` 等实词）。

## Alternatives considered

- **仅在 Swift 侧做几何重映射，不改 Rust 引擎**：在宿主层直接改写按下的字母会破坏原始拼写展示且缺少语言模型联合打分，误改率高；把触点送入 Rust 词网格纠错边由语言模型与空间距离共同裁决更稳健，且无触点桌面路径零改动。

## Consequences

- **收益**：26 键全拼手指按偏邻键边缘时，目标词的纠错边罚分从 20 降至 ~4–8 并优先进入查词预算与候选前排；英文输入手感和容错更贴近 iOS 原生键盘。
- **验证**：由 `cargo test -p msime-engine`、`platforms/ios/build-native.sh simulator && device` 重新编出 iOS 静态库、`TouchPointTests`、`EnglishTypingAssistTests`、`EnglishSuggestionPolicyTests` 与 `pnpm run verify-notes` 覆盖验证。
