# Agent Note: 引擎滑行解码保留共线次优读音候选并收紧停留阈值

Status: implemented

## Problem

在 26 键全拼滑行输入中，存在两类高频误判：

1. **停留判定过长（`DWELL_MS = 120`）**：真机快速滑行经过目标键并略作停顿时，实际停留时间常在 `60–100ms` 之间，`120ms` 阈值导致大量有意停留不被识别。
2. **共线或几何相近读音被主读音淹没**：例如 `r -> u -> i` 同时落在 `ri` 与 `rui` 的路径上，词典高频主读音 `ri` 会展开 20 多个单字候选，把 `rui`（如「瑞」）挤出可见候选栏，用户即使精准滑过 `u` 也看不到目标字。

## Decision

- **下调停留阈值（[glide.rs](../../../../crates/engine/src/pinyin/glide.rs)）**：将 `DWELL_MS` 从 `120` 调整为 `58`（保持 `DWELL_RADIUS = 0.35` 与其余 beam 参数不变），提高快速滑行中的停留灵敏度。
- **保留共线/相近次优读音候选（[glide.rs](../../../../crates/engine/src/session/glide.rs)）**：在空组字起手滑行成功后，取与最优读音代价差不超过 `5.5` 的至多 2 条备选读音，各自经 `query_raw_candidates` 筛出完整中文滑行候选（每条最多 3 项，标记 `CandidateSource::Generated`），去重后插入候选列表前排（索引 `min(len, 2)` 起），并置 `glide_candidates` 与 `glide_selection_pending = true`。

## Alternatives considered

- **直接提高次优读音的整体排序权重以取代主读音**：容易在用户本来就想滑 `ri` 时把首位「日」顶掉，反伤高频词命中率；保留主读音前两名、把次优读音插在第 3 位起更稳妥。

## Consequences

- **收益**：`r->u->i` 等共线滑行可同时在首屏看到主读音与次优读音候选，快速滑行停留识别率提升。
- **代价**：新增的次优候选会占用候选栏第 3 位起的少量位置；仅在空组字起手滑行时触发，不影响连续组字拼接。
- **验证**：由 `cargo test -p msime-engine glide`（含新增单测 `collinear_glide_rui_keeps_secondary_reading_candidates`）与 iOS `MSIMEKeyboardTests` 全套通过验证。
