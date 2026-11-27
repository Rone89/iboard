//! 滑行输入：手指一笔滑过若干字母键，解码成它最可能拼出的全拼字母串，代价低的在前。
//!
//! 解码器只看几何，只认得音节表；按词典给这些字母串排序是会话的事。一个假设是一串字母，加上每个字母对齐到的轨迹采样点：第一个字母在第一个采样点，最后一个在最后一个，其余按次序落在中间。它的代价有四部分：
//!
//! - 每个对齐点付它到字母键中心距离的平方，所以笔画可以偏离键位一部分键宽；
//! - 两个对齐字母之间的每个采样点付它到两键连线距离的平方，所以笔画拐弯的地方必须对齐一个字母，而笔画没有拐弯的键只有恰好在连线上时才不额外付费；沿两键方向往回走也要付费，所以沿一条线来回折返的笔画（`keneng`）不会被读成只走了一遍（`keng`）；
//! - 对齐时跳过的每一次停留（手指在键上停住）付固定罚分，所以在键上停一下，即使在直线上也能确认这个键；
//! - 每个字母付一个小的固定价，所以笔画走得同样好的两个串里短的那个胜出，只是经过的键不会被当成按下。
//!
//! 坐标先除以键宽和键高，不论宿主的像素、密度和键距如何，一个键都是单位正方形。搜索对每个采样点只保留对齐在那里的少数几个最便宜的前缀（令牌传递），连线代价来自前缀和，所以一次扩展的耗时只与这个字母键附近的采样点数有关。

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

use super::syllables::{intact_pinyin_list, is_intact, MAX_SYLLABLE_LENGTH};

mod calibration;
mod lexicon;
pub use calibration::GlideKeyCalibrator;
pub use lexicon::{GlideLexiconEntry, GlideMatcher};

/// 一笔最多重采样成多少个点；更长的笔画改为更稀的采样。
const MAX_SAMPLES: usize = 128;
/// 重采样的步长，以键为单位。
const SAMPLE_STEP: f32 = 0.25;
/// 对齐一个字母时代价为 1 所对应的距离平方（键为单位）；略微放宽以包容人手弧线滑行时的自然切弯。
const ALIGN_SCALE: f32 = 0.33;
/// 首尾两个采样点（起手与抬手落点）的对齐加权：人手起止更贴近目标键，强化首尾锚定。
const ENDPOINT_ALIGN_WEIGHT: f32 = 1.65;
/// 离两键连线多远（距离平方，键为单位）时，每单位笔画长度的代价为 1；略放宽以减少自然圆弧的连线罚分。
const LINE_SCALE: f32 = 0.20;
/// 每个字母的固定价。取得小：落在另外两个键连线上的键（`z` 与 `o` 之间的 `h`、`z` 与 `i` 之间的 `u`）对齐它只比跳过它贵一点，近直线拐弯（`zui`、`sui`）能靠几何胜出，完全共线则交由词典分辨。
const LETTER_COST: f32 = 0.55;
/// 字母与前一个相同时的额外价（元音或非音节边界重复）。笔画画不出连按两次，没有它的话每个经过的键都会被再读一遍（`de` 读成 `dee`）。
const REPEAT_COST: f32 = 0.85;
/// 音节边界处的同辅音连字（如 `dian'nao`、`zhong'guo`、`nan'ning`）允许单次经过同键并在同一采样点上低价完成边界重复。
const BOUNDARY_CONSONANT_REPEAT_COST: f32 = 0.30;
/// [`rank_by_dictionary`] 重排时，词典权重的一个对数单位抵多少几何代价。
const DICTIONARY_WEIGHT: f32 = 0.7;
/// 不是词典词的串在按最罕见音节计分之外再付的代价。
const UNKNOWN_WORD_COST: f32 = 6.0;
/// 词典词每多一个音节，对数权重加多少。出货词典里常用词的权重在五十万上下、常用字在几百万，没有这一项的话，只要 `y` 落在笔画的连线上，企业（`qi'ye`）就会输给切（`qie`）。
const WORD_SYLLABLE_BONUS: f32 = 1.5;
/// 多词组合 DP 每多一次词边界切分所付的代价，确保整词始终明显优于拆词，同时避免 `zaima`/`woqu`/`haode`/`shide` 等常用高频组合被 1 键偏移的整词反超。
const COMPOSITIONAL_SPLIT_PENALTY: f32 = 1.95;
/// 束搜索中每个音节的基础切分代价与生僻度先验权重，抑制 `he'di'o`、`du'de'nv` 等无意义碎音节抢占槽位。
const SYLLABLE_PRIOR_BASE: f32 = 0.25;
const SYLLABLE_PRIOR_SCALE: f32 = 0.16;
const SYLLABLE_PRIOR_MAX_RARITY: f32 = 1.8;
/// 单字母元音音节（`a`/`e`/`o`）紧接在另一音节之后时的额外先验惩罚，避免 `hao`、`shuo`、`zhongguo` 误落成 `he'di'o`、`su'o`、`zhong'o`。
const SINGLE_VOWEL_TAIL_PENALTY: f32 = 0.85;
/// 笔画逆着一个对齐键到下一个对齐键的方向每走一个键所付的代价。只有连线代价时，笔画沿一条线来回走不花钱，于是在键盘一行上来回两次的 `laishuo` 被读成了 `lao`。
const BACKTRACK_COST: f32 = 2.0;
/// 没有字母对齐到的停留付多少。
const SKIPPED_DWELL_COST: f32 = 4.0;
/// 没有字母对齐到的瞬时减速谷（短于停留门槛但明显放慢）付多少；刻意低于 `LETTER_COST`（0.55），不诱发重复字母。
const SKIPPED_SLOW_COST: f32 = 0.40;
/// 没有字母对齐到的轨迹尖锐拐点付多少；刻意低于 `LETTER_COST`（0.55），防止噪声抖动诱导虚构多余字母，只作为真实急转弯的对齐加权。
const SKIPPED_CORNER_COST: f32 = 0.45;
/// 判定拐点的余弦阈值（约 80° 急转，配合 ±3 采样弦窗过滤高频手抖）。
const CORNER_COS_THRESHOLD: f32 = 0.17;
/// 抬手甩尾过滤的时间窗（毫秒）、最大回勾长度（键宽单位）与反向余弦阈值。
const LIFTOFF_WINDOW_MS: u32 = 18;
const LIFTOFF_MAX_LEN: f32 = 0.45;
const LIFTOFF_REVERSE_COS: f32 = -0.5;
/// 减速谷判定的最短持续时间（毫秒）及相对整笔中位速度的上限比例。
const SLOW_WINDOW_MS: u32 = 55;
const SLOW_SPEED_RATIO: f32 = 0.30;
/// 静止微抖折叠半径（键宽单位）：电容屏静止停靠时的微小抖动不应累加假弧长或触发回退罚分。
const JITTER_COLLAPSE_RADIUS: f32 = 0.18;
/// 首尾静止团折叠半径（键宽单位）：起手前或抬手前在同一键上原地晃动的多点折为单点。
const ENDPOINT_CLUSTER_RADIUS: f32 = 0.30;
/// 首尾端点空间豁免半径（键宽单位）：距首/尾点在此范围内的停留或减速一律不标记，避免把 `hao` 读成 `haoo`。
const ENDPOINT_EXEMPT_RADIUS: f32 = 0.55;
/// 离每个中段采样点都比这远（键为单位）的键不可能在串里；放宽到 1.65 以接住边缘键（`a`/`q`/`p`）的自然圆角切弯。
const NEAR_DISTANCE: f32 = 1.65;
/// 起止采样点优先收紧的邻域半径（键为单位），无命中时自动回退到 [`NEAR_DISTANCE`]。
const ENDPOINT_NEAR_DISTANCE: f32 = 1.25;
/// 每个采样点保留的前缀数。
const TOKENS_PER_SAMPLE: usize = 12;
/// 比同一采样点上最便宜的前缀贵出这么多的前缀会被丢掉。
const BEAM: f32 = 12.0;
/// 已有足够短词候选到达终点时，给更长多音节前缀保留的几何余量，防止 2–4 字母短词在词典重排前提前掐死 6–10 字母长词。
const LONGER_WORD_MARGIN: f32 = 5.5;
/// 考虑的最长字母串；拼出更长的笔画不解码。
pub const MAX_GLIDE_LETTERS: usize = 30;
/// 手指在离停下处 [`DWELL_RADIUS`] 以内停这么久算一次主动停留（高于自然减速、低于刻意停顿）。
const DWELL_MS: u32 = 115;
const DWELL_RADIUS: f32 = 0.35;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GlidePoint {
    pub x: f32,
    pub y: f32,
    /// 距笔画开始的毫秒数，宿主量了才有；只有带时间才能找出停留。
    pub time_ms: Option<u32>,
}

/// 宿主画出来的字母键，用宿主自己的坐标。
#[derive(Debug, Clone, PartialEq)]
pub struct GlideKeyboard {
    /// `a`..=`z` 各键的中心，按这个次序。
    pub centers: [(f32, f32); 26],
    pub key_width: f32,
    pub key_height: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GlideHypothesis {
    /// 小写全拼字母，不带分隔符，每个音节都完整。
    pub letters: String,
    pub cost: f32,
}

#[derive(Debug, Clone, Copy)]
struct Sample {
    x: f32,
    y: f32,
    dwell: bool,
    slow: bool,
    corner: bool,
}

impl GlideKeyboard {
    /// 这套键位能不能用来解码：键宽键高为正的有限数，键中心都有限。
    pub fn is_valid(&self) -> bool {
        self.key_width.is_finite()
            && self.key_height.is_finite()
            && self.key_width > 0.0
            && self.key_height > 0.0
            && self
                .centers
                .iter()
                .all(|(x, y)| x.is_finite() && y.is_finite())
    }

    pub(crate) fn normalized_centers(&self) -> [(f32, f32); 26] {
        self.centers
            .map(|(x, y)| (x / self.key_width, y / self.key_height))
    }
}

/// 这一笔至多 `limit` 个字母串，代价低的在前；键位无效、不足两个点、有非有限坐标，或者没有完整的全拼串跟得上这一笔时为空。
#[allow(dead_code)]
pub fn decode_glide(
    keyboard: &GlideKeyboard,
    points: &[GlidePoint],
    limit: usize,
) -> Vec<GlideHypothesis> {
    if limit == 0
        || points.len() < 2
        || !keyboard.is_valid()
        || points.iter().any(|p| !p.x.is_finite() || !p.y.is_finite())
    {
        return Vec::new();
    }
    let normalized: Vec<GlidePoint> = points
        .iter()
        .map(|p| GlidePoint {
            x: p.x / keyboard.key_width,
            y: p.y / keyboard.key_height,
            time_ms: p.time_ms,
        })
        .collect();
    let samples = resample(&normalized);
    if samples.len() < 2 {
        return Vec::new();
    }
    Decoder::new(keyboard.normalized_centers(), &samples).run(limit)
}

/// `points` 里各次停留的空间位置 `(x, y)`：手指在 [`DWELL_RADIUS`] 以内停了 [`DWELL_MS`] 或更久的地方。
fn dwell_locations(points: &[GlidePoint]) -> Vec<(f32, f32)> {
    let mut dwells = Vec::new();
    let mut start = 0;
    while start < points.len() {
        let Some(begin) = points[start].time_ms else {
            start += 1;
            continue;
        };
        let mut end = start;
        while end + 1 < points.len() && distance(points[start], points[end + 1]) <= DWELL_RADIUS {
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

fn distance(a: GlidePoint, b: GlidePoint) -> f32 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}

/// 过滤抬手最后十余毫秒内因拇指离屏产生的短距反向回勾，不改动正常连续笔画与无时间戳的合成轨迹。
fn trim_liftoff_hook(points: &[GlidePoint]) -> &[GlidePoint] {
    if points.len() < 6 {
        return points;
    }
    let (Some(first_ms), Some(last_ms)) = (points[0].time_ms, points[points.len() - 1].time_ms)
    else {
        return points;
    };
    if last_ms.saturating_sub(first_ms) < 80 {
        return points;
    }
    let mut end = points.len();
    for _ in 0..2 {
        if end < 5 {
            break;
        }
        let tail = points[end - 1];
        let prev = points[end - 2];
        let (Some(t_tail), Some(t_prev)) = (tail.time_ms, prev.time_ms) else {
            break;
        };
        if last_ms.saturating_sub(t_prev) > LIFTOFF_WINDOW_MS
            || t_tail.saturating_sub(t_prev) > LIFTOFF_WINDOW_MS
        {
            break;
        }
        let (tx, ty) = (tail.x - prev.x, tail.y - prev.y);
        let t_len = (tx * tx + ty * ty).sqrt();
        if t_len <= 1e-4 || t_len > LIFTOFF_MAX_LEN {
            break;
        }
        // 回溯找到一段有效的主行进方向（至少 0.25 个键宽），避免用微抖动当参考方向。
        let mut anchor = end - 2;
        while anchor > 0 && distance(points[anchor], prev) < 0.25 {
            anchor -= 1;
        }
        let (px, py) = (prev.x - points[anchor].x, prev.y - points[anchor].y);
        let p_len = (px * px + py * py).sqrt();
        if p_len <= 1e-4 {
            break;
        }
        let cos = (tx * px + ty * py) / (t_len * p_len);
        if cos < LIFTOFF_REVERSE_COS {
            end -= 1;
        } else {
            break;
        }
    }
    &points[..end]
}

/// 折叠静止电容抖动与首尾键原地晃动团，避免静止微抖产生假弧长并在 `a -> o` 上累积回退罚分逼出 `haoo`。
fn collapse_stationary_jitter(points: &[GlidePoint]) -> Vec<GlidePoint> {
    if points.len() <= 2 {
        return points.to_vec();
    }
    let mut clean = Vec::with_capacity(points.len());
    clean.push(points[0]);
    for &point in &points[1..] {
        if distance(*clean.last().expect("non-empty"), point) >= JITTER_COLLAPSE_RADIUS {
            clean.push(point);
        } else if let Some(last) = clean.last_mut() {
            last.time_ms = point.time_ms;
        }
    }
    // 折叠尾键静止晃动团：如果末尾连续若干点始终停在末点 `ENDPOINT_CLUSTER_RADIUS` 内，只留一个干净终点。
    let tail_anchor = *points.last().expect("non-empty");
    let mut tail_start = clean.len();
    while tail_start > 1 && distance(clean[tail_start - 1], tail_anchor) <= ENDPOINT_CLUSTER_RADIUS {
        tail_start -= 1;
    }
    if tail_start < clean.len() {
        let kept_end = tail_start + 1;
        clean.truncate(kept_end);
        if let Some(last) = clean.last_mut() {
            last.time_ms = tail_anchor.time_ms;
        }
    }
    // 折叠首键静止晃动团。
    let head_anchor = points[0];
    let mut head_end = 0;
    while head_end + 2 < clean.len()
        && distance(clean[head_end + 1], head_anchor) <= ENDPOINT_CLUSTER_RADIUS
    {
        head_end += 1;
    }
    if head_end > 0 {
        clean.drain(1..=head_end);
    }
    if clean.len() < 2 {
        return vec![points[0], *points.last().expect("non-empty")];
    }
    clean
}

/// 找出未达到停留时长但瞬时速度跌至整笔中位速度一定比例以下的减速谷空间位置 `(x, y)`。
fn slow_locations(points: &[GlidePoint]) -> Vec<(f32, f32)> {
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
    for index in 1..points.len() {
        let (Some(t0), Some(t1)) = (points[index - 1].time_ms, points[index].time_ms) else {
            continue;
        };
        let dt = t1.saturating_sub(t0);
        if dt > 0 {
            let ds = distance(points[index - 1], points[index]);
            speeds.push(ds / dt as f32);
        }
    }
    if speeds.len() < 4 {
        return Vec::new();
    }
    speeds.sort_by(f32::total_cmp);
    let median = speeds[speeds.len() / 2];
    let threshold = median * SLOW_SPEED_RATIO;
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
            let ds = distance(points[end], points[end + 1]);
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

/// 在等距重采样点上用 ±3 步（约 0.75 键宽）弦向量检测真实急转拐点，并做 ±3 邻域非极大值抑制，过滤手抖噪声。
fn mark_corners(samples: &mut [Sample]) {
    if samples.len() < 9 {
        return;
    }
    let n = samples.len();
    let mut sharpness = vec![0.0f32; n];
    for i in 3..(n - 3) {
        let (ax, ay) = (samples[i].x - samples[i - 3].x, samples[i].y - samples[i - 3].y);
        let (bx, by) = (samples[i + 3].x - samples[i].x, samples[i + 3].y - samples[i].y);
        let a_len = (ax * ax + ay * ay).sqrt();
        let b_len = (bx * bx + by * by).sqrt();
        if a_len < 0.45 || b_len < 0.45 {
            continue;
        }
        let cos = ((ax * bx + ay * by) / (a_len * b_len)).clamp(-1.0, 1.0);
        if cos <= CORNER_COS_THRESHOLD {
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
        let is_peak = (lo..=hi).all(|j| j == i || sharpness[j] < score || (sharpness[j] == score && j > i));
        if is_peak {
            samples[i].corner = true;
        }
    }
}

/// 沿笔画等距的采样点，含两端，先折叠静止微抖再重采样，并按空间坐标投影中间键的停留、减速谷与拐点。
fn resample(points: &[GlidePoint]) -> Vec<Sample> {
    let raw = trim_liftoff_hook(points);
    let clean = collapse_stationary_jitter(raw);
    let mut arc = Vec::with_capacity(clean.len());
    let mut length = 0.0;
    arc.push(0.0);
    for pair in clean.windows(2) {
        length += distance(pair[0], pair[1]);
        arc.push(length);
    }
    let step = SAMPLE_STEP.max(length / (MAX_SAMPLES - 1) as f32);
    let count = ((length / step).ceil() as usize + 1).clamp(2, MAX_SAMPLES);
    let mut samples = Vec::with_capacity(count);
    let mut segment = 0;
    for index in 0..count {
        let target = length * index as f32 / (count - 1) as f32;
        while segment + 2 < arc.len() && arc[segment + 1] < target {
            segment += 1;
        }
        let (a, b) = (clean[segment], clean[segment + 1]);
        let span = arc[segment + 1] - arc[segment];
        let t = if span > 0.0 {
            ((target - arc[segment]) / span).clamp(0.0, 1.0)
        } else {
            0.0
        };
        samples.push(Sample {
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t,
            dwell: false,
            slow: false,
            corner: false,
        });
    }
    if length > 0.0 && count >= 5 {
        let head = clean[0];
        let tail = *clean.last().expect("non-empty");
        let exempt_sq = ENDPOINT_EXEMPT_RADIUS * ENDPOINT_EXEMPT_RADIUS;
        let max_interior = count - 3;
        let nearest_interior = |x: f32, y: f32, list: &[Sample]| -> Option<usize> {
            let d_head = (x - head.x).powi(2) + (y - head.y).powi(2);
            let d_tail = (x - tail.x).powi(2) + (y - tail.y).powi(2);
            if d_head <= exempt_sq || d_tail <= exempt_sq {
                return None;
            }
            (2..=max_interior)
                .map(|i| (i, (list[i].x - x).powi(2) + (list[i].y - y).powi(2)))
                .min_by(|a, b| a.1.total_cmp(&b.1))
                .filter(|&(_, dist_sq)| dist_sq <= DWELL_RADIUS * DWELL_RADIUS)
                .map(|(i, _)| i)
        };
        for (dx, dy) in dwell_locations(raw) {
            if let Some(index) = nearest_interior(dx, dy, &samples) {
                samples[index].dwell = true;
            }
        }
        for (sx, sy) in slow_locations(raw) {
            if let Some(index) = nearest_interior(sx, sy, &samples) {
                samples[index].slow = true;
            }
        }
        mark_corners(&mut samples);
    }
    samples
}

/// 完整音节组成的字母前缀树。节点 0 是根，也代表一个恰好结束在两个音节之间的前缀。
/// 同时保存每个音节由出货词库统计的先验惩罚及子树最小先验，供束搜索在剪枝阶段优先保留自然中文音节。
struct SyllableTrie {
    /// 每个字母的子节点；0 表示没有，因为根不会是谁的子节点。
    children: Vec<[u16; 26]>,
    intact: Vec<bool>,
    /// 节点为完整音节时的音节先验代价；非完整音节为 `f32::INFINITY`。
    intact_prior: Vec<f32>,
    /// 以该节点为前缀的所有完整音节中最小的先验代价（用于未完成音节的可容许下界）。
    min_subtree_prior: Vec<f32>,
    /// 节点有字母 `l` 的子节点时第 `l` 位为 1。
    masks: Vec<u32>,
}

/// 26 键滑行不会刻意用 `v` 代替 `j/q/x/y` 后的 `u`，而 `v` 恰好位于键盘底排中央，极易被对角轨迹误拼出 `xv`/`yv`/`jv` 垃圾音节；仅保留必须用 `v` 区分的 `lv`/`lve`/`nv`/`nve`。
fn is_redundant_v_alias(syllable: &str) -> bool {
    matches!(
        syllable,
        "jv" | "jve" | "qv" | "qve" | "xv" | "xve" | "yv" | "yve"
    )
}

fn syllable_trie() -> &'static SyllableTrie {
    static TRIE: OnceLock<SyllableTrie> = OnceLock::new();
    TRIE.get_or_init(|| {
        let mut freqs: HashMap<&'static str, u64> = HashMap::new();
        for line in crate::nine_key::SYLLABLE_FREQUENCY.lines() {
            let mut parts = line.split('\t');
            let (Some(syl), Some(weight)) = (parts.next(), parts.next()) else {
                continue;
            };
            if let Ok(w) = weight.parse::<u64>() {
                freqs.insert(syl, w);
            }
        }
        let max_freq = freqs.values().copied().max().unwrap_or(1).max(1) as f64;

        let mut trie = SyllableTrie {
            children: vec![[0; 26]],
            intact: vec![false],
            intact_prior: vec![f32::INFINITY],
            min_subtree_prior: vec![f32::INFINITY],
            masks: Vec::new(),
        };
        for &syllable in intact_pinyin_list() {
            if is_redundant_v_alias(syllable) {
                continue;
            }
            let freq = freqs.get(syllable).copied().unwrap_or(1).max(1) as f64;
            let rarity = ((max_freq / freq).ln() as f32 * SYLLABLE_PRIOR_SCALE)
                .clamp(0.0, SYLLABLE_PRIOR_MAX_RARITY);
            let prior = SYLLABLE_PRIOR_BASE + rarity;
            let mut node = 0;
            for &letter in syllable.as_bytes() {
                let slot = usize::from(letter - b'a');
                if trie.children[node][slot] == 0 {
                    trie.children.push([0; 26]);
                    trie.intact.push(false);
                    trie.intact_prior.push(f32::INFINITY);
                    trie.min_subtree_prior.push(f32::INFINITY);
                    trie.children[node][slot] =
                        u16::try_from(trie.children.len() - 1).expect("the syllable trie is small");
                }
                node = usize::from(trie.children[node][slot]);
                trie.min_subtree_prior[node] = trie.min_subtree_prior[node].min(prior);
            }
            trie.intact[node] = true;
            trie.intact_prior[node] = prior;
        }
        trie.min_subtree_prior[0] = SYLLABLE_PRIOR_BASE;
        trie.masks = trie
            .children
            .iter()
            .map(|children| {
                (0..26)
                    .filter(|&letter| children[letter] != 0)
                    .fold(0, |mask, letter| mask | 1 << letter)
            })
            .collect();
        trie
    })
}

/// 一个前缀在音节前缀树里同时活跃的状态上限：长度 1..=5 的后缀各至多 1 个节点，加上根节点 0，最多 6 个。
const MAX_TRIE_STATES: usize = 6;

impl SyllableTrie {
    /// `states` 里某种切分后面可以接的字母。
    fn followers(&self, states: &[u16]) -> u32 {
        states
            .iter()
            .fold(0, |mask, &state| mask | self.masks[usize::from(state)])
    }

    /// 把在 `states` 所示切分的前缀后面接上 `letter` 之后、每种合法切分的状态写进栈缓冲区并返回数量。
    fn extend(&self, states: &[u16], letter: u8, next: &mut [u16; MAX_TRIE_STATES]) -> usize {
        let mut len = 0usize;
        for &state in states {
            let child = self.children[usize::from(state)][usize::from(letter)];
            if child == 0 {
                continue;
            }
            let node = usize::from(child);
            if self.intact[node] && !next[..len].contains(&0) && len < MAX_TRIE_STATES {
                next[len] = 0;
                len += 1;
            }
            if self.masks[node] != 0 && !next[..len].contains(&child) && len < MAX_TRIE_STATES {
                next[len] = child;
                len += 1;
            }
        }
        len
    }

    /// 计算字母前缀在所有合法音节切分（可含末尾未完音节）下的最小先验代价，零堆分配。
    fn segmentation_prior(&self, letters: &[u8]) -> f32 {
        let len = letters.len();
        if len == 0 || len > MAX_GLIDE_LETTERS {
            return 0.0;
        }
        let mut dp = [f32::INFINITY; MAX_GLIDE_LETTERS + 1];
        dp[0] = 0.0;
        let mut best_partial = f32::INFINITY;
        for start in 0..len {
            let base = dp[start];
            if !base.is_finite() {
                continue;
            }
            let mut node = 0usize;
            let max_end = (start + MAX_SYLLABLE_LENGTH).min(len);
            for end in (start + 1)..=max_end {
                let child = self.children[node][usize::from(letters[end - 1])];
                if child == 0 {
                    break;
                }
                node = usize::from(child);
                if self.intact[node] {
                    let mut step = self.intact_prior[node];
                    if start > 0 && end - start == 1 {
                        step += SINGLE_VOWEL_TAIL_PENALTY;
                    }
                    let next_cost = base + step;
                    if next_cost < dp[end] {
                        dp[end] = next_cost;
                    }
                }
                if end == len {
                    let mut partial = self.min_subtree_prior[node];
                    if start > 0 && end - start == 1 && self.intact[node] && self.masks[node] == 0 {
                        partial += SINGLE_VOWEL_TAIL_PENALTY;
                    }
                    let next_cost = base + partial;
                    if next_cost < best_partial {
                        best_partial = next_cost;
                    }
                }
            }
        }
        let result = dp[len].min(best_partial);
        if result.is_finite() {
            result
        } else {
            0.0
        }
    }

    /// 完整串是否只能通过把单字母元音音节（`a`/`e`/`o`）粘在另一音节后面才能切分（如 `he'di'o`、`zhong'o`）。
    /// 不引入词频（避免与 `rank_by_dictionary` 双重计权），仅做结构正则。
    fn structural_tail_penalty(&self, letters: &[u8]) -> f32 {
        let len = letters.len();
        if len <= 1 || len > MAX_GLIDE_LETTERS {
            return 0.0;
        }
        let mut dp = [f32::INFINITY; MAX_GLIDE_LETTERS + 1];
        dp[0] = 0.0;
        for start in 0..len {
            let base = dp[start];
            if !base.is_finite() {
                continue;
            }
            let mut node = 0usize;
            let max_end = (start + MAX_SYLLABLE_LENGTH).min(len);
            for end in (start + 1)..=max_end {
                let child = self.children[node][usize::from(letters[end - 1])];
                if child == 0 {
                    break;
                }
                node = usize::from(child);
                if self.intact[node] {
                    let penalty = if start > 0 && end - start == 1 {
                        SINGLE_VOWEL_TAIL_PENALTY
                    } else {
                        0.0
                    };
                    let next_cost = base + penalty;
                    if next_cost < dp[end] {
                        dp[end] = next_cost;
                    }
                }
            }
        }
        if dp[len].is_finite() {
            dp[len]
        } else {
            0.0
        }
    }
}

/// 一个字母前缀（字母记作 `0..26`）、它各种合法切分在前缀树里的状态，以及它对齐到各采样点的代价，按采样点排序。`letters` 与 `states` 驻留在栈定长数组，避免束扩展高频堆分配。
struct Prefix {
    letters: [u8; MAX_GLIDE_LETTERS],
    letters_len: u8,
    states: [u16; MAX_TRIE_STATES],
    states_len: u8,
    costs: Vec<(usize, f32)>,
    prior: f32,
}

impl Prefix {
    fn empty() -> Self {
        Self {
            letters: [0; MAX_GLIDE_LETTERS],
            letters_len: 0,
            states: [0; MAX_TRIE_STATES],
            states_len: 0,
            costs: Vec::new(),
            prior: 0.0,
        }
    }

    #[inline]
    fn letters_slice(&self) -> &[u8] {
        &self.letters[..usize::from(self.letters_len)]
    }

    #[inline]
    fn states_slice(&self) -> &[u16] {
        &self.states[..usize::from(self.states_len)]
    }
}

/// `prune` 跨 beam 轮次复用的临时容器，避免每轮为采样点和前缀重新建嵌套向量。
struct PruneScratch {
    at: Vec<Vec<(f32, usize, usize)>>,
    keep: Vec<Vec<bool>>,
}

impl PruneScratch {
    fn new(count: usize) -> Self {
        Self {
            at: (0..count).map(|_| Vec::new()).collect(),
            keep: Vec::new(),
        }
    }
}

struct Decoder {
    /// 把字母 `l` 对齐到采样点 `j` 的代价是 `align[l][j]`；笔画从没靠近的字母为 `None`。
    align: [Option<Vec<f32>>; 26],
    /// 离各字母键 [`NEAR_DISTANCE`] 以内的采样点，升序：字母只对齐到这些地方。
    reach: [Vec<usize>; 26],
    /// 字母对 `from * 26 + to` 的逐点累计代价：偏离两键连线、沿连线往回走、跳过停留；第 `j` 项覆盖采样点 `0..=j`。只为两个字母都靠近笔画的字母对填写。
    lines: Vec<Option<Vec<f32>>>,
    samples_xy: Vec<(f32, f32)>,
    count: usize,
}

impl Decoder {
    fn new(centers: [(f32, f32); 26], samples: &[Sample]) -> Self {
        let length: f32 = samples
            .windows(2)
            .map(|pair| ((pair[0].x - pair[1].x).powi(2) + (pair[0].y - pair[1].y).powi(2)).sqrt())
            .sum();
        // 每个采样点代表的笔画长度，这样连线代价与采样疏密无关。
        let weight = length / (samples.len() - 1) as f32;
        let near = NEAR_DISTANCE * NEAR_DISTANCE;
        let endpoint_near = ENDPOINT_NEAR_DISTANCE * ENDPOINT_NEAR_DISTANCE;
        let last = samples.len() - 1;
        let squared: [Vec<f32>; 26] = std::array::from_fn(|letter| {
            let (cx, cy) = centers[letter];
            samples
                .iter()
                .map(|s| (s.x - cx).powi(2) + (s.y - cy).powi(2))
                .collect()
        });
        let start_limit = if (0..26).any(|l| squared[l][0] <= endpoint_near) {
            endpoint_near
        } else {
            near
        };
        let end_limit = if (0..26).any(|l| squared[l][last] <= endpoint_near) {
            endpoint_near
        } else {
            near
        };
        let reach: [Vec<usize>; 26] = std::array::from_fn(|letter| {
            (0..samples.len())
                .filter(|&j| {
                    let limit = if j == 0 {
                        start_limit
                    } else if j == last {
                        end_limit
                    } else {
                        near
                    };
                    squared[letter][j] <= limit
                })
                .collect()
        });
        let align: [Option<Vec<f32>>; 26] = std::array::from_fn(|letter| {
            (!reach[letter].is_empty()).then(|| {
                squared[letter]
                    .iter()
                    .enumerate()
                    .map(|(j, &d)| {
                        let base = d / ALIGN_SCALE;
                        if j == 0 || j == last {
                            base * ENDPOINT_ALIGN_WEIGHT
                        } else {
                            base
                        }
                    })
                    .collect()
            })
        });
        let mut lines = vec![None; 26 * 26];
        for from in 0..26 {
            for to in 0..26 {
                if align[from].is_none() || align[to].is_none() {
                    continue;
                }
                let a = centers[from];
                let b = centers[to];
                let (dx, dy) = (b.0 - a.0, b.1 - a.1);
                let span = dx * dx + dy * dy;
                let length = span.sqrt();
                let mut total = 0.0;
                let mut previous: Option<&Sample> = None;
                lines[from * 26 + to] = Some(
                    samples
                        .iter()
                        .map(|s| {
                            if let Some(p) = previous.filter(|_| length > 0.0) {
                                let along = ((s.x - p.x) * dx + (s.y - p.y) * dy) / length;
                                total += (-along).max(0.0) * BACKTRACK_COST;
                            }
                            previous = Some(s);
                            let t = if span > 0.0 {
                                (((s.x - a.0) * dx + (s.y - a.1) * dy) / span).clamp(0.0, 1.0)
                            } else {
                                0.0
                            };
                            let off = (s.x - a.0 - dx * t).powi(2) + (s.y - a.1 - dy * t).powi(2);
                            total += off / LINE_SCALE * weight;
                            if s.dwell {
                                total += SKIPPED_DWELL_COST;
                            } else if s.slow {
                                total += SKIPPED_SLOW_COST;
                            }
                            if s.corner && !s.dwell {
                                total += SKIPPED_CORNER_COST;
                            }
                            total
                        })
                        .collect(),
                );
            }
        }
        Self {
            align,
            reach,
            lines,
            samples_xy: samples.iter().map(|s| (s.x, s.y)).collect(),
            count: samples.len(),
        }
    }

    fn run(&self, limit: usize) -> Vec<GlideHypothesis> {
        let trie = syllable_trie();
        let count = self.count;
        let last = count - 1;
        let near: Vec<u8> = (0..26u8)
            .filter(|&letter| self.align[usize::from(letter)].is_some())
            .collect();
        let mut states = [0u16; MAX_TRIE_STATES];
        let mut level: Vec<Prefix> = Vec::new();
        for &letter in &near {
            // 第一个字母在第一个采样点上。
            if self.reach[usize::from(letter)].first() != Some(&0) {
                continue;
            }
            let states_len = trie.extend(&[0], letter, &mut states);
            if states_len == 0 {
                continue;
            }
            let cost = self.align[usize::from(letter)].as_ref().expect("near")[0] + LETTER_COST;
            let mut prefix = Prefix::empty();
            prefix.letters[0] = letter;
            prefix.letters_len = 1;
            prefix.states = states;
            prefix.states_len = states_len as u8;
            prefix.costs.push((0, cost));
            prefix.prior = trie.segmentation_prior(&[letter]);
            level.push(prefix);
        }
        let mut finals: Vec<GlideHypothesis> = Vec::new();
        let mut floors = vec![f32::INFINITY; count];
        let mut prune_scratch = PruneScratch::new(count);
        let mut recycled = Vec::new();
        for _ in 1..MAX_GLIDE_LETTERS {
            floors.fill(f32::INFINITY);
            let mut next = Vec::new();
            for prefix in &level {
                let p_letters = prefix.letters_slice();
                let p_states = prefix.states_slice();
                let from = usize::from(*p_letters.last().expect("prefixes are never empty"));
                let followers = trie.followers(p_states);
                let earliest = prefix.costs[0].0;
                let at_syllable_boundary = p_states.contains(&0);
                for &letter in &near {
                    let is_repeat = usize::from(letter) == from;
                    let is_vowel = matches!(letter, 0 | 4 | 8 | 14 | 20);
                    let boundary_consonant_repeat =
                        is_repeat && !is_vowel && at_syllable_boundary;
                    // 只扩展音节允许接在后面、并且键位在前缀最早对齐点之后还会被经过的字母（边界同辅音连字允许复对齐到同一采样点）。
                    let last_reach = self.reach[usize::from(letter)].last();
                    if followers & 1 << letter == 0
                        || if boundary_consonant_repeat {
                            last_reach < Some(&earliest)
                        } else {
                            last_reach <= Some(&earliest)
                        }
                    {
                        continue;
                    }
                    let states_len = trie.extend(p_states, letter, &mut states);
                    if states_len == 0 {
                        continue;
                    }
                    let lines = self.lines[from * 26 + usize::from(letter)]
                        .as_deref()
                        .expect("lines are filled for every pair of near letters");
                    let align = self.align[usize::from(letter)].as_deref().expect("near");
                    let step = if boundary_consonant_repeat {
                        LETTER_COST + BOUNDARY_CONSONANT_REPEAT_COST
                    } else if is_repeat {
                        LETTER_COST + REPEAT_COST
                    } else {
                        LETTER_COST
                    };
                    let mut candidate = recycled.pop().unwrap_or_else(Prefix::empty);
                    let next_len = p_letters.len() + 1;
                    candidate.letters[..p_letters.len()].copy_from_slice(p_letters);
                    candidate.letters[p_letters.len()] = letter;
                    candidate.letters_len = next_len as u8;
                    candidate.prior = trie.segmentation_prior(candidate.letters_slice());
                    candidate.costs.clear();
                    // `best` 是所有对齐点 i < j 上 cost[i] - lines[i] 的最小值；i 与 j 之间的采样点再付 lines[j - 1] - lines[i]。
                    let mut best = f32::INFINITY;
                    let mut taken = 0;
                    for &j in &self.reach[usize::from(letter)] {
                        while taken < prefix.costs.len() && prefix.costs[taken].0 < j {
                            let (i, cost) = prefix.costs[taken];
                            best = best.min(cost - lines[i]);
                            taken += 1;
                        }
                        let mut cost = if best.is_finite() {
                            best + lines[j - 1] + align[j] + step
                        } else {
                            f32::INFINITY
                        };
                        // 音节边界同辅音（如 `dian'nao`、`zhong'guo`）允许在同一点完成一次滑过，不再重复收取 `align[j]` 与 `LETTER_COST`。
                        if boundary_consonant_repeat
                            && taken < prefix.costs.len()
                            && prefix.costs[taken].0 == j
                        {
                            cost = cost.min(prefix.costs[taken].1 + BOUNDARY_CONSONANT_REPEAT_COST);
                        }
                        if !cost.is_finite() {
                            continue;
                        }
                        let ranked_cost = cost + candidate.prior;
                        if ranked_cost <= floors[j] + BEAM {
                            floors[j] = floors[j].min(ranked_cost);
                            candidate.costs.push((j, cost));
                        }
                    }
                    if candidate.costs.is_empty() {
                        recycled.push(candidate);
                        continue;
                    }
                    candidate.states = states;
                    candidate.states_len = states_len as u8;
                    next.push(candidate);
                }
            }
            recycled.append(&mut level);
            prune(&mut next, &mut prune_scratch, &mut recycled);
            finals.extend(next.iter().filter_map(|prefix| {
                let &(at, cost) = prefix.costs.last()?;
                (at == last && prefix.states_slice().contains(&0)).then(|| {
                    let letters_slice = prefix.letters_slice();
                    let tail_penalty = trie.structural_tail_penalty(letters_slice);
                    GlideHypothesis {
                        letters: letters_slice
                            .iter()
                            .map(|&l| char::from(b'a' + l))
                            .collect(),
                        cost: cost + tail_penalty,
                    }
                })
            }));
            // 给尚未走完的多音节长词保留 `LONGER_WORD_MARGIN` 几何余量，防止短词在词典重排前提前把长词剪死。
            if finals.len() >= limit {
                finals.select_nth_unstable_by(limit - 1, |a, b| a.cost.total_cmp(&b.cost));
                finals.truncate(limit);
                let ceiling = finals
                    .iter()
                    .map(|hypothesis| hypothesis.cost)
                    .fold(f32::NEG_INFINITY, f32::max)
                    + LONGER_WORD_MARGIN;
                for prefix in &mut next {
                    prefix.costs.retain(|&(_, cost)| cost < ceiling);
                }
                let current = std::mem::take(&mut next);
                next = current
                    .into_iter()
                    .filter_map(|prefix| {
                        if prefix.costs.is_empty() {
                            recycled.push(prefix);
                            None
                        } else {
                            Some(prefix)
                        }
                    })
                    .collect();
            }
            if next.is_empty() {
                break;
            }
            level = next;
        }
        finals.sort_by(|a, b| {
            a.cost
                .total_cmp(&b.cost)
                .then_with(|| a.letters.cmp(&b.letters))
        });
        finals.truncate(limit);
        finals
    }
}

/// 在每个采样点上只保留 [`TOKENS_PER_SAMPLE`] 个综合几何与音节先验最便宜、且与最便宜者相差不超过 [`BEAM`] 的前缀；哪里都没保留的前缀丢掉。
fn prune(prefixes: &mut Vec<Prefix>, scratch: &mut PruneScratch, recycled: &mut Vec<Prefix>) {
    for tokens in &mut scratch.at {
        tokens.clear();
    }
    for (p, prefix) in prefixes.iter().enumerate() {
        let prior = prefix.prior;
        for (entry, &(j, cost)) in prefix.costs.iter().enumerate() {
            scratch.at[j].push((cost + prior, p, entry));
        }
    }
    scratch.keep.resize_with(prefixes.len(), Vec::new);
    for (prefix, keep) in prefixes.iter().zip(&mut scratch.keep) {
        keep.clear();
        keep.resize(prefix.costs.len(), false);
    }
    for tokens in &mut scratch.at {
        if tokens.len() > TOKENS_PER_SAMPLE {
            tokens.select_nth_unstable_by(TOKENS_PER_SAMPLE - 1, |a, b| a.0.total_cmp(&b.0));
            tokens.truncate(TOKENS_PER_SAMPLE);
        }
        let floor = tokens
            .iter()
            .map(|token| token.0)
            .fold(f32::INFINITY, f32::min);
        for &(cost, p, entry) in tokens.iter() {
            if cost <= floor + BEAM {
                scratch.keep[p][entry] = true;
            }
        }
    }
    for (prefix, keep) in prefixes.iter_mut().zip(&scratch.keep) {
        let mut flags = keep.iter();
        prefix
            .costs
            .retain(|_| *flags.next().expect("one flag per entry"));
    }
    let current = std::mem::take(prefixes);
    *prefixes = Vec::with_capacity(current.len());
    for prefix in current {
        if prefix.costs.is_empty() {
            recycled.push(prefix);
        } else {
            prefixes.push(prefix);
        }
    }
}

/// 把 `letters` 切成完整音节的各种切法，至多 `limit` 种。
struct SyllableSplits<'a> {
    syllables: Vec<&'a str>,
    ranges: Vec<SplitRange>,
}

struct SplitRange {
    range: std::ops::Range<usize>,
    key: String,
}

impl<'a> SyllableSplits<'a> {
    fn new(letters: &'a str, limit: usize) -> Self {
        Self {
            syllables: Vec::with_capacity(letters.len().saturating_mul(limit)),
            ranges: Vec::with_capacity(limit),
        }
    }

    fn iter(&self) -> impl Iterator<Item = &[&'a str]> {
        self.ranges
            .iter()
            .map(|range| &self.syllables[range.range.clone()])
    }
}

fn syllable_splits(letters: &str, limit: usize) -> SyllableSplits<'_> {
    fn walk<'a>(
        rest: &'a str,
        split: &mut Vec<&'a str>,
        found: &mut SyllableSplits<'a>,
        limit: usize,
    ) {
        if found.ranges.len() >= limit {
            return;
        }
        if rest.is_empty() {
            let start = found.syllables.len();
            found.syllables.extend_from_slice(split);
            found.ranges.push(SplitRange {
                range: start..found.syllables.len(),
                key: split.join("'"),
            });
            return;
        }
        for end in (1..=rest.len().min(MAX_SYLLABLE_LENGTH)).rev() {
            if is_intact(&rest[..end]) {
                split.push(&rest[..end]);
                walk(&rest[end..], split, found, limit);
                split.pop();
            }
        }
    }
    let mut found = SyllableSplits::new(letters, limit);
    let mut split = Vec::with_capacity(letters.len());
    walk(letters, &mut split, &mut found, limit);
    found
}

/// 按笔画与串的吻合程度和词典给出的常用程度重排解码出的串。
///
/// `weights` 对一组词典键（以 `'` 连接的音节）回答它认得的每个键下最好那一行的权重。
/// - 整个串命中整词时按最高整词权重 + 多音节词奖励计分；
/// - 未命中整词但能由已知词/高频单音节组合覆盖（2–6 音节短语，如 `chi'fan+le`、`wo+qu`、`bu+zhi'dao`）时，通过组合 DP 按平均词段对数权重 + 词内跨度奖励 − 词界切分惩罚计分，确保整词仍严格优于拆词，同时常见组合短语远胜零散生僻音节；
/// - 含词典未知音节的串退回按最罕见音节计分再减 [`UNKNOWN_WORD_COST`]。
#[cfg(test)]
pub fn rank_by_dictionary(
    hypotheses: Vec<GlideHypothesis>,
    weights: impl FnOnce(&[String]) -> HashMap<String, i64>,
) -> Vec<GlideHypothesis> {
    rank_by_dictionary_with_prefix(hypotheses, None, weights)
}

/// 同 [`rank_by_dictionary`]，并在连续滑行（已有未上屏组字前缀 `prefix_syllables`，如 `"wo"` 或 `"jin'tian"`）时
/// 同步查询拼接整词键 `"{prefix}'{key}"`（如 `"wo'men"`）：若与前文凑成高频整词，则赋予连词加分，避免续滑被孤立高频单字反超。
pub fn rank_by_dictionary_with_prefix(
    hypotheses: Vec<GlideHypothesis>,
    prefix_syllables: Option<&str>,
    weights: impl FnOnce(&[String]) -> HashMap<String, i64>,
) -> Vec<GlideHypothesis> {
    const SPLITS: usize = 8;
    const MAX_COMP_SYLLABLES: usize = 6;
    let prefix_syllables = prefix_syllables.filter(|p| !p.is_empty());
    let splits: Vec<SyllableSplits<'_>> = hypotheses
        .iter()
        .map(|hypothesis| syllable_splits(&hypothesis.letters, SPLITS))
        .collect();
    let key_capacity = splits
        .iter()
        .map(|hypothesis| {
            hypothesis
                .iter()
                .map(|split| split.len() + 1)
                .sum::<usize>()
        })
        .sum();
    let mut unique: HashSet<&str> = HashSet::with_capacity(key_capacity);
    let mut keys = Vec::with_capacity(key_capacity);
    for hypothesis in &splits {
        for range in &hypothesis.ranges {
            if unique.insert(range.key.as_str()) {
                keys.push(range.key.clone());
            }
            let slice = &hypothesis.syllables[range.range.clone()];
            for &syllable in slice {
                if unique.insert(syllable) {
                    keys.push(syllable.to_owned());
                }
            }
        }
    }
    // 连续滑行时顺带把 `prefix'key` 放进同一批查询，零额外往返即可识别「我 + 们 → 我们」这类跨笔整词。
    if let Some(prefix) = prefix_syllables {
        let mut combined_buf = String::new();
        for hypothesis in &splits {
            for range in &hypothesis.ranges {
                combined_buf.clear();
                combined_buf.push_str(prefix);
                combined_buf.push('\'');
                combined_buf.push_str(&range.key);
                if !unique.contains(combined_buf.as_str()) {
                    keys.push(combined_buf.clone());
                }
            }
        }
    }
    // 对 3..=6 音节的切分额外收集 2–3 音节子词键进同一批 SQL 查询，支持 `chi'fan+le`、`bu+zhi'dao` 等多词组合 DP。
    // 直接追加后再排序去重，避免 `HashSet<String>` 带来的双倍堆分配。
    let mut sub_key_buf = String::new();
    for hypothesis in &splits {
        for range in &hypothesis.ranges {
            let slice = &hypothesis.syllables[range.range.clone()];
            if (3..=MAX_COMP_SYLLABLES).contains(&slice.len()) {
                for start in 0..slice.len() {
                    for span in 2..=3 {
                        let end = start + span;
                        if end > slice.len() || (start == 0 && end == slice.len()) {
                            continue;
                        }
                        sub_key_buf.clear();
                        for (idx, &syl) in slice[start..end].iter().enumerate() {
                            if idx > 0 {
                                sub_key_buf.push('\'');
                            }
                            sub_key_buf.push_str(syl);
                        }
                        if !unique.contains(sub_key_buf.as_str()) {
                            keys.push(sub_key_buf.clone());
                        }
                    }
                }
            }
        }
    }
    keys.sort_unstable();
    keys.dedup();
    let known = weights(&keys);
    let scores: Vec<f32> = splits
        .iter()
        .map(|splits| {
            let mut best_word: Option<f32> = None;
            let mut best_compositional: Option<f32> = None;
            let mut sub_buf = String::with_capacity(24);
            for (range, split) in splits.ranges.iter().zip(splits.iter()) {
                let k = split.len();
                if let Some(prefix) = prefix_syllables {
                    sub_buf.clear();
                    sub_buf.push_str(prefix);
                    sub_buf.push('\'');
                    sub_buf.push_str(&range.key);
                    if let Some(&combined_weight) = known.get(sub_buf.as_str()) {
                        // 跨笔拼成词典整词时给予 1 个音节桥接加成，帮助续滑消歧（例如 `wo` 后续滑 `men` 胜过 `ren`）。
                        let combined_score = (combined_weight.max(0) as f32).ln_1p()
                            + WORD_SYLLABLE_BONUS * (k as f32);
                        best_word =
                            Some(best_word.map_or(combined_score, |b| b.max(combined_score)));
                    }
                }
                if let Some(&weight) = known.get(&range.key) {
                    let score = (weight.max(0) as f32).ln_1p()
                        + WORD_SYLLABLE_BONUS * (k - 1) as f32;
                    best_word = Some(best_word.map_or(score, |b| b.max(score)));
                    continue;
                }
                if (2..=MAX_COMP_SYLLABLES).contains(&k) {
                    // dp[pos][segments] = 覆盖 split[0..pos] 用恰好 segments 个已知词段时的最大 (最小段对数权重, 对数权重和)。
                    // 组合短语偏向按最弱词段约束（防止高频单字 `de`/`yi` 拉高 `ha'si+de`、`za+si'ma` 等假拆词反超真整词）。
                    let mut dp = [[(f32::NEG_INFINITY, f32::NEG_INFINITY); MAX_COMP_SYLLABLES + 1];
                        MAX_COMP_SYLLABLES + 1];
                    dp[0][0] = (f32::INFINITY, 0.0);
                    for start in 0..k {
                        for segs in 0..=start {
                            let (base_min, base_sum) = dp[start][segs];
                            if !base_sum.is_finite() {
                                continue;
                            }
                            for span in 1..=3.min(k - start) {
                                if start == 0 && span == k {
                                    continue;
                                }
                                let weight_opt = if span == 1 {
                                    known.get(split[start]).copied()
                                } else {
                                    sub_buf.clear();
                                    for (idx, &syl) in split[start..start + span].iter().enumerate() {
                                        if idx > 0 {
                                            sub_buf.push('\'');
                                        }
                                        sub_buf.push_str(syl);
                                    }
                                    known.get(sub_buf.as_str()).copied()
                                };
                                let Some(w) = weight_opt else { continue };
                                let ln_w = (w.max(0) as f32).ln_1p();
                                let next_min = base_min.min(ln_w);
                                let next_sum = base_sum + ln_w;
                                let next_metric = next_min * 0.65 + (next_sum / (segs + 1) as f32) * 0.35;
                                let (cur_min, cur_sum) = dp[start + span][segs + 1];
                                let cur_metric = if cur_sum.is_finite() {
                                    cur_min * 0.65 + (cur_sum / (segs + 1) as f32) * 0.35
                                } else {
                                    f32::NEG_INFINITY
                                };
                                if next_metric > cur_metric {
                                    dp[start + span][segs + 1] = (next_min, next_sum);
                                }
                            }
                        }
                    }
                    for segs in 2..=k {
                        let (min_w, sum) = dp[k][segs];
                        if sum.is_finite() {
                            let blended = min_w * 0.65 + (sum / segs as f32) * 0.35;
                            let score = blended
                                + WORD_SYLLABLE_BONUS * 0.5 * (k - segs) as f32
                                - COMPOSITIONAL_SPLIT_PENALTY * (segs - 1) as f32;
                            best_compositional =
                                Some(best_compositional.map_or(score, |b| b.max(score)));
                        }
                    }
                }
            }
            best_word.or(best_compositional).unwrap_or_else(|| {
                splits
                    .iter()
                    .map(|split| {
                        split
                            .iter()
                            .map(|syllable| {
                                known
                                    .get(*syllable)
                                    .map(|&weight| (weight.max(0) as f32).ln_1p())
                                    .unwrap_or(0.0)
                            })
                            .fold(f32::INFINITY, f32::min)
                    })
                    .fold(0.0, f32::max)
                    - UNKNOWN_WORD_COST
            })
        })
        .collect();
    let mut ranked: Vec<GlideHypothesis> = hypotheses
        .into_iter()
        .zip(scores)
        .map(|(hypothesis, score)| GlideHypothesis {
            cost: hypothesis.cost - DICTIONARY_WEIGHT * score,
            ..hypothesis
        })
        .collect();
    ranked.sort_by(|a, b| {
        a.cost
            .total_cmp(&b.cost)
            .then_with(|| a.letters.cmp(&b.letters))
    });
    ranked
}

#[cfg(test)]
pub(crate) mod tests;
