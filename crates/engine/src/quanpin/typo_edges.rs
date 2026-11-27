//! Typo edges for the lattice's typo sentence (quanpin.md §10.5, QD:1056-1182): legal-to-legal syllable swaps, weak positions first, priced by kind and discounted by how often the user accepted that typo.

use std::collections::HashMap;
use std::sync::OnceLock;

use crate::cache::FifoCache;
use crate::dictionary::pinyin::PinyinDatabase;
use crate::dictionary::DictRow;
use crate::lattice::{SentencePath, TypoEdge};
use crate::pinyin::syllables::{intact_pinyin_list, normalized_syllable};
use crate::pinyin::typos::{
    autocorrect_bit, base_cost, discounted, syllable_typos, SyllableTypo, SyllableTypoKind,
    NEIGHBOR_COST,
};
use crate::text::count_utf8_chars;
use crate::touch::{KeyGeometry, KeyTouch, TouchTuning};
use crate::types::autocorrect_type;
use crate::user_dictionary::typo_profile::PersonalTypoProfile;

/// Typo edges are looked up for at most this many variant keys per query, most of them cache hits while typing on.
pub const TYPO_KEY_BUDGET: usize = 96;
/// A variant is only looked up as part of a phrase. Replacing a lone character almost never beats the literal reading, and those lookups were the costly half: a syllable's table holds hundreds of rows per key, all read to find the top few. Dropping them halved the lookup time and cost 0.1 point of recall on the typo eval set (QD:37-41).
pub const MIN_TYPO_SPAN_SYLLABLES: usize = 2;
pub const MAX_TYPO_SPAN_SYLLABLES: usize = 3;
pub const TYPO_ROWS_PER_KEY: usize = 4;

struct PlannedKey {
    start: usize,
    end: usize,
    key: String,
    penalty: f64,
}

enum WeakPositions {
    Bits(u64),
    Heap(Vec<bool>),
}

impl WeakPositions {
    fn new(length: usize) -> Self {
        if length <= u64::BITS as usize {
            Self::Bits(0)
        } else {
            Self::Heap(vec![false; length])
        }
    }

    fn set(&mut self, position: usize) {
        match self {
            Self::Bits(bits) => *bits |= 1u64 << position,
            Self::Heap(weak) => weak[position] = true,
        }
    }

    fn clear(&mut self) {
        match self {
            Self::Bits(bits) => *bits = 0,
            Self::Heap(weak) => weak.fill(false),
        }
    }

    fn get(&self, position: usize) -> bool {
        match self {
            Self::Bits(bits) => bits & (1u64 << position) != 0,
            Self::Heap(weak) => weak[position],
        }
    }
}

/// 按 `TYPO_KEY_BUDGET` 规划跨度键，通过 `span_cache` 查询并缓存空结果，逐行产生纠错边。
pub fn collect_typo_edges(
    database: &PinyinDatabase,
    span_cache: &mut FifoCache<String, Vec<DictRow>>,
    profile: &PersonalTypoProfile,
    segments: &[String],
    literal_best: &SentencePath,
    autocorrect_types: u32,
) -> Vec<TypoEdge> {
    let planned = plan_keys(profile, segments, literal_best, autocorrect_types);
    lookup_planned_edges(database, span_cache, &planned)
}

/// 全拼和双拼共用的规划与查词。`typos_at(i)` 给出第 i 个音节可能想打的音节（便宜的类型在前），`accepted(i, typo)` 给出用户接受过这条纠错的次数；全拼按音节拼写生成变体，双拼按当前方案的两键编码生成，之后的弱位置优先、跨度、预算、查词和罚分完全相同。
pub(crate) fn collect_span_typo_edges<'t>(
    database: &PinyinDatabase,
    span_cache: &mut FifoCache<String, Vec<DictRow>>,
    segments: &[String],
    literal_best: &SentencePath,
    autocorrect_types: u32,
    typos_at: impl Fn(usize) -> &'t [SyllableTypo],
    accepted: impl Fn(usize, &SyllableTypo) -> i32,
) -> Vec<TypoEdge> {
    let planned = plan_keys_with(
        segments,
        literal_best,
        autocorrect_types,
        typos_at,
        accepted,
    );
    lookup_planned_edges(database, span_cache, &planned)
}

fn lookup_planned_edges(
    database: &PinyinDatabase,
    span_cache: &mut FifoCache<String, Vec<DictRow>>,
    planned: &[PlannedKey],
) -> Vec<TypoEdge> {
    let mut misses = Vec::new();
    for entry in planned {
        if span_cache.get_ref(&entry.key).is_none() {
            if misses.is_empty() {
                misses = Vec::with_capacity(planned.len());
            }
            misses.push(entry.key.clone());
        }
    }
    if !misses.is_empty() {
        let mut fetched = database.query_exact_keys_per_key(&misses, TYPO_ROWS_PER_KEY);
        for key in misses {
            let key_rows = fetched.remove(&key).unwrap_or_default();
            span_cache.insert(key, key_rows);
        }
    }

    // 纠错键的查词页可能只有一两行；按缓存中的实际行数预留，避免把 96 个键的上限乘进返回缓冲。
    let edge_count = planned
        .iter()
        .filter_map(|entry| span_cache.get_ref(&entry.key))
        .fold(0usize, |count, rows| count.saturating_add(rows.len()));
    let mut edges = Vec::with_capacity(edge_count);
    for entry in planned {
        let Some(found) = span_cache.get_ref(&entry.key) else {
            continue;
        };
        edges.extend(found.iter().map(|row| TypoEdge {
            start: entry.start,
            end: entry.end,
            key: row.key.clone(),
            value: row.value.clone(),
            weight: row.weight,
            penalty: entry.penalty,
        }));
    }
    edges
}

/// 按弱位置优先规划并去重纠错跨度键，最多保留 `TYPO_KEY_BUDGET` 项。
fn plan_keys(
    profile: &PersonalTypoProfile,
    segments: &[String],
    literal_best: &SentencePath,
    autocorrect_types: u32,
) -> Vec<PlannedKey> {
    plan_keys_with(
        segments,
        literal_best,
        autocorrect_types,
        |position| syllable_typos(&segments[position]),
        |position, typo| profile.accepted(&segments[position], &typo.syllable),
    )
}

fn plan_keys_with<'t>(
    segments: &[String],
    literal_best: &SentencePath,
    autocorrect_types: u32,
    typos_at: impl Fn(usize) -> &'t [SyllableTypo],
    accepted: impl Fn(usize, &SyllableTypo) -> i32,
) -> Vec<PlannedKey> {
    let n = segments.len();
    // A syllable the best literal path spells as a lone character is where a typo most likely broke a phrase, so those positions are tried first. Word widths follow the character counts of the path's words; a path that does not tile the input marks nothing weak.
    let mut weak = WeakPositions::new(n);
    let mut covered = 0;
    for word in &literal_best.words {
        let width = count_utf8_chars(word);
        if width == 0 || covered + width > n {
            covered = n + 1;
            break;
        }
        if width == 1 {
            weak.set(covered);
        }
        covered += width;
    }
    if covered != n {
        weak.clear();
    }
    let positions = (0..n)
        .filter(|&i| weak.get(i))
        .chain((0..n).filter(|&i| !weak.get(i)));

    let mut planned = Vec::new();
    let mut variants = Vec::new();
    'positions: for position in positions {
        if planned.len() >= TYPO_KEY_BUDGET {
            break;
        }
        let typos = typos_at(position);
        variants.clear();
        variants.extend(
            typos
                .iter()
                .filter(|typo| autocorrect_types & autocorrect_bit(typo.kind) != 0)
                .map(|typo| (typo, accepted(position, typo))),
        );
        // Kinds are already cheapest first, so a stable sort on the personal count keeps that as the tie-break.
        variants.sort_by_key(|variant| std::cmp::Reverse(variant.1));
        for &(typo, accepted) in &variants {
            let penalty = discounted(base_cost(typo.kind), accepted);
            for length in MIN_TYPO_SPAN_SYLLABLES..=MAX_TYPO_SPAN_SYLLABLES.min(n) {
                let first = (position + 1).saturating_sub(length);
                for start in first..=position {
                    if start + length > n {
                        break;
                    }
                    let key = typo_span_key(
                        segments,
                        start,
                        start + length,
                        position - start,
                        &typo.syllable,
                    );
                    if planned_key_seen(&planned, &key) {
                        continue;
                    }
                    if planned.is_empty() {
                        planned = Vec::with_capacity(TYPO_KEY_BUDGET);
                    }
                    planned.push(PlannedKey {
                        start,
                        end: start + length,
                        key,
                        penalty,
                    });
                    if planned.len() >= TYPO_KEY_BUDGET {
                        break 'positions;
                    }
                }
            }
        }
    }
    planned
}

/// 按触点计过价的一个变体：第 i 个音节可能想打的音节，以及这次改动的罚分。
pub(crate) struct PricedTypo<'a> {
    pub syllable: &'a str,
    pub penalty: f64,
}

/// 静态合法全拼音节查表，返回 `'static` 规范音节切片以便零分配构造 `PricedTypo<'static>`。
fn canonical_intact_syllable(candidate: &str) -> Option<&'static str> {
    static TABLE: OnceLock<HashMap<&'static str, &'static str>> = OnceLock::new();
    let table = TABLE.get_or_init(|| {
        intact_pinyin_list()
            .iter()
            .map(|&syllable| (syllable, syllable))
            .collect()
    });
    let normalized = normalized_syllable(candidate);
    table.get(normalized.as_str()).copied()
}

/// 26 键全拼带触点时，按每个按键在 `KeyGeometry` 上的真实落点给单音节变体计价：
/// - 邻键替换若对应位置带有触点，按 `KeyGeometry::penalty` 计算各向异性空间罚分（手指偏靠目标邻键时罚分从 20 降至 ~4–8，按在键心仍保持 ~20）；
/// - 同时补入真实键位下罚分不超过 `tuning.cut` 的斜邻键合法音节；
/// - 个人纠错接受次数按原有折扣曲线扣减，并钳位到 `tuning.min_penalty` 以上。
pub(crate) fn priced_quanpin_variants(
    segments: &[String],
    touches: &[Option<KeyTouch>],
    geometry: &KeyGeometry,
    tuning: &TouchTuning,
    profile: &PersonalTypoProfile,
    autocorrect_types: u32,
) -> Vec<Vec<PricedTypo<'static>>> {
    let mut offset = 0usize;
    let mut all_variants = Vec::with_capacity(segments.len());
    let mut edited = Vec::with_capacity(8);

    for segment in segments {
        let seg_len = segment.len();
        let seg_touches = if offset + seg_len <= touches.len() {
            &touches[offset..offset + seg_len]
        } else {
            &[]
        };
        offset += seg_len;

        let typed_bytes = segment.as_bytes();
        let mut variants: Vec<PricedTypo<'static>> = Vec::new();
        let mut upsert = |syllable: &'static str, penalty: f64| {
            if let Some(existing) = variants.iter_mut().find(|item| item.syllable == syllable) {
                if penalty < existing.penalty {
                    existing.penalty = penalty;
                }
            } else {
                variants.push(PricedTypo { syllable, penalty });
            }
        };

        for typo in syllable_typos(segment) {
            if autocorrect_types & autocorrect_bit(typo.kind) == 0 {
                continue;
            }
            let accepted = profile.accepted(segment, &typo.syllable);
            let penalty = if typo.kind == SyllableTypoKind::Neighbor
                && typo.syllable.len() == seg_len
                && seg_touches.len() == seg_len
            {
                let intended_bytes = typo.syllable.as_bytes();
                let mut diff_pos = None;
                let mut diff_count = 0usize;
                for idx in 0..seg_len {
                    if typed_bytes[idx] != intended_bytes[idx] {
                        diff_pos = Some(idx);
                        diff_count += 1;
                    }
                }
                if diff_count == 1 {
                    let pos = diff_pos.unwrap();
                    if let Some(touch) = seg_touches[pos] {
                        let raw_penalty = if geometry.adjacent(
                            typed_bytes[pos],
                            touch,
                            intended_bytes[pos],
                        ) {
                            geometry
                                .penalty(typed_bytes[pos], touch, intended_bytes[pos], tuning)
                                .unwrap_or(NEIGHBOR_COST)
                        } else {
                            tuning.max_penalty
                        };
                        let discount = NEIGHBOR_COST - discounted(NEIGHBOR_COST, accepted);
                        (raw_penalty - discount).max(tuning.min_penalty.min(raw_penalty))
                    } else {
                        discounted(NEIGHBOR_COST, accepted)
                    }
                } else {
                    discounted(NEIGHBOR_COST, accepted)
                }
            } else {
                discounted(base_cost(typo.kind), accepted)
            };
            upsert(typo.syllable.as_str(), penalty);
        }

        // 补入平面邻键表之外但在当前真实布局上距离够近（<= tuning.cut）的合法音节。
        if autocorrect_types & autocorrect_type::NEIGHBOR != 0
            && seg_len >= 2
            && seg_touches.len() == seg_len
        {
            for pos in 0..seg_len {
                let Some(touch) = seg_touches[pos] else {
                    continue;
                };
                for candidate in b'a'..=b'z' {
                    if candidate == typed_bytes[pos] {
                        continue;
                    }
                    let Some(raw_penalty) =
                        geometry.penalty(typed_bytes[pos], touch, candidate, tuning)
                    else {
                        continue;
                    };
                    if raw_penalty > tuning.cut {
                        continue;
                    }
                    edited.clear();
                    edited.extend_from_slice(typed_bytes);
                    edited[pos] = candidate;
                    let Ok(candidate_str) = std::str::from_utf8(&edited) else {
                        continue;
                    };
                    let Some(canonical) = canonical_intact_syllable(candidate_str) else {
                        continue;
                    };
                    if canonical == segment.as_str() {
                        continue;
                    }
                    let accepted = profile.accepted(segment, canonical);
                    let discount = NEIGHBOR_COST - discounted(NEIGHBOR_COST, accepted);
                    let penalty =
                        (raw_penalty - discount).max(tuning.min_penalty.min(raw_penalty));
                    upsert(canonical, penalty);
                }
            }
        }

        variants.sort_by(|left, right| {
            left.penalty
                .total_cmp(&right.penalty)
                .then_with(|| left.syllable.cmp(right.syllable))
        });
        all_variants.push(variants);
    }

    all_variants
}

/// 26 键全拼带触点时的纠错边规划与查词：按触点罚分全局排序，优先查询触点最偏靠目标键的音节变体。
pub(crate) fn collect_priced_quanpin_typo_edges(
    database: &PinyinDatabase,
    span_cache: &mut FifoCache<String, Vec<DictRow>>,
    variants: &[Vec<PricedTypo<'static>>],
    segments: &[String],
    literal_best: &SentencePath,
) -> Vec<TypoEdge> {
    debug_assert_eq!(variants.len(), segments.len());
    collect_priced_span_typo_edges(database, span_cache, segments, literal_best, |position| {
        variants[position].as_slice()
    })
}

/// 纠错整句改动过的每个音节，在对应按键落点下改过去的罚分都不超过 `TouchTuning::show_penalty`：
/// 说明手指落点本身支持这次邻键改正，运行时（`ordering::runner_up_order_with`）应保留其前排座位而不当作次选读法沉底。
pub(crate) fn touch_supports_correction(
    variants: &[Vec<PricedTypo<'static>>],
    tuning: &TouchTuning,
    segments: &[String],
    corrected_key: &str,
) -> bool {
    let corrected: Vec<&str> = corrected_key.split('\'').collect();
    if corrected.len() != segments.len() || variants.len() != segments.len() {
        return false;
    }
    corrected
        .iter()
        .zip(segments)
        .zip(variants)
        .all(|((corrected, literal), variants)| {
            let corrected = normalized_syllable(corrected);
            if corrected == normalized_syllable(literal) {
                return true;
            }
            variants.iter().any(|variant| {
                variant.syllable == corrected && variant.penalty <= tuning.show_penalty
            })
        })
}

/// 全拼和双拼带触点时的规划与查词。`variants_at(i)` 给出第 i 个音节已经按纠错开关筛过、按罚分计过价的变体。与 [`collect_span_typo_edges`] 不同，所有位置的所有变体按罚分全局升序排，罚分相同时弱位置优先，所以 96 个键的预算不会被前一两个位置的便宜类型吃光；跨度、去重、查词和缓存相同。
pub(crate) fn collect_priced_span_typo_edges<'t>(
    database: &PinyinDatabase,
    span_cache: &mut FifoCache<String, Vec<DictRow>>,
    segments: &[String],
    literal_best: &SentencePath,
    variants_at: impl Fn(usize) -> &'t [PricedTypo<'t>],
) -> Vec<TypoEdge> {
    let planned = plan_priced_keys(segments, literal_best, variants_at);
    lookup_planned_edges(database, span_cache, &planned)
}

fn plan_priced_keys<'t>(
    segments: &[String],
    literal_best: &SentencePath,
    variants_at: impl Fn(usize) -> &'t [PricedTypo<'t>],
) -> Vec<PlannedKey> {
    let n = segments.len();
    // 弱位置的判定与 `plan_keys_with` 相同：最优字面路径里单独成字的音节最可能是按错打断了词。
    let mut weak = WeakPositions::new(n);
    let mut covered = 0;
    for word in &literal_best.words {
        let width = count_utf8_chars(word);
        if width == 0 || covered + width > n {
            covered = n + 1;
            break;
        }
        if width == 1 {
            weak.set(covered);
        }
        covered += width;
    }
    if covered != n {
        weak.clear();
    }
    let mut order: Vec<(f64, bool, usize, &PricedTypo<'t>)> = Vec::new();
    for position in 0..n {
        for typo in variants_at(position) {
            order.push((typo.penalty, !weak.get(position), position, typo));
        }
    }
    // 稳定排序：同价同强弱时按位置，同一位置内保持给出的次序。
    order.sort_by(|left, right| {
        left.0
            .total_cmp(&right.0)
            .then(left.1.cmp(&right.1))
            .then(left.2.cmp(&right.2))
    });

    let mut planned = Vec::new();
    'variants: for (penalty, _, position, typo) in order {
        for length in MIN_TYPO_SPAN_SYLLABLES..=MAX_TYPO_SPAN_SYLLABLES.min(n) {
            let first = (position + 1).saturating_sub(length);
            for start in first..=position {
                if start + length > n {
                    break;
                }
                let key = typo_span_key(
                    segments,
                    start,
                    start + length,
                    position - start,
                    typo.syllable,
                );
                if planned_key_seen(&planned, &key) {
                    continue;
                }
                if planned.is_empty() {
                    planned = Vec::with_capacity(TYPO_KEY_BUDGET);
                }
                planned.push(PlannedKey {
                    start,
                    end: start + length,
                    key,
                    penalty,
                });
                if planned.len() >= TYPO_KEY_BUDGET {
                    break 'variants;
                }
            }
        }
    }
    planned
}

fn planned_key_seen(planned: &[PlannedKey], key: &str) -> bool {
    planned.iter().any(|entry| entry.key == key)
}

/// 直接拼接替换后的短音节范围，避免先复制整个范围再改写一个位置。
fn typo_span_key(
    segments: &[String],
    start: usize,
    end: usize,
    replaced: usize,
    replacement: &str,
) -> String {
    debug_assert!(start < end);
    debug_assert!(replaced < end - start);
    let original_bytes = segments[start..end].iter().map(String::len).sum::<usize>();
    let capacity =
        original_bytes - segments[start + replaced].len() + replacement.len() + end - start - 1;
    let mut key = String::with_capacity(capacity);
    for (offset, segment) in segments[start..end].iter().enumerate() {
        if offset > 0 {
            key.push('\'');
        }
        if offset == replaced {
            key.push_str(replacement);
        } else {
            key.push_str(segment);
        }
    }
    key
}

#[cfg(test)]
#[path = "typo_edges/lazy_plan_tests.rs"]
mod lazy_plan_tests;

#[cfg(test)]
#[path = "typo_edges/lazy_buffer_tests.rs"]
mod lazy_buffer_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn planning_reuses_the_variant_buffer_across_positions() {
        let directory = tempfile::tempdir().unwrap();
        let profile = PersonalTypoProfile::shared(&directory.path().join("journal.db"));
        let segments = vec!["zhuang".to_owned(); 6];
        let literal_best = SentencePath {
            sentence: "一二三四五六".to_owned(),
            key: "zhuang'zhuang'zhuang'zhuang'zhuang'zhuang".to_owned(),
            log_prob: 0.0,
            words: vec!["一".to_owned(); 6],
            typo_edges: 0,
        };

        let _ = syllable_typos("zhuang");
        let (planned, allocations) = crate::ime::personal_rerank::allocations::count(|| {
            plan_keys(
                &profile,
                &segments,
                &literal_best,
                crate::types::autocorrect_type::TRANSPOSITION
                    | crate::types::autocorrect_type::NEIGHBOR
                    | crate::types::autocorrect_type::MISSING_OR_EXTRA,
            )
        });

        assert_eq!(planned.len(), 20);
        assert!(allocations <= 91, "{allocations}");
    }

    fn path(words: &[&str]) -> SentencePath {
        SentencePath {
            sentence: words.concat(),
            key: String::new(),
            log_prob: 0.0,
            words: words.iter().map(|word| (*word).to_owned()).collect(),
            typo_edges: 0,
        }
    }

    #[test]
    fn priced_planning_orders_every_variant_by_penalty_then_weak_positions() {
        let segments: Vec<String> = ["ni", "hao", "ma", "ba"].map(str::to_owned).to_vec();
        let variants = [
            vec![PricedTypo {
                syllable: "li",
                penalty: 20.0,
            }],
            vec![PricedTypo {
                syllable: "hai",
                penalty: 12.0,
            }],
            vec![PricedTypo {
                syllable: "na",
                penalty: 12.0,
            }],
            vec![PricedTypo {
                syllable: "pa",
                penalty: 4.0,
            }],
        ];
        // 你好 是词，吗 和 吧 单独成字，是弱位置。
        let planned = plan_priced_keys(&segments, &path(&["你好", "吗", "吧"]), |position| {
            variants[position].as_slice()
        });
        let replaced: Vec<(usize, usize, &str, f64)> = planned
            .iter()
            .map(|entry| (entry.start, entry.end, entry.key.as_str(), entry.penalty))
            .collect();
        // 最便宜的 pa 先排（位置 3 在末尾，只有两种跨度）；同价 12 的弱位置 2（na）排在强位置 1（hai）前面；最贵的 li 最后。
        assert_eq!(
            replaced.iter().map(|entry| entry.2).collect::<Vec<_>>(),
            [
                "ma'pa",
                "hao'ma'pa",
                "hao'na",
                "na'ba",
                "ni'hao'na",
                "hao'na'ba",
                "ni'hai",
                "hai'ma",
                "ni'hai'ma",
                "hai'ma'ba",
                "li'hao",
                "li'hao'ma",
            ]
        );
        assert!(replaced.windows(2).all(|pair| pair[0].3 <= pair[1].3));
    }

    #[test]
    fn priced_planning_stops_at_the_key_budget() {
        // 各音节互不相同，换掉不同位置得到的跨度键也互不相同，只有预算能让规划停下。
        let segments: Vec<String> = (0..40).map(|index| format!("s{index}")).collect();
        let variants: Vec<PricedTypo<'static>> = ["chuang", "shuang", "zhang"]
            .into_iter()
            .map(|syllable| PricedTypo {
                syllable,
                penalty: 20.0,
            })
            .collect();
        let planned = plan_priced_keys(&segments, &path(&[]), |_| variants.as_slice());
        assert_eq!(planned.len(), TYPO_KEY_BUDGET);
    }

    #[test]
    fn weak_position_bits_cover_the_boundary_without_heap_state() {
        let (mut weak, allocations) =
            crate::ime::personal_rerank::allocations::count(|| WeakPositions::new(64));
        weak.set(0);
        weak.set(63);

        assert_eq!(allocations, 0);
        assert!(weak.get(0));
        assert!(weak.get(63));
        assert!(!weak.get(1));
    }

    #[test]
    fn weak_position_storage_falls_back_for_long_internal_inputs() {
        let mut weak = WeakPositions::new(65);
        weak.set(64);
        assert!(weak.get(64));
        weak.clear();
        assert!(!weak.get(64));
    }

    #[test]
    fn planned_key_lookup_scans_owned_keys() {
        let planned = vec![PlannedKey {
            start: 0,
            end: 2,
            key: "ni'hao".to_owned(),
            penalty: 1.0,
        }];
        assert!(planned_key_seen(&planned, "ni'hao"));
        assert!(!planned_key_seen(&planned, "ni'he"));
    }

    #[test]
    fn planned_key_scan_uses_no_temporary_heap_state() {
        let planned = vec![PlannedKey {
            start: 0,
            end: 2,
            key: "ni'hao".to_owned(),
            penalty: 1.0,
        }];
        let (found, allocations) = crate::ime::personal_rerank::allocations::count(|| {
            planned_key_seen(&planned, "ni'hao")
        });

        assert!(found);
        assert_eq!(allocations, 0);
    }

    #[test]
    fn typo_span_key_replaces_one_segment_without_a_temporary_vector() {
        let segments = ["ni".to_owned(), "hao".to_owned(), "ma".to_owned()];

        let (key, allocations) = crate::ime::personal_rerank::allocations::count(|| {
            typo_span_key(&segments, 0, 3, 1, "he")
        });

        assert_eq!(key, "ni'he'ma");
        assert_eq!(key.capacity(), key.len());
        assert_eq!(allocations, 1);
    }

    #[test]
    fn typo_span_keys_match_cloned_ranges_at_every_replacement_position() {
        let segments = [
            "ni".to_owned(),
            "hao".to_owned(),
            "ma".to_owned(),
            "ba".to_owned(),
        ];
        for start in 0..segments.len() {
            for end in start + 1..=segments.len() {
                for replaced in 0..end - start {
                    for replacement in ["", "he", "shang"] {
                        let mut expected = segments[start..end].to_vec();
                        expected[replaced] = replacement.to_owned();
                        let key = typo_span_key(&segments, start, end, replaced, replacement);
                        assert_eq!(key, expected.join("'"));
                        assert_eq!(key.capacity(), key.len());
                    }
                }
            }
        }
    }

    #[test]
    fn priced_quanpin_variants_lower_penalty_when_touch_leans_toward_neighbor() {
        let rows: [&[u8]; 3] = [b"qwertyuiop", b"asdfghjkl", b"zxcvbnm"];
        let mut keys = [[0.0f32; 4]; 26];
        for (r, row) in rows.iter().enumerate() {
            let indent = match r {
                0 => 0.0,
                1 => 0.5,
                _ => 1.5,
            };
            for (c, &byte) in row.iter().enumerate() {
                keys[(byte - b'a') as usize] = [(c as f32 + indent) * 36.0, r as f32 * 48.0, 30.0, 40.0];
            }
        }
        let geometry = KeyGeometry::new(1, &keys, None, &[]).unwrap();
        let tuning = TouchTuning::default();
        let dir = tempfile::tempdir().unwrap();
        let profile = PersonalTypoProfile::shared(&dir.path().join("journal.db"));
        let segments = vec!["ni".to_owned(), "gao".to_owned()];

        // 按在 g 靠右边缘（偏向 h）：`gao -> hao` 空间罚分应明显低于键心（~20）且排在反方向邻键 `fao` 前面。
        let lean_right = geometry.touch(b'g', keys[(b'g' - b'a') as usize][0] + 13.0, keys[(b'g' - b'a') as usize][1]);
        let center = geometry.touch(b'g', keys[(b'g' - b'a') as usize][0], keys[(b'g' - b'a') as usize][1]);
        let leaned = priced_quanpin_variants(
            &segments,
            &[None, None, lean_right, None, None],
            &geometry,
            &tuning,
            &profile,
            autocorrect_type::NEIGHBOR | autocorrect_type::TRANSPOSITION,
        );
        let centered = priced_quanpin_variants(
            &segments,
            &[None, None, center, None, None],
            &geometry,
            &tuning,
            &profile,
            autocorrect_type::NEIGHBOR | autocorrect_type::TRANSPOSITION,
        );
        let hao_leaned = leaned[1].iter().find(|v| v.syllable == "hao").unwrap().penalty;
        let hao_centered = centered[1].iter().find(|v| v.syllable == "hao").unwrap().penalty;
        assert!(hao_leaned < 14.0, "偏靠 h 的落点罚分应显著下降，实际 {hao_leaned}");
        assert!(hao_centered > 20.0, "按在键心的落点罚分应高于桌面基线，实际 {hao_centered}");
        assert!(hao_leaned + 10.0 < hao_centered);
        assert!(
            touch_supports_correction(&leaned, &tuning, &segments, "ni'hao"),
            "边缘偏 h 的落点应支持 ni'hao 纠错"
        );
        assert!(
            !touch_supports_correction(&centered, &tuning, &segments, "ni'hao"),
            "键心明确点击 g 不应支持 ni'hao 纠错"
        );
    }

    #[test]
    fn resolve_series_query_with_touches_reranks_broken_syllable_cuts_by_touch_direction() {
        use crate::quanpin::series::resolve_series_query_with_touches;

        let rows: [&[u8]; 3] = [b"qwertyuiop", b"asdfghjkl", b"zxcvbnm"];
        let mut keys = [[0.0f32; 4]; 26];
        for (r, row) in rows.iter().enumerate() {
            let indent = match r {
                0 => 0.0,
                1 => 0.5,
                _ => 1.5,
            };
            for (c, &byte) in row.iter().enumerate() {
                keys[(byte - b'a') as usize] = [(c as f32 + indent) * 36.0, r as f32 * 48.0, 30.0, 40.0];
            }
        }
        let geometry = KeyGeometry::new(1, &keys, None, &[]).unwrap();
        let tuning = TouchTuning::default();
        let types = autocorrect_type::NEIGHBOR | autocorrect_type::TRANSPOSITION;
        let s_rect = keys[(b's' - b'a') as usize];

        // `shsng` 中第 3 键 `s` 落点偏上靠 `e` 时主切分应选 `sheng`；落点偏左靠 `a` 时主切分应选 `shang`。
        let s_toward_e = geometry.touch(b's', s_rect[0] + 6.0, s_rect[1] - 18.0);
        let s_toward_a = geometry.touch(b's', s_rect[0] - 14.0, s_rect[1]);
        let shsng_segments = vec!["sh".to_owned(), "s".to_owned(), "n".to_owned(), "g".to_owned()];

        let res_e = resolve_series_query_with_touches(
            "shsng",
            &shsng_segments,
            types,
            &[None, None, s_toward_e, None, None],
            &geometry,
            &tuning,
        );
        assert_eq!(res_e.corrected, vec!["sheng".to_owned()]);

        let res_a = resolve_series_query_with_touches(
            "shsng",
            &shsng_segments,
            types,
            &[None, None, s_toward_a, None, None],
            &geometry,
            &tuning,
        );
        assert_eq!(res_a.corrected, vec!["shang".to_owned()]);

        // `womsn`（想打 `wo'men`「我们」却误触 `e` 下方的 `s`）落点偏 `e` 时主切分应为 `wo'men`。
        let womsn_segments = vec!["wo".to_owned(), "m".to_owned(), "s".to_owned(), "n".to_owned()];
        let womsn_e = resolve_series_query_with_touches(
            "womsn",
            &womsn_segments,
            types,
            &[None, None, None, s_toward_e, None],
            &geometry,
            &tuning,
        );
        assert_eq!(womsn_e.corrected, vec!["wo".to_owned(), "men".to_owned()]);
    }
}
