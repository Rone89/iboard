import XCTest

/// 26 键字母键的长按变体（原生键盘的长按弹出）：变体表、弹出语境的门控，以及变体条的几何与选中判定。
@MainActor
final class KeyboardHoldVariantsTests: XCTestCase {
  // MARK: - 变体表

  func testPinyinVowelsCarryFourTones() {
    let variants = KeyboardLetterVariants.variants(for: "a", alphabet: .pinyin)
    XCTAssertEqual(variants, ["ā", "á", "ǎ", "à"])
    XCTAssertEqual(KeyboardLetterVariants.variants(for: "A", alphabet: .pinyin), variants)
    XCTAssertEqual(KeyboardLetterVariants.variants(for: "e", alphabet: .pinyin)?.count, 4)
    XCTAssertEqual(KeyboardLetterVariants.variants(for: "i", alphabet: .pinyin)?.count, 4)
    XCTAssertEqual(KeyboardLetterVariants.variants(for: "o", alphabet: .pinyin)?.count, 4)
  }

  func testPinyinUAndVCarryUmlautVariants() {
    // v 是 ü 的编码键，ü 放在最前；u 附上 ü 系四声。
    XCTAssertEqual(KeyboardLetterVariants.variants(for: "v", alphabet: .pinyin)?.first, "ü")
    XCTAssertEqual(KeyboardLetterVariants.variants(for: "u", alphabet: .pinyin), ["ū", "ú", "ǔ", "ù", "ǖ", "ǘ", "ǚ", "ǜ"])
    XCTAssertEqual(KeyboardLetterVariants.variants(for: "n", alphabet: .pinyin), ["ň", "ǹ"])
  }

  func testPinyinConsonantsHaveNoVariants() {
    for letter in ["b", "p", "m", "f", "d", "t", "l", "g", "k", "h", "j", "q", "x", "zh"] {
      XCTAssertNil(KeyboardLetterVariants.variants(for: letter, alphabet: .pinyin), letter)
    }
  }

  func testEnglishAccents() {
    let a = KeyboardLetterVariants.variants(for: "a", alphabet: .english)
    XCTAssertEqual(a?.first, "á")
    XCTAssertTrue(a?.contains("æ") ?? false)
    XCTAssertEqual(KeyboardLetterVariants.variants(for: "ñ", alphabet: .english), nil)
    XCTAssertNil(KeyboardLetterVariants.variants(for: "b", alphabet: .english))
  }

  func testNonLettersHaveNoVariants() {
    XCTAssertNil(KeyboardLetterVariants.variants(for: "3", alphabet: .pinyin))
    XCTAssertNil(KeyboardLetterVariants.variants(for: "ab", alphabet: .english))
    XCTAssertNil(KeyboardLetterVariants.variants(for: "", alphabet: .pinyin))
    XCTAssertNil(KeyboardLetterVariants.variants(for: "，", alphabet: .english))
  }

  // MARK: - 弹出语境

  func testPinyinAlphabetOnlyOnQuanpinPhoneLetters() {
    XCTAssertEqual(KeyboardLetterVariants.alphabet(chinese: true, scheme: .quanpin, letterGridShown: false,
                                                   localMode: false, phoneIdiom: true), .pinyin)
    // 双拼、九键、注音、韩文、粤拼的字母键各有编码语义，不弹变体。
    XCTAssertNil(KeyboardLetterVariants.alphabet(chinese: true, scheme: .shuangpin, letterGridShown: false,
                                                 localMode: false, phoneIdiom: true))
    XCTAssertNil(KeyboardLetterVariants.alphabet(chinese: true, scheme: .nineKey, letterGridShown: false,
                                                 localMode: false, phoneIdiom: true))
    XCTAssertNil(KeyboardLetterVariants.alphabet(chinese: true, scheme: .korean, letterGridShown: false,
                                                 localMode: false, phoneIdiom: true))
    XCTAssertNil(KeyboardLetterVariants.alphabet(chinese: true, scheme: .cantonese, letterGridShown: false,
                                                 localMode: false, phoneIdiom: true))
    // 画 14/18 键字母网格、本地模式、iPad 上的都不弹。
    XCTAssertNil(KeyboardLetterVariants.alphabet(chinese: true, scheme: .quanpin, letterGridShown: true,
                                                 localMode: false, phoneIdiom: true))
    XCTAssertNil(KeyboardLetterVariants.alphabet(chinese: true, scheme: .quanpin, letterGridShown: false,
                                                 localMode: true, phoneIdiom: true))
    XCTAssertNil(KeyboardLetterVariants.alphabet(chinese: true, scheme: .quanpin, letterGridShown: false,
                                                 localMode: false, phoneIdiom: false))
  }

  func testEnglishAlphabetFollowsEnglishMode() {
    XCTAssertEqual(KeyboardLetterVariants.alphabet(chinese: false, scheme: .quanpin, letterGridShown: false,
                                                   localMode: false, phoneIdiom: true), .english)
    // 本地模式按字面输入，不弹。
    XCTAssertNil(KeyboardLetterVariants.alphabet(chinese: false, scheme: .quanpin, letterGridShown: false,
                                                 localMode: true, phoneIdiom: true))
    XCTAssertNil(KeyboardLetterVariants.alphabet(chinese: false, scheme: .quanpin, letterGridShown: false,
                                                 localMode: false, phoneIdiom: false))
  }

  // MARK: - 变体条

  /// 手机 26 键一行的键位：36pt 一格、键宽 30，首行从 y=340 起（上方还有候选栏）。
  private static let keyFrame = CGRect(x: 0, y: 340, width: 30, height: 40)
  private static let hostBounds = CGRect(x: 0, y: 0, width: 390, height: 380)

  func testBarGeometryCentersOnKeyAndSitsAboveTheBubble() {
    // 中间的键左右都有余地：条与按键居中对齐。最左边的键放不下整条，压边行为在下面单独钉。
    let key = CGRect(x: 180, y: 340, width: 30, height: 40)
    let geometry = KeyboardHoldVariantBar.geometry(variantCount: 4, keyFrame: key,
                                                   bubbleTop: key.minY, in: Self.hostBounds)
    XCTAssertEqual(geometry.midX, key.midX, accuracy: 0.5)
    XCTAssertEqual(geometry.width, 30 * KeyPressPreviewView.widthFactor * 4, accuracy: 0.5)
    // 下边缘隔 4pt 顶着气泡上边缘，条高与气泡相同。
    XCTAssertEqual(geometry.maxY, key.minY - 4, accuracy: 0.5)
    XCTAssertEqual(geometry.height, KeyPressPreviewView.height, accuracy: 0.5)
  }

  func testBarGeometryClampsToHostEdges() {
    // 最左边的 q 键：条向左右压进边界 4pt。
    let left = KeyboardHoldVariantBar.geometry(variantCount: 8, keyFrame: CGRect(x: 0, y: 340, width: 30, height: 40),
                                               bubbleTop: 340, in: Self.hostBounds)
    XCTAssertGreaterThanOrEqual(left.minX, 0)
    XCTAssertLessThanOrEqual(left.maxX, Self.hostBounds.maxX)
    // 顶行上方放不下整条高度：气泡顶离边界只有 40pt 时条被压矮到剩下的空间，仍在边界内。
    let tight = KeyboardHoldVariantBar.geometry(variantCount: 4, keyFrame: CGRect(x: 0, y: 40, width: 30, height: 40),
                                                bubbleTop: 40, in: Self.hostBounds)
    XCTAssertGreaterThan(tight.height, 12)
    XCTAssertLessThan(tight.height, KeyPressPreviewView.height)
    XCTAssertGreaterThanOrEqual(tight.minY, Self.hostBounds.minY)
    // 完全没有空间时不出条。
    let none = KeyboardHoldVariantBar.geometry(variantCount: 4, keyFrame: CGRect(x: 0, y: 8, width: 30, height: 40),
                                               bubbleTop: 8, in: Self.hostBounds)
    XCTAssertTrue(none.isEmpty)
  }

  func testBarHighlightsTheVariantUnderTheFinger() {
    let bar = KeyboardHoldVariantBar()
    let variants = KeyboardLetterVariants.variants(for: "a", alphabet: .pinyin)!
    bar.show(variants, keyFrame: Self.keyFrame, in: Self.hostBounds,
             fill: .white, text: .black)
    XCTAssertEqual(bar.selected, nil)
    // 第二格中心选中第 2 项，条外与格间容差带之外不选中。
    let cellWidth = bar.bounds.width / CGFloat(variants.count)
    XCTAssertEqual(bar.selectedIndex(inLocalPoint: CGPoint(x: cellWidth * 1.5, y: bar.bounds.midY)), 1)
    XCTAssertNil(bar.selectedIndex(inLocalPoint: CGPoint(x: -8, y: bar.bounds.midY)))
    XCTAssertNil(bar.selectedIndex(inLocalPoint: CGPoint(x: cellWidth * 1.5, y: bar.bounds.midY - 40)))
    bar.set(selected: 1)
    XCTAssertEqual(bar.selected, 1)
    bar.set(selected: nil)
    XCTAssertEqual(bar.selected, nil)
  }
}
