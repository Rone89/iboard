import XCTest

/// The 输入 page's 整句联想 writes the same three levels as Android into `sentence_association`, keeps the object's other fields, and the keyboard that is already open accepts the result.
@MainActor
final class SentenceAssociationSettingsTests: XCTestCase {
  private var state: URL!
  private var savedExplicitGrammarChoice = false

  override func setUp() {
    super.setUp()
    savedExplicitGrammarChoice = SentenceAssociationPreference.hasExplicitGrammarModelChoice
    SentenceAssociationPreference.hasExplicitGrammarModelChoice = false
    state = FileManager.default.temporaryDirectory
      .appendingPathComponent("msime-sentence-association-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() {
    SentenceAssociationPreference.hasExplicitGrammarModelChoice = savedExplicitGrammarChoice
    try? FileManager.default.removeItem(at: state)
    super.tearDown()
  }

  func testLevelsReadTheDocumentAsAndroidDoes() {
    XCTAssertEqual(SentenceAssociationPreference.level(in: nil), .enhanced, "a missing object is the default 增强")
    XCTAssertEqual(SentenceAssociationPreference.level(in: ["sentence_association": [String: Any]()]), .enhanced)
    XCTAssertEqual(SentenceAssociationPreference.level(in: ["sentence_association": ["neural_keyboard": true]]), .enhanced)
    XCTAssertEqual(
      SentenceAssociationPreference.level(in: ["sentence_association": ["neural_keyboard": false]]), .standard,
      "an explicit 标准 stays 标准")
    XCTAssertEqual(
      SentenceAssociationPreference.level(in: ["sentence_association": ["word_lattice": false, "neural_keyboard": true]]),
      .off, "the lattice switch off is 关闭 whatever the model switch says")
  }

  func testEachLevelRoundTripsAndKeepsTheOtherFields() {
    XCTAssertTrue(MetasequoiaInputSessionBridge.updateSharedPreferences(stateRoot: state) {
      $0["sentence_association"] = ["neural_desktop": true, "show_next_on_duplicate": true]
    })
    for level in SentenceAssociationPreference.Level.allCases {
      XCTAssertTrue(SentenceAssociationPreference.save(level, stateRoot: state), "\(level)")
      let document = MetasequoiaInputSessionBridge.loadSharedPreferences(stateRoot: state)
      XCTAssertEqual(SentenceAssociationPreference.level(in: document), level)
      let association = document?["sentence_association"] as? [String: Any]
      XCTAssertEqual(association?["word_lattice"] as? Bool, level != .off)
      XCTAssertEqual(association?["neural_keyboard"] as? Bool, level == .enhanced)
      XCTAssertEqual(association?["neural_desktop"] as? Bool, true, "\(level) kept neural_desktop")
      XCTAssertEqual(association?["show_next_on_duplicate"] as? Bool, true, "\(level) kept show_next_on_duplicate")
    }
  }

  func testTheOpenKeyboardAcceptsTheChangedLevel() async {
    let bridge = MetasequoiaInputSessionBridge(stateRoot: state)
    XCTAssertTrue(SentenceAssociationPreference.save(.enhanced, stateRoot: state))
    let reloaded = expectation(description: "reload")
    var accepted = false
    bridge.reloadSharedPreferences { accepted = $0; reloaded.fulfill() }
    await fulfillment(of: [reloaded], timeout: 15)
    XCTAssertTrue(accepted, "the session refused a document carrying sentence_association")
  }

  func testGrammarModelDefaultsToBundledCompactAndHonorsExplicitDisable() {
    XCTAssertEqual(
      SentenceAssociationPreference.grammarModel(in: nil, explicitChoice: false, compactBundled: true),
      .baguwenCompact
    )
    XCTAssertEqual(
      SentenceAssociationPreference.grammarModel(
        in: ["sentence_association": ["grammar_model": "none"]],
        explicitChoice: false,
        compactBundled: true
      ),
      .baguwenCompact,
      "unselected desktop default upgrades to bundled compact grammar on iOS"
    )
    XCTAssertEqual(
      SentenceAssociationPreference.grammarModel(
        in: ["sentence_association": ["grammar_model": "none"]],
        explicitChoice: true,
        compactBundled: true
      ),
      .none,
      "explicitly disabled grammar model stays off"
    )
    XCTAssertEqual(
      SentenceAssociationPreference.grammarModel(
        in: ["sentence_association": ["grammar_model": "wanxiang"]],
        explicitChoice: true,
        compactBundled: true
      ),
      .wanxiang
    )
  }

  func testGrammarModelRoundTripsAndKeepsOtherFields() {
    XCTAssertTrue(MetasequoiaInputSessionBridge.updateSharedPreferences(stateRoot: state) {
      $0["sentence_association"] = ["word_lattice": true, "neural_keyboard": true, "show_next_on_duplicate": true]
    })
    for model in SentenceAssociationPreference.GrammarModel.allCases {
      XCTAssertTrue(SentenceAssociationPreference.saveGrammarModel(model, stateRoot: state), "\(model)")
      let document = MetasequoiaInputSessionBridge.loadSharedPreferences(stateRoot: state)
      XCTAssertEqual(SentenceAssociationPreference.grammarModel(in: document), model)
      let association = document?["sentence_association"] as? [String: Any]
      XCTAssertEqual(association?["grammar_model"] as? String, model.rawValue)
      XCTAssertEqual(association?["word_lattice"] as? Bool, true)
      XCTAssertEqual(association?["neural_keyboard"] as? Bool, true)
      XCTAssertEqual(association?["show_next_on_duplicate"] as? Bool, true)
    }
  }

  func testBundledCompactGrammarAndUpgradedColloquialDictionaryLoadInLiveSession() async {
    XCTAssertTrue(
      IOSResourcePacks.bundled(SentenceAssociationPreference.compactGrammarPackID),
      "MSIMEKeyboardTestHost should bundle grammar-models/zh-hans-t-essay-bgw-compact.gram"
    )
    let bridge = MetasequoiaInputSessionBridge(stateRoot: state)
    XCTAssertTrue(bridge.setTouchKeyboardScheme(.quanpin, enabledSchemes: [.quanpin]))

    func candidatesFor(_ pinyin: String) -> [String] {
      _ = bridge.cancel()
      var snapshot = bridge.cancel()
      for ch in pinyin {
        snapshot = bridge.handleCharacter(String(ch))
      }
      return snapshot.candidates
    }

    XCTAssertTrue(candidatesFor("chunzhao").contains("春招"), "upgraded dictionary should contain 春招")
    XCTAssertTrue(candidatesFor("gazhu").contains("尬住"), "upgraded dictionary should contain 尬住")
    XCTAssertTrue(candidatesFor("yijiansanlian").contains("一键三连"), "upgraded dictionary should contain 一键三连")
    // 常见错音容错词与中英混写词（26 键）
    XCTAssertTrue(candidatesFor("maopeifang").contains("毛坯房"), "cuoyin reading should offer 毛坯房")
    XCTAssertTrue(candidatesFor("shuofu").contains("说服"), "cuoyin reading should offer 说服")
    XCTAssertTrue(candidatesFor("bzhan").contains("B站"), "mixed CN-EN should offer B站")
    XCTAssertTrue(candidatesFor("upan").contains("U盘"), "mixed CN-EN should offer U盘")
    XCTAssertTrue(candidatesFor("cwei").contains("C位"), "mixed CN-EN should offer C位")
    XCTAssertTrue(candidatesFor("agu").contains("A股"), "mixed CN-EN should offer A股")

    // 光标前文同步与秒删学习回滚 FFI 链路（26 键误选次选词后秒删不顶掉首位）
    _ = bridge.cancel()
    bridge.setSurroundingContext("今天去逛了一下")
    XCTAssertTrue(candidatesFor("bzhan").contains("B站"))
    _ = bridge.cancel()
    XCTAssertFalse(bridge.undoLastLearning(expectedText: "不存在的词"))
    let shishiBefore = candidatesFor("shishi")
    XCTAssertGreaterThanOrEqual(shishiBefore.count, 2)
    let committed26 = bridge.selectCandidate(at: 1).commitText ?? ""
    XCTAssertFalse(committed26.isEmpty)
    XCTAssertTrue(bridge.undoLastLearning(expectedText: committed26), "immediate undo should revert just-learned 26-key word")
    XCTAssertFalse(bridge.undoLastLearning(expectedText: committed26), "second undo should be a no-op")
    XCTAssertEqual(candidatesFor("shishi").first, shishiBefore.first, "rolled-back 26-key pick should not hijack top slot")

    // 九宫格中英混写词与误选秒删防误学
    _ = bridge.cancel()
    XCTAssertTrue(bridge.setTouchKeyboardScheme(.nineKey, enabledSchemes: [.quanpin, .nineKey]))
    _ = bridge.switchToNineKey()
    XCTAssertTrue(candidatesFor("29426").contains("B站"), "nine-key 29426 should offer B站")
    XCTAssertTrue(candidatesFor("8726").contains("U盘"), "nine-key 8726 should offer U盘")
    let nineKeyBefore = candidatesFor("64426")
    XCTAssertGreaterThanOrEqual(nineKeyBefore.count, 2)
    let committedNineKey = bridge.selectCandidate(at: 1).commitText ?? ""
    XCTAssertFalse(committedNineKey.isEmpty)
    XCTAssertTrue(bridge.undoLastLearning(expectedText: committedNineKey), "immediate undo should revert nine-key recent pin and weight")
    XCTAssertFalse(bridge.undoLastLearning(expectedText: committedNineKey), "second nine-key undo should be a no-op")
    XCTAssertEqual(candidatesFor("64426").first, nineKeyBefore.first, "rolled-back nine-key pick should not hijack slot 1")
    _ = bridge.cancel()

    XCTAssertTrue(SentenceAssociationPreference.saveGrammarModel(.wanxiang, stateRoot: state))
    let reloaded = expectation(description: "reload wanxiang grammar model")
    var accepted = false
    bridge.reloadSharedPreferences { accepted = $0; reloaded.fulfill() }
    await fulfillment(of: [reloaded], timeout: 15)
    XCTAssertTrue(accepted, "live keyboard session should accept wanxiang grammar_model preference")
  }
}
