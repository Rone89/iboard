# Agent Note: 拼音九键支持滑行输入

Status: implemented

## Problem

滑行输入（`msime_client_glide`）此前仅支持全拼 26 键，切换到拼音九键（标准九键与「iOS 原生」十键）后无法滑行。九键只有 2–9 八枚字母键，且中文拼音在九键下存在大量音节边界同键连字（如 `ni'hao = 64|426`、`wo'men = 96|636`）与音节内连续重复数字（如 `shi = 744`、`zhong = 94664`），直接复用 26 键按字母去重的解码器无法正确还原重复数字，且在九键上滑手势开启时会与 `7→4`、`9→6` 等纵向滑行冲突。

## Decision

1. **零 FFI 改动复用 26 槽 `GlideKeyboard` 协议**：
   - iOS 侧在 [GlideTyping.swift](../../../../platforms/ios/KeyboardExtension/Sources/input/GlideTyping.swift) 新增 `nineKeyFrames(from:)` 与 `nineKeyRepresentativeIndex(forDigit:)`，将九键 2–9 八枚键的矩形按 T9 字母归属展开到 26 槽 `a..z` 坐标中；C ABI、JSON 协议和 `msime-host-api` 保持原样不变。
2. **Rust 独立九键拼音音节轨迹解码器（[glide.rs](../../../../crates/engine/src/nine_key/glide.rs)、[session/mod.rs](../../../../crates/engine/src/session/mod.rs)）**：
   - 遵循不往巨型 `nine_key.rs` 堆代码的原则，新建 `crates/engine/src/nine_key/glide.rs`。
   - 从 `intact_pinyin_list()` 与 `SYLLABLE_FREQUENCY` 预构建 ~240 组唯一九键数字音节表（每组保留前 6 个高频读音，覆盖 `926`/`7426` 等高密度键位），在 2–9 八键轨迹上做**按采样进度分桶剪枝**的音节束搜索（避免短音节挤掉 `shen`/`shang`/`zhong` 等长音节，起止键收紧到 `0.85` 键距并自动回退）：允许音节边界同键零位移续接（自动还原 `6426 → 64426`、`9636 → 96636`）与音节内重复数字（自动还原 `74 → 744`、`946486 → 94664486`），仅对可达键对预计算连线表提速，并采用原始轨迹空间停留/减速投影与 `±3` 拐点 NMS。
   - 词典打分支持整词命中加权、非整词组合短语（如 `wo'qu`「我去」）的二元/单音节分段 DP，以及个人二元上文语境加权（26 键与 9 键在 `set_rescoring_context` / 滑行前均立即将上屏语境同步给全拼词典，超长笔画连线代价按实际步长归一化）；空态起滑存在相近同路径次优数字串时（如 `64426` 你好 vs `6426` 年/面、`24` 比/次 vs `224` 才/白 与 `244` 吃、`744` 是 vs `74` 起/四），保留每个次优数字串的多条高频读音并批量并入候选前排，点选一次消费整段滑行数字且不污染主数字串词频。
   - **同路径重键拼音注入「选拼音」栏与起手回环检测**：`NineKeySession` 随本笔滑行记录同路径次优首音节及其目标数字串（`glide_alt_spellings`，如 `2→4` 补全 `cai`/`bai` -> `224`、`chi` -> `244`；`2→6` 补全 `ban`/`bao`/`can`/`cao` -> `226`；`7→4` 补全 `qi`/`si`/`pi`/`ri` -> `74`），在「选拼音」栏与首字母筛选中直接露出，点选即可无损替换数字串并展示该拼音全部候选字，`LockUndo.replacement_len` 保证换选和退格完全可逆；同时识别起手键上的主动回环/折返手势（`detect_start_key_repeat`），刻意在 `2` 上回环再滑向 `4` 可直接首选 `224`（`cai`）。
   - 同步优化 26 键双语滑行与 GlideBeam：[lexicon.rs](../../../../crates/engine/src/pinyin/glide/lexicon.rs) 暴露 `GlideMatcher::decode_quanpin` 复用已建 `Decoder` 消除重复重采样与连线表计算，[session/glide.rs](../../../../crates/engine/src/session/glide.rs) 次选读音同音字配额由 3 扩至 8，[GlideBeamEngine.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/GlideBeamEngine.swift) 提升队列 QoS 为 `.userInitiated`、120Hz 长轨迹抽稀至 256 点并以零中间分配解码 UTF-8 候选。
   - `Session::glide_with_readings` 与 `Session::bilingual_glide_with_readings` 在 `self.key_grid == Some(KeyGrid::NineKey)` 且通过 `is_nine_key_geometry` 校验时自动路由到 `self.nine_key.glide`，完整复用九键候选池、选拼音栏、个人调频与神经重排。
3. **iOS 手势、实时预览与冲突处理（[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)、[GlideTyping.swift](../../../../platforms/ios/KeyboardExtension/Sources/input/GlideTyping.swift)、[GlideLivePreviewAndUndo.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/GlideLivePreviewAndUndo.swift)）**：
   - 扩展 `glideTypingArmed` 与 `glideLivePreviewCanQuerySession` 同时覆盖全拼 26 键与拼音九键（标准九键与 `IOSNativeNineKeyView`）；九键拖动和抬手均绕过仅面向 26 键的 GlideBeam，改走 `session.previewGlideAsync` 在顶栏实时流式预览中文候选，兜底键序预览显示数字串（如 `742`）而非 T9 首字母。
   - `startsGlide` 改为按 `min(键宽, 键高) × 0.4` 计算纵横起滑门槛，保持 26 键不变，同时将宽扁九键的短距竖滑触发门槛从 `32–40 pt` 降至约 `19.6 pt`。
   - 开启九键滑行时 `activeNineKeySwipeDigits` 让位返回 `.off`，防止 `7→4`（是）、`9→6`（我）等向上滑行被九键上滑输数字抢占（长按 1–9 输入数字不受影响）。

## Alternatives considered

- **在 `msime_client_glide` FFI 层新增独立的九键请求结构**：需要同步改 C 头文件、Swift/Kotlin/ArkTS/C++ 桥接与 JSON 校验；而 T9 2–9 与 `a..z` 本身是满射归组，复用 26 槽坐标零 ABI 成本且未来其他端可直接复用同一后端解码器。
- **直接复用 26 键 `decode_glide` 并把同键字母设为相同坐标**：26 键解码器把相同坐标的连续字母当作同键停留，无法在用户流畅滑过 `6→4→2→6` 时补出 `ni'hao = 64426` 这类边界连字。

## Consequences

- **收益**：拼音九键（含默认「iOS 原生」十键与所有现有九键样式）开箱支持连续滑行、拖动实时中文预览、组合词识别与同路径次优读音候选，同时 26 键双语滑行免去一倍重复几何计算。
- **代价**：开启滑行输入时，拼音九键的「上滑输入数字」自动让位，数字需通过长按或 `123` 数字层输入。
- **验证**：由 `cargo test -p msime-engine glide`（50 条，含组合词与同路径次优候选单测）、`cargo test -p msime-host-api glide`、`pnpm run verify-notes`、iOS `GlideTypingTests` 及真机 `RCe2027` 编译安装覆盖验证。
