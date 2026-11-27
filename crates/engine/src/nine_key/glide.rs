//! 九键（T9）滑行输入解码：基于 2–9 八个键位的几何轨迹，在有效九键拼音音节表上做束搜索，
//! 天然支持音节边界同键连字（如 `ni'hao = 64|426` 滑 `6→4→2→6`、`wo'men = 96|636` 滑 `9→6→3→6`）
//! 以及音节内重复数字（如 `shi = 744` 滑 `7→4`、`zhong = 94664` 滑 `9→4→6→4`），再经全拼词库按词频择优写入 `NineKeySession`。

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

use super::{open_dictionary, KeyGrid, NineKeySession, DIGIT_LIMIT, KEYPAD, SYLLABLE_FREQUENCY};
use crate::diagnostics;
use crate::pinyin::glide::{GlideKeyboard, GlidePoint};
use crate::pinyin::syllables::intact_pinyin_list;
use crate::types::{CandidateSource, KeyResult, SchemeType, SharedString, WordItem};

/// 2–9 八个数字键在 `GlideKeyboard.centers`（a..z 26 槽）中的代表下标：`a,d,g,j,m,p,t,w`。
const DIGIT_REP_INDICES: [usize; 8] = [0, 3, 6, 9, 12, 15, 19, 22];

/// 判断 `GlideKeyboard` 的 26 槽坐标是否由九键 2–9 展开而来：同一数字键上的所有字母共享同一中心点。
/// 这样即使 `Session.key_grid` 因残留偏好或外接键盘仍停在 `NineKey`，26 键 QWERTY 轨迹也绝不会被误路由进九键解码器。
pub(crate) fn is_nine_key_geometry(keyboard: &GlideKeyboard) -> bool {
    if !keyboard.is_valid() {
        return false;
    }
    for (i, &digit) in KEYPAD.iter().enumerate() {
        let rep = DIGIT_REP_INDICES[usize::from(digit - b'2')];
        let (x, y) = keyboard.centers[i];
        let (rx, ry) = keyboard.centers[rep];
        if (x - rx).abs() > 0.5 || (y - ry).abs() > 0.5 {
            return false;
        }
    }
    true
}

/// 九键相邻键中心相距 ~1.08–1.14 个键宽/高，1.15 兼顾微偏触点；起止键收紧到 0.85（无命中时自动回退 1.15），减少起止键邻居误扩散。
const REACH: f32 = 1.15;
const ENDPOINT_REACH: f32 = 0.85;
const STEP: f32 = 0.25;
const MAX_SAMPLES: usize = 96;
const MAX_SYLLABLES: usize = 6;
const TOKENS_PER_SAMPLE: usize = 8;
const BEAM_WIDTH: usize = 256;
/// 较长多字滑行（如 3–4 字词含多次边界/音节内重键）在纯几何排序里容易被无重键假切分排到前面，放宽到 64 条交由单次批量词典查权裁决。
const HYPOTHESIS_LIMIT: usize = 64;
const EXPAND_OUTPUT_LIMIT: usize = 32;

/// 实时预览档位参数：搭配位掩码剪枝与零分配 DP，保证高频 55ms 拖动预览流畅且与抬手结果一致。
#[derive(Clone, Copy)]
struct DecodeConfig {
    beam_width: usize,
    tokens_per_sample: usize,
    hypothesis_limit: usize,
    expand_output_limit: usize,
}

impl DecodeConfig {
    const FULL: Self = Self {
        beam_width: BEAM_WIDTH,
        tokens_per_sample: TOKENS_PER_SAMPLE,
        hypothesis_limit: HYPOTHESIS_LIMIT,
        expand_output_limit: EXPAND_OUTPUT_LIMIT,
    };

    const PREVIEW: Self = Self {
        beam_width: 144,
        tokens_per_sample: 6,
        hypothesis_limit: 36,
        expand_output_limit: 24,
    };
}

const DWELL_MS: u32 = 115;
const DWELL_RADIUS: f32 = 0.35;
const SLOW_WINDOW_MS: u32 = 55;
const SLOW_SPEED_RATIO: f32 = 0.30;
const ENDPOINT_EXEMPT_RADIUS: f32 = 0.55;
const CORNER_COS: f32 = 0.1736; // cos(80°)
const LINE_WEIGHT: f32 = 0.55;
const SKIPPED_DWELL_COST: f32 = 1.6;
const SKIPPED_SLOW_COST: f32 = 0.40;
const SKIPPED_CORNER_COST: f32 = 0.45;
const BACKTRACK_COST: f32 = 1.2;
const ALIGN_WEIGHT: f32 = 1.4;
const SYLLABLE_COST: f32 = 0.42;
const BOUNDARY_REPEAT_COST: f32 = 0.10;
const INTRA_REPEAT_COST: f32 = 0.08;
const COMPOSITIONAL_BREAK_COST: f32 = 0.60;
const COMPOSITIONAL_BIGRAM_BONUS: f32 = 0.35;
const CROSS_STROKE_MAX_BONUS: f32 = 1.35;
const CROSS_STROKE_MIN_BONUS: f32 = 0.35;
const SECONDARY_SCORE_MARGIN: f32 = 2.2;
const SECONDARY_CLOSE_TIE_MARGIN: f32 = 0.7;
/// 同路径次优拼音注入「选拼音」栏的代价容忍窗口，覆盖 `24/224/244`、`26/226`、`74/744`、`94/944` 等重键折叠组合。
const ALT_SPELLING_MARGIN: f32 = 3.0;
const ALT_SPELLING_LIMIT: usize = 8;
/// 起手键上出现明显原地回环/折返（如刻意在 `2` 上描 `c→a` 再滑向 `4`）时，给首键重复音节（`224`/`226`/`334` 等）的几何加权。
const START_REPEAT_LOOP_BONUS: f32 = 0.65;
/// 末键上出现明显原地回环/折返（如刻意滑 `2→4` 后在 `4` 上画小环打 `chi = 244`，或 `7→4` 尾环打 `shi = 744`）时，给尾键重复音节的几何加权。
const END_REPEAT_LOOP_BONUS: f32 = 0.95;

#[derive(Clone, Copy)]
struct Sample {
    x: f32,
    y: f32,
    slow: bool,
    dwell: bool,
    corner: bool,
}

struct DigitSyllable {
    /// 完整九键数字串，如 `b"744"`（`shi`）、`b"94664"`（`zhong`）。
    digits: Vec<u8>,
    /// 折叠相邻重复数字后的键位下标序列（`0..8` 对应数字 `2..=9`），如 `744 -> [5, 2]`。
    keys: Vec<u8>,
    /// 该音节经过的全部键位掩码（bit `k` 对应数字 `2 + k`），用于束搜索 O(1) 剪枝。
    key_mask: u8,
    /// 去掉首键后的后续键位掩码，用于音节边界同键续接时 O(1) 剪枝。
    tail_key_mask: u8,
    /// 音节内部是否包含相邻重复数字（如 `shi = 744`、`zhong = 94664`、`de = 33`）。
    has_repeat: bool,
    /// 首两位是否同键（如 `cai = 224`、`bao = 226`）。
    starts_with_repeat: bool,
    /// 末两位是否同键（如 `shi = 744`、`chi = 244`、`zhi = 944`、`de = 33`）。
    ends_with_repeat: bool,
    /// 该数字串对应的按频度降序排列的前若干个合法全拼读音（用于词库查权）。
    readings: Vec<&'static str>,
    /// 音节先验惩罚（高频音节接近 0，生僻音节略高）。
    prior_penalty: f32,
}

struct DigitSyllableTable {
    syllables: Vec<DigitSyllable>,
    by_first_key: [Vec<u16>; 8],
}

fn syllable_table() -> &'static DigitSyllableTable {
    static TABLE: OnceLock<DigitSyllableTable> = OnceLock::new();
    TABLE.get_or_init(build_syllable_table)
}

fn build_syllable_table() -> DigitSyllableTable {
    let mut freqs: HashMap<&'static str, u64> = HashMap::new();
    for line in SYLLABLE_FREQUENCY.lines() {
        let mut parts = line.split('\t');
        let (Some(syl), Some(weight)) = (parts.next(), parts.next()) else {
            continue;
        };
        if let Ok(w) = weight.parse::<u64>() {
            freqs.insert(syl, w);
        }
    }
    let max_freq = freqs.values().copied().max().unwrap_or(1).max(1) as f64;

    let mut grouped: HashMap<Vec<u8>, Vec<(&'static str, u64)>> = HashMap::new();
    for &syl in intact_pinyin_list() {
        let mut digits = Vec::with_capacity(syl.len());
        let mut valid = true;
        for &b in syl.as_bytes() {
            if !b.is_ascii_lowercase() {
                valid = false;
                break;
            }
            digits.push(KEYPAD[usize::from(b - b'a')]);
        }
        if !valid || digits.is_empty() {
            continue;
        }
        let weight = freqs.get(syl).copied().unwrap_or(1).max(1);
        grouped.entry(digits).or_default().push((syl, weight));
    }

    let mut entries: Vec<(Vec<u8>, Vec<(&'static str, u64)>)> = grouped.into_iter().collect();
    entries.sort_by(|a, b| a.0.cmp(&b.0));

    let mut syllables = Vec::with_capacity(entries.len());
    let mut by_first_key: [Vec<u16>; 8] = Default::default();

    for (digits, mut readings) in entries {
        readings.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
        let total_weight = readings.iter().map(|(_, w)| *w).sum::<u64>().max(1) as f64;
        // 单键单字母元音音节（`a`/`e`/`o`）在多字词中间极少单独成音节，增加轻微先验惩罚，防止在束剪枝里挤掉真实双键音节（如 `me`/`de`）。
        let single_vowel_penalty = if digits.len() == 1 { 0.35 } else { 0.0 };
        let prior_penalty =
            ((max_freq / total_weight).ln() * 0.12).clamp(0.0, 0.9) as f32 + single_vowel_penalty;

        let mut keys = Vec::with_capacity(digits.len());
        let mut key_mask = 0u8;
        let mut tail_key_mask = 0u8;
        for &d in &digits {
            let k = d - b'2';
            if keys.last() != Some(&k) {
                if !keys.is_empty() {
                    tail_key_mask |= 1u8 << k;
                }
                keys.push(k);
                key_mask |= 1u8 << k;
            }
        }
        let has_repeat = digits.len() > keys.len();
        let starts_with_repeat = digits.len() >= 2 && digits[0] == digits[1];
        let ends_with_repeat =
            digits.len() >= 2 && digits[digits.len() - 1] == digits[digits.len() - 2];
        // 保留前 8 个读音，覆盖高密度九键数字串（如 `74`/`94`/`926`/`7426`）里的全部常用音节。
        let top_readings: Vec<&'static str> = readings.into_iter().take(8).map(|(r, _)| r).collect();
        let id = syllables.len() as u16;
        let first = usize::from(keys[0]);
        syllables.push(DigitSyllable {
            digits,
            keys,
            key_mask,
            tail_key_mask,
            has_repeat,
            starts_with_repeat,
            ends_with_repeat,
            readings: top_readings,
            prior_penalty,
        });
        by_first_key[first].push(id);
    }

    DigitSyllableTable {
        syllables,
        by_first_key,
    }
}

/// 将归一化格子坐标 `(x/W, y/H)` 映射回物理各向同性比例（以 `sqrt(W * H)` 为单位），
/// 消除宽扁九键（`80×49pt`，纵横比 ~1.63）在夹角、拐点、回勾与原地回环检测里的纵向拉伸畸变。
#[inline]
fn iso_scales(keyboard: &GlideKeyboard) -> (f32, f32) {
    let aspect = (keyboard.key_width / keyboard.key_height).clamp(0.5, 2.5);
    let sx = aspect.sqrt();
    (sx, 1.0 / sx)
}

#[inline]
fn iso_distance_xy(ax: f32, ay: f32, bx: f32, by: f32, iso_x: f32, iso_y: f32) -> f32 {
    ((bx - ax) * iso_x).hypot((by - ay) * iso_y)
}

#[inline]
fn point_iso_distance(a: GlidePoint, b: GlidePoint, iso_x: f32, iso_y: f32) -> f32 {
    iso_distance_xy(a.x, a.y, b.x, b.y, iso_x, iso_y)
}

/// 过滤抬手最后 18ms 内因拇指离屏产生的短距反向回勾（在物理各向同性尺度下计算真实转向角与回勾长度）。
fn trim_liftoff_hook(points: &[GlidePoint], iso_x: f32, iso_y: f32) -> &[GlidePoint] {
    if points.len() < 6 {
        return points;
    }
    let (Some(last_time), Some(first_time)) = (points[points.len() - 1].time_ms, points[0].time_ms)
    else {
        return points;
    };
    if last_time.saturating_sub(first_time) < 80 {
        return points;
    }
    let mut end = points.len();
    for _ in 0..2 {
        if end < 5 {
            break;
        }
        let tail = points[end - 1];
        let prev = points[end - 2];
        let (Some(tail_ms), Some(prev_ms)) = (tail.time_ms, prev.time_ms) else {
            break;
        };
        if last_time.saturating_sub(prev_ms) > 18 || tail_ms.saturating_sub(prev_ms) > 18 {
            break;
        }
        let tx = (tail.x - prev.x) * iso_x;
        let ty = (tail.y - prev.y) * iso_y;
        let tail_len = tx.hypot(ty);
        if tail_len <= 0.02 || tail_len > 0.45 {
            break;
        }
        let mut anchor = end - 2;
        while anchor > 0 && point_iso_distance(prev, points[anchor], iso_x, iso_y) < 0.25 {
            anchor -= 1;
        }
        let px = (prev.x - points[anchor].x) * iso_x;
        let py = (prev.y - points[anchor].y) * iso_y;
        let prev_len = px.hypot(py);
        if prev_len <= 0.02 {
            break;
        }
        let cos_angle = (tx * px + ty * py) / (tail_len * prev_len);
        if cos_angle < -0.5 {
            end -= 1;
        } else {
            break;
        }
    }
    &points[..end]
}

/// 折叠手指静止或起止点附近的微小电容抖动，避免在末键停顿产生虚假折返。
fn collapse_stationary_jitter(points: &[GlidePoint], iso_x: f32, iso_y: f32) -> Vec<GlidePoint> {
    if points.len() < 3 {
        return points.to_vec();
    }
    let mut cleaned = Vec::with_capacity(points.len());
    cleaned.push(points[0]);
    for &point in &points[1..] {
        let last = cleaned.last_mut().unwrap();
        let dist = point_iso_distance(point, *last, iso_x, iso_y);
        if dist < 0.18 {
            last.time_ms = point.time_ms;
        } else {
            cleaned.push(point);
        }
    }
    if cleaned.len() >= 3 {
        let last = *cleaned.last().unwrap();
        while cleaned.len() >= 3 {
            let prev = cleaned[cleaned.len() - 2];
            if point_iso_distance(last, prev, iso_x, iso_y) < 0.30 {
                let idx = cleaned.len() - 2;
                cleaned[idx].time_ms = last.time_ms;
                cleaned.pop();
            } else {
                break;
            }
        }
    }
    cleaned
}

/// 在未折叠的原始轨迹上找出停留中心（在物理各向同性半径 `DWELL_RADIUS` 内停满 `DWELL_MS`），避免抖动折叠后时间跨段涂抹。
fn dwell_locations(points: &[GlidePoint], iso_x: f32, iso_y: f32) -> Vec<(f32, f32)> {
    let mut dwells = Vec::new();
    let mut start = 0;
    while start < points.len() {
        let Some(begin) = points[start].time_ms else {
            start += 1;
            continue;
        };
        let mut end = start;
        while end + 1 < points.len()
            && point_iso_distance(points[start], points[end + 1], iso_x, iso_y) <= DWELL_RADIUS
        {
            end += 1;
        }
        let rested = points[end]
            .time_ms
            .is_some_and(|stop| stop.saturating_sub(begin) >= DWELL_MS);
        if rested {
            let count = (end - start + 1) as f32;
            let (sx, sy) = points[start..=end]
                .iter()
                .fold((0.0f32, 0.0f32), |(ax, ay), p| (ax + p.x, ay + p.y));
            dwells.push((sx / count, sy / count));
            start = end + 1;
        } else {
            start += 1;
        }
    }
    dwells
}

/// 在未折叠的原始轨迹上找出相对整笔中位物理速度跌落到 `SLOW_SPEED_RATIO` 以下的减速谷空间中心。
fn slow_locations(points: &[GlidePoint], iso_x: f32, iso_y: f32) -> Vec<(f32, f32)> {
    if points.len() < 6 {
        return Vec::new();
    }
    let (Some(first_ms), Some(last_ms)) = (points[0].time_ms, points[points.len() - 1].time_ms)
    else {
        return Vec::new();
    };
    if last_ms.saturating_sub(first_ms) < 100 {
        return Vec::new();
    }
    let mut speeds = Vec::with_capacity(points.len());
    for i in 1..points.len() {
        let (Some(t0), Some(t1)) = (points[i - 1].time_ms, points[i].time_ms) else {
            continue;
        };
        let dt = t1.saturating_sub(t0);
        if dt > 0 {
            speeds.push(point_iso_distance(points[i - 1], points[i], iso_x, iso_y) / dt as f32);
        }
    }
    if speeds.len() < 4 {
        return Vec::new();
    }
    speeds.sort_by(f32::total_cmp);
    let threshold = speeds[speeds.len() / 2] * SLOW_SPEED_RATIO;
    if threshold <= 1e-6 {
        return Vec::new();
    }
    let mut slows = Vec::new();
    let mut start = 1;
    while start + 1 < points.len() {
        let Some(begin_ms) = points[start].time_ms else {
            start += 1;
            continue;
        };
        let mut end = start;
        while end + 2 < points.len() {
            let (Some(t0), Some(t1)) = (points[end].time_ms, points[end + 1].time_ms) else {
                break;
            };
            let dt = t1.saturating_sub(t0);
            let ds = point_iso_distance(points[end], points[end + 1], iso_x, iso_y);
            if dt > 0 && (ds / dt as f32) <= threshold {
                end += 1;
            } else {
                break;
            }
        }
        let duration = points[end]
            .time_ms
            .map_or(0, |stop| stop.saturating_sub(begin_ms));
        if end > start && duration >= SLOW_WINDOW_MS && duration < DWELL_MS {
            let count = (end - start + 1) as f32;
            let (sx, sy) = points[start..=end]
                .iter()
                .fold((0.0f32, 0.0f32), |(ax, ay), p| (ax + p.x, ay + p.y));
            slows.push((sx / count, sy / count));
            start = end + 1;
        } else {
            start += 1;
        }
    }
    slows
}

/// 在物理等距采样点上做 ±3 步真实屏幕弦角拐点检测与 ±3 邻域非极大值抑制，每个真实急转只标 1 个峰值采样。
fn mark_corners(
    samples: &mut [Sample],
    head: (f32, f32),
    tail: (f32, f32),
    iso_x: f32,
    iso_y: f32,
) {
    let n = samples.len();
    if n < 9 {
        return;
    }
    let mut sharpness = vec![0.0f32; n];
    for i in 3..(n - 3) {
        let s = samples[i];
        let d_head = iso_distance_xy(s.x, s.y, head.0, head.1, iso_x, iso_y);
        let d_tail = iso_distance_xy(s.x, s.y, tail.0, tail.1, iso_x, iso_y);
        if d_head <= ENDPOINT_EXEMPT_RADIUS || d_tail <= ENDPOINT_EXEMPT_RADIUS {
            continue;
        }
        let ax = (s.x - samples[i - 3].x) * iso_x;
        let ay = (s.y - samples[i - 3].y) * iso_y;
        let bx = (samples[i + 3].x - s.x) * iso_x;
        let by = (samples[i + 3].y - s.y) * iso_y;
        let la = ax.hypot(ay);
        let lb = bx.hypot(by);
        if la < 0.35 || lb < 0.35 {
            continue;
        }
        let cos = ((ax * bx + ay * by) / (la * lb)).clamp(-1.0, 1.0);
        if cos <= CORNER_COS {
            sharpness[i] = 1.0 - cos;
        }
    }
    for i in 3..(n - 3) {
        let score = sharpness[i];
        if score <= 0.0 {
            continue;
        }
        let lo = i.saturating_sub(3);
        let hi = (i + 3).min(n - 1);
        let is_peak = (lo..=hi)
            .all(|j| j == i || sharpness[j] < score || (sharpness[j] == score && j > i));
        if is_peak {
            samples[i].corner = true;
        }
    }
}

fn resample(trimmed: &[GlidePoint], iso_x: f32, iso_y: f32) -> Vec<Sample> {
    let collapsed = collapse_stationary_jitter(trimmed, iso_x, iso_y);
    if collapsed.len() < 2 {
        return Vec::new();
    }
    let mut cumulative = Vec::with_capacity(collapsed.len());
    cumulative.push(0.0f32);
    for pair in collapsed.windows(2) {
        let step = point_iso_distance(pair[0], pair[1], iso_x, iso_y);
        cumulative.push(cumulative.last().copied().unwrap_or(0.0) + step);
    }
    let total = *cumulative.last().unwrap_or(&0.0);
    if total < 0.35 {
        return Vec::new();
    }
    let count = ((total / STEP).ceil() as usize + 1).clamp(2, MAX_SAMPLES);
    let mut samples = Vec::with_capacity(count);
    let mut seg = 0usize;
    for i in 0..count {
        let target = total * (i as f32) / ((count - 1) as f32);
        while seg + 1 < cumulative.len() - 1 && cumulative[seg + 1] < target {
            seg += 1;
        }
        let d0 = cumulative[seg];
        let d1 = cumulative[seg + 1];
        let t = if d1 > d0 {
            ((target - d0) / (d1 - d0)).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let p0 = collapsed[seg];
        let p1 = collapsed[seg + 1];
        let x = p0.x + (p1.x - p0.x) * t;
        let y = p0.y + (p1.y - p0.y) * t;
        samples.push(Sample {
            x,
            y,
            slow: false,
            dwell: false,
            corner: false,
        });
    }

    if count >= 5 {
        let head = (collapsed[0].x, collapsed[0].y);
        let tail = (
            collapsed[collapsed.len() - 1].x,
            collapsed[collapsed.len() - 1].y,
        );
        let max_interior = count - 3;
        let nearest_interior = |x: f32, y: f32, list: &[Sample]| -> Option<usize> {
            let d_head = iso_distance_xy(x, y, head.0, head.1, iso_x, iso_y);
            let d_tail = iso_distance_xy(x, y, tail.0, tail.1, iso_x, iso_y);
            if d_head <= ENDPOINT_EXEMPT_RADIUS || d_tail <= ENDPOINT_EXEMPT_RADIUS {
                return None;
            }
            (2..=max_interior)
                .map(|i| (i, iso_distance_xy(list[i].x, list[i].y, x, y, iso_x, iso_y)))
                .min_by(|a, b| a.1.total_cmp(&b.1))
                .filter(|&(_, dist)| dist <= DWELL_RADIUS)
                .map(|(i, _)| i)
        };
        // 按物理坐标把原始停留与减速谷投射到最近内部采样点，首尾豁免半径内不触发虚假重键。
        for (dx, dy) in dwell_locations(trimmed, iso_x, iso_y) {
            if let Some(idx) = nearest_interior(dx, dy, &samples) {
                samples[idx].dwell = true;
            }
        }
        for (sx, sy) in slow_locations(trimmed, iso_x, iso_y) {
            if let Some(idx) = nearest_interior(sx, sy, &samples) {
                samples[idx].slow = true;
            }
        }
        mark_corners(&mut samples, head, tail, iso_x, iso_y);
    }
    samples
}

/// 检测起手键上是否出现主动回环/往复动作（物理弧长明显大于径向离起距离，排除直线滑过与微小电容抖动），
/// 用于区分用户刻意在首键上重键起滑（如 `2(回环)→4` 打 `cai`）与直接直线滑行（`2→4`）。
fn detect_start_key_repeat(trimmed: &[GlidePoint], iso_x: f32, iso_y: f32) -> bool {
    if trimmed.len() < 4 {
        return false;
    }
    let head = trimmed[0];
    let mut local_arc = 0.0f32;
    let mut max_r = 0.0f32;
    let mut prev = head;
    for &p in &trimmed[1..] {
        let r = point_iso_distance(head, p, iso_x, iso_y);
        if r > 0.55 {
            break;
        }
        let seg = point_iso_distance(prev, p, iso_x, iso_y);
        if seg >= 0.14 {
            local_arc += seg;
            prev = p;
        }
        if r > max_r {
            max_r = r;
        }
    }
    max_r >= 0.16 && local_arc >= 0.45 && local_arc >= max_r * 1.8
}

/// 检测末键上是否出现主动回环/往复动作（如 `2→4` 在 `4` 上描小环打 `chi = 244`）：
/// 先按 `0.20` 物理单位滤除末键停顿的微小电容抖动，避免抬手前原地微晃误触发尾键重键。
fn detect_end_key_repeat(trimmed: &[GlidePoint], iso_x: f32, iso_y: f32) -> bool {
    if trimmed.len() < 5 {
        return false;
    }
    let tail = trimmed[trimmed.len() - 1];
    let mut local_arc = 0.0f32;
    let mut max_r = 0.0f32;
    let mut prev = tail;
    let mut steps = 0usize;
    for &p in trimmed[..trimmed.len() - 1].iter().rev() {
        let r = point_iso_distance(tail, p, iso_x, iso_y);
        if r > 0.58 {
            break;
        }
        let seg = point_iso_distance(prev, p, iso_x, iso_y);
        if seg >= 0.20 {
            local_arc += seg;
            prev = p;
            steps += 1;
        }
        if r > max_r {
            max_r = r;
        }
    }
    steps >= 3 && max_r >= 0.22 && local_arc >= 0.65 && local_arc >= max_r * 2.1
}

/// 音节 DP 复用缓冲：整笔束搜索共用一份，消除内层循环数万次堆分配。
struct MatchScratch {
    dp: [f32; MAX_SAMPLES],
    next_dp: [f32; MAX_SAMPLES],
    active: Vec<usize>,
    next_active: Vec<usize>,
    results: Vec<(usize, f32)>,
}

impl MatchScratch {
    fn new() -> Self {
        Self {
            dp: [f32::INFINITY; MAX_SAMPLES],
            next_dp: [f32::INFINITY; MAX_SAMPLES],
            active: Vec::with_capacity(24),
            next_active: Vec::with_capacity(24),
            results: Vec::with_capacity(24),
        }
    }
}

struct NineKeyDecoder {
    count: usize,
    samples: Vec<Sample>,
    align: [Vec<f32>; 8],
    reach: [Vec<usize>; 8],
    /// 各键可达的最后采样点下标，O(1) 排除已过期的后续键。
    max_reach: [Option<usize>; 8],
    /// 整笔轨迹可达的全部键位掩码。
    present_mask: u8,
    /// `future_mask[t]` 为在采样点 `> t` 上仍可达的键位掩码，供束搜索 O(1) 跳过不可达音节。
    future_mask: Vec<u8>,
    /// 起点（sample 0）与终点（last_sample）的收紧可达掩码，避免正中起滑时误扩散到四邻键。
    start_mask: u8,
    end_mask: u8,
    /// 起手键上检测到主动回环/折返手势时为真，偏好首两位同键音节（如 `224`/`226`/`334`）。
    has_start_repeat: bool,
    /// 末键上检测到主动回环/折返手势时为真，偏好末两位同键音节（如 `244`/`744`/`944`/`33`）。
    has_end_repeat: bool,
    /// `lines[from * 8 + to]` 存从 `from` 到 `to` 线段的前缀代价和（长度 `count`）。
    lines: Vec<Vec<f32>>,
}

impl NineKeyDecoder {
    fn new(
        centers: [(f32, f32); 8],
        samples: Vec<Sample>,
        iso_x: f32,
        iso_y: f32,
        has_start_repeat: bool,
        has_end_repeat: bool,
    ) -> Self {
        let count = samples.len();
        let last = count - 1;
        let aspect = (iso_x / iso_y).max(1.0);
        // 宽扁九键（`80×49pt`）纵向略窄，对 `align` 纵向偏心给温和阻尼（约 0.84），避免 49pt 键高上的微抖惩罚过重，同时保持相邻行中心判别力。
        let y_align_scale = (1.0 / aspect.powf(0.35)).clamp(0.82, 1.0);
        let mut align: [Vec<f32>; 8] = Default::default();
        let mut reach: [Vec<usize>; 8] = Default::default();
        let mut max_reach = [None; 8];
        let mut present_mask = 0u8;
        let mut start_mask = 0u8;
        let mut end_mask = 0u8;
        for k in 0..8 {
            let (cx, cy) = centers[k];
            let mut a = Vec::with_capacity(count);
            let mut r = Vec::new();
            for (i, s) in samples.iter().enumerate() {
                let dx = s.x - cx;
                let dy = s.y - cy;
                let cell_d = dx.hypot(dy);
                let align_d_sq = dx * dx + (dy * y_align_scale) * (dy * y_align_scale);
                a.push(align_d_sq * ALIGN_WEIGHT);
                if cell_d <= REACH {
                    r.push(i);
                }
                if i == 0 && cell_d <= ENDPOINT_REACH {
                    start_mask |= 1u8 << k;
                }
                if i == last && cell_d <= ENDPOINT_REACH {
                    end_mask |= 1u8 << k;
                }
            }
            if let Some(&last_t) = r.last() {
                max_reach[k] = Some(last_t);
                present_mask |= 1u8 << k;
            }
            align[k] = a;
            reach[k] = r;
        }
        // 起止点落在键缝较远处时自动回退到宽松半径 `REACH`。
        if start_mask == 0 {
            for k in 0..8 {
                if reach[k].first() == Some(&0) {
                    start_mask |= 1u8 << k;
                }
            }
        }
        if end_mask == 0 {
            for k in 0..8 {
                if reach[k].last() == Some(&last) {
                    end_mask |= 1u8 << k;
                }
            }
        }

        let mut future_mask = vec![0u8; count];
        for (t, slot) in future_mask.iter_mut().enumerate() {
            let mut mask = 0u8;
            for (k, &mr) in max_reach.iter().enumerate() {
                if mr.is_some_and(|max_t| max_t > t) {
                    mask |= 1u8 << k;
                }
            }
            *slot = mask;
        }

        // 按物理各向同性实际步长归一化连线代价，确保超长轨迹触及 MAX_SAMPLES 抽稀时几何尺度不变。
        let arc_length: f32 = samples
            .windows(2)
            .map(|pair| iso_distance_xy(pair[0].x, pair[0].y, pair[1].x, pair[1].y, iso_x, iso_y))
            .sum();
        let line_scale = if count > 1 && arc_length > 0.0 {
            (arc_length / (count - 1) as f32 / STEP).max(0.5)
        } else {
            1.0
        };
        let mut lines = vec![Vec::new(); 64];
        for from in 0..8 {
            if reach[from].is_empty() {
                continue;
            }
            for to in 0..8 {
                if from == to || reach[to].is_empty() {
                    continue;
                }
                let (ax, ay) = centers[from];
                let (bx, by) = centers[to];
                let dx = (bx - ax) * iso_x;
                let dy = (by - ay) * iso_y;
                let len_sq = (dx * dx + dy * dy).max(1e-6);
                let len = len_sq.sqrt();
                let mut prefix = Vec::with_capacity(count);
                let mut acc = 0.0f32;
                let mut prev_proj = 0.0f32;
                for (i, s) in samples.iter().enumerate() {
                    let vx = (s.x - ax) * iso_x;
                    let vy = (s.y - ay) * iso_y;
                    let proj = ((vx * dx + vy * dy) / len_sq).clamp(0.0, 1.0);
                    let perp_x = vx - dx * proj;
                    let perp_y = vy - dy * proj;
                    let dist = perp_x.hypot(perp_y);
                    let mut step_cost = dist * LINE_WEIGHT * line_scale;
                    if i > 0 {
                        let backtrack = (prev_proj - proj).max(0.0) * len;
                        step_cost += backtrack * BACKTRACK_COST;
                    }
                    prev_proj = proj;
                    if s.dwell {
                        step_cost += SKIPPED_DWELL_COST;
                    } else if s.slow {
                        step_cost += SKIPPED_SLOW_COST;
                    }
                    if s.corner {
                        step_cost += SKIPPED_CORNER_COST;
                    }
                    acc += step_cost;
                    prefix.push(acc);
                }
                lines[from * 8 + to] = prefix;
            }
        }

        Self {
            count,
            samples,
            align,
            reach,
            max_reach,
            present_mask,
            future_mask,
            start_mask,
            end_mask,
            has_start_repeat,
            has_end_repeat,
            lines,
        }
    }

    #[inline]
    fn segment_cost(&self, from: usize, to: usize, a: usize, b: usize) -> f32 {
        if a >= b {
            return 0.0;
        }
        let line = &self.lines[from * 8 + to];
        if line.is_empty() || b <= a + 1 {
            return 0.0;
        }
        (line[b - 1] - line[a]).max(0.0)
    }

    /// 计算从状态 `(prev_key, start_at)` 匹配整个音节 `syl` 到各可达末采样点的最优增量代价。
    /// 全程复用 `scratch` 零堆分配，返回至多 3 条 `(end_sample, delta_cost)` 及其有效条数。
    fn match_syllable(
        &self,
        syl: &DigitSyllable,
        prev_key: Option<usize>,
        start_at: usize,
        scratch: &mut MatchScratch,
    ) -> ([(usize, f32); 3], usize) {
        let mut kept = [(0usize, 0.0f32); 3];
        let first_key = usize::from(syl.keys[0]);
        scratch.active.clear();

        match prev_key {
            None => {
                // 笔画起点必须从 sample 0 开始。
                if self.reach[first_key].first() != Some(&0) {
                    return (kept, 0);
                }
                scratch.dp[0] = self.align[first_key][0];
                scratch.active.push(0);
            }
            Some(pk) if pk == first_key => {
                // 音节边界同键连字（如 `ni|hao = 64|426`）：允许停在同一采样点零位移续接。
                let repeat_cost = if self.samples[start_at].dwell {
                    0.0
                } else {
                    BOUNDARY_REPEAT_COST
                };
                scratch.dp[start_at] = repeat_cost;
                scratch.active.push(start_at);
            }
            Some(pk) => {
                let first_reach = &self.reach[first_key];
                let start_idx = first_reach.partition_point(|&t| t <= start_at);
                for &t in &first_reach[start_idx..] {
                    let cost = self.segment_cost(pk, first_key, start_at, t)
                        + self.align[first_key][t];
                    if cost < scratch.dp[t] {
                        scratch.dp[t] = cost;
                        scratch.active.push(t);
                    }
                }
            }
        }

        if scratch.active.is_empty() {
            return (kept, 0);
        }

        let mut from_key = first_key;
        for &next_key_u8 in &syl.keys[1..] {
            let to_key = usize::from(next_key_u8);
            scratch.next_active.clear();
            let min_prev = scratch.active[0];
            let to_reach = &self.reach[to_key];
            let reach_start = to_reach.partition_point(|&t| t <= min_prev);
            for &t in &to_reach[reach_start..] {
                let mut best = f32::INFINITY;
                for &prev_t in &scratch.active {
                    if prev_t >= t {
                        break;
                    }
                    let prev_cost = scratch.dp[prev_t];
                    if !prev_cost.is_finite() {
                        continue;
                    }
                    let cand = prev_cost
                        + self.segment_cost(from_key, to_key, prev_t, t)
                        + self.align[to_key][t];
                    if cand < best {
                        best = cand;
                    }
                }
                if best.is_finite() {
                    scratch.next_dp[t] = best;
                    scratch.next_active.push(t);
                }
            }
            for &idx in &scratch.active {
                scratch.dp[idx] = f32::INFINITY;
            }
            std::mem::swap(&mut scratch.dp, &mut scratch.next_dp);
            std::mem::swap(&mut scratch.active, &mut scratch.next_active);
            if scratch.active.is_empty() {
                return (kept, 0);
            }
            from_key = to_key;
        }

        let repeat_penalty = if syl.has_repeat {
            let had_dwell = scratch
                .active
                .iter()
                .any(|&t| self.samples[t].dwell || self.samples[t].slow);
            if had_dwell {
                0.0
            } else {
                INTRA_REPEAT_COST
            }
        } else {
            0.0
        };
        let start_repeat_bonus =
            if prev_key.is_none() && self.has_start_repeat && syl.starts_with_repeat {
                START_REPEAT_LOOP_BONUS
            } else {
                0.0
            };
        let allow_end_repeat_bonus = self.has_end_repeat
            && syl.ends_with_repeat
            && !(prev_key.is_none() && syl.keys.len() == 1 && self.has_start_repeat);
        let extra = SYLLABLE_COST + syl.prior_penalty + repeat_penalty - start_repeat_bonus;

        let last_sample = self.count - 1;
        scratch.results.clear();
        for &t in &scratch.active {
            let c = scratch.dp[t];
            scratch.dp[t] = f32::INFINITY;
            if c.is_finite() {
                let end_bonus = if allow_end_repeat_bonus && t == last_sample {
                    END_REPEAT_LOOP_BONUS
                } else {
                    0.0
                };
                scratch.results.push((t, c + extra - end_bonus));
            }
        }
        // 总是保留落在终点的项，再按代价取前 2 个中间转移点，避免同一音节在相邻采样点产生冗余重复状态。
        scratch.results.sort_by(|a, b| a.1.total_cmp(&b.1));
        let mut kept_len = 0usize;
        let mut non_terminal = 0usize;
        for &(t, cost) in &scratch.results {
            if kept_len == 3 {
                break;
            }
            if kept[..kept_len].iter().any(|&(existing, _)| existing == t) {
                continue;
            }
            if t == last_sample {
                kept[kept_len] = (t, cost);
                kept_len += 1;
            } else if non_terminal < 2 {
                kept[kept_len] = (t, cost);
                kept_len += 1;
                non_terminal += 1;
            }
        }
        (kept, kept_len)
    }
}

#[derive(Clone)]
struct NineKeyHypothesis {
    digits: String,
    syllable_ids: Vec<u16>,
    geom_cost: f32,
}

#[derive(Clone, Copy)]
struct BeamState {
    syllable_ids: [u16; MAX_SYLLABLES],
    len: u8,
    last_key: usize,
    sample_at: usize,
    cost: f32,
}

impl BeamState {
    #[inline]
    fn from_first(syl_id: u16, last_key: usize, sample_at: usize, cost: f32) -> Self {
        let mut syllable_ids = [0u16; MAX_SYLLABLES];
        syllable_ids[0] = syl_id;
        Self {
            syllable_ids,
            len: 1,
            last_key,
            sample_at,
            cost,
        }
    }

    #[inline]
    fn extended(&self, syl_id: u16, last_key: usize, sample_at: usize, cost: f32) -> Self {
        let mut syllable_ids = self.syllable_ids;
        let idx = usize::from(self.len);
        syllable_ids[idx] = syl_id;
        Self {
            syllable_ids,
            len: self.len + 1,
            last_key,
            sample_at,
            cost,
        }
    }

    #[inline]
    fn ids(&self) -> &[u16] {
        &self.syllable_ids[..usize::from(self.len)]
    }
}

/// 从 `GlideKeyboard` 的 26 字母槽还原九键 2–9 八个数字键的归一化中心坐标。
fn extract_nine_key_centers(keyboard: &GlideKeyboard) -> Option<[(f32, f32); 8]> {
    if !keyboard.is_valid() {
        return None;
    }
    let mut centers = [(0.0f32, 0.0f32); 8];
    for (i, &rep) in DIGIT_REP_INDICES.iter().enumerate() {
        let (x, y) = keyboard.centers[rep];
        centers[i] = (x / keyboard.key_width, y / keyboard.key_height);
    }
    // 确认至少存在两个明显分离的数字键中心，避免误把未初始化或退化键盘送进解码。
    let mut min_x = f32::INFINITY;
    let mut max_x = f32::NEG_INFINITY;
    let mut min_y = f32::INFINITY;
    let mut max_y = f32::NEG_INFINITY;
    for &(x, y) in &centers {
        min_x = min_x.min(x);
        max_x = max_x.max(x);
        min_y = min_y.min(y);
        max_y = max_y.max(y);
    }
    if (max_x - min_x) < 1.0 && (max_y - min_y) < 1.0 {
        return None;
    }
    Some(centers)
}

fn decode_nine_key_hypotheses(
    keyboard: &GlideKeyboard,
    points: &[GlidePoint],
    config: DecodeConfig,
) -> Vec<NineKeyHypothesis> {
    if points.len() < 2
        || points
            .iter()
            .any(|p| !p.x.is_finite() || !p.y.is_finite())
    {
        return Vec::new();
    }
    let Some(centers) = extract_nine_key_centers(keyboard) else {
        return Vec::new();
    };
    let (iso_x, iso_y) = iso_scales(keyboard);
    let normalized_points: Vec<GlidePoint> = points
        .iter()
        .map(|p| GlidePoint {
            x: p.x / keyboard.key_width,
            y: p.y / keyboard.key_height,
            time_ms: p.time_ms,
        })
        .collect();
    // 先在未裁回勾的轨迹上识别末键主动回环（避免 `trim_liftoff_hook` 把回环收口误当离屏回勾裁掉）；
    // 确认无末键回环后再做离屏回勾裁剪。
    let has_end_repeat = detect_end_key_repeat(&normalized_points, iso_x, iso_y);
    let trimmed = if has_end_repeat {
        normalized_points.as_slice()
    } else {
        trim_liftoff_hook(&normalized_points, iso_x, iso_y)
    };
    let has_start_repeat = detect_start_key_repeat(trimmed, iso_x, iso_y);
    let samples = resample(trimmed, iso_x, iso_y);
    if samples.len() < 2 {
        return Vec::new();
    }

    let decoder = NineKeyDecoder::new(
        centers,
        samples,
        iso_x,
        iso_y,
        has_start_repeat,
        has_end_repeat,
    );
    let last_sample = decoder.count - 1;
    let table = syllable_table();
    let mut scratch = MatchScratch::new();

    let mut beam: Vec<BeamState> = Vec::with_capacity(config.beam_width);
    let mut next_beam: Vec<BeamState> = Vec::with_capacity(config.beam_width);
    let mut completed: Vec<NineKeyHypothesis> = Vec::new();

    // 第 1 个音节：只从 sample 0 可达的键位起滑，并用 `present_mask` O(1) 跳过轨迹未触达的音节。
    let present_mask = decoder.present_mask;
    for first_key in 0..8 {
        if (decoder.start_mask & (1u8 << first_key)) == 0 {
            continue;
        }
        for &syl_id in &table.by_first_key[first_key] {
            let syl = &table.syllables[usize::from(syl_id)];
            if (syl.key_mask & !present_mask) != 0 {
                continue;
            }
            // 单键单音节（如 a=2, e=3）不能仅靠起手就消费整笔长滑动，除非笔画真停在该键或后续继续延伸。
            let end_key = usize::from(*syl.keys.last().unwrap());
            let (matches, match_count) = decoder.match_syllable(syl, None, 0, &mut scratch);
            for &(end_at, cost) in &matches[..match_count] {
                if end_at == last_sample {
                    // 单笔必须至少跨过两个键或匹配带重键的多位数字音节，且末键在收紧终点半径内。
                    if (syl.keys.len() >= 2 || syl.digits.len() >= 2)
                        && (decoder.end_mask & (1u8 << end_key)) != 0
                    {
                        completed.push(NineKeyHypothesis {
                            digits: String::from_utf8_lossy(&syl.digits).into_owned(),
                            syllable_ids: vec![syl_id],
                            geom_cost: cost,
                        });
                    }
                } else {
                    beam.push(BeamState::from_first(syl_id, end_key, end_at, cost));
                }
            }
        }
    }

    prune_beam(&mut beam, decoder.count, config);

    for _step in 1..MAX_SYLLABLES {
        if beam.is_empty() {
            break;
        }
        next_beam.clear();
        for &state in &beam {
            let future_mask = decoder.future_mask[state.sample_at];
            // 从当前状态扩展下一个音节：允许从同一键续接（边界同键连字）或滑向任意后续可达键。
            for next_first in 0..8 {
                let same_key = next_first == state.last_key;
                if !same_key
                    && decoder.max_reach[next_first].is_none_or(|max_t| max_t <= state.sample_at)
                {
                    continue;
                }
                for &syl_id in &table.by_first_key[next_first] {
                    let syl = &table.syllables[usize::from(syl_id)];
                    // 连续两个 1 键单字母音节（如 `e'e`）几乎不构成真实词组，跳过减噪。
                    if syl.keys.len() == 1 && same_key {
                        continue;
                    }
                    let needed_mask = if same_key {
                        syl.tail_key_mask
                    } else {
                        syl.key_mask
                    };
                    if (needed_mask & !future_mask) != 0 {
                        continue;
                    }
                    let end_key = usize::from(*syl.keys.last().unwrap());
                    let (matches, match_count) = decoder.match_syllable(
                        syl,
                        Some(state.last_key),
                        state.sample_at,
                        &mut scratch,
                    );
                    for &(end_at, delta) in &matches[..match_count] {
                        let total_cost = state.cost + delta;
                        let extended = state.extended(syl_id, end_key, end_at, total_cost);
                        if end_at == last_sample {
                            if (decoder.end_mask & (1u8 << end_key)) == 0 {
                                continue;
                            }
                            let ids = extended.ids();
                            let mut digits = String::with_capacity(ids.len() * 4);
                            for &id in ids {
                                digits.push_str(
                                    std::str::from_utf8(&table.syllables[usize::from(id)].digits)
                                        .unwrap_or(""),
                                );
                            }
                            completed.push(NineKeyHypothesis {
                                digits,
                                syllable_ids: ids.to_vec(),
                                geom_cost: total_cost,
                            });
                        } else if end_at > state.sample_at {
                            next_beam.push(extended);
                        }
                    }
                }
            }
        }
        prune_beam(&mut next_beam, decoder.count, config);
        std::mem::swap(&mut beam, &mut next_beam);
    }

    completed.sort_by(|a, b| {
        a.geom_cost
            .total_cmp(&b.geom_cost)
            .then_with(|| a.digits.cmp(&b.digits))
    });
    let mut deduped = Vec::with_capacity(config.hypothesis_limit);
    let mut seen: HashSet<String> = HashSet::new();
    for hyp in completed {
        if seen.insert(hyp.digits.clone()) {
            deduped.push(hyp);
            if deduped.len() == config.hypothesis_limit {
                break;
            }
        }
    }
    deduped
}

/// 先按 `(last_key, len, syllable_ids)` 零分配全局去重（同一音节串只保留最优采样落点），再按采样进度 `sample_at` 分桶剪枝，
/// 避免同一音节串在相邻采样点占满多个桶，也避免短音节挤掉走得更远的长音节（如 `shen`/`shang`/`zhong`）。
fn prune_beam(beam: &mut Vec<BeamState>, sample_count: usize, config: DecodeConfig) {
    if beam.is_empty() {
        return;
    }
    beam.sort_by(|a, b| a.cost.total_cmp(&b.cost));
    let mut best_by_path: HashSet<(usize, u8, [u16; MAX_SYLLABLES])> =
        HashSet::with_capacity(beam.len().min(config.beam_width * 2));
    let mut buckets: Vec<Vec<BeamState>> = (0..sample_count).map(|_| Vec::new()).collect();
    for state in beam.drain(..) {
        if state.sample_at < sample_count
            && best_by_path.insert((state.last_key, state.len, state.syllable_ids))
        {
            buckets[state.sample_at].push(state);
        }
    }
    for bucket in &mut buckets {
        if bucket.is_empty() {
            continue;
        }
        let floor = bucket[0].cost;
        bucket.retain(|state| state.cost <= floor + 6.0);
        bucket.truncate(config.tokens_per_sample);
    }
    // 逆向从高进度采样桶往回轮询，优先保住已经推进更远的多音节前缀（如 3–4 字词），避免早期短采样桶吃光配额。
    let mut kept = Vec::with_capacity(config.beam_width);
    for rank in 0..config.tokens_per_sample {
        for bucket in buckets.iter().rev() {
            if rank < bucket.len() {
                kept.push(bucket[rank]);
                if kept.len() == config.beam_width {
                    *beam = kept;
                    return;
                }
            }
        }
    }
    *beam = kept;
}

/// 为每条数字假设按「各槽读音名次和」升序展开高频音节序列（上限 `output_limit` 条），供词典单次批量查权与组合词分段打分。
/// 相比按槽顺序截断，按名次和排序可确保 `mei'guan'xi`（`xi` 在 `94` 上排第 3）、`zao'shang'hao`（`zao` 在 `926` 上排第 5）等组合不会被前面的低频笛卡尔积挤掉。
fn expand_pinyin_sequences(
    syllable_ids: &[u16],
    table: &DigitSyllableTable,
    output_limit: usize,
) -> Vec<Vec<&'static str>> {
    let per_slot = match syllable_ids.len() {
        1 => 6,
        2 => 6,
        3 => 5,
        _ => 4,
    };
    let expand_beam = (output_limit * 3).max(48);
    let mut current: Vec<(u16, Vec<&'static str>)> = vec![(0, Vec::with_capacity(syllable_ids.len()))];
    for &id in syllable_ids {
        let readings = &table.syllables[usize::from(id)].readings;
        let mut next: Vec<(u16, Vec<&'static str>)> = Vec::new();
        for (rank_sum, prefix) in &current {
            for (r_idx, &r) in readings.iter().take(per_slot).enumerate() {
                let mut seq = Vec::with_capacity(prefix.len() + 1);
                seq.extend_from_slice(prefix);
                seq.push(r);
                next.push((*rank_sum + r_idx as u16, seq));
            }
        }
        if next.len() > expand_beam {
            next.sort_by_key(|(sum, _)| *sum);
            next.truncate(expand_beam);
        }
        current = next;
    }
    current.sort_by_key(|(sum, _)| *sum);
    current.truncate(output_limit);
    current.into_iter().map(|(_, seq)| seq).collect()
}

/// 评估一条音节序列的词典匹配惩罚：
/// - 整词命中词典时按批内相对对数权重计分，并按音节数给予温和多音节整词加分；
/// - 连续滑行存在未确认前缀音节时，若「前缀 + 本笔音节」构成词库高频整词（如 `wo` + `men` -> `我们`、`bu` + `zhi'dao` -> `不知道`），给予跨笔整词加分；
/// - 未命中整词的多音节组合短语（如 `wo'qu`「我去」、`ni'chi`「你吃」）改用二元/单音节最优分段 DP 打分，避免被 3.5 的生僻词悬崖误杀。
fn score_sequence_dictionary(
    seq: &[&str],
    weights: &HashMap<String, i64>,
    max_weight: f64,
    prefix_tails: &[String],
) -> (f32, Option<String>, i64) {
    let n = seq.len();
    let full_key = seq.join("'");

    // 若存在连滑前缀音节，先检查跨笔整词权重，供整词命中与分段路径共同享用。
    let mut best_cross_weight = 0i64;
    if !prefix_tails.is_empty() && n <= 3 {
        for tail in prefix_tails {
            let tail_syls = tail.bytes().filter(|&b| b == b'\'').count() + 1;
            if tail_syls + n > 4 {
                continue;
            }
            let combined = format!("{tail}'{full_key}");
            if let Some(&w) = weights.get(&combined) {
                if w > best_cross_weight {
                    best_cross_weight = w;
                }
            }
        }
    }

    let apply_cross_bonus = |base_pen: f32| -> f32 {
        if best_cross_weight <= 0 {
            return base_pen;
        }
        let combined_rel =
            ((max_weight / best_cross_weight as f64).ln() as f32 * 0.42).clamp(0.0, 3.5);
        let bonus = (CROSS_STROKE_MAX_BONUS - combined_rel * 0.28)
            .clamp(CROSS_STROKE_MIN_BONUS, CROSS_STROKE_MAX_BONUS);
        (base_pen - bonus).min(combined_rel - 1.05)
    };

    if let Some(&w) = weights.get(&full_key) {
        if w > 0 {
            let rel = ((max_weight / w as f64).ln() as f32 * 0.42).clamp(0.0, 3.5);
            let phrase_bonus = if n >= 2 {
                1.05 * ((n - 1).min(3) as f32)
            } else {
                0.0
            };
            let eff_w = w.max(best_cross_weight);
            return (apply_cross_bonus(rel - phrase_bonus), Some(full_key), eff_w);
        }
    }
    if n < 2 {
        if best_cross_weight > 0 {
            return (apply_cross_bonus(3.5), Some(full_key), best_cross_weight);
        }
        return (3.5, None, 0);
    }
    // 组合词分段 DP（每步可取单音节或相邻二元词组）。
    let mut dp = vec![f32::INFINITY; n + 1];
    dp[0] = 0.0;
    let inv_n = 1.0 / n as f32;
    for pos in 0..n {
        if !dp[pos].is_finite() {
            continue;
        }
        let break_pen = if pos > 0 {
            COMPOSITIONAL_BREAK_COST
        } else {
            0.0
        };
        if let Some(&w) = weights.get(seq[pos]) {
            if w > 0 {
                let rel = ((max_weight / w as f64).ln() as f32 * 0.42).clamp(0.0, 3.5);
                let cand = dp[pos] + rel * inv_n + break_pen;
                if cand < dp[pos + 1] {
                    dp[pos + 1] = cand;
                }
            }
        }
        if pos + 2 <= n {
            let bigram = format!("{}'{}", seq[pos], seq[pos + 1]);
            if let Some(&w) = weights.get(&bigram) {
                if w > 0 {
                    let rel = ((max_weight / w as f64).ln() as f32 * 0.42).clamp(0.0, 3.5);
                    let cand =
                        dp[pos] + rel * (2.0 * inv_n) + break_pen - COMPOSITIONAL_BIGRAM_BONUS;
                    if cand < dp[pos + 2] {
                        dp[pos + 2] = cand;
                    }
                }
            }
        }
    }
    let base_pen = if dp[n].is_finite() { dp[n] } else { 3.5 };
    let pen = apply_cross_bonus(base_pen);
    if best_cross_weight > 0 {
        (pen, Some(full_key), best_cross_weight)
    } else {
        (pen, None, 0)
    }
}

struct ScoredNineKeyHypothesis {
    digits: String,
    syllable_ids: Vec<u16>,
    score: f32,
    /// 该假设命中的全部整词拼音键及其权重（按权重降序，最多保留 4 条），避免像 `224 (cai/bai)`、`226 (ban/bao/can/cao)` 只保留一条而漏掉同键高频读音。
    top_full_keys: Vec<(String, i64)>,
    /// 该假设展开后的首条拼音序列（用于在无整词命中时回退作组合词预览读音）。
    fallback_reading: Option<String>,
}

/// 连续九键滑行时从当前未上屏组字提取的上下文：
/// - `extra_context`：当前首选中文词（传给 `best_weights_with_context` 触发二元语法/个人语境加权）；
/// - `prefix_tails`：末尾 1–2 个拼音音节（用于跨笔整词查权，如 `wo` + `men` -> `wo'men`）；
/// - `full_prefix_reading` / `prefix_word`：仅当当前首选完整覆盖已打数字时非空，供续滑次优整词安全合成与完整消费。
struct ActiveNineKeyContext {
    extra_context: Option<String>,
    prefix_tails: Vec<String>,
    full_prefix_reading: Option<String>,
    prefix_word: Option<String>,
}

struct ScoredGlideBatch {
    scored: Vec<ScoredNineKeyHypothesis>,
    weights: HashMap<String, i64>,
    max_weight: f64,
    context: ActiveNineKeyContext,
}

fn is_valid_pinyin_reading(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b == b'\'')
        && !s.starts_with('\'')
        && !s.ends_with('\'')
}

/// 从已排序的假设列表里筛出同路径相近次优读音键，供 `preview_glide` 与 `glide` 共用，保证拖动预览与抬手候选同序一致。
fn collect_secondary_runners(
    scored: &[ScoredNineKeyHypothesis],
    best_digits: &str,
    best_score: f32,
    max_weight: f64,
    limit: usize,
) -> Vec<(String, f32, f32)> {
    let mut runners: Vec<(String, f32, f32)> = Vec::new();
    for alt in scored.iter().skip(1) {
        if alt.digits == best_digits || alt.score > best_score + SECONDARY_SCORE_MARGIN {
            continue;
        }
        for (key, weight) in &alt.top_full_keys {
            let w = (*weight).max(1) as f64;
            let eff = alt.score + ((max_weight / w).ln() as f32 * 0.25).clamp(0.0, 2.0);
            if let Some(existing) = runners.iter_mut().find(|(k, _, _)| k == key) {
                if eff < existing.1 {
                    existing.1 = eff;
                    existing.2 = alt.score;
                }
            } else {
                runners.push((key.clone(), eff, alt.score));
            }
        }
    }
    runners.sort_by(|a, b| a.1.total_cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
    runners.truncate(limit);
    runners
}

impl NineKeySession {
    fn active_glide_context(&self) -> ActiveNineKeyContext {
        if !self.active() || self.caret_position() != self.digits.len() {
            return ActiveNineKeyContext {
                extra_context: None,
                prefix_tails: Vec::new(),
                full_prefix_reading: None,
                prefix_word: None,
            };
        }
        let first = self.candidates.first();
        let extra_context = first
            .map(|c| c.word.as_str())
            .filter(|w| !w.is_empty() && !w.is_ascii())
            .map(str::to_owned);

        let full_covered = first.is_some_and(|c| c.pinyin.len() == self.digits.len());
        let raw_reading = if is_valid_pinyin_reading(&self.reading) {
            Some(self.reading.clone())
        } else if let Some(cand) = first.filter(|c| is_valid_pinyin_reading(c.canonical_pinyin.as_str()))
        {
            Some(cand.canonical_pinyin.to_string())
        } else if !self.locked.is_empty() {
            let joined = self.locked.join("'");
            is_valid_pinyin_reading(&joined).then_some(joined)
        } else {
            None
        };

        let mut prefix_tails = Vec::with_capacity(2);
        if let Some(ref reading) = raw_reading {
            let syls: Vec<&str> = reading.split('\'').filter(|s| !s.is_empty()).collect();
            if syls.len() >= 2 {
                prefix_tails.push(format!("{}'{}", syls[syls.len() - 2], syls[syls.len() - 1]));
            }
            if let Some(&last) = syls.last() {
                prefix_tails.push(last.to_owned());
            }
        }

        let full_prefix_reading = if full_covered { raw_reading } else { None };
        let prefix_word = if full_covered {
            extra_context.clone()
        } else {
            None
        };
        ActiveNineKeyContext {
            extra_context,
            prefix_tails,
            full_prefix_reading,
            prefix_word,
        }
    }

    /// 统一执行「几何束搜索 + 展开拼音 + 含上下文/跨笔整词批量查权 + 假设打分排序」，供实时预览与抬手提交共用。
    fn score_glide_hypotheses(
        &mut self,
        keyboard: &GlideKeyboard,
        points: &[GlidePoint],
        config: DecodeConfig,
    ) -> Option<ScoredGlideBatch> {
        let hypotheses = decode_nine_key_hypotheses(keyboard, points, config);
        if hypotheses.is_empty() {
            return None;
        }
        let context = self.active_glide_context();
        let table = syllable_table();
        let mut seqs_per_hyp: Vec<Vec<Vec<&'static str>>> = Vec::with_capacity(hypotheses.len());
        let mut all_keys: Vec<String> = Vec::new();
        let mut unique_keys: HashSet<String> = HashSet::new();
        let mut push_key = |key: String| {
            if unique_keys.insert(key.clone()) {
                all_keys.push(key);
            }
        };
        for hyp in &hypotheses {
            let seqs = expand_pinyin_sequences(&hyp.syllable_ids, table, config.expand_output_limit);
            for seq in &seqs {
                let full_key = seq.join("'");
                if !context.prefix_tails.is_empty() && seq.len() <= 3 {
                    for tail in &context.prefix_tails {
                        let tail_syls = tail.bytes().filter(|&b| b == b'\'').count() + 1;
                        if tail_syls + seq.len() <= 4 {
                            push_key(format!("{tail}'{full_key}"));
                        }
                    }
                }
                push_key(full_key);
                if seq.len() >= 2 {
                    for &syl in seq {
                        push_key(syl.to_owned());
                    }
                    if seq.len() >= 3 {
                        for pair in seq.windows(2) {
                            push_key(format!("{}'{}", pair[0], pair[1]));
                        }
                    }
                }
            }
            seqs_per_hyp.push(seqs);
        }

        let options = self.dictionary_options();
        let paths = &self.paths;
        let rescoring_context = &self.rescoring_context;
        let dictionary = self
            .dictionary
            .get_or_insert_with(|| open_dictionary(paths, options));
        dictionary.set_rescoring_context(rescoring_context);
        let weights =
            dictionary.best_weights_with_context(&all_keys, context.extra_context.as_deref());
        let max_weight = weights.values().copied().max().unwrap_or(0).max(1) as f64;

        let mut scored: Vec<ScoredNineKeyHypothesis> = Vec::with_capacity(hypotheses.len());
        for (i, hyp) in hypotheses.into_iter().enumerate() {
            let mut best_dict_pen = 3.5f32;
            let mut top_full_keys: Vec<(String, i64)> = Vec::new();
            for seq in &seqs_per_hyp[i] {
                let (pen, full_key, full_w) =
                    score_sequence_dictionary(seq, &weights, max_weight, &context.prefix_tails);
                if pen < best_dict_pen {
                    best_dict_pen = pen;
                }
                if let Some(key) = full_key {
                    if let Some(existing) = top_full_keys.iter_mut().find(|(k, _)| k == &key) {
                        if full_w > existing.1 {
                            existing.1 = full_w;
                        }
                    } else {
                        top_full_keys.push((key, full_w));
                    }
                }
            }
            top_full_keys.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
            top_full_keys.truncate(4);
            let fallback_reading = seqs_per_hyp[i].first().map(|seq| seq.join("'"));
            scored.push(ScoredNineKeyHypothesis {
                digits: hyp.digits,
                syllable_ids: hyp.syllable_ids,
                score: hyp.geom_cost + best_dict_pen,
                top_full_keys,
                fallback_reading,
            });
        }
        scored.sort_by(|a, b| {
            a.score
                .total_cmp(&b.score)
                .then_with(|| a.digits.cmp(&b.digits))
        });

        Some(ScoredGlideBatch {
            scored,
            weights,
            max_weight,
            context,
        })
    }

    /// 只读实时预览九键滑行：解出最佳拼音串与前若干个中文候选，绝不改动当前正在进行的九键组字与锁定前缀。
    /// 与 `glide()` 共享上下文查权与同路径次优合并逻辑，确保拖动预览与抬手落字前排候选一致无跳变。
    pub fn preview_glide(
        &mut self,
        keyboard: &GlideKeyboard,
        points: &[GlidePoint],
    ) -> Option<(String, Vec<String>)> {
        if self.grid != KeyGrid::NineKey
            || self.english_only
            || !self.pinyin
            || self.helpcode.is_some()
        {
            return None;
        }
        let batch = self.score_glide_hypotheses(keyboard, points, DecodeConfig::PREVIEW)?;
        let best = batch.scored.first()?;
        let reading = best
            .top_full_keys
            .first()
            .map(|(k, _)| k.clone())
            .or_else(|| best.fallback_reading.clone())?;

        const PREVIEW_LIMIT: usize = 9;
        let runners = collect_secondary_runners(
            &batch.scored,
            &best.digits,
            best.score,
            batch.max_weight,
            3,
        );
        let prefix_reading = batch.context.full_prefix_reading.as_deref();
        let prefix_word = batch.context.prefix_word.as_deref();

        let mut query_keys: Vec<String> = Vec::new();
        let mut push_query = |key: String| {
            if !query_keys.iter().any(|existing| existing == &key) {
                query_keys.push(key);
            }
        };
        if let Some(prefix_r) = prefix_reading {
            push_query(format!("{prefix_r}'{reading}"));
            for (k, _) in &best.top_full_keys {
                push_query(format!("{prefix_r}'{k}"));
            }
            for (k, _, _) in &runners {
                push_query(format!("{prefix_r}'{k}"));
            }
        }
        if best.top_full_keys.len() > 1 {
            for (k, _) in &best.top_full_keys {
                push_query(k.clone());
            }
        }
        for (k, _, _) in &runners {
            push_query(k.clone());
        }

        let options = self.dictionary_options();
        let paths = &self.paths;
        let dictionary = self
            .dictionary
            .get_or_insert_with(|| open_dictionary(paths, options));
        let exact_map = if query_keys.is_empty() {
            HashMap::new()
        } else {
            dictionary.exact_rows_for_keys(&query_keys, 3)
        };

        // 先构造本笔滑行自身的主/次优词表，再按是否处于连续滑行态无缝拼接前缀整词或组合词，确保拖动预览与抬手落字零跳变。
        let mut stroke_words = Vec::with_capacity(PREVIEW_LIMIT);
        if best.top_full_keys.len() > 1 {
            // 同一数字串含多读音时（如 `24` -> `bi/ci/ai`），按词频合并展示，与 `NineKeySession::refresh` 首屏一致。
            let mut primary_rows = Vec::new();
            for (k, _) in &best.top_full_keys {
                if let Some(rows) = exact_map.get(k) {
                    primary_rows.extend(rows.iter());
                }
            }
            primary_rows.sort_by(|a, b| b.weight.cmp(&a.weight).then_with(|| a.value.cmp(&b.value)));
            for row in primary_rows {
                if !stroke_words.iter().any(|w: &String| w == &row.value) {
                    stroke_words.push(row.value.clone());
                    if stroke_words.len() >= PREVIEW_LIMIT {
                        break;
                    }
                }
            }
        }
        if stroke_words.len() < PREVIEW_LIMIT {
            let span: Vec<String> = reading.split('\'').map(str::to_owned).collect();
            let rows = dictionary.conversion_rows(&span, PREVIEW_LIMIT);
            for row in rows {
                if !stroke_words.iter().any(|w: &String| w == &row.value) {
                    stroke_words.push(row.value);
                    if stroke_words.len() >= PREVIEW_LIMIT {
                        break;
                    }
                }
            }
        }

        if let Some(prefix_r) = prefix_reading {
            let mut combined_words = Vec::with_capacity(PREVIEW_LIMIT);
            let mut push_word = |word: String| {
                if !combined_words.iter().any(|existing| existing == &word)
                    && combined_words.len() < PREVIEW_LIMIT
                {
                    combined_words.push(word);
                }
            };
            // 1) 优先放「已有前缀 + 本笔读音」命中的跨笔整词（如 `wo` + `men` -> `我们`）。
            let mut primary_combined_rows = Vec::new();
            let best_combined_key = format!("{prefix_r}'{reading}");
            if let Some(rows) = exact_map.get(&best_combined_key) {
                primary_combined_rows.extend(rows.iter());
            }
            for (k, _) in &best.top_full_keys {
                let ck = format!("{prefix_r}'{k}");
                if ck != best_combined_key {
                    if let Some(rows) = exact_map.get(&ck) {
                        primary_combined_rows.extend(rows.iter());
                    }
                }
            }
            primary_combined_rows
                .sort_by(|a, b| b.weight.cmp(&a.weight).then_with(|| a.value.cmp(&b.value)));
            for row in primary_combined_rows {
                push_word(row.value.clone());
            }
            // 2) 并入相近次优跨笔整词（与 `glide()` 续滑逻辑同序）。
            for (key, _, alt_score) in &runners {
                let close_tie = *alt_score <= best.score + SECONDARY_CLOSE_TIE_MARGIN;
                let take_limit = if close_tie { 2 } else { 1 };
                let ck = format!("{prefix_r}'{key}");
                if let Some(rows) = exact_map.get(&ck) {
                    for row in rows.iter().take(take_limit) {
                        push_word(row.value.clone());
                    }
                } else if let (Some(pw), Some(rows)) = (prefix_word, exact_map.get(key)) {
                    if let Some(row) = rows.first() {
                        push_word(format!("{pw}{}", row.value));
                    }
                }
            }
            // 3) 用「已有前缀词 + 本笔词」兜底补齐整页预览（如 `我们` + `去` -> `我们去`）。
            if let Some(pw) = prefix_word {
                for word in stroke_words {
                    push_word(format!("{pw}{word}"));
                }
            } else {
                for word in stroke_words {
                    push_word(word);
                }
            }
            return Some((format!("{prefix_r}'{reading}"), combined_words));
        }

        let mut words = stroke_words;
        if !runners.is_empty() && !words.is_empty() {
            let mut insert_at = words.len().min(2);
            for (key, _, alt_score) in runners {
                let close_tie = alt_score <= best.score + SECONDARY_CLOSE_TIE_MARGIN;
                if close_tie && insert_at > 1 {
                    insert_at = words.len().min(1);
                }
                let take_limit = if close_tie { 3 } else { 2 };
                if let Some(rows) = exact_map.get(&key) {
                    for row in rows.iter().take(take_limit) {
                        if words.iter().any(|w| w == &row.value) {
                            continue;
                        }
                        words.insert(insert_at, row.value.clone());
                        insert_at += 1;
                    }
                }
            }
            words.truncate(PREVIEW_LIMIT);
        }

        Some((reading, words))
    }

    /// 九键滑行一笔：先按轨迹与有效九键拼音音节表解出候选数字串，再经全拼词典（含连滑上下文、跨笔整词与组合词分段 DP）排序，
    /// 把最优数字串整体写入当前九键会话（已有未确认数字时自动加 `'` 分隔），并在空态与连滑态下均并入相近同路径次优候选。
    pub fn glide(&mut self, keyboard: &GlideKeyboard, points: &[GlidePoint]) -> KeyResult {
        if self.grid != KeyGrid::NineKey
            || self.english_only
            || !self.pinyin
            || self.helpcode.is_some()
        {
            return KeyResult::unhandled();
        }
        let had_composition = self.active();
        let caret_at_end_before = self.caret_position() == self.digits.len();
        let Some(batch) = self.score_glide_hypotheses(keyboard, points, DecodeConfig::FULL) else {
            return KeyResult::unhandled();
        };
        let scored = batch.scored;
        let weights = batch.weights;
        let max_weight = batch.max_weight;
        let context = batch.context;
        let table = syllable_table();

        let best = &scored[0];
        let best_digits = best.digits.clone();
        let best_score = best.score;
        let best_first_digit = best_digits.as_bytes().first().copied();

        // 收集同路径因重键折叠而落选的合法首音节拼音（如 `2→4` 选了 `24` 后附带 `cai`/`bai` -> `224`、`chi` -> `244`），
        // 写入 `glide_alt_spellings` 供「选拼音」栏直接展示并一键无损切换数字串。
        let mut alt_spellings_scored: Vec<(String, String, f32)> = Vec::new();
        for alt in scored.iter().skip(1) {
            if alt.digits == best_digits
                || alt.score > best_score + ALT_SPELLING_MARGIN
                || alt.digits.as_bytes().first().copied() != best_first_digit
            {
                continue;
            }
            let Some(&first_syl_id) = alt.syllable_ids.first() else {
                continue;
            };
            let syl = &table.syllables[usize::from(first_syl_id)];
            for (r_idx, &reading) in syl.readings.iter().enumerate() {
                let dict_bonus = weights
                    .get(reading)
                    .copied()
                    .filter(|&w| w > 0)
                    .map_or(0.35, |w| {
                        ((max_weight / w as f64).ln() as f32 * 0.12).clamp(0.0, 0.35)
                    });
                let rank_cost = alt.score + r_idx as f32 * 0.14 + dict_bonus;
                if let Some(existing) = alt_spellings_scored
                    .iter_mut()
                    .find(|(s, _, _)| s == reading)
                {
                    if rank_cost < existing.2 {
                        existing.1 = alt.digits.clone();
                        existing.2 = rank_cost;
                    }
                } else {
                    alt_spellings_scored.push((reading.to_owned(), alt.digits.clone(), rank_cost));
                }
            }
        }
        alt_spellings_scored.sort_by(|a, b| a.2.total_cmp(&b.2).then_with(|| a.0.cmp(&b.0)));
        alt_spellings_scored.truncate(ALT_SPELLING_LIMIT);
        let alt_spellings: Vec<(String, String)> = alt_spellings_scored
            .into_iter()
            .map(|(spelling, digits, _)| (spelling, digits))
            .collect();

        let digits_before = self.digits.len();
        let result = self.push_glide_digits(&best_digits, alt_spellings);
        let full_inserted_at_end = caret_at_end_before
            && self.caret_position() == self.digits.len()
            && self.digits.len() == digits_before + best_digits.len();

        // 空态起滑且存在同路径相近次优数字串（如 `6→4→2→6` 的 `64426` 你好 vs `6426` 年/面、`2→4` 的 `24` 比/次 vs `224` 才/白 与 `244` 吃）时，
        // 把次优读音的前若干高频词并入候选前排（保留首位不变），点选后一次消费整段滑行数字并干净上屏。
        if !had_composition && result.handled && !self.candidates.is_empty() && full_inserted_at_end {
            let runners =
                collect_secondary_runners(&scored, &best_digits, best_score, max_weight, 3);
            if !runners.is_empty() {
                let alt_keys: Vec<String> = runners.iter().map(|(k, _, _)| k.clone()).collect();
                let options = self.dictionary_options();
                let paths = &self.paths;
                let dictionary = self
                    .dictionary
                    .get_or_insert_with(|| open_dictionary(paths, options));
                let exact_map = dictionary.exact_rows_for_keys(&alt_keys, 3);
                let mut insert_at = self.candidates.len().min(2);
                let full_digits = SharedString::from(self.digits.as_str());
                for (key, _, alt_score) in runners {
                    let close_tie = alt_score <= best_score + SECONDARY_CLOSE_TIE_MARGIN;
                    if close_tie && insert_at > 1 {
                        insert_at = self.candidates.len().min(1);
                    }
                    let take_limit = if close_tie { 3 } else { 2 };
                    if let Some(rows) = exact_map.get(&key) {
                        for row in rows.iter().take(take_limit) {
                            if self
                                .candidates
                                .iter()
                                .any(|existing| existing.word.as_str() == row.value.as_str())
                            {
                                continue;
                            }
                            let item = WordItem {
                                pinyin: full_digits.clone(),
                                canonical_pinyin: SharedString::from(row.key.as_str()),
                                word: SharedString::from(row.value.as_str()),
                                weight: row.weight,
                                source: CandidateSource::Generated,
                                scheme: SchemeType::Quanpin,
                                fixed_position: 0,
                                fuzzy: false,
                                corrected_from: SharedString::default(),
                                sentence_association: false,
                                sentence_words: Vec::new(),
                                touch_supported: false,
                                confident_correction: false,
                            };
                            self.candidates.insert(insert_at, item);
                            if !self.contests.is_empty() {
                                self.contests.insert(insert_at.min(self.contests.len()), 0);
                            }
                            insert_at += 1;
                        }
                    }
                }
            }
        } else if had_composition
            && result.handled
            && !self.candidates.is_empty()
            && full_inserted_at_end
        {
            // 连续滑行第二、三笔时，同样将同路径相近次优读音与已有前缀拼成整词并入 1..2 位，减少续滑微偏时的整段重打。
            if let Some(prefix_reading) = context.full_prefix_reading.as_deref() {
                let runners =
                    collect_secondary_runners(&scored, &best_digits, best_score, max_weight, 2);
                if !runners.is_empty() {
                    let mut query_keys: Vec<String> = Vec::with_capacity(runners.len() * 2);
                    for (key, _, _) in &runners {
                        query_keys.push(format!("{prefix_reading}'{key}"));
                        query_keys.push(key.clone());
                    }
                    let options = self.dictionary_options();
                    let paths = &self.paths;
                    let dictionary = self
                        .dictionary
                        .get_or_insert_with(|| open_dictionary(paths, options));
                    let exact_map = dictionary.exact_rows_for_keys(&query_keys, 2);
                    let mut insert_at = self.candidates.len().min(1);
                    let full_digits = SharedString::from(self.digits.as_str());
                    for (key, _, alt_score) in runners {
                        let combined_key = format!("{prefix_reading}'{key}");
                        let close_tie = alt_score <= best_score + SECONDARY_CLOSE_TIE_MARGIN;
                        let take_limit = if close_tie { 2 } else { 1 };
                        let mut inserted_any = false;
                        if let Some(rows) = exact_map.get(&combined_key) {
                            for row in rows.iter().take(take_limit) {
                                if self
                                    .candidates
                                    .iter()
                                    .any(|existing| existing.word.as_str() == row.value.as_str())
                                {
                                    continue;
                                }
                                let item = WordItem {
                                    pinyin: full_digits.clone(),
                                    canonical_pinyin: SharedString::from(row.key.as_str()),
                                    word: SharedString::from(row.value.as_str()),
                                    weight: row.weight,
                                    source: CandidateSource::Generated,
                                    scheme: SchemeType::Quanpin,
                                    fixed_position: 0,
                                    fuzzy: false,
                                    corrected_from: SharedString::default(),
                                    sentence_association: false,
                                    sentence_words: Vec::new(),
                                    touch_supported: false,
                                    confident_correction: false,
                                };
                                self.candidates.insert(insert_at, item);
                                if !self.contests.is_empty() {
                                    self.contests.insert(insert_at.min(self.contests.len()), 0);
                                }
                                insert_at += 1;
                                inserted_any = true;
                            }
                        }
                        if !inserted_any {
                            if let (Some(prefix_word), Some(rows)) =
                                (context.prefix_word.as_deref(), exact_map.get(&key))
                            {
                                if let Some(row) = rows.first() {
                                    let combined_word = format!("{prefix_word}{}", row.value);
                                    if !self.candidates.iter().any(|existing| {
                                        existing.word.as_str() == combined_word.as_str()
                                    }) {
                                        let item = WordItem {
                                            pinyin: full_digits.clone(),
                                            canonical_pinyin: SharedString::from(combined_key.as_str()),
                                            word: SharedString::from(combined_word.as_str()),
                                            weight: row.weight,
                                            source: CandidateSource::Generated,
                                            scheme: SchemeType::Quanpin,
                                            fixed_position: 0,
                                            fuzzy: false,
                                            corrected_from: SharedString::default(),
                                            sentence_association: false,
                                            sentence_words: Vec::new(),
                                            touch_supported: false,
                                            confident_correction: false,
                                        };
                                        self.candidates.insert(insert_at, item);
                                        if !self.contests.is_empty() {
                                            self.contests
                                                .insert(insert_at.min(self.contests.len()), 0);
                                        }
                                        insert_at += 1;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        result
    }

    /// 将解码出的九键数字串一次写入当前光标处；若已有组字且光标不在边界上，自动加 `'` 分隔音节。
    fn push_glide_digits(
        &mut self,
        digits: &str,
        alt_spellings: Vec<(String, String)>,
    ) -> KeyResult {
        if digits.is_empty() || !digits.bytes().all(|b| self.grid.is_code(b)) {
            return KeyResult::unhandled();
        }
        if self.digits.len() >= DIGIT_LIMIT {
            return KeyResult::handled()
                .with_diagnostic(Some(diagnostics::NINE_KEY_DIGIT_LIMIT.to_string()));
        }
        self.clear_glide_alt_spellings();
        self.browse_spelling = None;
        let mut caret = self.caret_position();
        self.unlock_from(caret);
        if caret == self.locked_length() {
            self.initial = None;
        }
        // 已有组字且光标前有数字时加音节分隔符，避免上一笔与本笔滑行粘成一个错音节。
        if self.active() && caret > 0 && !self.on_lock_boundary(caret) && !self.splits.contains(&caret) {
            let at = self.splits.partition_point(|&split| split < caret);
            self.splits.insert(at, caret);
        }
        let available = DIGIT_LIMIT - self.digits.len();
        let inserted = &digits[..digits.len().min(available)];
        let inserted_len = inserted.len();
        let inserted_at = caret;
        self.digits.insert_str(caret, inserted);
        for split in &mut self.splits {
            if *split > caret {
                *split += inserted_len;
            }
        }
        caret += inserted_len;
        // 仅当整段完整写入末尾时附挂同路径次优拼音选项，防止超长截断或插入中间时覆盖错位。
        if inserted_len == digits.len() && caret == self.digits.len() && !alt_spellings.is_empty() {
            self.glide_alt_offset = inserted_at;
            self.glide_alt_base_digits = inserted.to_owned();
            self.glide_alt_spellings = alt_spellings;
        }
        self.set_caret(caret);
        self.refresh();
        KeyResult::handled()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::RuntimePaths;
    use crate::types::{
        EnglishInputOptions, FrequencyAdjustmentOptions, FuzzyPinyinOptions,
    };
    use rusqlite::Connection;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn nine_key_keyboard() -> GlideKeyboard {
        // 标准 3×3 九宫格坐标（键宽 80pt，键高 49pt，间隙 6/7pt）：
        // Row 0: [1]  [2:ABC]  [3:DEF]
        // Row 1: [4:GHI] [5:JKL] [6:MNO]
        // Row 2: [7:PQRS] [8:TUV] [9:WXYZ]
        let key_width = 80.0;
        let key_height = 49.0;
        let col_x = [130.0f32, 216.0, 302.0];
        let row_y = [28.0f32, 84.0, 140.0];
        let digit_center = |digit: u8| -> (f32, f32) {
            match digit {
                b'2' => (col_x[1], row_y[0]),
                b'3' => (col_x[2], row_y[0]),
                b'4' => (col_x[0], row_y[1]),
                b'5' => (col_x[1], row_y[1]),
                b'6' => (col_x[2], row_y[1]),
                b'7' => (col_x[0], row_y[2]),
                b'8' => (col_x[1], row_y[2]),
                b'9' => (col_x[2], row_y[2]),
                _ => (0.0, 0.0),
            }
        };
        let mut centers = [(0.0f32, 0.0f32); 26];
        for (i, &d) in KEYPAD.iter().enumerate() {
            centers[i] = digit_center(d);
        }
        GlideKeyboard {
            centers,
            key_width,
            key_height,
        }
    }

    fn stroke_digits(keyboard: &GlideKeyboard, path: &str) -> Vec<GlidePoint> {
        let mut points = Vec::new();
        let mut time_ms = 0u32;
        let coords: Vec<(f32, f32)> = path
            .bytes()
            .map(|d| keyboard.centers[DIGIT_REP_INDICES[usize::from(d - b'2')]])
            .collect();
        for (seg_idx, pair) in coords.windows(2).enumerate() {
            let steps = 8usize;
            for step in 0..=steps {
                if seg_idx > 0 && step == 0 {
                    continue;
                }
                let t = step as f32 / steps as f32;
                points.push(GlidePoint {
                    x: pair[0].0 + (pair[1].0 - pair[0].0) * t,
                    y: pair[0].1 + (pair[1].1 - pair[0].1) * t,
                    time_ms: Some(time_ms),
                });
                time_ms += 18;
            }
        }
        points
    }

    struct TempNineKey {
        dir: PathBuf,
        session: NineKeySession,
    }

    impl Drop for TempNineKey {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    fn test_session(sql: &str) -> TempNineKey {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT_ID: AtomicU64 = AtomicU64::new(0);
        let seq = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "msime-nk-glide-{}-{nanos}-{seq}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("msime-pinyin.db");
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(sql).unwrap();
        drop(conn);
        let paths = RuntimePaths {
            resources: dir.clone(),
            user_data: dir.clone(),
            cache: dir.clone(),
            dictionaries: dir.clone(),
        };
        let session = NineKeySession::new(
            &paths,
            false,
            FrequencyAdjustmentOptions::default(),
            FuzzyPinyinOptions::default(),
            EnglishInputOptions::default(),
            true,
            false,
        );
        TempNineKey { dir, session }
    }

    #[test]
    fn nine_key_glide_decodes_nihao_with_boundary_repeat() {
        let mut harness = test_session(
            "CREATE TABLE tbl_1_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_n VALUES('ni','n','你',80000);\
             CREATE TABLE tbl_1_h(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_h VALUES('hao','h','好',90000);\
             CREATE TABLE tbl_2_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_n VALUES('ni''hao','nh','你好',500000);\
             CREATE TABLE tbl_2_m(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_m VALUES('mi''an','ma','密案',100);",
        );
        let kb = nine_key_keyboard();
        // 滑 6→4→2→6（不在 4 上停顿），应自动补齐边界同键连字得到 64426 → 你好。
        let res = harness.session.glide(&kb, &stroke_digits(&kb, "6426"));
        assert!(res.handled);
        let snap = harness.session.snapshot();
        assert_eq!(snap.editing_text, "64426");
        assert_eq!(snap.candidates.first().map(|c| c.word.as_str()), Some("你好"));
    }

    #[test]
    fn nine_key_glide_decodes_women_and_shi_and_zhongguo() {
        let mut harness = test_session(
            "CREATE TABLE tbl_1_s(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_s VALUES('shi','s','是',900000),('si','s','四',50000);\
             CREATE TABLE tbl_1_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_w VALUES('wo','w','我',500000);\
             CREATE TABLE tbl_1_m(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_m VALUES('men','m','们',300000);\
             CREATE TABLE tbl_2_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_w VALUES('wo''men','wm','我们',800000);\
             CREATE TABLE tbl_1_z(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_z VALUES('zhong','z','中',400000);\
             CREATE TABLE tbl_1_g(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_g VALUES('guo','g','国',400000);\
             CREATE TABLE tbl_2_z(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_z VALUES('zhong''guo','zg','中国',900000);",
        );
        let kb = nine_key_keyboard();

        // 我们：9→6→3→6 -> 96636
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "9636")).handled);
        assert_eq!(harness.session.snapshot().editing_text, "96636");
        assert_eq!(
            harness.session.snapshot().candidates.first().map(|c| c.word.as_str()),
            Some("我们")
        );
        harness.session.command(crate::types::Command::Cancel);

        // 是：7→4 -> 744
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "74")).handled);
        assert_eq!(harness.session.snapshot().editing_text, "744");
        assert_eq!(
            harness.session.snapshot().candidates.first().map(|c| c.word.as_str()),
            Some("是")
        );
        harness.session.command(crate::types::Command::Cancel);

        // 中国：9→4→6→4→8→6 -> 94664486
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "946486")).handled);
        assert_eq!(harness.session.snapshot().editing_text, "94664486");
        assert_eq!(
            harness.session.snapshot().candidates.first().map(|c| c.word.as_str()),
            Some("中国")
        );
    }

    #[test]
    fn consecutive_nine_key_glides_insert_syllable_separator() {
        let mut harness = test_session(
            "CREATE TABLE tbl_1_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_n VALUES('ni','n','你',80000);\
             CREATE TABLE tbl_1_h(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_h VALUES('hao','h','好',90000);\
             CREATE TABLE tbl_2_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_n VALUES('ni''hao','nh','你好',500000);",
        );
        let kb = nine_key_keyboard();
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "64")).handled);
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "426")).handled);
        let snap = harness.session.snapshot();
        assert_eq!(snap.editing_text, "64426");
        assert_eq!(snap.candidates.first().map(|c| c.word.as_str()), Some("你好"));
    }

    #[test]
    fn nine_key_glide_scores_compositional_phrases_without_monolithic_entry() {
        // 词库仅含单字 `wo`（我）与 `qu`（去），无整词 `wo'qu`；滑 `9→6→7→8` 应通过组合词分段 DP 正确解出 `9678`。
        let mut harness = test_session(
            "CREATE TABLE tbl_1_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_w VALUES('wo','w','我',600000);\
             CREATE TABLE tbl_1_q(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_q VALUES('qu','q','去',450000);",
        );
        let kb = nine_key_keyboard();
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "9678")).handled);
        assert_eq!(harness.session.snapshot().editing_text, "9678");
    }

    #[test]
    fn nine_key_glide_merges_secondary_same_path_candidates_and_commits_cleanly() {
        // 同路径 `6→4→2→6` 同时对应 `64426`（你好）和 `6426`（年/面）：首位为「你好」，次优读音的「年」「面」应合并进前排，点选后完整消费整串数字。
        let mut harness = test_session(
            "CREATE TABLE tbl_1_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_n VALUES('ni','n','你',80000),('nian','n','年',420000);\
             CREATE TABLE tbl_1_m(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_m VALUES('mian','m','面',380000);\
             CREATE TABLE tbl_1_h(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_h VALUES('hao','h','好',90000);\
             CREATE TABLE tbl_2_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_n VALUES('ni''hao','nh','你好',500000);",
        );
        let kb = nine_key_keyboard();
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "6426")).handled);
        let snap = harness.session.snapshot();
        assert_eq!(snap.editing_text, "64426");
        assert_eq!(snap.candidates.first().map(|c| c.word.as_str()), Some("你好"));
        let nian_pos = snap
            .candidates
            .iter()
            .position(|c| c.word.as_str() == "年")
            .expect("同路径次优读音候选「年」应并入候选栏");
        assert!(nian_pos <= 3, "次优候选应在前排，实际位置 {nian_pos}");
        let commit = harness.session.select(nian_pos);
        assert_eq!(commit.commit.as_deref(), Some("年"));
        assert!(!harness.session.active(), "选完次优读音候选后应消费整段滑行组字");
    }

    #[test]
    fn nine_key_glide_decodes_common_multi_syllable_phrases_with_long_syllables() {
        // 覆盖含长音节（shen/shang/guan）、边界同键、音节内重键与 3–4 字连滑的高频日常词，校验分桶剪枝与 6 读音表不会漏词。
        let mut harness = test_session(
            "CREATE TABLE tbl_1_s(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_s VALUES('shen','s','什',200000),('shi','s','是',900000),('si','s','四',100000),('shang','s','上',600000);\
             CREATE TABLE tbl_1_m(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_m VALUES('me','m','么',300000),('mei','m','没',500000);\
             CREATE TABLE tbl_1_z(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_z VALUES('zen','z','怎',150000),('zhi','z','知',400000),('zao','z','早',300000);\
             CREATE TABLE tbl_1_d(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_d VALUES('dao','d','道',400000),('de','d','的',1200000);\
             CREATE TABLE tbl_1_g(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_g VALUES('guan','g','关',300000);\
             CREATE TABLE tbl_1_x(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_x VALUES('xi','x','系',300000);\
             CREATE TABLE tbl_1_h(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_h VALUES('hou','h','候',200000),('hao','h','好',700000);\
             CREATE TABLE tbl_1_b(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_b VALUES('bu','b','不',800000);\
             CREATE TABLE tbl_1_y(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_y VALUES('yi','y','意',400000);\
             CREATE TABLE tbl_1_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_w VALUES('wo','w','我',900000);\
             CREATE TABLE tbl_2_s(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_s VALUES('shen''me','sm','什么',900000),('shi''hou','sh','时候',700000),('shi''de','sd','是的',500000);\
             CREATE TABLE tbl_2_z(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_z VALUES('zen''me','zm','怎么',850000),('zhi''dao','zd','知道',800000);\
             CREATE TABLE tbl_2_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_w VALUES('wo''de','wd','我的',800000);\
             CREATE TABLE tbl_3_m(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_3_m VALUES('mei''guan''xi','mgx','没关系',700000);\
             CREATE TABLE tbl_3_z(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_3_z VALUES('zao''shang''hao','zsh','早上好',600000);\
             CREATE TABLE tbl_4_s(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_4_s VALUES('shen''me''shi''hou','smsh','什么时候',750000);\
             CREATE TABLE tbl_4_b(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_4_b VALUES('bu''hao''yi''si','bhys','不好意思',750000);",
        );
        let kb = nine_key_keyboard();
        let cases = [
            ("74363", "743663", "什么"),
            ("9363", "93663", "怎么"),
            ("94326", "944326", "知道"),
            ("963", "9633", "我的"),
            ("743", "74433", "是的"),
            ("63482694", "634482694", "没关系"),
            ("9267426426", "92674264426", "早上好"),
            ("743637468", "743663744468", "什么时候"),
            ("284269474", "284269474", "不好意思"),
        ];
        for (path, expected_digits, expected_word) in cases {
            assert!(
                harness.session.glide(&kb, &stroke_digits(&kb, path)).handled,
                "path {path} ({expected_word}) should be handled"
            );
            let snap = harness.session.snapshot();
            assert_eq!(
                snap.editing_text, expected_digits,
                "path {path} ({expected_word}) digits mismatch"
            );
            assert_eq!(
                snap.candidates.first().map(|c| c.word.as_str()),
                Some(expected_word),
                "path {path} ({expected_word}) top candidate mismatch"
            );
            harness.session.command(crate::types::Command::Cancel);
        }
    }

    #[test]
    fn nine_key_glide_tolerates_noisy_off_center_strokes_and_end_key_rest() {
        // 模拟真机拇指偏心（±0.28 键宽）与抬手前在末键多停顿 240ms 的抖动团：仍应稳定解出「你好」「我们」，不因末键停顿误出多余音节。
        let mut harness = test_session(
            "CREATE TABLE tbl_1_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_n VALUES('ni','n','你',80000);\
             CREATE TABLE tbl_1_h(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_h VALUES('hao','h','好',90000);\
             CREATE TABLE tbl_2_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_n VALUES('ni''hao','nh','你好',500000);\
             CREATE TABLE tbl_1_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_w VALUES('wo','w','我',500000);\
             CREATE TABLE tbl_1_m(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_m VALUES('men','m','们',300000);\
             CREATE TABLE tbl_2_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_w VALUES('wo''men','wm','我们',800000);",
        );
        let kb = nine_key_keyboard();
        let mut noisy_nihao = stroke_digits(&kb, "6426");
        for (idx, p) in noisy_nihao.iter_mut().enumerate() {
            let phase = (idx as f32) * 0.9;
            p.x += phase.sin() * (kb.key_width * 0.22);
            p.y += phase.cos() * (kb.key_height * 0.20);
        }
        // 末键原地晃动 240ms 模拟思考后抬手。
        if let Some(&last) = noisy_nihao.last() {
            let mut t = last.time_ms.unwrap_or(0);
            for k in 1..=8 {
                t += 30;
                noisy_nihao.push(GlidePoint {
                    x: last.x + if k % 2 == 0 { 4.0 } else { -4.0 },
                    y: last.y + if k % 2 == 0 { -3.0 } else { 3.0 },
                    time_ms: Some(t),
                });
            }
        }
        assert!(harness.session.glide(&kb, &noisy_nihao).handled);
        assert_eq!(harness.session.snapshot().editing_text, "64426");
        assert_eq!(
            harness.session.snapshot().candidates.first().map(|c| c.word.as_str()),
            Some("你好")
        );
    }

    #[test]
    fn nine_key_glide_24_exposes_cai_bai_chi_in_spellings_and_switches_losslessly() {
        // 真机词库权重分布下，直线滑 `2→4` 会优先落入 `24`（比/次/哎），但同路径的 `224`（cai/bai）与 `244`（chi）
        // 必须同时把高频字并入候选栏，并把 `cai`/`bai`/`chi` 放进「选拼音」栏且支持无损换选与退格还原。
        let mut harness = test_session(
            "CREATE TABLE tbl_1_a(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_a VALUES('ai','a','爱',804364);\
             CREATE TABLE tbl_1_b(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_b VALUES('bi','b','比',4971047),('bai','b','白',323389),('bai','b','百',220532);\
             CREATE TABLE tbl_1_c(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_c VALUES('ci','c','次',1222933),('cai','c','才',2732902),('cai','c','菜',341616),('cai','c','猜',60000),('cai','c','彩',50000),('chi','c','吃',1402977),('chi','c','持',175372);",
        );
        let kb = nine_key_keyboard();
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "24")).handled);

        let snap = harness.session.snapshot();
        assert_eq!(snap.editing_text, "24");
        // 候选栏前排同时包含 `cai`（才）、`chi`（吃）与 `bai`（白）。
        let words: Vec<&str> = snap.candidates.iter().map(|c| c.word.as_str()).collect();
        assert!(words.contains(&"才"), "2→4 候选栏应并入才: {words:?}");
        assert!(words.contains(&"吃"), "2→4 候选栏应并入吃: {words:?}");
        assert!(words.contains(&"白"), "2→4 候选栏应并入白: {words:?}");
        // 「选拼音」栏包含 cai / bai / chi，且排在字母筛选 A/B/C 与数字 2 之前。
        assert!(snap.nine_key_spellings.contains(&"cai".to_owned()), "{:?}", snap.nine_key_spellings);
        assert!(snap.nine_key_spellings.contains(&"bai".to_owned()), "{:?}", snap.nine_key_spellings);
        assert!(snap.nine_key_spellings.contains(&"chi".to_owned()), "{:?}", snap.nine_key_spellings);
        let cai_pos = snap.nine_key_spellings.iter().position(|s| s == "cai").unwrap();
        let letter_c_pos = snap.nine_key_spellings.iter().position(|s| s == "C").unwrap();
        assert!(cai_pos < letter_c_pos, "cai 应排在首字母 C 之前: {:?}", snap.nine_key_spellings);

        // 先按首字母 C 筛选：应同时留住 ci / cai / chi，而不是只剩 ci。
        assert!(harness.session.choose_spelling(letter_c_pos).handled);
        let filtered = harness.session.snapshot();
        assert!(filtered.nine_key_spellings.contains(&"ci".to_owned()), "{:?}", filtered.nine_key_spellings);
        assert!(filtered.nine_key_spellings.contains(&"cai".to_owned()), "{:?}", filtered.nine_key_spellings);
        assert!(filtered.nine_key_spellings.contains(&"chi".to_owned()), "{:?}", filtered.nine_key_spellings);
        assert!(!filtered.nine_key_spellings.contains(&"bi".to_owned()), "{:?}", filtered.nine_key_spellings);

        // 在选拼音栏点选 `cai`：数字串无损切换为 `224`，读音切为 `cai`，所有 `cai` 候选字（包括较靠后的 猜/彩）全部出现。
        let filtered_cai_pos = filtered.nine_key_spellings.iter().position(|s| s == "cai").unwrap();
        assert!(harness.session.choose_spelling(filtered_cai_pos).handled);
        let cai_snap = harness.session.snapshot();
        assert_eq!(cai_snap.editing_text, "224");
        assert_eq!(cai_snap.nine_key_reading, "cai");
        let cai_words: Vec<&str> = cai_snap.candidates.iter().map(|c| c.word.as_str()).collect();
        assert!(cai_words.contains(&"才") && cai_words.contains(&"猜") && cai_words.contains(&"彩"), "{cai_words:?}");

        // 全部锁定时仍可在选拼音栏无损换选为 `chi`（244）或换回 `ci`（24），退格也能还原 `24`。
        let chi_pos = cai_snap.nine_key_spellings.iter().position(|s| s == "chi").unwrap();
        assert!(harness.session.choose_spelling(chi_pos).handled);
        let chi_snap = harness.session.snapshot();
        assert_eq!(chi_snap.editing_text, "244");
        assert_eq!(chi_snap.nine_key_reading, "chi");
        assert_eq!(chi_snap.candidates.first().map(|c| c.word.as_str()), Some("吃"));

        let ci_pos = chi_snap.nine_key_spellings.iter().position(|s| s == "ci").unwrap();
        assert!(harness.session.choose_spelling(ci_pos).handled);
        let ci_snap = harness.session.snapshot();
        assert_eq!(ci_snap.editing_text, "24");
        assert_eq!(ci_snap.nine_key_reading, "ci");
        assert_eq!(ci_snap.candidates.first().map(|c| c.word.as_str()), Some("次"));

        assert!(harness.session.command(crate::types::Command::Backspace).handled);
        let undone = harness.session.snapshot();
        assert_eq!(undone.editing_text, "24");
        assert!(undone.nine_key_spellings.contains(&"cai".to_owned()), "{:?}", undone.nine_key_spellings);
    }

    #[test]
    fn nine_key_glide_start_loop_on_2_prioritizes_cai_224() {
        // 在起手键 2 上小幅回环再滑向 4（刻意表示 224），直接首选 `cai`（才）。
        let mut harness = test_session(
            "CREATE TABLE tbl_1_b(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_b VALUES('bi','b','比',4971047),('bai','b','白',323389);\
             CREATE TABLE tbl_1_c(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_c VALUES('ci','c','次',1222933),('cai','c','才',2732902),('cai','c','菜',341616);",
        );
        let kb = nine_key_keyboard();
        let (x2, y2) = kb.centers[DIGIT_REP_INDICES[0]];
        let (x4, y4) = kb.centers[DIGIT_REP_INDICES[2]];
        let mut pts = vec![
            GlidePoint { x: x2, y: y2, time_ms: Some(0) },
            GlidePoint { x: x2 + kb.key_width * 0.25, y: y2, time_ms: Some(18) },
            GlidePoint { x: x2, y: y2 + kb.key_height * 0.25, time_ms: Some(36) },
            GlidePoint { x: x2 - kb.key_width * 0.22, y: y2, time_ms: Some(54) },
            GlidePoint { x: x2, y: y2, time_ms: Some(72) },
        ];
        let mut t = 90u32;
        for step in 1..=8 {
            let frac = step as f32 / 8.0;
            pts.push(GlidePoint {
                x: x2 + (x4 - x2) * frac,
                y: y2 + (y4 - y2) * frac,
                time_ms: Some(t),
            });
            t += 18;
        }
        assert!(harness.session.glide(&kb, &pts).handled);
        let snap = harness.session.snapshot();
        assert_eq!(snap.editing_text, "224");
        assert_eq!(snap.candidates.first().map(|c| c.word.as_str()), Some("才"));
    }

    #[test]
    fn nine_key_glide_74_and_26_expose_alt_spellings() {
        let mut harness = test_session(
            "CREATE TABLE tbl_1_s(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_s VALUES('shi','s','是',53237347),('si','s','四',669216);\
             CREATE TABLE tbl_1_q(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_q VALUES('qi','q','起',900000);\
             CREATE TABLE tbl_1_a(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_a VALUES('an','a','按',1183359);\
             CREATE TABLE tbl_1_b(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_b VALUES('ban','b','办',907683),('bao','b','包',405314);\
             CREATE TABLE tbl_1_c(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_c VALUES('cao','c','草',108528);",
        );
        let kb = nine_key_keyboard();

        // 7→4 首选 744 (shi)，选拼音栏补全 si/qi 并可点选切换为 74。
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "74")).handled);
        let snap74 = harness.session.snapshot();
        assert_eq!(snap74.editing_text, "744");
        assert!(snap74.nine_key_spellings.contains(&"si".to_owned()), "{:?}", snap74.nine_key_spellings);
        assert!(snap74.nine_key_spellings.contains(&"qi".to_owned()), "{:?}", snap74.nine_key_spellings);
        let si_pos = snap74.nine_key_spellings.iter().position(|s| s == "si").unwrap();
        assert!(harness.session.choose_spelling(si_pos).handled);
        assert_eq!(harness.session.snapshot().editing_text, "74");
        assert_eq!(harness.session.snapshot().candidates.first().map(|c| c.word.as_str()), Some("四"));
        harness.session.command(crate::types::Command::Cancel);

        // 2→6 首选 26 (an)，选拼音栏补全 ban/bao/cao 并可点选切换为 226。
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "26")).handled);
        let snap26 = harness.session.snapshot();
        assert_eq!(snap26.editing_text, "26");
        assert!(snap26.nine_key_spellings.contains(&"ban".to_owned()), "{:?}", snap26.nine_key_spellings);
        assert!(snap26.nine_key_spellings.contains(&"bao".to_owned()), "{:?}", snap26.nine_key_spellings);
        let bao_pos = snap26.nine_key_spellings.iter().position(|s| s == "bao").unwrap();
        assert!(harness.session.choose_spelling(bao_pos).handled);
        assert_eq!(harness.session.snapshot().editing_text, "226");
        assert_eq!(harness.session.snapshot().candidates.first().map(|c| c.word.as_str()), Some("包"));
    }

    #[test]
    fn nine_key_consecutive_glide_uses_cross_stroke_whole_word_and_merges_secondary() {
        // 先滑 `wo`（96 -> 我），再滑 `6→3→6`：尽管单字 `me`（63）权重更高，跨笔整词 `wo'men`（我们）应把第二笔稳稳判成 `636`；
        // 同时相近次优路径 `63`（么）或 `634`（没）拼上前缀组成的整词应并入候选前排，点选后完整消费整段组字。
        let mut harness = test_session(
            "CREATE TABLE tbl_1_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_w VALUES('wo','w','我',900000);\
             CREATE TABLE tbl_1_m(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_m VALUES('me','m','么',700000),('men','m','们',200000),('mei','m','没',650000),('mo','m','模',150000);\
             CREATE TABLE tbl_2_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_w VALUES('wo''men','wm','我们',950000),('wo''mei','wm','我没',600000);",
        );
        let kb = nine_key_keyboard();
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "96")).handled);
        assert_eq!(
            harness.session.snapshot().candidates.first().map(|c| c.word.as_str()),
            Some("我")
        );

        // 第二笔从 6→3→6 略偏向 6→3→6：跨笔整词 `wo'men` 胜出，且 `我没`（634 次优）若进入次优窗口亦能干净消费。
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "636")).handled);
        let snap = harness.session.snapshot();
        assert_eq!(snap.editing_text, "96636");
        assert_eq!(snap.candidates.first().map(|c| c.word.as_str()), Some("我们"));

        // 测试续滑次优合并：重置后先滑 `bu`（28 -> 不），再滑 `2→4`（同时对应 `24` 比/次、`244` 吃、`224` 才/白）。
        harness.session.command(crate::types::Command::Cancel);
        let mut harness2 = test_session(
            "CREATE TABLE tbl_1_b(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_b VALUES('bu','b','不',900000),('bi','b','比',4000000);\
             CREATE TABLE tbl_1_c(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_c VALUES('chi','c','吃',1600000),('cai','c','才',2200000);\
             CREATE TABLE tbl_2_b(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_b VALUES('bu''bi','bb','不必',800000),('bu''chi','bc','不吃',700000),('bu''cai','bc','不才',300000);",
        );
        assert!(harness2.session.glide(&kb, &stroke_digits(&kb, "28")).handled);
        assert!(harness2.session.glide(&kb, &stroke_digits(&kb, "24")).handled);
        let snap2 = harness2.session.snapshot();
        assert_eq!(snap2.candidates.first().map(|c| c.word.as_str()), Some("不必"));
        let buchi_pos = snap2
            .candidates
            .iter()
            .position(|c| c.word.as_str() == "不吃")
            .expect("续滑次优组合整词「不吃」应并入候选前排");
        assert!(buchi_pos <= 3, "「不吃」应位于前排，实际 {buchi_pos}");
        let commit = harness2.session.select(buchi_pos);
        assert_eq!(commit.commit.as_deref(), Some("不吃"));
        assert!(!harness2.session.active(), "选完续滑次优整词应完整消费整段组字");
    }

    #[test]
    fn nine_key_glide_end_loop_on_4_prioritizes_chi_244() {
        // 直线滑 `2→4` 默认落入 `24`（比），而在末键 `4` 上主动描小环时应识别尾键重键并首选 `244`（吃）。
        let mut harness = test_session(
            "CREATE TABLE tbl_1_b(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_b VALUES('bi','b','比',4971047),('bai','b','白',323389);\
             CREATE TABLE tbl_1_c(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_c VALUES('ci','c','次',1222933),('chi','c','吃',1402977),('cai','c','才',2732902);",
        );
        let kb = nine_key_keyboard();
        let (x2, y2) = kb.centers[DIGIT_REP_INDICES[0]];
        let (x4, y4) = kb.centers[DIGIT_REP_INDICES[2]];
        let mut pts = Vec::new();
        let mut t = 0u32;
        for step in 0..=8 {
            let frac = step as f32 / 8.0;
            pts.push(GlidePoint {
                x: x2 + (x4 - x2) * frac,
                y: y2 + (y4 - y2) * frac,
                time_ms: Some(t),
            });
            t += 18;
        }
        // 在末键 4 上画一圈 ~20pt×13pt 的主动回环。
        for (dx, dy) in [
            (kb.key_width * 0.25, 0.0),
            (0.0, kb.key_height * 0.28),
            (-kb.key_width * 0.24, 0.0),
            (0.0, 0.0),
        ] {
            pts.push(GlidePoint {
                x: x4 + dx,
                y: y4 + dy,
                time_ms: Some(t),
            });
            t += 18;
        }
        assert!(harness.session.glide(&kb, &pts).handled);
        let snap = harness.session.snapshot();
        assert_eq!(snap.editing_text, "244");
        assert_eq!(snap.candidates.first().map(|c| c.word.as_str()), Some("吃"));
    }

    #[test]
    fn nine_key_preview_glide_matches_commit_top_and_secondary_candidates() {
        // 拖动实时预览与抬手提交应给出一致的首选词与前排次优同路径词，避免抬手时候选栏跳变。
        let mut harness = test_session(
            "CREATE TABLE tbl_1_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_n VALUES('ni','n','你',80000),('nian','n','年',420000);\
             CREATE TABLE tbl_1_m(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_m VALUES('mian','m','面',380000);\
             CREATE TABLE tbl_1_h(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_h VALUES('hao','h','好',90000);\
             CREATE TABLE tbl_2_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_n VALUES('ni''hao','nh','你好',500000);\
             CREATE TABLE tbl_1_b(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_b VALUES('bi','b','比',4971047),('bai','b','白',323389);\
             CREATE TABLE tbl_1_c(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_c VALUES('ci','c','次',1222933),('cai','c','才',2732902),('chi','c','吃',1402977);",
        );
        let kb = nine_key_keyboard();

        // 1. 6→4→2→6：预览与抬手首位均为「你好」，且前排均含「年」「面」，预览不修改会话状态。
        let stroke_nihao = stroke_digits(&kb, "6426");
        let (preview_reading, preview_words) = harness
            .session
            .preview_glide(&kb, &stroke_nihao)
            .expect("6426 预览应有结果");
        assert!(!harness.session.active(), "preview_glide 不得修改会话组字状态");
        assert_eq!(preview_reading, "ni'hao");
        assert_eq!(preview_words.first().map(String::as_str), Some("你好"));
        assert!(
            preview_words.iter().take(4).any(|w| w == "年"),
            "预览前排应并入次优「年」: {preview_words:?}"
        );
        assert!(harness.session.glide(&kb, &stroke_nihao).handled);
        let commit_words: Vec<String> = harness
            .session
            .snapshot()
            .candidates
            .iter()
            .take(3)
            .map(|c| c.word.to_string())
            .collect();
        assert_eq!(&preview_words[..commit_words.len().min(preview_words.len())], &commit_words[..]);

        harness.session.command(crate::types::Command::Cancel);

        // 2. 2→4：预览同时包含同数字串多读音（比/次）与同路径次优（才/吃），与抬手一致。
        let stroke_24 = stroke_digits(&kb, "24");
        let (_, preview_24) = harness
            .session
            .preview_glide(&kb, &stroke_24)
            .expect("24 预览应有结果");
        assert_eq!(preview_24.first().map(String::as_str), Some("比"));
        assert!(preview_24.iter().any(|w| w == "才"), "24 预览应含才: {preview_24:?}");
        assert!(preview_24.iter().any(|w| w == "吃"), "24 预览应含吃: {preview_24:?}");
    }

    #[test]
    fn nine_key_preview_glide_stitches_active_prefix_smoothly() {
        let mut harness = test_session(
            "CREATE TABLE tbl_1_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_w VALUES('wo','w','我',900000);\
             CREATE TABLE tbl_1_m(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_m VALUES('men','m','们',500000);\
             CREATE TABLE tbl_1_q(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_1_q VALUES('qu','q','去',600000);\
             CREATE TABLE tbl_2_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
             INSERT INTO tbl_2_w VALUES('wo''men','wm','我们',1200000);",
        );
        let kb = nine_key_keyboard();

        // 第一笔滑出「我」（9→6），再预演第二笔「们」（6→3→6）：实时预览应直接给出跨笔整词「我们」与合并读音 `wo'men`。
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "96")).handled);
        assert_eq!(
            harness.session.snapshot().candidates.first().map(|c| c.word.as_str()),
            Some("我")
        );
        let (preview_reading, preview_words) = harness
            .session
            .preview_glide(&kb, &stroke_digits(&kb, "636"))
            .expect("连滑第二笔预览应命中跨笔整词");
        assert_eq!(preview_reading, "wo'men");
        assert_eq!(preview_words.first().map(String::as_str), Some("我们"));

        // 正式落笔成「我们」后再预演第三笔「去」（7→8）：预览应自动拼接前缀词成「我们去」，抬手零跳变。
        assert!(harness.session.glide(&kb, &stroke_digits(&kb, "636")).handled);
        assert_eq!(
            harness.session.snapshot().candidates.first().map(|c| c.word.as_str()),
            Some("我们")
        );
        let (third_reading, third_words) = harness
            .session
            .preview_glide(&kb, &stroke_digits(&kb, "78"))
            .expect("连滑第三笔预览应拼接前缀词");
        assert_eq!(third_reading, "wo'men'qu");
        assert_eq!(third_words.first().map(String::as_str), Some("我们去"));
    }
}
