use std::collections::HashMap;

use super::*;

const KEY_WIDTH: f32 = 100.0;
const KEY_HEIGHT: f32 = 150.0;

#[test]
fn an_english_word_uses_the_shared_geometry_and_collapses_repeated_letters() {
    for word in ["hello", "meeting", "women", "world"] {
        let matcher = GlideMatcher::new(&keyboard(), &stroke(word, 0.1, &[])).unwrap();
        let score = matcher.score(word).unwrap();
        assert!(score.is_finite(), "{word}");
        assert!(matcher.score("zqxzqx").is_none_or(|wrong| score < wrong));
    }
    let points = stroke("helo", 0.0, &[]);
    let matcher = GlideMatcher::new(&keyboard(), &points).unwrap();
    assert_eq!(matcher.score("hello"), matcher.score("helo"));
    assert!(matcher.score("hello-world").is_none());
}

/// 各移动宿主画的 26 键布局：第二行缩进半个键，第三行越过 Shift 缩进一个半键。
pub(crate) fn keyboard() -> GlideKeyboard {
    let rows: [(&[u8], f32); 3] = [(b"qwertyuiop", 0.0), (b"asdfghjkl", 0.5), (b"zxcvbnm", 1.5)];
    let mut centers = [(0.0, 0.0); 26];
    for (row, (keys, indent)) in rows.iter().enumerate() {
        for (column, &key) in keys.iter().enumerate() {
            centers[usize::from(key - b'a')] = (
                (column as f32 + indent + 0.5) * KEY_WIDTH,
                (row as f32 + 0.5) * KEY_HEIGHT,
            );
        }
    }
    GlideKeyboard {
        centers,
        key_width: KEY_WIDTH,
        key_height: KEY_HEIGHT,
    }
}

fn center(keyboard: &GlideKeyboard, letter: u8) -> (f32, f32) {
    keyboard.centers[usize::from(letter - b'a')]
}

/// `-amplitude..amplitude` 之间的确定性抖动，让带噪声的笔画每次运行都相同。
struct Jitter(u32);

impl Jitter {
    fn next(&mut self, amplitude: f32) -> f32 {
        self.0 = self.0.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        ((self.0 >> 8) as f32 / (1u32 << 24) as f32 * 2.0 - 1.0) * amplitude
    }
}

/// 经过 `word` 各键中心的笔画，每十像素、8 毫秒一个点，每点偏移至多 `noise` 个键；`dwell_on` 里的字母上停留 200 毫秒。
pub(crate) fn stroke(word: &str, noise: f32, dwell_on: &[usize]) -> Vec<GlidePoint> {
    let keyboard = keyboard();
    let mut jitter = Jitter(word.len() as u32 * 7919 + 17);
    let mut points = Vec::new();
    let mut time = 0;
    let letters = word.as_bytes();
    let mut push = |x: f32, y: f32, time: u32, jitter: &mut Jitter| {
        points.push(GlidePoint {
            x: x + jitter.next(noise) * KEY_WIDTH,
            y: y + jitter.next(noise) * KEY_HEIGHT,
            time_ms: Some(time),
        });
    };
    for (index, pair) in letters.windows(2).enumerate() {
        let (ax, ay) = center(&keyboard, pair[0]);
        let (bx, by) = center(&keyboard, pair[1]);
        if dwell_on.contains(&index) {
            for _ in 0..25 {
                push(ax, ay, time, &mut jitter);
                time += 8;
            }
        }
        let steps = (((bx - ax).powi(2) + (by - ay).powi(2)).sqrt() / 10.0)
            .ceil()
            .max(1.0) as usize;
        for step in 0..steps {
            let t = step as f32 / steps as f32;
            push(ax + (bx - ax) * t, ay + (by - ay) * t, time, &mut jitter);
            time += 8;
        }
    }
    let (x, y) = center(&keyboard, *letters.last().expect("non-empty word"));
    if dwell_on.contains(&(letters.len() - 1)) {
        for _ in 0..25 {
            push(x, y, time, &mut jitter);
            time += 8;
        }
    }
    push(x, y, time, &mut jitter);
    points
}

fn decoded(points: &[GlidePoint]) -> Vec<String> {
    decode_glide(&keyboard(), points, 16)
        .into_iter()
        .map(|hypothesis| hypothesis.letters)
        .collect()
}

#[test]
fn clean_strokes_decode_to_the_letters_they_trace() {
    for word in [
        "nihao", "shi", "women", "xian", "xiang", "wo", "de", "shenme", "pinyin", "shurufa",
        "huanying", "qing", "jintian", "mei",
    ] {
        let result = decoded(&stroke(word, 0.0, &[]));
        assert_eq!(
            result.first().map(String::as_str),
            Some(word),
            "{word}: {result:?}"
        );
    }
}

#[test]
fn a_key_on_the_line_between_two_others_is_left_to_the_dictionary() {
    // `h` 几乎在 `z` 到 `o` 的连线上，`y` 在 `e` 到 `i` 的连线上，`d` 在 `i` 到 `a` 的连线上，所以每一对的笔画几乎相同；两个都要返回，留给词典来选。
    for (word, twin) in [
        ("zhong", "zong"),
        ("zhongguo", "zongguo"),
        ("keyi", "kei"),
        ("zhidao", "zhiao"),
    ] {
        let result = decoded(&stroke(word, 0.0, &[]));
        assert!(result.contains(&word.to_owned()), "{word}: {result:?}");
        assert!(result.contains(&twin.to_owned()), "{word}: {result:?}");
    }
}

/// `letters` 能否切成完整音节。
fn splits_into_syllables(letters: &str) -> bool {
    letters.is_empty()
        || (1..=letters.len().min(6)).any(|end| {
            crate::pinyin::syllables::is_intact(&letters[..end])
                && splits_into_syllables(&letters[end..])
        })
}

#[test]
fn noisy_strokes_still_decode() {
    for word in ["nihao", "women", "xiang", "shenme", "huanying", "jintian"] {
        let result = decoded(&stroke(word, 0.3, &[]));
        assert_eq!(
            result.first().map(String::as_str),
            Some(word),
            "{word}: {result:?}"
        );
    }
}

#[test]
fn a_corner_the_stroke_turns_on_is_a_letter() {
    // `shi` 在 `h` 上拐弯；从 `s` 到 `i` 的直线会读成 `si`。
    let result = decoded(&stroke("shi", 0.0, &[]));
    assert_eq!(result[0], "shi");
    let straight = decoded(&stroke("si", 0.0, &[]));
    assert_eq!(straight[0], "si");
    assert!(!straight.iter().take(1).any(|letters| letters == "shi"));
}

#[test]
fn a_key_passed_over_is_not_typed_but_a_dwell_on_it_is() {
    // `u` 在 `s` 到 `i` 的直线上。
    let passed = decoded(&stroke("sui", 0.0, &[]));
    assert_eq!(passed[0], "si", "{passed:?}");
    assert!(passed.contains(&"sui".to_owned()), "{passed:?}");
    let rested = decoded(&stroke("sui", 0.0, &[1]));
    assert_eq!(rested[0], "sui", "{rested:?}");
}

#[test]
fn every_hypothesis_is_complete_quanpin() {
    let hypotheses = decode_glide(&keyboard(), &stroke("zhongguo", 0.2, &[]), 8);
    assert!(!hypotheses.is_empty());
    for hypothesis in &hypotheses {
        let letters = &hypothesis.letters;
        assert!(splits_into_syllables(letters), "{letters}");
    }
    assert!(hypotheses
        .windows(2)
        .all(|pair| pair[0].cost <= pair[1].cost));
}

#[test]
fn coordinates_are_measured_in_keys() {
    let mut scaled = keyboard();
    scaled.key_width *= 3.0;
    scaled.key_height *= 0.5;
    for center in &mut scaled.centers {
        center.0 *= 3.0;
        center.1 *= 0.5;
    }
    let points: Vec<GlidePoint> = stroke("women", 0.1, &[])
        .into_iter()
        .map(|p| GlidePoint {
            x: p.x * 3.0,
            y: p.y * 0.5,
            ..p
        })
        .collect();
    let original = decode_glide(&keyboard(), &stroke("women", 0.1, &[]), 4);
    let rescaled = decode_glide(&scaled, &points, 4);
    let letters =
        |list: &[GlideHypothesis]| list.iter().map(|h| h.letters.clone()).collect::<Vec<_>>();
    assert_eq!(letters(&original), letters(&rescaled));
}

#[test]
fn unusable_input_decodes_to_nothing() {
    let points = stroke("nihao", 0.0, &[]);
    assert!(decode_glide(&keyboard(), &points[..1], 8).is_empty());
    assert!(decode_glide(&keyboard(), &points, 0).is_empty());
    let mut broken = keyboard();
    broken.key_width = 0.0;
    assert!(decode_glide(&broken, &points, 8).is_empty());
    let mut nan = points.clone();
    nan[3].x = f32::NAN;
    assert!(decode_glide(&keyboard(), &nan, 8).is_empty());
}

#[test]
fn a_very_long_stroke_is_bounded() {
    let word = "zhonghuarenmingongheguowansui";
    let points = stroke(word, 0.0, &[]);
    let started = std::time::Instant::now();
    let hypotheses = decode_glide(&keyboard(), &points, 8);
    let elapsed = started.elapsed();
    assert!(!hypotheses.is_empty());
    eprintln!(
        "{} letters, {} points: {elapsed:?}, best {:?}",
        word.len(),
        points.len(),
        hypotheses[0]
    );
}

/// 出货词典里的权重量级：单字几百万，常用词几十万。
fn shipped_weights(keys: &[String]) -> HashMap<String, i64> {
    let table: &[(&str, i64)] = &[
        ("zhong", 7_680_869),
        ("zong", 1_273_655),
        ("kei", 192),
        ("ke", 3_000_000),
        ("yi", 20_000_000),
        ("ke'yi", 505_814),
        ("shi", 31_422_712),
        ("si", 1_979_349),
        ("sui", 1_211_358),
        ("ni'hao", 332_885),
        ("ni", 9_000_000),
        ("hao", 6_000_000),
        ("zhong'guo", 505_879),
        ("guo", 8_000_000),
        ("de", 40_000_000),
        ("e", 400_000),
        ("wo", 20_000_000),
        ("wu", 3_000_000),
        ("o", 300_000),
        ("you", 12_000_000),
        ("yi'ou", 1_200),
        ("ou", 400_000),
        ("zhi'dao", 480_000),
        ("zhi", 5_000_000),
        ("dao", 3_000_000),
        ("ao", 300_000),
    ];
    keys.iter()
        .filter_map(|key| {
            table
                .iter()
                .find(|(known, _)| known == key)
                .map(|&(_, weight)| (key.clone(), weight))
        })
        .collect()
}

fn ranked(points: &[GlidePoint]) -> Vec<String> {
    rank_by_dictionary(decode_glide(&keyboard(), points, 16), shipped_weights)
        .into_iter()
        .map(|hypothesis| hypothesis.letters)
        .collect()
}

#[test]
fn the_dictionary_settles_what_the_stroke_cannot() {
    for (word, dwell) in [
        ("zhong", &[][..]),
        ("zong", &[]),
        ("keyi", &[]),
        ("zhongguo", &[]),
        ("nihao", &[]),
        ("de", &[]),
        ("wo", &[]),
        ("you", &[]),
        ("zhidao", &[]),
        ("si", &[]),
        ("shi", &[]),
        ("sui", &[1]),
    ] {
        let result = ranked(&stroke(word, 0.15, dwell));
        assert_eq!(
            result.first().map(String::as_str),
            Some(word),
            "{word}: {result:?}"
        );
    }
}

#[test]
fn a_doubled_key_needs_more_than_a_touch() {
    for word in ["de", "ta", "le"] {
        let result = decoded(&stroke(word, 0.15, &[]));
        let doubled = format!("{word}{}", &word[word.len() - 1..]);
        let plain = result.iter().position(|letters| letters == word);
        let twice = result.iter().position(|letters| *letters == doubled);
        assert_eq!(plain, Some(0), "{word}: {result:?}");
        assert!(twice.is_none_or(|at| at > 0), "{word}: {result:?}");
    }
}

#[test]
fn ranking_scores_a_string_by_its_best_word_split() {
    let hypotheses = vec![
        GlideHypothesis {
            letters: "xian".into(),
            cost: 2.0,
        },
        GlideHypothesis {
            letters: "xiaan".into(),
            cost: 2.0,
        },
    ];
    let ranked = rank_by_dictionary(hypotheses, |keys| {
        assert!(
            keys.contains(&"xi'an".to_owned()) && keys.contains(&"xian".to_owned()),
            "{keys:?}"
        );
        assert!(keys.windows(2).all(|pair| pair[0] < pair[1]), "{keys:?}");
        HashMap::from([("xi'an".to_owned(), 100_000), ("xi".to_owned(), 1_000_000)])
    });
    assert_eq!(ranked[0].letters, "xian");
}

#[test]
fn ranking_a_decoded_stroke_keeps_dictionary_key_allocations_bounded() {
    let hypotheses = decode_glide(
        &keyboard(),
        &stroke("zhonghuarenmingongheguowansui", 0.0, &[]),
        16,
    );
    let (_, allocations) = crate::ime::personal_rerank::allocations::count(|| {
        rank_by_dictionary(hypotheses, |_| HashMap::new())
    });
    assert!(
        allocations <= 200,
        "glide ranking allocations: {allocations}"
    );
}

#[test]
fn ranking_reuses_materialized_split_keys_for_scoring() {
    let hypotheses = (0..16)
        .map(|index| GlideHypothesis {
            letters: "xian".into(),
            cost: index as f32,
        })
        .collect();
    let (_, allocations) = crate::ime::personal_rerank::allocations::count(|| {
        rank_by_dictionary(hypotheses, |_| HashMap::new())
    });
    assert!(
        allocations <= 110,
        "glide ranking repeated split-key allocations: {allocations}"
    );
}

#[test]
fn a_stroke_that_doubles_back_is_not_one_pass() {
    // 这几笔都在一条线上来回走；读成只走一遍就会是 `lao`、`keng`、`shou` 和 `gen`。
    for (word, single) in [
        ("laishuo", "lao"),
        ("keneng", "keng"),
        ("shihou", "shou"),
        ("geren", "gen"),
    ] {
        let result = decoded(&stroke(word, 0.0, &[]));
        let found = result.iter().position(|letters| letters == word);
        let one_pass = result.iter().position(|letters| letters == single);
        assert_eq!(found, Some(0), "{word}: {result:?}");
        assert!(one_pass.is_none_or(|at| at > 0), "{word}: {result:?}");
    }
}

#[test]
fn decoding_a_long_stroke_reuses_beam_storage() {
    let keyboard = keyboard();
    let points = stroke("zhonghuarenmingongheguowansui", 0.0, &[]);
    let (_, allocations) =
        crate::ime::personal_rerank::allocations::count(|| decode_glide(&keyboard, &points, 8));
    assert!(
        allocations <= 22_000,
        "glide beam allocations: {allocations}"
    );
}

#[test]
fn resting_on_end_key_does_not_double_the_final_letter() {
    // 在 `hao`、`wo`、`de` 的尾键上停留 200ms（模拟抬手前自然减速/稍作停顿），不能把尾字母重复拼成 `haoo`、`woo`、`dee`。
    for word in ["hao", "wo", "de"] {
        let points = stroke(word, 0.12, &[word.len() - 1]);
        let result = ranked(&points);
        assert_eq!(
            result.first().map(String::as_str),
            Some(word),
            "{word} with end-key rest: {result:?}"
        );
    }
}

#[test]
fn liftoff_hook_tail_is_trimmed_without_affecting_clean_strokes() {
    let kb = keyboard();
    let mut points = stroke("nihao", 0.0, &[]);
    for (index, point) in points.iter_mut().enumerate() {
        point.time_ms = Some((index as u32) * 10);
    }
    let last = *points.last().expect("non-empty stroke");
    let prev = points[points.len() - 2];
    let dx = last.x - prev.x;
    let dy = last.y - prev.y;
    let len = (dx * dx + dy * dy).sqrt().max(1.0);
    // 在最后 10ms 构造一个反向短回勾（0.3 个键宽）模拟拇指离屏抖动。
    let hook = GlidePoint {
        x: last.x - (dx / len) * kb.key_width * 0.3,
        y: last.y - (dy / len) * kb.key_width * 0.3,
        time_ms: Some(last.time_ms.unwrap() + 10),
    };
    let mut hooked = points.clone();
    hooked.push(hook);
    let normalize = |pts: &[GlidePoint]| -> Vec<GlidePoint> {
        pts.iter()
            .map(|p| GlidePoint {
                x: p.x / kb.key_width,
                y: p.y / kb.key_height,
                time_ms: p.time_ms,
            })
            .collect()
    };
    let normalized_hooked = normalize(&hooked);
    let normalized_clean = normalize(&points);
    assert_eq!(trim_liftoff_hook(&normalized_hooked).len(), normalized_clean.len());
    assert_eq!(trim_liftoff_hook(&normalized_clean).len(), normalized_clean.len());

    let result = decoded(&hooked);
    assert_eq!(result.first().map(String::as_str), Some("nihao"));
}

#[test]
fn english_matcher_prunes_mismatched_words_with_zero_heap_allocations() {
    let kb = keyboard();
    let points = stroke("hello", 0.0, &[]);
    let matcher = GlideMatcher::new(&kb, &points).expect("matcher");
    let (matched, allocs_hit) =
        crate::ime::personal_rerank::allocations::count(|| matcher.score("hello"));
    assert!(matched.is_some());
    assert_eq!(allocs_hit, 0, "matching word should allocate zero heap memory");

    let (missed, allocs_miss) =
        crate::ime::personal_rerank::allocations::count(|| matcher.score("happy"));
    assert!(missed.is_none());
    assert_eq!(allocs_miss, 0, "pruned word should allocate zero heap memory");
}

#[test]
fn boundary_consonant_repeat_decodes_diannao_and_zhongguo_in_one_pass() {
    for word in ["diannao", "zhongguo"] {
        let result = decoded(&stroke(word, 0.0, &[]));
        assert!(
            result.contains(&word.to_owned()),
            "{word} should survive beam with single-pass boundary repeat: {result:?}"
        );
    }
}

#[test]
fn ranking_compositional_dp_prefers_known_phrase_pieces_over_scattered_syllables() {
    let hypotheses = vec![
        GlideHypothesis {
            letters: "chifanle".into(),
            cost: 3.0,
        },
        GlideHypothesis {
            letters: "cidanle".into(),
            cost: 2.6,
        },
    ];
    let ranked = rank_by_dictionary(hypotheses, |_| {
        HashMap::from([
            ("chi'fan".to_owned(), 400_000),
            ("chi".to_owned(), 5_000_000),
            ("fan".to_owned(), 3_000_000),
            ("le".to_owned(), 25_000_000),
            ("ci".to_owned(), 4_000_000),
            ("dan".to_owned(), 3_000_000),
        ])
    });
    assert_eq!(
        ranked[0].letters, "chifanle",
        "chi'fan + le 组合短语应击败零散三音节 ci'dan'le: {ranked:?}"
    );
}

#[test]
fn lexicon_matcher_recovers_curved_multisyllable_words_with_bitmask_filter() {
    let kb = keyboard();
    let entries: Vec<GlideLexiconEntry> = [
        "xian'zai",
        "mei'guan'xi",
        "bu'hao'yi'si",
        "dian'hua",
        "zhong'guo",
        "bu'zhi'dao",
    ]
    .into_iter()
    .filter_map(GlideLexiconEntry::from_key)
    .collect();
    for word in ["xianzai", "meiguanxi", "buhaoyisi", "dianhua"] {
        let pts = human_curved_stroke(word, 0.45, 0.20, 0.15);
        let matcher = GlideMatcher::new(&kb, &pts).expect("matcher");
        let hits = matcher.score_lexicon(&entries, 8);
        assert!(
            hits.iter().any(|h| h.letters == word),
            "{word} should be recovered directly by lexicon matcher: {hits:?}"
        );
    }

    // 模拟单手拇指缩手滑长词（整体向键盘中心收缩 22%，边缘键 `a`/`i` 落在严格邻域外），SHARK2 形状+方向双通道应仍能召回整词。
    let center_x = 4.5 * KEY_WIDTH;
    let center_y = 1.5 * KEY_HEIGHT;
    let shrunk_entries: Vec<GlideLexiconEntry> = [
        "kai'xin",
        "dian'nao",
        "bu'hao'yi'si",
        "wan'shang'hao",
        "he'wo",
        "mo'ren",
    ]
    .into_iter()
    .filter_map(GlideLexiconEntry::from_key)
    .collect();
    for word in ["kaixin", "diannao", "buhaoyisi"] {
        let shrunk: Vec<GlidePoint> = stroke(word, 0.05, &[])
            .into_iter()
            .map(|p| GlidePoint {
                x: center_x + (p.x - center_x) * 0.78,
                y: center_y + (p.y - center_y) * 0.85,
                time_ms: p.time_ms,
            })
            .collect();
        let matcher = GlideMatcher::new(&kb, &shrunk).expect("matcher");
        let hits = matcher.score_lexicon(&shrunk_entries, 8);
        assert_eq!(
            hits.first().map(|h| h.letters.as_str()),
            Some(word),
            "缩手整词 {word} 应由 SHARK2 形状通道排到首位: {hits:?}"
        );
    }
}

/// 模拟真实人手拇指滑行：首尾落点带轻微偏移，中间拐角按 `corner_cut` 做 Chaikin 圆角切弯，并叠加平滑抖动。
fn human_curved_stroke(
    word: &str,
    corner_cut: f32,
    jitter_amp: f32,
    endpoint_offset: f32,
) -> Vec<GlidePoint> {
    let kb = keyboard();
    let letters = word.as_bytes();
    let mut jitter = Jitter(word.len() as u32 * 31337 + 911);
    let mut anchors: Vec<(f32, f32)> = letters
        .iter()
        .enumerate()
        .map(|(i, &b)| {
            let (cx, cy) = center(&kb, b);
            let scale = if i == 0 || i + 1 == letters.len() {
                endpoint_offset
            } else {
                jitter_amp
            };
            (
                cx + jitter.next(scale) * KEY_WIDTH,
                cy + jitter.next(scale) * KEY_HEIGHT,
            )
        })
        .collect();
    if anchors.len() >= 3 && corner_cut > 0.0 {
        // 两轮可控圆角切弯：保持首尾锚点不动，中间拐点向相邻线段内切。
        let t = (corner_cut * 0.5).clamp(0.0, 0.35);
        let mut next = Vec::with_capacity(anchors.len() * 2);
        next.push(anchors[0]);
        for i in 0..anchors.len() - 1 {
            let a = anchors[i];
            let b = anchors[i + 1];
            if i > 0 {
                next.push((a.0 * (1.0 - t) + b.0 * t, a.1 * (1.0 - t) + b.1 * t));
            }
            if i + 2 < anchors.len() {
                next.push((a.0 * t + b.0 * (1.0 - t), a.1 * t + b.1 * (1.0 - t)));
            }
        }
        next.push(*anchors.last().unwrap());
        anchors = next;
    }
    let mut points = Vec::new();
    let mut time = 0u32;
    for pair in anchors.windows(2) {
        let (ax, ay) = pair[0];
        let (bx, by) = pair[1];
        let dist = ((bx - ax).powi(2) + (by - ay).powi(2)).sqrt();
        let steps = (dist / 14.0).ceil().max(1.0) as usize;
        for step in 0..steps {
            let f = step as f32 / steps as f32;
            points.push(GlidePoint {
                x: ax + (bx - ax) * f,
                y: ay + (by - ay) * f,
                time_ms: Some(time),
            });
            time += 8;
        }
    }
    let &(lx, ly) = anchors.last().unwrap();
    points.push(GlidePoint {
        x: lx,
        y: ly,
        time_ms: Some(time),
    });
    points
}

#[test]
#[ignore]
fn benchmark_shipped_dictionary_real_human_glides() {
    let db_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/ios/EngineResources/msime-pinyin.db");
    let db = crate::dictionary::pinyin::PinyinDatabase::open(&db_path);
    assert!(db.is_open(), "shipped msime-pinyin.db should open");
    let lookup = |keys: &[String]| -> HashMap<String, i64> {
        db.query_exact_keys_per_key(keys, 1)
            .into_iter()
            .filter_map(|(k, rows)| rows.first().map(|r| (k, r.weight)))
            .collect()
    };
    let mut lex_cache: [Option<Vec<GlideLexiconEntry>>; 26] = std::array::from_fn(|_| None);
    let words = [
        // 常见单音节与双音节词
        "wo", "ni", "de", "shi", "bu", "you", "zhe", "le", "hao", "men",
        "nihao", "women", "shenme", "zenme", "zhidao", "keyi", "xianzai", "wanshang",
        "mingtian", "jintian", "zuotian", "pengyou", "shijian", "gongzuo", "dianhua",
        "weixin", "shouji", "diannao", "xihuan", "kaixin", "xiexie", "zhongguo",
        "shihou", "laishuo", "keneng", "geren", "yijing", "yinwei", "suoyi", "ruguo",
        // 三四音节常用词与日常组合短语（含非整词短语）
        "meiguanxi", "buhaoyisi", "weishenme", "zenmeyang", "duibuqi", "buzhidao",
        "woqu", "zaima", "chifanle", "henhao", "haode", "shide", "bushi", "woshuo",
        "nishuo", "zaoshanghao", "wanshanghao", "meiwenti", "yidianer", "kexi",
    ];
    let kb = keyboard();
    for (label, cut, jit, end_off) in [
        ("clean", 0.0f32, 0.0f32, 0.0f32),
        ("human-medium", 0.45, 0.25, 0.20),
        ("human-sloppy", 0.65, 0.35, 0.30),
    ] {
        for use_lexicon in [false, true] {
            let mut top1 = 0usize;
            let mut top3 = 0usize;
            let mut in_pool = 0usize;
            let mut misses = Vec::new();
            let started = std::time::Instant::now();
            for &word in &words {
                let pts = human_curved_stroke(word, cut, jit, end_off);
                let matcher = GlideMatcher::new(&kb, &pts).expect("matcher");
                let mut hyps = matcher.decode_quanpin(48);
                if use_lexicon {
                    for initial in matcher.lexicon_starting_letters() {
                        let slot = usize::from(initial - b'a');
                        let entries = lex_cache[slot]
                            .get_or_insert_with(|| db.top_glide_lexicon_for_initial(initial));
                        for hit in matcher.score_lexicon(entries, 48) {
                            if let Some(existing) = hyps.iter_mut().find(|h| h.letters == hit.letters) {
                                existing.cost = existing.cost.min(hit.cost);
                            } else {
                                hyps.push(hit);
                            }
                        }
                    }
                    hyps.sort_by(|a, b| a.cost.total_cmp(&b.cost).then_with(|| a.letters.cmp(&b.letters)));
                    hyps.truncate(96);
                }
                if hyps.iter().any(|h| h.letters == word) {
                    in_pool += 1;
                }
                let ranked = rank_by_dictionary(hyps, &lookup);
                let pos = ranked.iter().position(|h| h.letters == word);
                if pos == Some(0) {
                    top1 += 1;
                }
                if pos.is_some_and(|p| p < 3) {
                    top3 += 1;
                } else {
                    let got: Vec<&str> = ranked.iter().take(3).map(|h| h.letters.as_str()).collect();
                    misses.push(format!("{word}->{got:?}"));
                }
            }
            let elapsed = started.elapsed();
            let mode = if use_lexicon { "beam+lex" } else { "beam-only" };
            eprintln!(
                "[{label} | {mode}] total={} top1={top1} ({:.1}%) top3={top3} ({:.1}%) recall={in_pool} ({:.1}%) avg={:.2}ms",
                words.len(),
                top1 as f64 * 100.0 / words.len() as f64,
                top3 as f64 * 100.0 / words.len() as f64,
                in_pool as f64 * 100.0 / words.len() as f64,
                elapsed.as_secs_f64() * 1000.0 / words.len() as f64,
            );
            if use_lexicon && !misses.is_empty() {
                eprintln!("  misses: {}", misses.join(", "));
            }
        }
    }
}

#[test]
fn glide_calibrator_adapts_systematic_thumb_bias_clamps_outliers_and_persists() {
    let kb = keyboard();
    let raw_centers = kb.normalized_centers();
    let mut calibrator = GlideKeyCalibrator::default();

    // 模拟单手拇指系统性右偏 +0.28 键宽、上偏 -0.10 键高
    let shift_x = KEY_WIDTH * 0.28;
    let shift_y = -KEY_HEIGHT * 0.10;
    for word in ["nihao", "women", "shenme", "nihao"] {
        let mut pts = stroke(word, 0.0, &[]);
        for p in &mut pts {
            p.x += shift_x;
            p.y += shift_y;
        }
        let matcher = GlideMatcher::new(&kb, &pts).expect("matcher");
        let aligned = matcher.align_letters(word).expect("aligned");
        assert!(calibrator.observe_alignment(&aligned, &raw_centers));
    }
    assert_eq!(calibrator.total_observations(), 4);

    let adapted = calibrator.apply(&kb);
    let idx_n = usize::from(b'n' - b'a');
    let (ax, ay) = center(&adapted, b'n');
    let (bx, by) = center(&kb, b'n');
    let dx_n = (ax - bx) / kb.key_width;
    let dy_n = (ay - by) / kb.key_height;
    assert!(
        dx_n > 0.05 && dx_n <= 0.35,
        "expected calibrated x shift toward +0.28, got {dx_n}"
    );
    assert!(
        dy_n < -0.02 && dy_n >= -0.35,
        "expected calibrated y shift toward -0.10, got {dy_n}"
    );

    // 极端离群样本（偏 2 格）应被拒收，且多次大偏移也受 ±0.35 键宽硬上限约束
    let wild = vec![(idx_n, raw_centers[idx_n].0 + 2.0, raw_centers[idx_n].1)];
    assert!(!calibrator.observe_alignment(&wild, &raw_centers));
    for _ in 0..30 {
        let big = vec![(idx_n, raw_centers[idx_n].0 + 0.70, raw_centers[idx_n].1)];
        let _ = calibrator.observe_alignment(&big, &raw_centers);
    }
    let clamped = calibrator.apply(&kb);
    let (cx, _) = center(&clamped, b'n');
    let clamped_dx = (cx - bx) / kb.key_width;
    assert!(
        clamped_dx <= 0.351,
        "calibration offset must stay clamped <= 0.35, got {clamped_dx}"
    );

    // 落盘与重加载往返一致
    let path = std::env::temp_dir().join(format!(
        "msime-glide-cal-test-{}.json",
        std::process::id()
    ));
    calibrator.save(&path);
    let reloaded = GlideKeyCalibrator::load(&path);
    let _ = std::fs::remove_file(&path);
    assert_eq!(reloaded.total_observations(), calibrator.total_observations());
    let reloaded_kb = reloaded.apply(&kb);
    let (rx, _) = center(&reloaded_kb, b'n');
    assert!((rx - cx).abs() < 1e-3);
}

#[test]
fn rank_by_dictionary_with_prefix_bridges_multi_stroke_phrases() {
    let hyps = vec![
        GlideHypothesis {
            letters: "ren".to_owned(),
            cost: 4.0,
        },
        GlideHypothesis {
            letters: "men".to_owned(),
            cost: 4.0,
        },
    ];
    let lookup = |keys: &[String]| -> HashMap<String, i64> {
        let mut map = HashMap::new();
        for key in keys {
            match key.as_str() {
                "ren" => {
                    map.insert(key.clone(), 900_000);
                }
                "men" => {
                    map.insert(key.clone(), 300_000);
                }
                "wo'men" => {
                    map.insert(key.clone(), 3_000_000);
                }
                _ => {}
            }
        }
        map
    };

    // 无前缀时高频单字 `ren` 领先；有前缀 `wo` 时跨笔整词 `wo'men` 将 `men` 拉到首位
    let standalone = rank_by_dictionary_with_prefix(hyps.clone(), None, lookup);
    assert_eq!(standalone[0].letters, "ren");

    let bridged = rank_by_dictionary_with_prefix(hyps, Some("wo"), lookup);
    assert_eq!(bridged[0].letters, "men");
}

#[test]
fn rounded_template_and_banded_dtw_recover_corner_cut_long_words() {
    let kb = keyboard();
    let entries = vec![
        GlideLexiconEntry::from_key("mei'guan'xi").unwrap(),
        GlideLexiconEntry::from_key("xian'zai").unwrap(),
        GlideLexiconEntry::from_key("bu'hao'yi'si").unwrap(),
    ];
    for word in ["meiguanxi", "xianzai", "buhaoyisi"] {
        let pts = human_curved_stroke(word, 0.65, 0.35, 0.30);
        let matcher = GlideMatcher::new(&kb, &pts).expect("matcher");
        let hits = matcher.score_lexicon(&entries, 8);
        assert_eq!(
            hits.first().map(|h| h.letters.as_str()),
            Some(word),
            "corner-cut long word `{word}` should lead lexicon hits, got {hits:?}"
        );
    }
}
