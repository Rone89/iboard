//! 连续滑行语境重排、续滑次优候选合并与拇指落点偏移自适应校准的会话级回归。

use super::*;
use crate::pinyin::glide::tests::{keyboard, stroke};

#[test]
fn continuous_glide_bridges_prefix_phrase_and_merges_secondary_combined_candidates() {
    let fixture = Fixture::new(
        "CREATE TABLE tbl_1_w(key TEXT, jp TEXT, value TEXT, weight INTEGER);\
         INSERT INTO tbl_1_w VALUES('wo','w','我',9000);\
         CREATE TABLE tbl_1_m(key TEXT, jp TEXT, value TEXT, weight INTEGER);\
         INSERT INTO tbl_1_m VALUES('men','m','们',3000);\
         CREATE TABLE tbl_1_r(key TEXT, jp TEXT, value TEXT, weight INTEGER);\
         INSERT INTO tbl_1_r VALUES('ren','r','人',9000);\
         CREATE TABLE tbl_2_w(key TEXT, jp TEXT, value TEXT, weight INTEGER);\
         INSERT INTO tbl_2_w VALUES('wo''men','wm','我们',90000),('wo''ren','wr','我人',2000);",
    );
    let mut session = fixture.session();
    let kb = keyboard();

    // 第一笔先滑 `wo` 进入活跃组字
    assert!(session.glide(&kb, &stroke("wo", 0.0, &[])).handled);
    assert_eq!(session.snapshot().editing_text, "wo");

    // 第二笔外部候选把高频单字 `ren` 排在第 0 位、`men` 排在第 1 位；
    // 借助当前前缀 `wo` 查跨笔整词 `wo'men`（我们），应反超孤立 `ren`，并把次优组合整词 `我人` 并进前排候选。
    let men_points = stroke("men", 0.0, &[]);
    assert!(
        session
            .glide_with_readings(&kb, &men_points, &["ren".into(), "men".into()])
            .handled
    );
    assert_eq!(session.snapshot().editing_text, "wo'men");
    let list = words(&session);
    assert_eq!(list.first().map(String::as_str), Some("我们"), "{list:?}");
    let alt_pos = list
        .iter()
        .position(|w| w == "我人")
        .unwrap_or_else(|| panic!("expected merged continuous secondary candidate 我人 in {list:?}"));
    assert!(
        alt_pos <= 2,
        "secondary continuous candidate should be surfaced on first page, got pos {alt_pos} in {list:?}"
    );

    // 点选合并进来的续滑次优整词应直接完整上屏并清空组字
    let committed = session.input.select_candidate(alt_pos);
    assert_eq!(committed.commit.as_deref(), Some("我人"));
    assert!(!session.input.has_composition());
}

#[test]
fn confirmed_glide_updates_calibrator_persists_and_respects_learning_and_edits() {
    let fixture = Fixture::new(
        "CREATE TABLE tbl_1_n(key TEXT, jp TEXT, value TEXT, weight INTEGER);\
         INSERT INTO tbl_1_n VALUES('ni','n','你',5000);\
         CREATE TABLE tbl_1_h(key TEXT, jp TEXT, value TEXT, weight INTEGER);\
         INSERT INTO tbl_1_h VALUES('hao','h','好',5000);\
         CREATE TABLE tbl_2_n(key TEXT, jp TEXT, value TEXT, weight INTEGER);\
         INSERT INTO tbl_2_n VALUES('ni''hao','nh','你好',90000);\
         CREATE TABLE tbl_1_r(key TEXT, jp TEXT, value TEXT, weight INTEGER);\
         INSERT INTO tbl_1_r VALUES('ri','r','日',5000),('rui','r','瑞',1000);",
    );
    let kb = keyboard();
    let shifted_nihao = || {
        let mut pts = stroke("nihao", 0.0, &[]);
        for p in &mut pts {
            p.x += kb.key_width * 0.25;
        }
        pts
    };

    // 1. 学习开启时，普通单笔滑行上屏与次优候选点选（走 `glide_candidates` 分支）都会记录校准样本，并在会话释放时自动落盘。
    {
        let mut session = fixture.session_with(|options| {
            options.learning = true;
        });
        assert_eq!(session.input.glide_calibrator.total_observations(), 0);
        assert!(session.glide(&kb, &shifted_nihao()).handled);
        let commit1 = session.input.select_candidate(0);
        assert_eq!(commit1.commit.as_deref(), Some("你好"));
        assert_eq!(session.input.glide_calibrator.total_observations(), 1);

        // 共线次优候选自纠（命中 `glide_candidates` 早退分支）同样应反向对齐选中词读音并累计校准样本
        assert!(session.glide(&kb, &stroke("rui", 0.0, &[])).handled);
        let rui_idx = words(&session)
            .iter()
            .position(|w| w == "瑞")
            .expect("secondary candidate 瑞");
        let commit2 = session.input.select_candidate(rui_idx);
        assert_eq!(commit2.commit.as_deref(), Some("瑞"));
        assert_eq!(session.input.glide_calibrator.total_observations(), 2);
    }

    // 2. 重建会话自动从 `glide_calibration.json` 恢复已学习的偏移状态；
    //    滑行后若用户退格改字再上屏，待校准轨迹快照自动作废，不污染统计。
    {
        let mut session = fixture.session_with(|options| {
            options.learning = true;
        });
        assert_eq!(session.input.glide_calibrator.total_observations(), 2);

        assert!(session.glide(&kb, &shifted_nihao()).handled);
        assert!(session.input.handle_command(Command::Backspace).handled);
        let _ = session.input.select_candidate(0);
        assert_eq!(
            session.input.glide_calibrator.total_observations(),
            2,
            "manual backspace after glide must invalidate pending calibration"
        );
    }

    // 3. 关闭学习开关（`options.learning = false`）时，确认上屏绝不写入新校准样本。
    {
        let mut session = fixture.session_with(|options| {
            options.learning = false;
        });
        assert_eq!(session.input.glide_calibrator.total_observations(), 2);
        assert!(session.glide(&kb, &shifted_nihao()).handled);
        assert_eq!(
            session.input.select_candidate(0).commit.as_deref(),
            Some("你好")
        );
        assert_eq!(
            session.input.glide_calibrator.total_observations(),
            2,
            "learning = false must skip glide key calibration"
        );
    }
}

#[test]
fn pure_chinese_glide_with_secondary_candidates_commits_on_punctuation_and_learns_frequency_and_context() {
    let fixture = Fixture::new(
        "CREATE TABLE tbl_1_r(key TEXT, jp TEXT, value TEXT, weight INTEGER);\
         INSERT INTO tbl_1_r VALUES('ri','r','日',5000),('rui','r','瑞',4000);\
         CREATE TABLE tbl_1_s(key TEXT, jp TEXT, value TEXT, weight INTEGER);\
         INSERT INTO tbl_1_s VALUES('shi','s','是',50000),('shi','s','时',20000),('shui','s','谁',45000);",
    );
    let kb = keyboard();
    let mut session = fixture.session_with(|options| {
        options.learning = true;
        options.personal_context = true;
        options.frequency.mode = crate::types::FrequencyAdjustmentMode::Pin;
    });

    // 1. 纯中文滑行合并次优候选（`ri`/`rui`）后不进入强制选词门禁，按标点直接顶字上屏。
    assert!(session.glide(&kb, &stroke("rui", 0.0, &[])).handled);
    assert!(session.input.glide_candidates.is_some());
    assert!(
        !session.requires_candidate_selection(),
        "pure-Chinese glide should not block punctuation top-commit"
    );
    let punct = session.punctuation(b',');
    assert_eq!(punct.commit.as_deref(), Some("日，"), "{punct:?}");
    assert!(!session.input.has_composition());

    // 2. 从合并次优候选的 `glide_candidates` 中选非首词（`shi` 选「时」）应触发个人词频调频与个人二元上下文记录。
    assert!(session.glide(&kb, &stroke("shi", 0.0, &[])).handled);
    assert!(session.input.glide_candidates.is_some());
    let list = words(&session);
    assert_eq!(list.first().map(String::as_str), Some("是"), "{list:?}");
    let shi_time_idx = list
        .iter()
        .position(|w| w == "时")
        .unwrap_or_else(|| panic!("expected 时 in {list:?}"));
    let committed = session.select(shi_time_idx);
    assert_eq!(committed.commit.as_deref(), Some("时"));
    assert!(
        session.input.personal_context.model().word_count("时") > 0,
        "committing Chinese glide candidate must record personal context"
    );

    // 再次滑行 `shi`，已调频的「时」应升至首位。
    assert!(session.glide(&kb, &stroke("shi", 0.0, &[])).handled);
    assert_eq!(
        words(&session).first().map(String::as_str),
        Some("时"),
        "dynamic frequency adjustment must take effect on subsequent glides: {:?}",
        words(&session)
    );
}
