//! 组字会话里的滑行输入：解码出的字母像打出来的一样，一次编辑写进组字。

mod composition;
mod contractions;
mod ranking;

use super::input::InputSession;
use crate::pinyin::glide::{
    rank_by_dictionary_with_prefix, GlideHypothesis, GlideKeyboard, GlideMatcher, GlidePoint,
    MAX_GLIDE_LETTERS,
};
use crate::types::{CandidateSource, KeyResult, LocalInputMode, SchemeType, WordItem};

/// 待确认单笔滑行轨迹快照：用户随后明确选中并上屏中文候选时，用选中词的真实 `canonical_pinyin` 反向对齐采样点更新拇指键心偏置。
#[derive(Debug, Clone)]
pub(super) struct PendingGlideCalibration {
    pub stroke_spelling: String,
    pub raw_keyboard: GlideKeyboard,
    pub points: Vec<GlidePoint>,
}

/// 几何交给词典排序的候选串数；宽候选池保证共线键与多音节长词在词典重排前不被短串挤出。
const GLIDE_HYPOTHESES: usize = 48;

/// 过滤并去重宿主（如 GlideBeam）预先解出的外部拼音读音假设。
fn sanitize_external_readings(readings: &[String]) -> Vec<String> {
    let mut cleaned = Vec::new();
    for reading in readings.iter().take(GLIDE_HYPOTHESES) {
        if reading.is_empty()
            || reading.len() > MAX_GLIDE_LETTERS
            || !reading.bytes().all(|b| b.is_ascii_lowercase())
        {
            continue;
        }
        if !cleaned.iter().any(|existing| existing == reading) {
            cleaned.push(reading.clone());
        }
    }
    cleaned
}

/// 词典行的 `pinyin` 可以只是匹配前缀；整笔必须覆盖完整读音，不能替用户补出未滑过的字母。
fn complete_chinese_glide_candidate(row: &WordItem, spelling: &str) -> bool {
    !row.word.is_ascii()
        && [&row.pinyin, &row.canonical_pinyin].iter().all(|reading| {
            reading
                .bytes()
                .filter(|&letter| letter != b'\'')
                .eq(spelling.bytes().filter(|&letter| letter != b'\''))
        })
}

/// 预览条展示的读音文本：直接使用最优全拼读音（若无则返回首条）。
fn rows_reading_hint(best_letters: &str, _ranked: &[GlideHypothesis]) -> String {
    best_letters.to_owned()
}

impl InputSession {
    /// 提取当前活跃组字供连续滑行（`had_composition == true`）使用的双重上下文：
    /// 1. 候选首位中文词（叠入静/动态二元语境重排）；
    /// 2. 当前编辑拼音末尾 1–2 个有效音节（用于 `rank_by_dictionary_with_prefix` 查跨笔整词，如 `wo` + `men` → `wo'men`）。
    fn active_glide_context(&self) -> (Option<String>, Option<String>) {
        if !self.has_composition() {
            return (None, None);
        }
        let extra_context = self
            .candidates()
            .first()
            .filter(|row| !row.word.is_empty() && !row.word.is_ascii())
            .map(|row| row.word.to_string());
        let editing = self.editing_text();
        let parts: Vec<&str> = editing
            .split('\'')
            .filter(|part| {
                !part.is_empty() && part.bytes().all(|b| b.is_ascii_lowercase())
            })
            .collect();
        let prefix_syllables = if parts.is_empty() {
            None
        } else {
            let take_count = parts.len().min(2);
            Some(parts[parts.len() - take_count..].join("'"))
        };
        (extra_context, prefix_syllables)
    }

    /// 当用户明确上屏候选词时，若存在挂起的单笔滑行快照且允许学习，则按实际选中的中文词读音反向对齐采样点并更新拇指偏移校准器。
    pub(super) fn observe_confirmed_glide_calibration(&mut self, selected: &WordItem) {
        let Some(pending) = self.pending_glide_calibration.take() else {
            return;
        };
        if !self.learning_enabled || selected.word.is_ascii() {
            return;
        }
        let reading = if !selected.canonical_pinyin.is_empty() {
            selected.canonical_pinyin.as_ref()
        } else {
            selected.pinyin.as_ref()
        };
        let letters: String = reading
            .bytes()
            .filter(|b| b.is_ascii_alphabetic())
            .map(|b| char::from(b.to_ascii_lowercase()))
            .collect();
        if !(2..=MAX_GLIDE_LETTERS).contains(&letters.len()) {
            return;
        }
        let Some(raw_matcher) = GlideMatcher::new(&pending.raw_keyboard, &pending.points) else {
            return;
        };
        let Some(aligned) = raw_matcher.align_letters(&letters) else {
            return;
        };
        let raw_centers = pending.raw_keyboard.normalized_centers();
        if self
            .glide_calibrator
            .observe_alignment(&aligned, &raw_centers)
            && self.glide_calibrator.should_flush()
        {
            let path = self.paths.user("glide_calibration.json");
            self.glide_calibrator.save(&path);
        }
    }

    /// 合并音节束搜索与词典直评两路全拼几何假设：常用 1–4 音节词直接按 `GlideMatcher` 形状+位置双通道计分永不被束宽挤掉，非整词与长短语继续由束搜索补全。
    fn decode_quanpin_merged(&self, matcher: &GlideMatcher) -> Vec<GlideHypothesis> {
        let mut hypotheses = matcher.decode_quanpin(GLIDE_HYPOTHESES);
        let starting = matcher.lexicon_starting_letters();
        let mut lexicon_hits = Vec::new();
        self.engine
            .with_quanpin_glide_lexicon(&starting, |entries| {
                lexicon_hits.extend(matcher.score_lexicon(entries, GLIDE_HYPOTHESES));
            });
        for hit in lexicon_hits {
            if let Some(existing) = hypotheses.iter_mut().find(|h| h.letters == hit.letters) {
                existing.cost = existing.cost.min(hit.cost);
            } else {
                hypotheses.push(hit);
            }
        }
        hypotheses.sort_by(|a, b| {
            a.cost
                .total_cmp(&b.cost)
                .then_with(|| a.letters.cmp(&b.letters))
        });
        hypotheses.truncate(GLIDE_HYPOTHESES * 2);
        hypotheses
    }

    /// 每笔同时查询拼音和英文；完整候选独立保留，选词不改变中英文模式。
    /// 当宿主传入外部读音（如 GlideBeam 解码结果）时，用同一 `GlideMatcher` 计算几何代价后并入中文候选池，与英文候选在同一尺度上竞争。
    pub(super) fn bilingual_glide(
        &mut self,
        keyboard: &GlideKeyboard,
        points: &[GlidePoint],
        external_readings: &[String],
    ) -> KeyResult {
        if self.dedicated_english
            || self.local_mode != LocalInputMode::None
            || self.scheme() != SchemeType::Quanpin
            || self.has_active_helpcode()
        {
            return KeyResult::unhandled();
        }
        let calibrated = self.glide_calibrator.apply(keyboard);
        let Some(matcher) = GlideMatcher::new(&calibrated, points) else {
            return KeyResult::unhandled();
        };
        let (extra_context, prefix_syllables) = self.active_glide_context();
        let mut hypotheses = self.decode_quanpin_merged(&matcher);
        for (rank, reading) in sanitize_external_readings(external_readings)
            .into_iter()
            .enumerate()
        {
            // 使用含 SHARK2 圆角/DTW 的中文双通道计分，避免手指略微切弯超过严格位置阈值时把 GlideBeam 正确读音直接丢弃。
            if let Some(geom_cost) = matcher.score_pinyin_dual(&reading) {
                // 对 GlideBeam 首位读音给予轻微先验优势，但保持与几何/英文同一量纲，不压倒真正的英文滑行。
                let adjusted = geom_cost - if rank == 0 { 0.4 } else { 0.0 };
                if let Some(existing) = hypotheses.iter_mut().find(|h| h.letters == reading) {
                    existing.cost = existing.cost.min(adjusted);
                } else {
                    hypotheses.push(GlideHypothesis {
                        letters: reading,
                        cost: adjusted,
                    });
                }
            }
        }
        // 记录每条读音的纯几何代价作为与英文同尺度竞争的锚点，同时保留 `rank_by_dictionary_with_prefix`
        // 算出的中文词典多音节加分、组合 DP 与二元语境排序，避免开启中英混滑后中文长词/语境词被短词反超。
        let geom_costs: std::collections::HashMap<String, f32> = hypotheses
            .iter()
            .map(|h| (h.letters.clone(), h.cost))
            .collect();
        let ranked_cn = {
            let engine = &self.engine;
            rank_by_dictionary_with_prefix(
                hypotheses,
                prefix_syllables.as_deref(),
                |keys| engine.quanpin_best_weights_with_context(keys, extra_context.as_deref()),
            )
        };
        let best_ranked = ranked_cn.first().map_or(f32::INFINITY, |h| h.cost);
        let best_geom = ranked_cn
            .first()
            .and_then(|h| geom_costs.get(&h.letters).copied())
            .unwrap_or(f32::INFINITY);
        let selected_cn: Vec<GlideHypothesis> = ranked_cn
            .into_iter()
            .take(8)
            .filter_map(|h| {
                let geom = geom_costs.get(&h.letters).copied()?;
                let ranked_delta = (h.cost - best_ranked).max(0.0);
                // 首选中文读音锚定在自身真实几何代价（不给相对英文的额外折扣），
                // 次选中文读音按 `best_geom + ranked_delta` 保持中文内部词典与语境序差，且不低于自身几何代价。
                let effective = (best_geom + ranked_delta).max(geom);
                Some(GlideHypothesis {
                    letters: h.letters,
                    cost: effective,
                })
            })
            .collect();
        let best_cn_cost = selected_cn
            .first()
            .map_or(f32::INFINITY, |h| h.cost);
        let mut chinese = Vec::new();
        for (hyp_index, hypothesis) in selected_cn
            .into_iter()
            .filter(|h| h.cost <= best_cn_cost + 5.0)
            .take(6)
            .enumerate()
        {
            let rows = self
                .engine
                .query_raw_candidates(&hypothesis.letters, &hypothesis.letters);
            let complete_rows: Vec<WordItem> = rows
                .into_iter()
                .filter(|row| complete_chinese_glide_candidate(row, &hypothesis.letters))
                .collect();
            let top_weight = complete_rows.first().map_or(1, |row| row.weight.max(1));
            // 首选读音保留前 36 个高频同音词参与中英与次选读音前排竞争（避免 `shi` 的「食、室、识、试、失」等常用字在前排被截断）；
            // 次选读音（hyp_index >= 1）最多取前 4 条且过滤词频低于该读音首词 1/200 的生僻字（如 `shui` 的「帨、氺、稅」），避免生僻字挤入前排。
            let per_hypothesis_limit = match hyp_index {
                0 => 36,
                1 => 4,
                _ => 2,
            };
            let max_w = top_weight as f64;
            for row in complete_rows
                .into_iter()
                .filter(|row| hyp_index == 0 || row.weight.max(1) >= top_weight / 200)
                .take(per_hypothesis_limit)
            {
                // 同读音内按相对首词词频拉开同音字间距（最多 2.0 分），跨读音的词频、多音节与语境优势已体现在 `hypothesis.cost` 中，
                // 避免次选单字的高原始词频反过来压低主选多音节整词（如「切」压低「企业」）。
                let homophone_penalty =
                    ((max_w / row.weight.max(1) as f64).ln() * 0.25).min(2.0) as f32;
                // 英文真词与任意拼音拼出的生僻组合竞争时，完整词典词应有有限优势。
                // 保留原始来源（词典词不被改写为 `Generated`），免得下游句子重排器把滑行词典首选当成词网格读法误重排。
                let cost = hypothesis.cost
                    + homophone_penalty
                    + if row.source.is_dictionary() { 0.0 } else { 2.0 };
                chinese.push((hypothesis.letters.clone(), row, cost));
            }
        }
        let mut english = Vec::new();
        let starting_en = matcher.starting_letters();
        self.queries
            .english_dictionary()
            .with_glide_entries_for_initials(&starting_en, |bucket| {
                let mut last_word: &str = "";
                let mut last_cost: Option<f32> = None;
                for entry in bucket.entries() {
                    if !matcher.matches_strict_masks(entry.letter_mask, entry.last) {
                        continue;
                    }
                    let word = bucket.word(entry);
                    let cost = if word == last_word {
                        last_cost
                    } else {
                        last_word = word;
                        last_cost = matcher.score(word);
                        last_cost
                    };
                    if let Some(cost) = cost {
                        let row = WordItem::new(
                            word,
                            bucket.display(entry),
                            entry.weight,
                            CandidateSource::EnglishDictionary,
                            "",
                        );
                        english.push((word.to_owned(), row, cost));
                    }
                }
            });
        contractions::append(
            &matcher,
            |base| {
                self.queries
                    .english_dictionary()
                    .query_exact(base)
                    .map(|row| row.weight)
            },
            &mut english,
        );
        // 用英文词库常见词频基准作下限，防止滑中文时只碰到一个生僻英文词（如 `zing`）因自身成为批内最大值而拿到 0 频度惩罚。
        // 不含 `the` 的小型测试夹具退回下限 1，保持既有测试尺度不变。
        let english_weight_floor = self.queries.english_dictionary().glide_weight_floor();
        // 英文频度归一化：频度最多抵有限几何代价。
        let english_maximum = english
            .iter()
            .map(|(_, row, _)| row.weight.max(1))
            .max()
            .unwrap_or(1)
            .max(english_weight_floor.max(1)) as f64;
        for (_, row, cost) in &mut english {
            *cost += ((english_maximum / row.weight.max(1) as f64).ln() * 0.25).min(2.5) as f32;
        }
        let preference = self
            .candidates()
            .first()
            .filter(|_| self.has_composition())
            .and_then(|row| ranking::english_ending(&row.word))
            .or(self.glide_prefers_english);
        if let Some(prefer_english) = preference {
            let preferred = if prefer_english {
                &mut english
            } else {
                &mut chinese
            };
            for (_, _, cost) in preferred {
                *cost -= 0.5;
            }
        }
        chinese.extend(english);
        chinese.sort_by(|a, b| {
            a.2.total_cmp(&b.2)
                .then_with(|| b.1.weight.cmp(&a.1.weight))
                .then_with(|| a.1.word.cmp(&b.1.word))
        });
        let Some((spelling, _, best)) = chinese.first() else {
            return KeyResult::unhandled();
        };
        let spelling = spelling.clone();
        let ceiling = *best + 10.0;
        let mut rows = Vec::new();
        for (_, row, cost) in chinese {
            if cost <= ceiling && !rows.iter().any(|other: &WordItem| other.word == row.word) {
                rows.push(row);
                if rows.len() == ranking::CANDIDATE_LIMIT {
                    break;
                }
            }
        }
        if self.has_composition() {
            self.pending_glide_calibration = None;
            return self.continue_bilingual_glide(&spelling, &rows);
        }
        // 候选语言只影响排序，不能替用户决定何时上屏。
        self.leave_conversion();
        let result = self.replace_editing_text(&spelling, spelling.len());
        if result.handled {
            self.pending_glide_calibration = Some(PendingGlideCalibration {
                stroke_spelling: self.raw_with_cases().to_owned(),
                raw_keyboard: keyboard.clone(),
                points: points.to_vec(),
            });
        }
        // 将主读音在词典中的其余完整同音字按词频顺序追加到列表尾部，确保展开候选面板可找到第 17 位以后的全部同音字（如 `shi` 的「食、室、识、试、失…」）。
        for candidate in self.candidates() {
            if complete_chinese_glide_candidate(candidate, &spelling)
                && !rows.iter().any(|existing| existing.word == candidate.word)
            {
                rows.push(candidate.clone());
            }
        }
        self.glide_candidates = Some((spelling, rows));
        self.glide_selection_pending = true;
        result
    }

    /// 只读实时预览：解码当前滑行轨迹并查询顶栏候选，绝不改动正在进行的组字、光标、候选态或学习记录，因此连滑第二、第三词时也能实时展示中文候选。
    pub(super) fn preview_glide(
        &mut self,
        keyboard: &GlideKeyboard,
        points: &[GlidePoint],
        external_readings: &[String],
    ) -> Option<(String, Vec<String>)> {
        if self.dedicated_english
            || self.local_mode != LocalInputMode::None
            || self.scheme() != SchemeType::Quanpin
        {
            return None;
        }
        let calibrated = self.glide_calibrator.apply(keyboard);
        let (extra_context, prefix_syllables) = self.active_glide_context();
        let cleaned_external = sanitize_external_readings(external_readings);
        let ranked = if !cleaned_external.is_empty() {
            let external_hyps: Vec<GlideHypothesis> = cleaned_external
                .into_iter()
                .enumerate()
                .map(|(index, letters)| GlideHypothesis {
                    letters,
                    cost: index as f32 * 1.2,
                })
                .collect();
            let engine = &self.engine;
            rank_by_dictionary_with_prefix(
                external_hyps,
                prefix_syllables.as_deref(),
                |keys| engine.quanpin_best_weights_with_context(keys, extra_context.as_deref()),
            )
        } else {
            let matcher = GlideMatcher::new(&calibrated, points)?;
            let hypotheses = self.decode_quanpin_merged(&matcher);
            let engine = &self.engine;
            rank_by_dictionary_with_prefix(
                hypotheses,
                prefix_syllables.as_deref(),
                |keys| engine.quanpin_best_weights_with_context(keys, extra_context.as_deref()),
            )
        };
        let best = ranked.first()?;
        let rows = self
            .engine
            .query_raw_candidates(&best.letters, &best.letters);
        // 优先使用词典返回的带分词读音（如 `mei'guan'xi`），与抬手后的正式组字读音一致，避免顶栏读音跳动。
        let reading = rows
            .first()
            .filter(|row| complete_chinese_glide_candidate(row, &best.letters))
            .map(|row| row.canonical_pinyin.to_string())
            .filter(|r| !r.is_empty())
            .unwrap_or_else(|| rows_reading_hint(&best.letters, &ranked));
        // 滑行实时预览直接渲染在正式候选栏中，给足一整页候选（最多 9 个），并沿用与抬手提交一致的次优读音前置顺序，抬手交接时不跳动。
        const PREVIEW_LIMIT: usize = 9;
        let primary_words: Vec<String> = {
            let mut list = Vec::with_capacity(PREVIEW_LIMIT);
            for row in rows {
                if !list.iter().any(|w: &String| w == row.word.as_ref()) {
                    list.push(row.word.to_string());
                    if list.len() >= PREVIEW_LIMIT {
                        break;
                    }
                }
            }
            list
        };
        let is_multi_syllable = best.letters.len() >= 4;
        let head_count = primary_words.len().min(if is_multi_syllable { 1 } else { 2 });
        let mut words = Vec::with_capacity(PREVIEW_LIMIT);
        words.extend(primary_words.iter().take(head_count).cloned());

        let alt_limit = if is_multi_syllable { 3 } else { 2 };
        for alt in ranked
            .iter()
            .skip(1)
            .filter(|alt| alt.letters != best.letters && alt.cost <= best.cost + 5.5)
            .take(alt_limit)
        {
            if words.len() >= PREVIEW_LIMIT {
                break;
            }
            let alt_rows = self
                .engine
                .query_raw_candidates(&alt.letters, &alt.letters);
            if let Some(top) = alt_rows
                .into_iter()
                .find(|row| complete_chinese_glide_candidate(row, &alt.letters))
            {
                if !words.iter().any(|w| w == top.word.as_ref()) {
                    words.push(top.word.to_string());
                }
            }
        }
        for word in primary_words.into_iter().skip(head_count) {
            if words.len() >= PREVIEW_LIMIT {
                break;
            }
            if !words.iter().any(|w| w == &word) {
                words.push(word);
            }
        }
        Some((reading, words))
    }

    pub(super) fn glide(
        &mut self,
        keyboard: &GlideKeyboard,
        points: &[GlidePoint],
        external_readings: &[String],
    ) -> KeyResult {
        self.exit_date_time_menu();
        if self.dedicated_english
            || self.local_mode != LocalInputMode::None
            || self.scheme() != SchemeType::Quanpin
        {
            return KeyResult::unhandled();
        }
        // 一笔滑行写进组字，与键入字母一样先退出整句改字。
        let had_composition = self.has_composition();
        self.leave_conversion();
        let calibrated = self.glide_calibrator.apply(keyboard);
        let (extra_context, prefix_syllables) = self.active_glide_context();
        let prefix_before_glide = had_composition.then(|| self.raw_with_cases().to_owned());
        let cleaned_external = sanitize_external_readings(external_readings);
        let ranked = if !cleaned_external.is_empty() {
            let external_hyps: Vec<GlideHypothesis> = cleaned_external
                .into_iter()
                .enumerate()
                .map(|(index, letters)| GlideHypothesis {
                    letters,
                    cost: index as f32 * 1.2,
                })
                .collect();
            let mut has_any_known = false;
            let ranked_external = {
                let engine = &self.engine;
                rank_by_dictionary_with_prefix(
                    external_hyps,
                    prefix_syllables.as_deref(),
                    |keys| {
                        let weights =
                            engine.quanpin_best_weights_with_context(keys, extra_context.as_deref());
                        has_any_known = !weights.is_empty();
                        weights
                    },
                )
            };
            // 若词典权重表已命中外部读音，直接复用排序结果（零额外 `query_raw_candidates` 开销）；
            // 仅当词典完全未命中时才惰性检查一次是否可出候选，仍无果则无缝回退内置几何解码，绝不清空已有组字。
            let usable = has_any_known
                || ranked_external.first().is_some_and(|hyp| {
                    !self
                        .engine
                        .query_raw_candidates(&hyp.letters, &hyp.letters)
                        .is_empty()
                });
            if usable {
                ranked_external
            } else if let Some(matcher) = GlideMatcher::new(&calibrated, points) {
                let hypotheses = self.decode_quanpin_merged(&matcher);
                let engine = &self.engine;
                rank_by_dictionary_with_prefix(
                    hypotheses,
                    prefix_syllables.as_deref(),
                    |keys| engine.quanpin_best_weights_with_context(keys, extra_context.as_deref()),
                )
            } else {
                Vec::new()
            }
        } else if let Some(matcher) = GlideMatcher::new(&calibrated, points) {
            let hypotheses = self.decode_quanpin_merged(&matcher);
            let engine = &self.engine;
            rank_by_dictionary_with_prefix(
                hypotheses,
                prefix_syllables.as_deref(),
                |keys| engine.quanpin_best_weights_with_context(keys, extra_context.as_deref()),
            )
        } else {
            Vec::new()
        };
        let mut ranked_iter = ranked.into_iter();
        let Some(best) = ranked_iter.next() else {
            return KeyResult::unhandled();
        };
        let result = self.insert_glide_letters(&best.letters);
        if result.handled {
            if !had_composition {
                // 记录本次单笔滑行原始轨迹，待用户确认中文候选上屏后学习拇指落点偏置。
                self.pending_glide_calibration = Some(PendingGlideCalibration {
                    stroke_spelling: self.raw_with_cases().to_owned(),
                    raw_keyboard: keyboard.clone(),
                    points: points.to_vec(),
                });
            } else {
                self.pending_glide_calibration = None;
            }
        }
        if !had_composition && result.handled {
            // 共线或相近读音（如 `r->u->i` 同时匹配 `ri` 与 `rui`、`z->u->i` 匹配 `zi` 与 `zui`，以及多音节相近整词 `现在/选择`、`谢谢/学学`）
            // 把代价相近的次优读音候选插到首屏可见前排，避免被主读音 20+ 个冷门同音词挤到屏幕外。
            let is_multi_syllable = best.letters.len() >= 4;
            let secondary_limit = best.cost + 5.5;
            let mut merged = self.candidates().to_vec();
            let mut insert_at = merged.len().min(if is_multi_syllable { 1 } else { 2 });
            let mut added_secondary = false;
            let alt_limit = if is_multi_syllable { 3 } else { 2 };
            let mut alt_batches: Vec<(bool, Vec<WordItem>)> = Vec::new();
            for alt in ranked_iter
                .filter(|alt| alt.letters != best.letters && alt.cost <= secondary_limit)
                .take(alt_limit)
            {
                let close_tie = alt.cost <= best.cost + 1.5;
                let rows: Vec<WordItem> = self
                    .engine
                    .query_raw_candidates(&alt.letters, &alt.letters)
                    .into_iter()
                    .filter(|row| complete_chinese_glide_candidate(row, &alt.letters))
                    .take(if is_multi_syllable { 2 } else { 3 })
                    .collect();
                if !rows.is_empty() {
                    alt_batches.push((close_tie, rows));
                }
            }
            if !is_multi_syllable {
                for (close_tie, rows) in alt_batches {
                    if close_tie && insert_at > 1 {
                        insert_at = merged.len().min(1);
                    }
                    for mut row in rows {
                        if !merged.iter().any(|existing| existing.word == row.word) {
                            if !row.source.is_dictionary() {
                                row.source = CandidateSource::Generated;
                            }
                            merged.insert(insert_at, row);
                            insert_at += 1;
                            added_secondary = true;
                        }
                    }
                }
            } else {
                // 多音节整词先轮转插入每个次优读音的第 1 个词（占前排 1..3 位，一屏可见、一键直选），再补入其余同音备选。
                for round in 0..2 {
                    for (_, rows) in &alt_batches {
                        if let Some(mut row) = rows.get(round).cloned() {
                            if !merged.iter().any(|existing| existing.word == row.word) {
                                if !row.source.is_dictionary() {
                                    row.source = CandidateSource::Generated;
                                }
                                merged.insert(insert_at, row);
                                insert_at += 1;
                                added_secondary = true;
                            }
                        }
                    }
                }
            }
            if added_secondary {
                // 纯中文滑行保留常规标点顶字与失焦上屏语义，不设置仅限中英混滑使用的 `glide_selection_pending`。
                self.glide_candidates = Some((best.letters, merged));
            }
        } else if had_composition && result.handled {
            // 连续滑行第二、第三笔时，同样将代价接近的次优读音拼上原前缀后的高频整词前置到 1..2 位，减少续滑微偏时的整段重打。
            if let Some(prefix_raw) = prefix_before_glide.filter(|p| !p.is_empty()) {
                let combined_best = self.raw_with_cases().to_owned();
                let mut merged = self.candidates().to_vec();
                let mut insert_at = merged.len().min(1);
                let mut added_secondary = false;
                for alt in ranked_iter
                    .filter(|alt| alt.letters != best.letters && alt.cost <= best.cost + 3.5)
                    .take(2)
                {
                    let combined_alt = if prefix_raw.ends_with('\'') {
                        format!("{prefix_raw}{}", alt.letters)
                    } else {
                        format!("{prefix_raw}'{}", alt.letters)
                    };
                    if let Some(mut top) = self
                        .engine
                        .query_raw_candidates(&combined_alt, &combined_alt)
                        .into_iter()
                        .find(|row| complete_chinese_glide_candidate(row, &combined_alt))
                    {
                        if !merged.iter().any(|existing| existing.word == top.word) {
                            if !top.source.is_dictionary() {
                                top.source = CandidateSource::Generated;
                            }
                            merged.insert(insert_at, top);
                            insert_at += 1;
                            added_secondary = true;
                        }
                    }
                }
                if added_secondary {
                    self.glide_candidates = Some((combined_best, merged));
                }
            }
        }
        result
    }

    /// 把 `letters`（小写、非空）写到光标处。新组字的第一个字母按打字的方式输入，所以它的开始和打字时一样；滑进已有组字时，凡是挨着其他字母的一侧都加 `'` 隔开，两次滑行不会被读成一个音节（先 `xi` 再 `an` 仍是 `xi'an`）。
    fn insert_glide_letters(&mut self, letters: &str) -> KeyResult {
        let Some((&first, rest)) = letters.as_bytes().split_first() else {
            return KeyResult::unhandled();
        };
        if !self.has_composition() {
            let typed = self.handle_character(first, false);
            if !typed.handled || rest.is_empty() {
                return typed;
            }
            let text = {
                let current = self.raw_with_cases();
                let mut text = String::with_capacity(current.len() + rest.len());
                text.push_str(current);
                text.push_str(&letters[1..]);
                text
            };
            let caret = text.len();
            return self.replace_editing_text(&text, caret);
        }
        let caret = self.caret_position();
        let (text, new_caret) = {
            let current = self.raw_with_cases();
            let left_separator = caret > 0 && !current[..caret].ends_with('\'');
            let right_separator = caret < current.len() && !current[caret..].starts_with('\'');
            let inserted_len =
                letters.len() + usize::from(left_separator) + usize::from(right_separator);
            let mut text = String::with_capacity(current.len() + inserted_len);
            text.push_str(&current[..caret]);
            if left_separator {
                text.push('\'');
            }
            text.push_str(letters);
            if right_separator {
                text.push('\'');
            }
            text.push_str(&current[caret..]);
            (text, caret + inserted_len)
        };
        self.replace_editing_text(&text, new_caret)
    }
}
