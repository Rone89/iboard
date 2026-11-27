//! 高频中英混写词（如 B站、C位、A股、P图、U盘、UP主、T恤、X光、AA制、B超）的轻量内嵌索引。
//!
//! 拼音词库分表 `tbl_<len>_<initial>` 只收标准汉语拼音音节与纯汉字，且 `i`/`u`/`v` 没有分表，
//! 因此像 `bzhan`（B站）、`upan`（U盘）、`upzhu`（UP主）这类混写词直接由本表在 26 键与九宫格
//! 候选装配阶段按精确编码零开销注入；纯英文词仍由 `msime-english.db` 负责，互不重复。

use crate::types::{CandidateSource, SchemeType, WordItem};

struct Entry {
    code: &'static str,
    t9: &'static str,
    word: &'static str,
}

const ENTRIES: &[Entry] = &[
    Entry { code: "bzhan", t9: "29426", word: "B站" },
    Entry { code: "upzhu", t9: "87948", word: "UP主" },
    Entry { code: "cwei", t9: "2934", word: "C位" },
    Entry { code: "agu", t9: "248", word: "A股" },
    Entry { code: "bgu", t9: "248", word: "B股" },
    Entry { code: "hgu", t9: "448", word: "H股" },
    Entry { code: "ptu", t9: "788", word: "P图" },
    Entry { code: "kge", t9: "543", word: "K歌" },
    Entry { code: "txu", t9: "898", word: "T恤" },
    Entry { code: "xguang", t9: "948264", word: "X光" },
    Entry { code: "upan", t9: "8726", word: "U盘" },
    Entry { code: "bchao", t9: "22426", word: "B超" },
    Entry { code: "aazhi", t9: "22944", word: "AA制" },
    Entry { code: "abjiao", t9: "225426", word: "AB胶" },
    Entry { code: "cpgan", t9: "27426", word: "CP感" },
    Entry { code: "cpfen", t9: "27336", word: "CP粉" },
    Entry { code: "vling", t9: "85464", word: "V领" },
    Entry { code: "ttai", t9: "8824", word: "T台" },
    Entry { code: "qban", t9: "7226", word: "Q版" },
    Entry { code: "qqun", t9: "7786", word: "Q群" },
    Entry { code: "qhao", t9: "7426", word: "Q号" },
    Entry { code: "nci", t9: "624", word: "N次" },
    Entry { code: "cpan", t9: "2726", word: "C盘" },
    Entry { code: "dpan", t9: "3726", word: "D盘" },
    Entry { code: "epan", t9: "3726", word: "E盘" },
    Entry { code: "fpan", t9: "3726", word: "F盘" },
    Entry { code: "sma", t9: "762", word: "S码" },
    Entry { code: "mma", t9: "662", word: "M码" },
    Entry { code: "lma", t9: "562", word: "L码" },
    Entry { code: "xlma", t9: "9562", word: "XL码" },
    Entry { code: "xxlma", t9: "99562", word: "XXL码" },
    Entry { code: "axing", t9: "29464", word: "A型" },
    Entry { code: "bxing", t9: "29464", word: "B型" },
    Entry { code: "oxing", t9: "69464", word: "O型" },
    Entry { code: "abxing", t9: "229464", word: "AB型" },
    Entry { code: "axingxue", t9: "29464983", word: "A型血" },
    Entry { code: "bxingxue", t9: "29464983", word: "B型血" },
    Entry { code: "oxingxue", t9: "69464983", word: "O型血" },
    Entry { code: "abxingxue", t9: "229464983", word: "AB型血" },
    Entry { code: "uxing", t9: "89464", word: "U型" },
    Entry { code: "vxing", t9: "89464", word: "V型" },
    Entry { code: "yxing", t9: "99464", word: "Y型" },
    Entry { code: "zxing", t9: "99464", word: "Z型" },
    Entry { code: "azhu", t9: "2948", word: "A柱" },
    Entry { code: "bzhu", t9: "2948", word: "B柱" },
    Entry { code: "czhu", t9: "2948", word: "C柱" },
    Entry { code: "ipdizhi", t9: "4734944", word: "IP地址" },
    Entry { code: "simka", t9: "74652", word: "SIM卡" },
    Entry { code: "sdka", t9: "7352", word: "SD卡" },
    Entry { code: "icka", t9: "4252", word: "IC卡" },
    Entry { code: "atmji", t9: "28654", word: "ATM机" },
    Entry { code: "itnan", t9: "48626", word: "IT男" },
    Entry { code: "ccshuang", t9: "22748264", word: "CC霜" },
    Entry { code: "bbshuang", t9: "22748264", word: "BB霜" },
    Entry { code: "bbji", t9: "2254", word: "BB机" },
    Entry { code: "tzi", t9: "894", word: "T字" },
    Entry { code: "xji", t9: "954", word: "X级" },
    Entry { code: "kpian", t9: "57426", word: "K片" },
    Entry { code: "pihua", t9: "74482", word: "P话" },
    Entry { code: "aka", t9: "252", word: "A卡" },
    Entry { code: "nka", t9: "652", word: "N卡" },
    Entry { code: "dka", t9: "352", word: "D卡" },
    Entry { code: "eka", t9: "352", word: "E卡" },
    Entry { code: "opqu", t9: "6778", word: "OP曲" },
    Entry { code: "edqu", t9: "3378", word: "ED曲" },
    Entry { code: "bgmyinyue", t9: "246946983", word: "BGM音乐" },
    Entry { code: "puahuashu", t9: "782482748", word: "PUA话术" },
    Entry { code: "ctjiancha", t9: "285426242", word: "CT检查" },
    Entry { code: "mrijiancha", t9: "6745426242", word: "MRI检查" },
];

fn make_item(pinyin: &str, word: &str) -> WordItem {
    WordItem {
        pinyin: pinyin.into(),
        canonical_pinyin: pinyin.into(),
        word: word.into(),
        weight: 0,
        source: CandidateSource::QuickPhrase,
        scheme: SchemeType::Quanpin,
        ..WordItem::default()
    }
}

/// 26 键全拼按精确原始输入插入中英混写词：
/// 若当前候选里没有完整覆盖全部字母的精确中文词典词（如 `bzhan` / `upan` / `txu` / `ptu`），
/// 直接放到首位；若已有精确中文词（如 `agu`），放到次位避免抢占普通词。
pub(crate) fn insert_for_quanpin(raw_input: &str, candidates: &mut Vec<WordItem>) {
    if raw_input.len() < 3 || !raw_input.bytes().all(|b| b.is_ascii_lowercase()) {
        return;
    }
    let mut matches = Vec::new();
    for entry in ENTRIES {
        if entry.code == raw_input
            && !candidates.iter().any(|existing| existing.word == entry.word)
        {
            matches.push(make_item(raw_input, entry.word));
        }
    }
    if matches.is_empty() {
        return;
    }
    let has_exact_chinese_word = candidates.first().is_some_and(|first| {
        first.source.is_dictionary()
            && !first.fuzzy
            && first.corrected_from.is_empty()
            && first.pinyin.bytes().filter(|&b| b != b'\'').count() == raw_input.len()
    });
    let slot = if has_exact_chinese_word {
        1.min(candidates.len())
    } else {
        0
    };
    candidates.splice(slot..slot, matches);
}

/// 九宫格按精确数字串插入中英混写词：规则与 26 键对称，不干扰已有完整覆盖的常用中文词。
pub(crate) fn insert_for_nine_key(digits: &str, candidates: &mut Vec<WordItem>) {
    if digits.len() < 3 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return;
    }
    let mut matches = Vec::new();
    for entry in ENTRIES {
        if entry.t9 == digits && !candidates.iter().any(|existing| existing.word == entry.word) {
            matches.push(make_item(digits, entry.word));
        }
    }
    if matches.is_empty() {
        return;
    }
    let has_exact_chinese_word = candidates.first().is_some_and(|first| {
        first.source.is_dictionary() && !first.fuzzy && first.pinyin.len() == digits.len()
    });
    let slot = if has_exact_chinese_word {
        1.min(candidates.len())
    } else {
        0
    };
    candidates.splice(slot..slot, matches);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t9_of(code: &str) -> String {
        code.bytes()
            .map(|b| match b {
                b'a'..=b'c' => '2',
                b'd'..=b'f' => '3',
                b'g'..=b'i' => '4',
                b'j'..=b'l' => '5',
                b'm'..=b'o' => '6',
                b'p'..=b's' => '7',
                b't'..=b'v' => '8',
                b'w'..=b'z' => '9',
                _ => panic!("non-lowercase ascii in mixed entry: {code}"),
            })
            .collect()
    }

    #[test]
    fn every_entry_t9_matches_its_letters() {
        for entry in ENTRIES {
            assert_eq!(entry.t9, t9_of(entry.code), "{}", entry.word);
        }
    }

    #[test]
    fn quanpin_and_nine_key_insert_mixed_cn_en_at_expected_slots() {
        let mut empty = Vec::new();
        insert_for_quanpin("bzhan", &mut empty);
        assert_eq!(empty[0].word, "B站");

        let mut with_chinese = vec![WordItem {
            pinyin: "a'gu".into(),
            canonical_pinyin: "a'gu".into(),
            word: "阿姑".into(),
            source: CandidateSource::Database,
            ..WordItem::default()
        }];
        insert_for_quanpin("agu", &mut with_chinese);
        assert_eq!(with_chinese[0].word, "阿姑");
        assert_eq!(with_chinese[1].word, "A股");

        let mut t9 = Vec::new();
        insert_for_nine_key("8726", &mut t9);
        assert_eq!(t9[0].word, "U盘");
    }
}
