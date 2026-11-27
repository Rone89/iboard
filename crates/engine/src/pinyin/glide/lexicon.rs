//! 中英混合滑行的英文词表几何匹配，复用拼音滑行的轨迹度量。

use super::*;

/// 词典中高频全拼词条的紧凑滑行索引：按起手字母分桶懒加载，用位掩码 O(1) 筛掉无关词后直接交由 `GlideMatcher` 零分配打分，彻底消除多音节常用词在纯字母束搜索中被挤掉的问题。
#[derive(Clone, Debug)]
pub struct GlideLexiconEntry {
    pub letters: Box<str>,
    pub letter_mask: u32,
    pub last: u8,
}

impl GlideLexiconEntry {
    /// 从词典的 `'` 分隔拼音键（如 `"xian'zai"`）构造紧凑索引；长度越界或含非小写字母时返回 `None`。
    pub fn from_key(key: &str) -> Option<Self> {
        let mut letters = String::with_capacity(key.len());
        let mut mask = 0u32;
        for byte in key.bytes() {
            if byte == b'\'' {
                continue;
            }
            if !byte.is_ascii_lowercase() {
                return None;
            }
            mask |= 1u32 << (byte - b'a');
            letters.push(char::from(byte));
        }
        if !(2..=MAX_GLIDE_LETTERS).contains(&letters.len()) {
            return None;
        }
        let last = letters.as_bytes()[letters.len() - 1] - b'a';
        Some(Self {
            letters: letters.into_boxed_str(),
            letter_mask: mask,
            last,
        })
    }
}

/// SHARK2 形状通道的固定重采样点数（全部在栈上完成，零堆分配）。
const SHAPE_POINTS: usize = 24;
/// 形状与位置带状 DTW 的时间偏移带宽（±2 步，约 ±8% 弧长弹性，吸收快慢不均与不对称切弯）。
const DTW_BAND: usize = 2;
/// 词典直评通道对缩手/圆角切弯的放宽邻域半径（键宽单位）：避免单手滑长词时边缘键（`a`/`q`/`i`/`o`）被硬拒。
const LEXICON_NEAR_DISTANCE: f32 = 2.45;
const LEXICON_ENDPOINT_NEAR: f32 = 1.65;
/// 形状归一化均方误差、绝对位置均方误差、局部峰值偏移、方向一致性、弧长比例与基础偏置，对齐束搜索几何代价尺度（防止干净笔画上形状通道反超精确位置匹配）。
const SHAPE_MSE_SCALE: f32 = 34.0;
const LOC_MSE_SCALE: f32 = 4.2;
const LOC_PEAK_SCALE: f32 = 2.1;
const SHAPE_DIR_SCALE: f32 = 4.0;
const SHAPE_ARC_RATIO_SCALE: f32 = 5.0;
const SHAPE_BASE_BIAS: f32 = 2.15;
const SHAPE_ROUNDED_BIAS: f32 = 0.25;
const SHAPE_LETTER_SCALE: f32 = LETTER_COST;

/// 快速计算折线总弧长，供重采样与 DTW 之前做 O(len) 弧长门控早退。
fn polyline_arc_len(points: &[(f32, f32)]) -> f32 {
    let mut total = 0.0f32;
    for pair in points.windows(2) {
        total += ((pair[1].0 - pair[0].0).powi(2) + (pair[1].1 - pair[0].1).powi(2)).sqrt();
    }
    total
}

/// 对折线中间拐点执行一轮 Chaikin 圆角切弯（`t = 0.25`，首尾锚点不动），模拟真实人手拇指弧线切弯后的模板形状。
fn smooth_polyline_corners(
    points: &[(f32, f32)],
    out: &mut [(f32, f32); MAX_GLIDE_LETTERS * 2],
) -> usize {
    if points.len() < 3 {
        for (i, &p) in points.iter().enumerate() {
            out[i] = p;
        }
        return points.len();
    }
    const T: f32 = 0.25;
    let mut n = 0usize;
    out[n] = points[0];
    n += 1;
    for i in 0..(points.len() - 1) {
        let a = points[i];
        let b = points[i + 1];
        if i > 0 && n < out.len() {
            out[n] = (a.0 * (1.0 - T) + b.0 * T, a.1 * (1.0 - T) + b.1 * T);
            n += 1;
        }
        if i + 2 < points.len() && n < out.len() {
            out[n] = (a.0 * T + b.0 * (1.0 - T), a.1 * T + b.1 * (1.0 - T));
            n += 1;
        }
    }
    if n < out.len() {
        out[n] = points[points.len() - 1];
        n += 1;
    }
    n
}

/// 在栈上计算两条定长重采样折线的有界 Sakoe-Chiba 带状 DTW 均方误差（零堆分配）；
/// 当某一行最小累计误差已超过 `max_mse * SHAPE_POINTS` 时立即早退，与无早退版本数学等价但跳过绝大多数不匹配词条的后半段计算。
fn banded_dtw_mse_bounded(
    a: &[(f32, f32); SHAPE_POINTS],
    b: &[(f32, f32); SHAPE_POINTS],
    max_mse: f32,
) -> f32 {
    let max_total = max_mse * SHAPE_POINTS as f32;
    let mut prev = [f32::INFINITY; SHAPE_POINTS];
    let mut curr = [f32::INFINITY; SHAPE_POINTS];
    let d0 = (a[0].0 - b[0].0).powi(2) + (a[0].1 - b[0].1).powi(2);
    if d0 > max_total {
        return f32::INFINITY;
    }
    prev[0] = d0;
    for j in 1..=DTW_BAND.min(SHAPE_POINTS - 1) {
        let d = (a[0].0 - b[j].0).powi(2) + (a[0].1 - b[j].1).powi(2);
        prev[j] = prev[j - 1] + d;
    }
    for i in 1..SHAPE_POINTS {
        curr.fill(f32::INFINITY);
        let j_start = i.saturating_sub(DTW_BAND);
        let j_end = (i + DTW_BAND).min(SHAPE_POINTS - 1);
        let mut row_min = f32::INFINITY;
        for j in j_start..=j_end {
            let d = (a[i].0 - b[j].0).powi(2) + (a[i].1 - b[j].1).powi(2);
            let mut best = prev[j];
            if j > 0 {
                best = best.min(prev[j - 1]).min(curr[j - 1]);
            }
            let val = d + best;
            curr[j] = val;
            row_min = row_min.min(val);
        }
        if row_min > max_total {
            return f32::INFINITY;
        }
        prev = curr;
    }
    prev[SHAPE_POINTS - 1] / SHAPE_POINTS as f32
}

/// 把归一化坐标折线按等弧长重采样成 `SHAPE_POINTS` 个点，返回 `(原始采样, 零均值归一化形状, 单位切向, 总弧长)`。
fn resample_polyline(
    points: &[(f32, f32)],
) -> (
    [(f32, f32); SHAPE_POINTS],
    [(f32, f32); SHAPE_POINTS],
    [(f32, f32); SHAPE_POINTS - 1],
    f32,
) {
    let mut raw = [(0.0f32, 0.0f32); SHAPE_POINTS];
    let mut total_len = 0.0f32;
    if points.is_empty() {
        return (raw, raw, [(0.0, 0.0); SHAPE_POINTS - 1], 0.0);
    }
    if points.len() == 1 {
        raw.fill(points[0]);
    } else {
        for pair in points.windows(2) {
            total_len += ((pair[1].0 - pair[0].0).powi(2) + (pair[1].1 - pair[0].1).powi(2)).sqrt();
        }
        if total_len <= 1e-5 {
            raw.fill(points[0]);
        } else {
            raw[0] = points[0];
            raw[SHAPE_POINTS - 1] = points[points.len() - 1];
            let step = total_len / (SHAPE_POINTS - 1) as f32;
            let mut seg_idx = 0usize;
            let mut seg_start_arc = 0.0f32;
            let mut seg_len = ((points[1].0 - points[0].0).powi(2) + (points[1].1 - points[0].1).powi(2)).sqrt();
            for k in 1..(SHAPE_POINTS - 1) {
                let target = step * k as f32;
                while seg_idx + 2 < points.len() && seg_start_arc + seg_len < target {
                    seg_start_arc += seg_len;
                    seg_idx += 1;
                    let a = points[seg_idx];
                    let b = points[seg_idx + 1];
                    seg_len = ((b.0 - a.0).powi(2) + (b.1 - a.1).powi(2)).sqrt();
                }
                let a = points[seg_idx];
                let b = points[seg_idx + 1];
                let t = if seg_len > 1e-5 {
                    ((target - seg_start_arc) / seg_len).clamp(0.0, 1.0)
                } else {
                    0.0
                };
                raw[k] = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t);
            }
        }
    }

    // 零均值 + 最大包络跨度归一化（SHARK2 尺度无关形状通道）。
    let mut sum_x = 0.0f32;
    let mut sum_y = 0.0f32;
    let mut min_x = f32::INFINITY;
    let mut max_x = f32::NEG_INFINITY;
    let mut min_y = f32::INFINITY;
    let mut max_y = f32::NEG_INFINITY;
    for &(x, y) in &raw {
        sum_x += x;
        sum_y += y;
        min_x = min_x.min(x);
        max_x = max_x.max(x);
        min_y = min_y.min(y);
        max_y = max_y.max(y);
    }
    let inv_n = 1.0 / SHAPE_POINTS as f32;
    let cx = sum_x * inv_n;
    let cy = sum_y * inv_n;
    let scale = (max_x - min_x).max(max_y - min_y).max(0.75);
    let inv_scale = 1.0 / scale;
    let mut norm = [(0.0f32, 0.0f32); SHAPE_POINTS];
    for k in 0..SHAPE_POINTS {
        norm[k] = ((raw[k].0 - cx) * inv_scale, (raw[k].1 - cy) * inv_scale);
    }
    let mut dirs = [(0.0f32, 0.0f32); SHAPE_POINTS - 1];
    for k in 0..(SHAPE_POINTS - 1) {
        let dx = raw[k + 1].0 - raw[k].0;
        let dy = raw[k + 1].1 - raw[k].1;
        let len = (dx * dx + dy * dy).sqrt();
        if len > 1e-4 {
            dirs[k] = (dx / len, dy / len);
        }
    }
    (raw, norm, dirs, total_len)
}

/// 英文词表与拼音共用同一套轨迹几何；英文的连续重复字母不要求手指重复画一遍。
/// 预计算起点/终点/可达字母位掩码以及 SHARK2 24 点归一化形状模板，让双语滑行与中文整词直评都能零堆分配完成 O(1) 剪枝与形状+位置双通道计分。
pub struct GlideMatcher {
    decoder: Decoder,
    centers: [(f32, f32); 26],
    start_mask: u32,
    end_mask: u32,
    near_mask: u32,
    lex_start_mask: u32,
    lex_end_mask: u32,
    lex_near_mask: u32,
    stroke_raw: [(f32, f32); SHAPE_POINTS],
    stroke_norm: [(f32, f32); SHAPE_POINTS],
    stroke_dirs: [(f32, f32); SHAPE_POINTS - 1],
    stroke_arc_len: f32,
    start_point: (f32, f32),
    end_point: (f32, f32),
}

impl GlideMatcher {
    pub fn new(keyboard: &GlideKeyboard, points: &[GlidePoint]) -> Option<Self> {
        if !keyboard.is_valid()
            || points.len() < 2
            || points
                .iter()
                .any(|point| !point.x.is_finite() || !point.y.is_finite())
        {
            return None;
        }
        let points: Vec<_> = points
            .iter()
            .map(|point| GlidePoint {
                x: point.x / keyboard.key_width,
                y: point.y / keyboard.key_height,
                time_ms: point.time_ms,
            })
            .collect();
        let samples = resample(&points);
        if samples.len() < 2 {
            return None;
        }
        let centers = keyboard.normalized_centers();
        let decoder = Decoder::new(centers, &samples);
        let last = decoder.count - 1;
        let mut start_mask = 0u32;
        let mut end_mask = 0u32;
        let mut near_mask = 0u32;
        for letter in 0..26 {
            let reach = &decoder.reach[letter];
            if !reach.is_empty() {
                near_mask |= 1u32 << letter;
                if reach.first() == Some(&0) {
                    start_mask |= 1u32 << letter;
                }
                if reach.last() == Some(&last) {
                    end_mask |= 1u32 << letter;
                }
            }
        }
        // 为整词词典直评预计算更宽容的缩手可达掩码，避免单手滑长词时边缘键（a/q/i/o）被硬截断。
        let lex_near_sq = LEXICON_NEAR_DISTANCE * LEXICON_NEAR_DISTANCE;
        let lex_end_sq = LEXICON_ENDPOINT_NEAR * LEXICON_ENDPOINT_NEAR;
        let start_point = (samples[0].x, samples[0].y);
        let end_point = (samples[last].x, samples[last].y);
        let mut lex_start_mask = start_mask;
        let mut lex_end_mask = end_mask;
        let mut lex_near_mask = near_mask;
        for letter in 0..26 {
            let (cx, cy) = centers[letter];
            let d0 = (start_point.0 - cx).powi(2) + (start_point.1 - cy).powi(2);
            if d0 <= lex_end_sq {
                lex_start_mask |= 1u32 << letter;
            }
            let d1 = (end_point.0 - cx).powi(2) + (end_point.1 - cy).powi(2);
            if d1 <= lex_end_sq {
                lex_end_mask |= 1u32 << letter;
            }
            if (lex_near_mask & (1u32 << letter)) == 0
                && samples
                    .iter()
                    .any(|s| (s.x - cx).powi(2) + (s.y - cy).powi(2) <= lex_near_sq)
            {
                lex_near_mask |= 1u32 << letter;
            }
        }
        let sample_coords: Vec<(f32, f32)> = samples.iter().map(|s| (s.x, s.y)).collect();
        let (stroke_raw, stroke_norm, stroke_dirs, stroke_arc_len) = resample_polyline(&sample_coords);
        Some(Self {
            decoder,
            centers,
            start_mask,
            end_mask,
            near_mask,
            lex_start_mask,
            lex_end_mask,
            lex_near_mask,
            stroke_raw,
            stroke_norm,
            stroke_dirs,
            stroke_arc_len,
            start_point,
            end_point,
        })
    }

    /// 直接复用已构建的 `Decoder` 解码全拼假设，避免双语滑行时对同一笔轨迹重复重采样与重建 26×26 连线前缀表。
    pub fn decode_quanpin(&self, limit: usize) -> Vec<GlideHypothesis> {
        if limit == 0 {
            return Vec::new();
        }
        self.decoder.run(limit)
    }

    /// 只查询起点附近的首字母，每个首字母的词数另有上限。
    pub fn starting_letters(&self) -> Vec<u8> {
        (0..26u8)
            .filter(|&letter| (self.start_mask & (1u32 << letter)) != 0)
            .map(|letter| b'a' + letter)
            .collect()
    }

    /// 扫描同一首字母桶内的词典词条，用宽松缩手位掩码 O(1) 剪枝，对多音节词结合 SHARK2 形状+方向双通道与位置 DP 计分，返回代价最低的至多 `limit` 条假设。
    pub fn score_lexicon(
        &self,
        entries: &[GlideLexiconEntry],
        limit: usize,
    ) -> Vec<GlideHypothesis> {
        if limit == 0 || entries.is_empty() {
            return Vec::new();
        }
        let mut results: Vec<GlideHypothesis> = Vec::with_capacity(limit.min(32));
        for entry in entries {
            if (self.lex_end_mask & (1u32 << entry.last)) == 0
                || (entry.letter_mask & !self.lex_near_mask) != 0
            {
                continue;
            }
            if let Some(cost) = self.score_pinyin_dual(&entry.letters) {
                results.push(GlideHypothesis {
                    letters: entry.letters.as_ref().to_owned(),
                    cost,
                });
            }
        }
        if results.len() > limit {
            results.select_nth_unstable_by(limit - 1, |a, b| {
                a.cost
                    .total_cmp(&b.cost)
                    .then_with(|| a.letters.cmp(&b.letters))
            });
            results.truncate(limit);
        }
        results.sort_by(|a, b| {
            a.cost
                .total_cmp(&b.cost)
                .then_with(|| a.letters.cmp(&b.letters))
        });
        results
    }

    /// 供中文整词直评查询的起手字母（比英文略宽容，允许首点微偏到邻键）。
    pub fn lexicon_starting_letters(&self) -> Vec<u8> {
        (0..26u8)
            .filter(|&letter| (self.lex_start_mask & (1u32 << letter)) != 0)
            .map(|letter| b'a' + letter)
            .collect()
    }

    /// 中文词典整词双通道计分（保证严格单调：未进严格邻域的词绝不会比同等形状下已进严格邻域的词更便宜）：
    /// - 命中严格位置 DP（`tight = Some(t)`）且 `< 5` 独立键位的干净短词：若平均每键位置代价不高则直接保真，
    ///   防止短词微偏被异形词借形状通道反超；若切弯导致 `t` 显著偏高或 `>= 5` 独立键位长词，则与圆角+DTW 形状通道取 `t.min(s)`；
    /// - 未进严格邻域的缩手整词（`tight == None`）：采用 `s + SHAPE_OUT_OF_REACH_PENALTY`（`+1.5`）救援。
    pub(crate) fn score_pinyin_dual(&self, word: &str) -> Option<f32> {
        const SHAPE_OUT_OF_REACH_PENALTY: f32 = 1.5;
        let tight = self.score_pinyin(word);
        let unique_len = word
            .as_bytes()
            .iter()
            .enumerate()
            .filter(|&(i, &b)| i == 0 || word.as_bytes()[i - 1] != b)
            .count();
        if let Some(t) = tight {
            // 形状通道代价数学下界为 `SHAPE_BASE_BIAS + unique_len * SHAPE_LETTER_SCALE`，严格位置 DP 已低于下界时必胜，直接短路省去模板重采样与 DTW。
            if t <= SHAPE_BASE_BIAS + unique_len as f32 * SHAPE_LETTER_SCALE {
                return Some(t);
            }
            // 短词在干净笔画上保持严格位置 DP；当大角度圆角切弯拉高 `t`（如单手缩手滑 `hao`/`men`/`woqu`）时同样允许形状通道兜底。
            if unique_len < 5 && t < unique_len as f32 * 1.45 {
                return Some(t);
            }
            if let Some(s) = self.score_shape_channel(word) {
                return Some(t.min(s));
            }
            return Some(t);
        }
        self.score_shape_channel(word)
            .map(|s| s + SHAPE_OUT_OF_REACH_PENALTY)
    }

    /// 评估单条理想模板折线（锐角或圆角）与用户轨迹的 SHARK2 形状 + 位置 DTW + 局部峰值偏移 + 切向 + 弧长代价。
    fn eval_shape_template(
        &self,
        coords: &[(f32, f32)],
        first: usize,
        last: usize,
        unique_len: usize,
        repeats: usize,
        extra_bias: f32,
    ) -> Option<f32> {
        let stroke_len = self.stroke_arc_len.max(0.5);
        let approx_arc_len = polyline_arc_len(coords);
        let arc_ratio = approx_arc_len.max(0.5) / stroke_len;
        // 短划更严防长词反超（`hao` 不应被 `heshuo` 抢走），长词保留合理切弯弧长余量；在重采样与 DTW 前先早退省时。
        let max_arc_ratio = if stroke_len < 5.5 { 1.48 } else { 1.75 };
        if !(0.60..=max_arc_ratio).contains(&arc_ratio) {
            return None;
        }
        let (word_raw, word_norm, word_dirs, word_arc_len) = resample_polyline(coords);
        let arc_ratio = word_arc_len.max(0.5) / stroke_len;
        let arc_penalty = arc_ratio.ln().abs() * SHAPE_ARC_RATIO_SCALE;

        let shape_mse = banded_dtw_mse_bounded(&self.stroke_norm, &word_norm, 0.26);
        if shape_mse > 0.26 {
            return None;
        }
        let loc_mse = banded_dtw_mse_bounded(&self.stroke_raw, &word_raw, 3.2);
        if loc_mse > 3.2 {
            return None;
        }
        // 局部峰值偏移：捕捉单键偏错（如 `shige` 相对干净 `shide` 的 `g` 键偏 2 格），防止被其余 20 个对齐点平均稀释。
        let mut peak_loc_d2 = 0.0f32;
        for i in 0..SHAPE_POINTS {
            let j_start = i.saturating_sub(DTW_BAND);
            let j_end = (i + DTW_BAND).min(SHAPE_POINTS - 1);
            let mut best_d2 = f32::INFINITY;
            for j in j_start..=j_end {
                let dx = self.stroke_raw[i].0 - word_raw[j].0;
                let dy = self.stroke_raw[i].1 - word_raw[j].1;
                best_d2 = best_d2.min(dx * dx + dy * dy);
            }
            peak_loc_d2 = peak_loc_d2.max(best_d2);
        }
        let peak_excess = (peak_loc_d2 - 0.50).max(0.0);
        let mut dir_mismatch = 0.0f32;
        for k in 0..(SHAPE_POINTS - 1) {
            let dot = self.stroke_dirs[k].0 * word_dirs[k].0
                + self.stroke_dirs[k].1 * word_dirs[k].1;
            dir_mismatch += (1.0 - dot).max(0.0);
        }
        let dir_mean = dir_mismatch / (SHAPE_POINTS - 1) as f32;

        let sc = self.centers[first];
        let ec = self.centers[last];
        let start_d2 = (self.start_point.0 - sc.0).powi(2) + (self.start_point.1 - sc.1).powi(2);
        let end_d2 = (self.end_point.0 - ec.0).powi(2) + (self.end_point.1 - ec.1).powi(2);
        let endpoint_cost = (start_d2 + end_d2) / ALIGN_SCALE * ENDPOINT_ALIGN_WEIGHT;

        let cost = SHAPE_BASE_BIAS
            + extra_bias
            + endpoint_cost
            + arc_penalty
            + shape_mse * SHAPE_MSE_SCALE
            + loc_mse * LOC_MSE_SCALE
            + peak_excess * LOC_PEAK_SCALE
            + dir_mean * SHAPE_DIR_SCALE
            + unique_len as f32 * SHAPE_LETTER_SCALE
            + repeats as f32 * BOUNDARY_CONSONANT_REPEAT_COST;
        cost.is_finite().then_some(cost)
    }

    /// SHARK2 形状+方向+首尾锚点通道（支持 `>= 3` 独立键位，同步评估锐角与 Chaikin 圆角切弯模板，零堆分配）。
    fn score_shape_channel(&self, word: &str) -> Option<f32> {
        let bytes = word.as_bytes();
        if !(3..=MAX_GLIDE_LETTERS).contains(&bytes.len()) {
            return None;
        }
        let first = usize::from(bytes[0].checked_sub(b'a')?);
        let last = usize::from(bytes[bytes.len() - 1].checked_sub(b'a')?);
        if first >= 26
            || last >= 26
            || (self.lex_start_mask & (1u32 << first)) == 0
            || (self.lex_end_mask & (1u32 << last)) == 0
        {
            return None;
        }
        let mut coords = [(0.0f32, 0.0f32); MAX_GLIDE_LETTERS];
        let mut len = 0usize;
        let mut repeats = 0usize;
        let mut prev_idx = usize::MAX;
        for &b in bytes {
            if !b.is_ascii_lowercase() {
                return None;
            }
            let idx = usize::from(b - b'a');
            if (self.lex_near_mask & (1u32 << idx)) == 0 {
                return None;
            }
            if idx == prev_idx {
                repeats += 1;
                continue;
            }
            coords[len] = self.centers[idx];
            len += 1;
            prev_idx = idx;
        }
        if len < 3 {
            return None;
        }
        let sharp = self.eval_shape_template(&coords[..len], first, last, len, repeats, 0.0);
        let mut rounded_buf = [(0.0f32, 0.0f32); MAX_GLIDE_LETTERS * 2];
        let rlen = smooth_polyline_corners(&coords[..len], &mut rounded_buf);
        let rounded = self.eval_shape_template(
            &rounded_buf[..rlen],
            first,
            last,
            len,
            repeats,
            SHAPE_ROUNDED_BIAS,
        );
        match (sharp, rounded) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (Some(a), None) => Some(a),
            (None, Some(b)) => Some(b),
            (None, None) => None,
        }
    }

    /// 反向对齐一条已确认上屏词的拼音字母到本次轨迹采样点，返回各去重字母对应的 `(字母下标, 归一化采样 x, 归一化采样 y)`，供拇指偏移自适应学习。
    pub fn align_letters(&self, word: &str) -> Option<Vec<(usize, f32, f32)>> {
        let bytes = word.as_bytes();
        if !(2..=MAX_GLIDE_LETTERS).contains(&bytes.len()) {
            return None;
        }
        let mut letters = [0usize; MAX_GLIDE_LETTERS];
        let mut len = 0usize;
        for &b in bytes {
            if b == b'\'' {
                continue;
            }
            if !b.is_ascii_lowercase() {
                return None;
            }
            let idx = usize::from(b - b'a');
            if (self.near_mask & (1u32 << idx)) == 0 {
                return None;
            }
            if len == 0 || letters[len - 1] != idx {
                if len >= MAX_GLIDE_LETTERS {
                    return None;
                }
                letters[len] = idx;
                len += 1;
            }
        }
        if len < 2 {
            return None;
        }
        let first = letters[0];
        let last_letter = letters[len - 1];
        if (self.start_mask & (1u32 << first)) == 0
            || (self.end_mask & (1u32 << last_letter)) == 0
        {
            return None;
        }
        let count = self.decoder.count;
        let first_align = self.decoder.align[first].as_ref()?;
        let mut costs = [f32::INFINITY; MAX_SAMPLES];
        let mut back = [[0u8; MAX_SAMPLES]; MAX_GLIDE_LETTERS];
        costs[0] = first_align[0] + LETTER_COST;
        let mut from = first;
        for step in 1..len {
            let to = letters[step];
            let line = self.decoder.lines[from * 26 + to].as_deref()?;
            let align = self.decoder.align[to].as_deref()?;
            let mut next = [f32::INFINITY; MAX_SAMPLES];
            let mut best = f32::INFINITY;
            let mut best_prev = 0usize;
            let mut cursor = 0usize;
            for &at in &self.decoder.reach[to] {
                if at == 0 {
                    continue;
                }
                while cursor < at {
                    let c = costs[cursor];
                    if c.is_finite() {
                        let cand = c - line[cursor];
                        if cand < best {
                            best = cand;
                            best_prev = cursor;
                        }
                    }
                    cursor += 1;
                }
                if best.is_finite() {
                    next[at] = best + line[at - 1] + align[at] + LETTER_COST;
                    back[step][at] = best_prev as u8;
                }
            }
            costs = next;
            from = to;
        }
        if !costs[count - 1].is_finite() {
            return None;
        }
        let mut positions = [0usize; MAX_GLIDE_LETTERS];
        let mut cur = count - 1;
        for step in (0..len).rev() {
            positions[step] = cur;
            if step > 0 {
                cur = usize::from(back[step][cur]);
            }
        }
        let mut result = Vec::with_capacity(len);
        for step in 0..len {
            let sample = self.decoder.samples_xy[positions[step]];
            result.push((letters[step], sample.0, sample.1));
        }
        Some(result)
    }

    /// 为中文词典直评计分：与 `score` 共用零分配 DP，但对音节边界折叠的相邻重复辅音（如 `dian'nao`、`zhong'guo`）加记温和重复代价，保持与束搜索同一几何尺度。
    fn score_pinyin(&self, word: &str) -> Option<f32> {
        let base = self.score(word)?;
        let repeats = word
            .as_bytes()
            .windows(2)
            .filter(|pair| pair[0] == pair[1])
            .count();
        Some(base + repeats as f32 * BOUNDARY_CONSONANT_REPEAT_COST)
    }

    /// O(1) 严格位置通道位掩码预检：与 `score` 内对终点键与可达字母集的判定完全等价，供英文滑行词表零分配剪枝。
    #[inline]
    pub(crate) fn matches_strict_masks(&self, letter_mask: u32, last: u8) -> bool {
        (self.end_mask & (1u32 << last)) != 0 && (letter_mask & !self.near_mask) == 0
    }

    pub fn score(&self, word: &str) -> Option<f32> {
        let bytes = word.as_bytes();
        if !(2..=MAX_GLIDE_LETTERS).contains(&bytes.len()) {
            return None;
        }
        let first_byte = bytes[0];
        let last_byte = bytes[bytes.len() - 1];
        if !first_byte.is_ascii_lowercase() || !last_byte.is_ascii_lowercase() {
            return None;
        }
        let first = usize::from(first_byte - b'a');
        let last = usize::from(last_byte - b'a');
        if (self.start_mask & (1u32 << first)) == 0 || (self.end_mask & (1u32 << last)) == 0 {
            return None;
        }
        // 栈上原地去重并同步检查所有字母是否均靠近轨迹，避免每词堆分配 Vec。
        let mut letters = [0usize; MAX_GLIDE_LETTERS];
        let mut len = 0usize;
        for &b in bytes {
            if !b.is_ascii_lowercase() {
                return None;
            }
            let idx = usize::from(b - b'a');
            if (self.near_mask & (1u32 << idx)) == 0 {
                return None;
            }
            if len == 0 || letters[len - 1] != idx {
                letters[len] = idx;
                len += 1;
            }
        }
        let count = self.decoder.count;
        let first_align = self.decoder.align[first].as_ref()?;
        let mut costs = [f32::INFINITY; MAX_SAMPLES];
        costs[0] = first_align[0] + LETTER_COST;
        let mut from = first;
        for &to in &letters[1..len] {
            let line = self.decoder.lines[from * 26 + to].as_deref()?;
            let align = self.decoder.align[to].as_deref()?;
            let mut next = [f32::INFINITY; MAX_SAMPLES];
            let mut best = f32::INFINITY;
            let mut cursor = 0usize;
            for &at in &self.decoder.reach[to] {
                if at == 0 {
                    continue;
                }
                while cursor < at {
                    let c = costs[cursor];
                    if c.is_finite() {
                        best = best.min(c - line[cursor]);
                    }
                    cursor += 1;
                }
                if best.is_finite() {
                    next[at] = best + line[at - 1] + align[at] + LETTER_COST;
                }
            }
            costs = next;
            from = to;
        }
        let score = costs[count - 1];
        score.is_finite().then_some(score)
    }
}
