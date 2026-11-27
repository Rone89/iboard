//! 26 键全拼一到两个完整音节的亚像素触点纠错：
//! 当输入的字母恰好构成合法音节（例如想打 `hao`「好」或 `ni'hao`「你好」却按到了 `g` 键靠右边缘成了 `gao` / `ni'gao`），
//! 按每个按键在 `KeyGeometry` 上的真实落点筛选空间罚分不超过 `TouchTuning::show_penalty` 的邻键音节，
//! 查询完整词条并按落点折算词频并入前排候选，同时标记 `touch_supported = true`（与双拼 `shuangpin::dictionary::short_words` 对齐）。

use super::matched_letters;
use super::super::series::fold_reading;
use super::super::typo_edges::{priced_quanpin_variants, TYPO_KEY_BUDGET, TYPO_ROWS_PER_KEY};
use super::{QuanpinDictionary, TYPO_EDGE_TYPES};
use crate::pinyin::syllables::has_only_complete_pinyin_segments;
use crate::types::{CandidateSource, WordItem};

fn score(weight: i64) -> f64 {
    (weight.max(1) as f64).ln()
}

impl QuanpinDictionary {
    /// 对 1–2 个完整音节且携带全量按键触点的 26 键全拼查询，按亚像素触点偏移并入边缘邻键纠错词条。
    pub(super) fn merge_short_touch_words(
        &mut self,
        candidates: &mut Vec<WordItem>,
        raw: &str,
        segments: &[String],
    ) {
        let types = self.current_autocorrect_types & TYPO_EDGE_TYPES;
        if types == 0
            || raw.contains('\'')
            || !matches!(segments.len(), 1 | 2)
            || !has_only_complete_pinyin_segments(segments)
            || self.key_touches.is_empty()
            || raw != self.touch_input
            || self.key_touches.len() != raw.len()
            || self.key_touches.iter().any(Option::is_none)
            || candidates.is_empty()
        {
            return;
        }
        let Some(geometry) = self.key_geometry.as_deref() else {
            return;
        };
        let segment_bytes: usize = segments.iter().map(String::len).sum();
        if segment_bytes != self.key_touches.len() {
            return;
        }

        let tuning = self.touch_tuning;
        let variants = priced_quanpin_variants(
            segments,
            &self.key_touches,
            geometry,
            &tuning,
            &self.typo_profile,
            types,
        );
        let mut planned: Vec<(String, f64)> = Vec::new();
        for (position, alternatives) in variants.iter().enumerate() {
            for variant in alternatives
                .iter()
                .filter(|v| v.penalty <= tuning.show_penalty)
            {
                let mut syllables = segments.to_vec();
                syllables[position] = variant.syllable.to_owned();
                let key = syllables.join("'");
                if let Some((_, penalty)) = planned.iter_mut().find(|(old, _)| *old == key) {
                    *penalty = penalty.min(variant.penalty);
                } else {
                    planned.push((key, variant.penalty));
                }
            }
        }
        if planned.is_empty() {
            return;
        }
        planned.sort_by(|left, right| {
            left.1
                .total_cmp(&right.1)
                .then_with(|| left.0.cmp(&right.0))
        });
        planned.truncate(TYPO_KEY_BUDGET);

        let misses: Vec<String> = planned
            .iter()
            .filter(|(key, _)| self.typo_span_cache.get_ref(key).is_none())
            .map(|(key, _)| key.clone())
            .collect();
        if !misses.is_empty() {
            let mut rows = self
                .database
                .query_exact_keys_per_key(&misses, TYPO_ROWS_PER_KEY);
            for key in misses {
                let found = rows.remove(&key).unwrap_or_default();
                self.typo_span_cache.insert(key, found);
            }
        }

        let literal_key = segments.join("'");
        let literal_best = candidates
            .iter()
            .filter(|row| {
                row.source.is_dictionary()
                    && row.canonical_pinyin == literal_key
                    && row.corrected_from.is_empty()
            })
            .map(|row| score(row.weight))
            .reduce(f64::max);

        let folded_raw = fold_reading(raw);
        let mut corrected = Vec::new();
        for (key, penalty) in planned {
            let Some(rows) = self.typo_span_cache.get_ref(&key) else {
                continue;
            };
            for row in rows {
                let rank = score(row.weight) - penalty;
                if literal_best.is_some_and(|best| rank < best - tuning.show_margin)
                    || candidates.iter().enumerate().any(|(index, old)| {
                        old.word == row.value
                            && (index == 0 || matched_letters(&old.pinyin) >= raw.len())
                    })
                {
                    continue;
                }
                let mut word = WordItem::new(
                    &literal_key,
                    row.value.clone(),
                    row.weight,
                    CandidateSource::Database,
                    row.key.clone(),
                );
                word.corrected_from = folded_raw.clone().into();
                word.touch_supported = true;
                corrected.push((word, rank));
            }
        }
        if corrected.is_empty() {
            return;
        }
        corrected.sort_by(|left, right| {
            right
                .1
                .total_cmp(&left.1)
                .then_with(|| left.0.canonical_pinyin.cmp(&right.0.canonical_pinyin))
                .then_with(|| left.0.word.cmp(&right.0.word))
        });

        let mut count = 0;
        for (row, rank) in corrected {
            if candidates.iter().enumerate().any(|(index, old)| {
                old.word == row.word && (index == 0 || matched_letters(&old.pinyin) >= raw.len())
            }) {
                continue;
            }
            candidates.retain(|old| old.word != row.word);
            // 保留字面首选；其余完整词比较扣减触点罚分后的对数词频，单字前缀排在完整触点纠错词之后。
            let at = candidates
                .iter()
                .enumerate()
                .skip(1)
                .find(|(_, old)| {
                    if !old.corrected_from.is_empty() {
                        return false;
                    }
                    matched_letters(&old.pinyin) < raw.len()
                        || (old.source.is_dictionary() && score(old.weight) < rank)
                })
                .map_or(candidates.len(), |(at, _)| at);
            candidates.insert(at, row);
            count += 1;
            if count == TYPO_ROWS_PER_KEY {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use crate::quanpin::dictionary::QuanpinDictionary;
    use crate::quanpin::fixture::Fixture;
    use crate::touch::{KeyGeometry, TouchTuning};
    use crate::types::{autocorrect_type, FuzzyPinyinOptions};

    fn test_geometry() -> (Arc<KeyGeometry>, [[f32; 4]; 26]) {
        let rows: [&[u8]; 3] = [b"qwertyuiop", b"asdfghjkl", b"zxcvbnm"];
        let mut keys = [[0.0f32; 4]; 26];
        for (r, row) in rows.iter().enumerate() {
            let indent = match r {
                0 => 0.0,
                1 => 0.5,
                _ => 1.5,
            };
            for (c, &byte) in row.iter().enumerate() {
                keys[(byte - b'a') as usize] =
                    [(c as f32 + indent) * 36.0, r as f32 * 48.0, 30.0, 40.0];
            }
        }
        (
            Arc::new(KeyGeometry::new(1, &keys, None, &[]).unwrap()),
            keys,
        )
    }

    #[test]
    fn short_touch_words_merge_neighbor_word_only_when_touch_leans_toward_neighbor() {
        let fixture = Fixture::new();
        fixture
            .insert("ni", "你", 5000)
            .insert("gao", "高", 4000)
            .insert("hao", "好", 9000)
            .insert("ni'hao", "你好", 12000);
        let mut dict = QuanpinDictionary::new(&fixture.paths);
        let (geometry, keys) = test_geometry();
        let tuning = TouchTuning::default();
        let types = autocorrect_type::NEIGHBOR | autocorrect_type::TRANSPOSITION;

        let center = |b: u8| {
            let k = keys[(b - b'a') as usize];
            geometry.touch(b, k[0], k[1])
        };
        let g_rect = keys[(b'g' - b'a') as usize];
        let g_lean_h = geometry.touch(b'g', g_rect[0] + 13.5, g_rect[1]);

        // 1. 按在 `g` 键心输入 `nigao`：不应误把 `你好` 注入前排。
        dict.set_key_touches(
            &[center(b'n'), center(b'i'), center(b'g'), center(b'a'), center(b'o')],
            "nigao",
            Some(&geometry),
            tuning,
        );
        let centered_rows = dict.query("nigao", "ni'gao", types, FuzzyPinyinOptions::default());
        assert!(
            centered_rows.iter().all(|row| row.word != "你好"),
            "键心明确点击 g 时不应注入「你好」: {centered_rows:?}"
        );

        // 2. 按在 `g` 靠右边缘（偏向 `h`）输入 `nigao`：应将「你好」作为 `touch_supported = true` 并入前排（且不受上一轮键心缓存污染）。
        dict.set_key_touches(
            &[center(b'n'), center(b'i'), g_lean_h, center(b'a'), center(b'o')],
            "nigao",
            Some(&geometry),
            tuning,
        );
        let leaned_rows = dict.query("nigao", "ni'gao", types, FuzzyPinyinOptions::default());
        let nihao = leaned_rows
            .iter()
            .find(|row| row.word == "你好")
            .expect("落点偏向 h 时应并入「你好」");
        assert!(nihao.touch_supported);
        assert_eq!(nihao.corrected_from.as_str(), "nigao");
        let nihao_pos = leaned_rows.iter().position(|row| row.word == "你好").unwrap();
        let prefix_pos = leaned_rows.iter().position(|row| row.word == "你").unwrap();
        assert!(
            nihao_pos < prefix_pos,
            "完整触点纠错词「你好」({nihao_pos})应排在单字前缀「你」({prefix_pos})前面"
        );
    }
}
