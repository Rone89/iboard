//! 同笔中英识别、候选选择和组字生命周期的行为回归。

use super::*;

#[test]
fn bilingual_glide_keeps_complete_readings_instead_of_dictionary_prefix_completions() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(
        "CREATE TABLE tbl_2_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_2_w VALUES('wo''men','wm','我们',1000);\
CREATE TABLE tbl_3_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_3_w VALUES('wo''men''de','wmd','我们的',100000);",
    )
    .with_english("INSERT INTO english_words VALUES('women','women',1000);");
    let mut session = fixture.session();
    assert!(
        session
            .bilingual_glide(&keyboard(), &stroke("women", 0.0, &[]))
            .handled
    );
    let candidates = words(&session);
    assert!(candidates.contains(&"我们".to_owned()), "{candidates:?}");
    assert!(candidates.contains(&"women".to_owned()), "{candidates:?}");
    assert!(
        !candidates.contains(&"我们的".to_owned()),
        "没滑入 de：{candidates:?}"
    );
}

#[test]
fn an_offset_english_glide_is_not_displaced_by_an_incomplete_chinese_reading() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(
        "CREATE TABLE tbl_2_h(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_2_h VALUES('he''long','hl','合拢',100000);",
    )
    .with_english("INSERT INTO english_words VALUES('hello','hello',1000);");
    let keyboard = keyboard();
    let mut points = stroke("helo", 0.0, &[]);
    for point in &mut points {
        point.x += keyboard.key_width * 0.24;
        point.y -= keyboard.key_height * 0.12;
    }
    let mut session = fixture.session();
    assert!(session.bilingual_glide(&keyboard, &points).handled);
    assert_eq!(words(&session).first().map(String::as_str), Some("hello"));
    assert!(!words(&session).contains(&"合拢".to_owned()));
}

#[test]
fn consecutive_chinese_glides_do_not_complete_an_unswiped_suffix() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(
        "CREATE TABLE tbl_1_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_1_n VALUES('ni','n','你',1000);\
CREATE TABLE tbl_1_h(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_1_h VALUES('hao','h','好',1000);\
CREATE TABLE tbl_2_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_2_n VALUES('ni''hao','nh','你好',2000);\
CREATE TABLE tbl_3_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_3_n VALUES('ni''hao''ma','nhm','你好吗',100000);",
    );
    let mut session = fixture.session();
    for spelling in ["ni", "hao"] {
        let result = session.bilingual_glide(&keyboard(), &stroke(spelling, 0.0, &[]));
        assert!(result.handled);
        assert_eq!(result.commit, None);
    }
    let candidates = words(&session);
    assert!(candidates.contains(&"你好".to_owned()), "{candidates:?}");
    assert!(
        !candidates.contains(&"你好吗".to_owned()),
        "没滑入 ma：{candidates:?}"
    );
    assert_eq!(
        session.command(Command::CommitCandidate).commit.as_deref(),
        Some("你好")
    );
}

#[test]
fn bilingual_glides_offer_both_languages_and_commit_without_switching() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(QUANPIN_FIXTURE).with_english(
        "INSERT INTO english_words VALUES('hello','hello',1000),('world','world',900);",
    );
    let mut session = fixture.session();
    assert!(
        session
            .bilingual_glide(&keyboard(), &stroke("nihao", 0.05, &[]))
            .handled
    );
    assert!(
        words(&session).contains(&"你好".to_owned()),
        "{:?}",
        words(&session)
    );
    assert_eq!(
        select_word(&mut session, "你好").commit.as_deref(),
        Some("你好")
    );
    assert!(
        session
            .bilingual_glide(&keyboard(), &stroke("hello", 0.05, &[]))
            .handled
    );
    assert!(
        words(&session).contains(&"hello".to_owned()),
        "{:?}",
        words(&session)
    );
    assert_eq!(
        select_word(&mut session, "hello").commit.as_deref(),
        Some("hello ")
    );
    assert!(!session.snapshot().dedicated_english);
    assert!(
        session
            .bilingual_glide(&keyboard(), &stroke("nihao", 0.05, &[]))
            .handled
    );
    assert!(words(&session).contains(&"你好".to_owned()));
}

#[test]
fn bilingual_glide_preserves_identical_spelling_choices_and_clears_on_edit() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(
        "CREATE TABLE tbl_2_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_2_w VALUES('wo''men','wm','我们',1000);",
    )
    .with_english("INSERT INTO english_words VALUES('women','women',900);");
    let mut session = fixture.session();
    assert!(
        session
            .bilingual_glide(&keyboard(), &stroke("women", 0.05, &[]))
            .handled
    );
    assert!(
        words(&session).contains(&"我们".to_owned()),
        "{:?}",
        words(&session)
    );
    assert!(words(&session).contains(&"women".to_owned()));
    let mut invalid = keyboard();
    invalid.key_width = 0.0;
    let before = session.snapshot();
    assert!(
        !session
            .bilingual_glide(&invalid, &stroke("hello", 0.0, &[]))
            .handled
    );
    assert_eq!(session.snapshot().candidates, before.candidates);
    session.command(Command::Backspace);
    assert!(session.input.glide_candidates.is_none());
    session.command(Command::Cancel);
    assert!(session.snapshot().candidates.is_empty());
}

#[test]
fn a_following_bilingual_glide_waits_for_explicit_phrase_selection() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(HELLO_FIXTURE).with_english(
        "INSERT INTO english_words VALUES('hello','hello',1000),('world','world',900);",
    );
    let mut session = fixture.session();
    assert!(
        session
            .bilingual_glide(&keyboard(), &stroke("hello", 0.0, &[]))
            .handled
    );
    assert_eq!(
        session
            .bilingual_glide(&keyboard(), &stroke("world", 0.0, &[]))
            .commit
            .as_deref(),
        None
    );
    assert_eq!(
        select_word(&mut session, "hello world").commit.as_deref(),
        Some("hello world ")
    );
    assert!(session.snapshot().preedit.is_empty());
    assert!(
        session
            .bilingual_glide(&keyboard(), &stroke("hello", 0.0, &[]))
            .handled
    );
    let before = session.snapshot().candidates;
    assert!(!session.select(usize::MAX).handled);
    assert_eq!(session.snapshot().candidates, before);
    assert!(session.finish(usize::MAX).handled);
    assert!(!session.snapshot().preedit.is_empty());
    session.command(Command::Cancel);
    assert!(session.snapshot().preedit.is_empty());
}

#[test]
fn consecutive_chinese_glides_keep_the_whole_phrase_uncommitted() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(QUANPIN_FIXTURE)
        .with_english("INSERT INTO english_words VALUES('hello','hello',1000);");
    let mut session = fixture.session();
    for (spelling, expected) in [("ni", "ni"), ("hao", "nihao"), ("nihao", "nihaonihao")] {
        let result = session.bilingual_glide(&keyboard(), &stroke(spelling, 0.0, &[]));
        assert!(result.handled);
        assert_eq!(result.commit, None, "中文下一笔不能替用户确认上一笔");
        assert_eq!(session.input.editing_text().replace('\'', ""), expected);
    }
    assert!(
        words(&session).contains(&"你好你好".to_owned()),
        "{:?}",
        words(&session)
    );
    assert_eq!(
        select_word(&mut session, "你好你好").commit.as_deref(),
        Some("你好你好")
    );
    assert!(session.snapshot().preedit.is_empty());
}

#[test]
fn pending_chinese_keeps_an_ambiguous_next_stroke_in_the_phrase() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(
        "CREATE TABLE tbl_1_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_1_w VALUES('wo','w','我',1000);\
CREATE TABLE tbl_1_m(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_1_m VALUES('men','m','们',1000);\
CREATE TABLE tbl_2_w(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_2_w VALUES('wo''men','wm','我们',2000);",
    )
    .with_english("INSERT INTO english_words VALUES('men','men',1000),('hello','hello',1000);");
    let mut session = fixture.session();
    assert!(
        session
            .bilingual_glide(&keyboard(), &stroke("wo", 0.0, &[]))
            .handled
    );
    let result = session.bilingual_glide(&keyboard(), &stroke("men", 0.0, &[]));
    assert_eq!(result.commit, None);
    assert!(
        words(&session).contains(&"我们".to_owned()),
        "{:?}",
        words(&session)
    );
    let english = session.bilingual_glide(&keyboard(), &stroke("hello", 0.0, &[]));
    assert_eq!(english.commit, None);
    assert!(words(&session).contains(&"我们 hello".to_owned()));
}

#[test]
fn bilingual_glide_never_commits_at_a_language_boundary_or_implicit_finish() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(QUANPIN_FIXTURE).with_english(
        "INSERT INTO english_words VALUES('hello','hello',1000),('world','world',900);",
    );
    for (strokes, expected) in [
        (vec!["nihao", "hello"], "你好 hello "),
        (vec!["hello", "nihao"], "hello 你好"),
        (vec!["hello", "world", "nihao"], "hello world 你好"),
    ] {
        let mut session = fixture.session();
        for spelling in strokes {
            let result = session.bilingual_glide(&keyboard(), &stroke(spelling, 0.0, &[]));
            assert!(result.handled);
            assert_eq!(result.commit, None, "滑行不能隐式上屏：{spelling}");
        }
        let before = session.snapshot().preedit;
        for command in [
            Command::CommitRaw,
            Command::CommitRawWithoutLearning,
            Command::CommitReading,
        ] {
            let result = session.command(command);
            assert!(result.handled);
            assert_eq!(result.commit, None);
            assert_eq!(session.snapshot().preedit, before);
        }
        assert_eq!(session.finish(0).commit, None);
        assert_eq!(session.punctuation(b',').commit, None);
        assert_eq!(session.snapshot().preedit, before);
        let candidate = expected.trim_end();
        assert!(
            words(&session).contains(&candidate.to_owned()),
            "{:?}",
            words(&session)
        );
        assert_eq!(
            select_word(&mut session, candidate).commit.as_deref(),
            Some(expected)
        );
        assert!(session.snapshot().preedit.is_empty());
    }
}

#[test]
fn editing_bilingual_glide_still_requires_selection_and_cancel_restores_normal_typing() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(QUANPIN_FIXTURE);
    let mut session = fixture.session();
    session.bilingual_glide(&keyboard(), &stroke("nihao", 0.0, &[]));
    session.command(Command::Backspace);
    assert_eq!(session.command(Command::CommitRaw).commit, None);
    assert_eq!(session.character(b'o', false).commit, None);
    assert_eq!(session.finish(0).commit, None);
    session.command(Command::Cancel);
    type_text(&mut session, "nihao");
    assert_eq!(
        session.command(Command::CommitCandidate).commit.as_deref(),
        Some("你好")
    );
    session.bilingual_glide(&keyboard(), &stroke("nihao", 0.0, &[]));
    while !session.snapshot().preedit.is_empty() {
        session.command(Command::Backspace);
    }
    assert!(!session.requires_candidate_selection());
    type_text(&mut session, "nihao");
    assert_eq!(
        session.command(Command::CommitCandidate).commit.as_deref(),
        Some("你好")
    );
}

#[test]
fn space_explicitly_selects_the_current_whole_bilingual_glide_candidate() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(QUANPIN_FIXTURE).with_english(
        "INSERT INTO english_words VALUES('hello','hello',1000),('world','world',900);",
    );
    for spellings in [
        ["ni", "hao"],
        ["hello", "world"],
        ["nihao", "hello"],
        ["hello", "nihao"],
    ] {
        let mut session = fixture.session();
        for spelling in spellings {
            assert_eq!(
                session
                    .bilingual_glide(&keyboard(), &stroke(spelling, 0.0, &[]))
                    .commit,
                None
            );
        }
        let mut expected = words(&session)[0].clone();
        if expected
            .as_bytes()
            .last()
            .is_some_and(u8::is_ascii_alphabetic)
        {
            expected.push(' ');
        }
        assert_eq!(
            session.command(Command::CommitCandidate).commit.as_deref(),
            Some(expected.as_str())
        );
        assert!(session.snapshot().preedit.is_empty());
        assert_eq!(session.command(Command::CommitCandidate).commit, None);
    }
}

#[test]
fn editing_a_chinese_glide_does_not_make_the_next_stroke_commit_the_prefix() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(QUANPIN_FIXTURE);
    let mut session = fixture.session();
    assert!(
        session
            .bilingual_glide(&keyboard(), &stroke("nihao", 0.0, &[]))
            .handled
    );
    session.command(Command::Backspace);
    assert!(session.input.glide_candidates.is_none());
    let before = session.input.editing_text().to_owned();
    let result = session.bilingual_glide(&keyboard(), &stroke("hao", 0.0, &[]));
    assert!(result.handled);
    assert_eq!(result.commit, None);
    assert!(session.input.editing_text().starts_with(&before));
    assert!(session.input.editing_text().len() > before.len());
}

#[test]
fn primary_single_syllable_exposes_homophones_without_noisy_annotations_or_rare_english_hijack() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(
        "CREATE TABLE tbl_1_x(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_1_x VALUES\
('xing','x','行',100000),('xing','x','性',90000),('xing','x','姓',80000),\
('xing','x','星',70000),('xing','x','兴',60000),('xing','x','馨',50000),\
('xing','x','幸',40000),('xing','x','型',30000),('xing','x','形',20000),\
('xing','x','醒',10000);",
    )
    .with_english(
        "INSERT INTO english_words VALUES('the','the',23135851162),('zing','zing',329159);",
    );
    let mut session = fixture.session();
    assert!(
        session
            .bilingual_glide(&keyboard(), &stroke("xing", 0.0, &[]))
            .handled
    );
    let snapshot = session.snapshot();
    let list = words(&session);
    assert_eq!(list.first().map(String::as_str), Some("行"));
    for expected in ["行", "性", "姓", "星", "兴", "馨", "幸", "型", "形", "醒"] {
        assert!(list.contains(&expected.to_owned()), "缺少同音字 {expected}: {list:?}");
    }
    assert!(
        snapshot.candidate_sources[0].is_dictionary(),
        "首选中文词典候选应保留词典来源：{:?}",
        snapshot.candidate_sources[0]
    );
    assert!(
        snapshot.candidate_annotations.iter().all(String::is_empty),
        "中英混合滑行不应对普通中文候选输出冗余拼音副标题：{:?}",
        snapshot.candidate_annotations
    );
    assert!(
        snapshot.candidate_answers_key.iter().all(|&answers| answers),
        "滑行池内候选应全部标记为回答当前输入"
    );
    if let Some(zing_index) = list.iter().position(|word| word == "zing") {
        assert_eq!(
            snapshot.candidate_sources[zing_index],
            CandidateSource::EnglishDictionary
        );
    }
}

#[test]
fn bilingual_glide_shi_retains_all_homophones_beyond_sixteen_including_shi_food_and_filters_archaic_secondary_noise() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(
        "CREATE TABLE tbl_1_s(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_1_s VALUES\
('shi','s','是',53000000),('shi','s','时',12000000),('shi','s','十',9000000),('shi','s','石',8000000),\
('shi','s','事',7500000),('shi','s','拾',7000000),('shi','s','使',6500000),('shi','s','市',6000000),\
('shi','s','式',5500000),('shi','s','视',5000000),('shi','s','饰',4500000),('shi','s','世',4000000),\
('shi','s','史',3500000),('shi','s','实',3000000),('shi','s','师',2500000),('shi','s','诗',2000000),\
('shi','s','室',1800000),('shi','s','食',1600000),('shi','s','识',1400000),('shi','s','试',1200000),\
('shi','s','失',1000000),('shi','s','释',800000),('shi','s','适',600000),('shi','s','势',500000),\
('shi','s','示',400000),('shi','s','氏',300000),('shi','s','施',200000),('shi','s','湿',150000),\
('shui','s','谁',8000000),('shui','s','水',7000000),('shui','s','睡',1500000),('shui','s','税',800000),\
('shui','s','帨',50),('shui','s','氺',30),('shui','s','稅',20);",
    );
    let mut session = fixture.session();
    assert!(
        session
            .bilingual_glide(&keyboard(), &stroke("shi", 0.0, &[]))
            .handled
    );
    let list = words(&session);
    for expected in ["是", "诗", "室", "食", "识", "试", "失", "释", "适", "势", "示", "氏", "施", "湿"] {
        assert!(
            list.contains(&expected.to_owned()),
            "滑行 shi 必须保留第 16 位之后的常用同音字「{expected}」: {list:?}"
        );
    }
    for archaic in ["帨", "氺", "稅"] {
        assert!(
            !list.contains(&archaic.to_owned()),
            "次选读音 shui 的极低频生僻字「{archaic}」不应混入 shi 候选: {list:?}"
        );
    }
}

#[test]
fn bilingual_glide_preserves_multisyllable_dictionary_ranking_and_dual_channel_external_readings() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(
        "CREATE TABLE tbl_1_q(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_1_q VALUES('qie','q','切',800000);\
CREATE TABLE tbl_2_q(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_2_q VALUES('qi''ye','qy','企业',500000);\
CREATE TABLE tbl_2_n(key TEXT,jp TEXT,value TEXT,weight INTEGER);\
INSERT INTO tbl_2_n VALUES('ni''hao','nh','你好',90000);",
    )
    .with_english("INSERT INTO english_words VALUES('the','the',23135851162),('hello','hello',1000000);");
    let kb = keyboard();
    let mut pure_session = fixture.session();
    assert!(pure_session.glide(&kb, &stroke("qiye", 0.0, &[])).handled);
    assert_eq!(words(&pure_session).first().map(String::as_str), Some("企业"));
    let mut session = fixture.session();

    // 1. `y` 落在 `i -> e` 连线附近，`qie` 原始几何代价低于 `qiye` 且单字词频更高；
    //    保留 `rank_by_dictionary_with_prefix` 的多音节排序后，`bilingual_glide` 同样应把「企业」排在「切」前面。
    assert!(session.bilingual_glide(&kb, &stroke("qiye", 0.0, &[])).handled);
    let list = words(&session);
    assert_eq!(
        list.first().map(String::as_str),
        Some("企业"),
        "bilingual glide must preserve multi-syllable Chinese ranking over shorter collinear single char: {list:?}"
    );
    session.command(Command::Cancel);

    // 2. 切弯略微偏离中间键 `a`（超过严格位置半径 1.65 键宽，仍在 SHARK2 圆角通道 2.45 键宽内）时，
    //    外部 GlideBeam 读音 `nihao` 走 `score_pinyin_dual` 应能被成功接住而非被严格 DP 丢弃。
    let (ax, ay) = kb.centers[0];
    let (ix, iy) = kb.centers[usize::from(b'i' - b'a')];
    let (hx, hy) = kb.centers[usize::from(b'h' - b'a')];
    let (ox, oy) = kb.centers[usize::from(b'o' - b'a')];
    let (nx, ny) = kb.centers[usize::from(b'n' - b'a')];
    let mid_x = ax + kb.key_width * 1.9;
    let mid_y = ay;
    let cut_corner = vec![
        crate::GlidePoint { x: nx, y: ny, time_ms: Some(0) },
        crate::GlidePoint { x: ix, y: iy, time_ms: Some(40) },
        crate::GlidePoint { x: hx, y: hy, time_ms: Some(80) },
        crate::GlidePoint { x: mid_x, y: mid_y, time_ms: Some(120) },
        crate::GlidePoint { x: ox, y: oy, time_ms: Some(160) },
    ];
    let matcher = crate::pinyin::glide::GlideMatcher::new(&kb, &cut_corner).unwrap();
    assert!(
        matcher.score("nihao").is_none(),
        "test fixture requires strict position DP to reject the cut-corner stroke"
    );
    assert!(
        session
            .bilingual_glide_with_readings(&kb, &cut_corner, &["nihao".to_owned()])
            .handled
    );
    assert!(
        words(&session).contains(&"你好".to_owned()),
        "bilingual_glide must score external readings via dual channel to rescue cut-corner strokes: {:?}",
        words(&session)
    );
}

#[test]
fn english_glide_bucket_cache_serves_repeated_bilingual_strokes_without_rescanning_sqlite() {
    use crate::pinyin::glide::tests::{keyboard, stroke};
    let fixture = Fixture::new(QUANPIN_FIXTURE).with_english(
        "INSERT INTO english_words VALUES\
('the','the',23135851162),('hello','hello',10000),('hello','Hello',8000),('hello','HELLO',6000);",
    );
    let kb = keyboard();
    let mut session = fixture.session();

    // 首次滑行预热 `h` 桶与 `the` 基准权重。
    assert!(session.bilingual_glide(&kb, &stroke("hello", 0.0, &[])).handled);
    let first = words(&session);
    assert!(first.contains(&"hello".to_owned()), "{first:?}");
    assert!(first.contains(&"Hello".to_owned()), "{first:?}");
    assert!(first.contains(&"HELLO".to_owned()), "{first:?}");
    session.command(Command::Cancel);

    // 独占锁住英文数据库模拟无 SQLite 读取：第二次滑行命中内存紧凑桶缓存仍完整返回所有大小写词形。
    let english_path = fixture.directory.path().join("msime-english.db");
    let lock = rusqlite::Connection::open(&english_path).unwrap();
    lock.execute_batch("BEGIN EXCLUSIVE;").unwrap();
    let second_ok = session.bilingual_glide(&kb, &stroke("hello", 0.0, &[])).handled;
    let second = words(&session);
    lock.execute_batch("ROLLBACK;").unwrap();
    assert!(second_ok);
    assert!(second.contains(&"hello".to_owned()), "{second:?}");
    assert!(second.contains(&"Hello".to_owned()), "{second:?}");
    assert!(second.contains(&"HELLO".to_owned()), "{second:?}");
}

