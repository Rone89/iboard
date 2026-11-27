# Agent Note: 滑行输入手感容错、GlideBeam 统一会话链路与 Rust 解码准确率/性能优化

Status: implemented

## Problem

在完成滑行实时预览、滑后一键撤回与按音节回删之后，iOS 滑行输入与共享 Rust 滑行引擎仍存在三组高感知体验与性能短板：

1. **手感与视觉跳动**：
   - `GlideTypingGestureRecognizer.touchesBegan` 要求 `touch.view` 严格命中字母键，拇指起手落在两枚字母键之间 6pt 键缝时会直接 `state = .failed` 导致起滑断触。
   - 拇指快速离屏最后 10–18ms 常带短距反向回勾，会污染尾键锚点。
   - 抬手时 `endGlide` 立即隐藏 `glideLivePreviewBar`，随后异步 GlideBeam 解码落地再展示候选栏，顶栏会先闪回工具栏再切到候选。
2. **GlideBeam 链路与水杉内置滑行能力割裂**：
   - `submitGlideReadings` 逐条调用 `session.enqueueCharacters(reading)`，续滑时缺少 `'` 音节分隔符（先滑 `xi` 再滑 `an` 粘成 `xian`），首位读音无候选时调用 `session.cancel()` 还会把已有组字整段清空。
   - GlideBeam 返回 Top 5 读音但只消费第 1 条，丢失了次优读音候选合并；开启「中英混合滑行」时也被 GlideBeam 分支完全绕过。
3. **Rust 引擎解码特征与双语性能瓶颈**：
   - `crates/engine/src/pinyin/glide.rs` 仅靠 `>= 58ms` 静态停留标注中间键，快滑很少长时间停顿；`QuanpinDictionary::best_weights` 仅查静态库权重，未结合个人词频与 `rescoring_context` 上文语境。
   - `GlideMatcher::score` 在双语滑行中对每个英文词堆分配 `Vec<usize>` 并做全采样循环加二分查找，缺乏首尾/可达字母位掩码预剪枝。

## Decision

1. **iOS 手感与防闪烁（[GlideTyping.swift](../../../../platforms/ios/KeyboardExtension/Sources/input/GlideTyping.swift)、[GlideTypingGesture.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/GlideTypingGesture.swift)、[KeyboardViewController.swift](../../../../platforms/ios/KeyboardExtension/Sources/keyboard/KeyboardViewController.swift)）**：
   - 新增 `GlideTyping.nearestKeyIndex(at:in:maxGapPadding:)`（默认 `10pt`），在 `touchesBegan` 命中键区空白/行容器（且非 `UIButton` 功能键）时吸附到中心最近的字母键，保留 `GlideTyping.keyIndex` 原有严格语义。
   - 新增 `GlideTyping.trimmedLiftoffHook(_:frames:)`，仅对总时长 `>= 80ms` 的真实采样在末 `18ms` 内过滤夹角超 120°（`cos < -0.5`）且长度不超过 `0.45` 个键宽的离屏回勾，同时惠及 GlideBeam 与内置引擎。
   - `endGlide(fading:keepPreviewUntilCommit:)` 在异步 GlideBeam 解码期间冻结但不隐藏 `glideLivePreviewBar`，待解码落地或任何新输入进入 `render` 时同帧收起切换，消除顶栏闪回工具栏。
   - **26 键防误触六层保护与速度自适应起滑**：针对 26 键普通快打频繁误起滑行的问题，将 26 键常态慢速滚滑起滑门槛维持在 `0.72` / 键缝起手 `0.85` / 240ms 连打节律内 `0.95` 键宽（九键维持 `min(宽, 高) × 0.4` 不变），同时引入速度自适应快滑（`velocity >= 360 pt/s` 且非连打/非键缝/无同向角标冲突时降至 `0.56` 键宽 + 8% 内缩），兼顾防误触与蓄意滑行零迟滞出轨迹；抬手尾迹淡出加速至 `0.24s`，实时候选预览节拍收紧至 `55ms` / `20pt` / `10pt`。
   - **只读连滑实时预览（`"preview": true`）**：`msime_client_glide` 新增向后兼容的可选布尔字段 `preview`，由 `Session::preview_glide`（覆盖 26 键全拼与九键）在不改动当前活跃组字、光标与学习记录的前提下直接返回读音与前排中文候选；iOS 端在连续滑行第二、第三词（`hasComposition == true`）时也能实时刷新中文候选，不再退化为原始键序字母。
2. **GlideBeam 统一走 `msime_client_glide` 可选 `readings` 字段（[input.rs](../../../../crates/host-api/src/ffi/input.rs)、[session/glide.rs](../../../../crates/engine/src/session/glide.rs)）**：
   - `GlideRequest` 新增向后兼容的可选字段 `#[serde(default)] readings: Vec<String>`（至多 16 条纯小写拼音），缺省请求 JSON 格式逐字节不变。
   - 纯中文滑行时，`InputSession::glide` 对外部读音走 `rank_by_dictionary` → `insert_glide_letters`（自动插 `'`、不清空已有组字）→ 合并次优读音到 `glide_candidates`，全无候选时在同一次调用内无缝回退内置几何解码。
   - 中英混合滑行时，`InputSession::bilingual_glide` 用同一 `GlideMatcher::score` 计算外部读音的真实几何代价后再并入中文候选池，与英文词在同一量纲上竞争，并先经中文词典重排再截断候选池；同时 iOS 实时预览保持只读不堵线程。
3. **Rust 滑行引擎词典直评通道、音节先验、组合 DP 与零分配优化（[pinyin/glide.rs](../../../../crates/engine/src/pinyin/glide.rs)、[lexicon.rs](../../../../crates/engine/src/pinyin/glide/lexicon.rs)、[pinyin.rs](../../../../crates/engine/src/dictionary/pinyin.rs)、[dictionary.rs](../../../../crates/engine/src/quanpin/dictionary.rs)）**：
   - 在 `resample` 中加入对称的 `trim_liftoff_hook`、减速谷检测（55–114ms 且低于中位速度 30%，`SKIPPED_SLOW_COST = 0.40 < LETTER_COST`）、主动停留门槛收紧至 `DWELL_MS = 115ms`、首尾 `0.55` 键宽端点豁免停留/减速谷（防止抬手减速把 `hao` 读成 `haoo`），以及 `±3` 采样弦窗的急转拐点检测（`>= 80°`，`SKIPPED_CORNER_COST = 0.45 < LETTER_COST`）。
   - **26 键束搜索与词典直评双路融合**：
     - 音节前缀树剔除冗余 `v` 别名（`jv`/`qv`/`xv`/`yv` 及其 `ve` 变体，保留 `lv`/`nv`），并复用内置 `SYLLABLE_FREQUENCY` 表做束内音节频度先验剪枝与单字母元音尾缀正则（抑制 `he'di'o`、`zhong'o`、`du'de'nv` 等碎音节占槽），但不对 `finals` 重复叠加频度以免与 `rank_by_dictionary` 双重计权。
     - `Prefix.letters` 与 `Prefix.states` 改为栈上定长数组（≤30 字节 / ≤6 状态），把 `TOKENS_PER_SAMPLE` 从 6 扩至 12、`GLIDE_HYPOTHESES` 从 16 扩至 48，并引入 `LONGER_WORD_MARGIN = 5.5` 防止短词在词典重排前提前剪死长词，同时长句堆分配仍远低于既有预算。
     - 放宽中段弧线容差（`NEAR_DISTANCE = 1.65`、`ALIGN_SCALE = 0.33`、`LINE_SCALE = 0.20`），同时强化首尾采样点锚定（`ENDPOINT_NEAR_DISTANCE = 1.25`、`ENDPOINT_ALIGN_WEIGHT = 1.65`），并放通音节边界同辅音单遍重键（`dian'nao`、`zhong'guo`、`nan'ning` 允许在同采样点低价复对齐）。
     - 新增按起手字母懒加载缓存的中文高频词直评通道（`PinyinDatabase::top_glide_lexicon_for_initial` + `QuanpinDictionary::with_glide_lexicon_for_initials` + `GlideMatcher::score_lexicon`，每字母取 `tbl_1..4` 高频键至多 `64/1400/1000/500` 条），结合 **SHARK2 24 点归一化形状 + 切向 + 弧长比例门控双通道**，并在二期升级为 **锐角 + Chaikin 圆角切弯双模板（`t = 0.25`）+ 有界 Sakoe-Chiba 带状 DTW（`DTW_BAND = 2`，早退零堆分配）+ 局部峰值偏移罚分 + 严格代价下界短路**，短词与长词（`>= 3` 独立键位）在大角度缩手切弯下均可安全兜底；`rank_by_dictionary_with_prefix` 支持 2–6 音节组合 DP（`COMPOSITIONAL_SPLIT_PENALTY = 1.95`）与连续滑行跨笔前缀整词桥接（如已有 `wo` 续滑 `men` 同步查询 `wo'men`）。
     - 多音节一笔整词滑行抬手后在首屏前排（1..3 位）轮转插入最多 3 组相近次优读音的首选词；连续滑行（`had_composition == true`）同样把代价接近的次优组合整词合并到首屏前排（1..2 位）；实时预览条直接渲染在正式候选栏中（最多 9 条）并优先使用带分词撇号的 `canonical_pinyin`，减少翻页与抬手跳动。
     - 60 词出货词库真实弧线切弯基准对比：`clean` Top-1 `86.7% → 96.7%`（Top-3 `98.3%`、召回 `100%`），`human-medium` Top-1 `31.7% → 68.3% → 88.3%`、Top-3 `51.7% → 85.0% → 93.3%`、召回 `60.0% → 96.7%`，`human-sloppy` Top-1 `20.0% → 36.7% → 76.7%`、Top-3 `28.3% → 50.0% → 88.3%`、召回 `38.3% → 78.3% → 96.7%`。
   - `QuanpinDictionary::best_weights_with_context` 叠加当前未上屏组字首位词（`extra_context`）与 `rescoring_context`，在个人词频/二元语境（封顶 4× / 3×）之外进一步引入出货静态中文二元 PMI（`SentenceNgramTables::bigram_score`，封顶约 5×），使首笔与续滑均具备语境消歧能力。
   - 新增轻量级在线拇指落点偏移自适应校准器 `GlideKeyCalibrator`（[calibration.rs](../../../../crates/engine/src/pinyin/glide/calibration.rs)）：仅在用户确认选中中文候选上屏（含 `glide_candidates` 次优自纠）且 `learning = true` 时，经 `GlideMatcher::align_letters` 反向对齐原始轨迹与真实 `canonical_pinyin`，用归一化 EWMA 学习每键 + 全局柔和偏置（±0.35 键宽硬上限、拒收离群切弯、批量落盘至 `user_data/glide_calibration.json`）；手动退格/改字自动作废挂起快照。
   - `GlideMatcher` 预计算 `start_mask`/`end_mask`/`near_mask` 三个 `u32` 位掩码，`score()` 改为栈数组原地去重 + 线性 `reach[to]` 游标扫描，实现零堆分配与 O(1) 首尾剪枝。

## Alternatives considered

- **在 Swift 层维护 GlideBeam 的次优候选合并表与回滚逻辑**：绕开 Rust 会话在 Swift 侧拼装候选会导致 `selectCandidate(at:)` 下标错位、无法触发引擎个人词频学习，且续滑回滚复杂易留残态；通过向 `msime_client_glide` 增加向后兼容的 `readings` 字段，一次调用同时解决续滑分隔、安全回退、次优合并与双语竞争。
- **使用更大拐点罚分（如 `SKIPPED_CORNER_COST = 1.2` + `±2` 步 52° 阈角）**：实测会使 `noisy_strokes_still_decode` 与 `the_dictionary_settles_what_the_stroke_cannot` 在抖动笔画上为躲避拐点罚分而虚构多余字母（`nihao` → `nihasio`、`zong` → `zhong`），因此收紧为 `±3` 弦窗、`80°` 急转且罚分低于 `LETTER_COST`。

## Consequences

- **收益**：起滑不易在键缝断触、快抬手不易甩尾偏键、GlideBeam 抬手顶栏无闪烁、续滑正确插 `'` 且兼容次优候选与中英混合、双语英文匹配零堆分配并大幅剪枝、个人常用词与上文语境可直接助力滑行排序。
- **兼容性**：默认 `GlideRequest` JSON 结构保持完全兼容，未传 `readings` 时各平台零改动即可享受 Rust 解码器与性能收益。
- **中英混合滑行候选保真与重排隔离**（`crates/engine/src/session/glide.rs`、`glide/composition.rs`、`glide/contractions.rs`、`session/composition.rs`、`ordering.rs`）：
  - 保留中文词典来源与英文 `CandidateSource::EnglishDictionary`（不再一律覆写为 `Generated`），并在 `ordering::row_answers_key` 排除 `ENGLISH_SOURCE`，防止中文句子重排器将英文候选（如 `zing`）提到中文首选之前。
  - `selection_completes_composition` 对 `glide_candidates` 直接返回 `true`，移除对 `row.corrected_from` 的占位写入，消除所有中文候选下方冗余的拼音灰字副标题。
  - 主中文读音上限由 3 扩至 16（次优读音仍各取 3 条，阈值由 `+6.0` 收紧为 `+4.5`），保证 `xing` 等单音节同音字完整展示；英文词频归一化以词库常见词基准（`the / 1000`）作下限，避免滑中文时偶遇的生僻英文词因批内最大权重而获得 0 频度惩罚。
- **验证**：由 `cargo test -p msime-engine glide`、`cargo test -p msime-engine ordering`、`cargo test -p msime-input-runtime the_reranker_leaves_a_leading_english_word_in_place`、`cargo test -p msime-host-api glide`、`pnpm run verify-notes`、iOS 真机/模拟器静态库重编及 `GlideTypingTests` / `GlideEngineTests` / `GlideLivePreviewAndUndoTests` / `BackspaceSyllableTests` 覆盖验证。
