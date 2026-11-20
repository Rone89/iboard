import XCTest

/// Editing inside the spelling, as the Windows composition does with ← / →: the caret the runtime moves is the one the strip draws, and a key then acts there.
final class CompositionCaretTests: XCTestCase {
  private var state: URL!

  override func setUp() {
    super.setUp()
    state = FileManager.default.temporaryDirectory
      .appendingPathComponent("msime-composition-caret-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: state)
    super.tearDown()
  }

  func testTheCaretMovesThroughTheSpellingAndEditsHappenThere() {
    let bridge = MetasequoiaInputSessionBridge(stateRoot: state)
    var snapshot = MetasequoiaInputSnapshot()
    for letter in "nihao" { snapshot = bridge.handleCharacter(String(letter)) }
    XCTAssertEqual(snapshot.editingText, "nihao")
    XCTAssertEqual(snapshot.caretPosition, 5)
    XCTAssertNil(snapshot.editingTextWithCaret, "a caret at the end leaves the segmented pinyin in place")

    for _ in 0..<3 { snapshot = bridge.moveCaretLeft() }
    XCTAssertTrue(snapshot.isHandled)
    XCTAssertEqual(snapshot.caretPosition, 2)
    XCTAssertEqual(snapshot.editingTextWithCaret, "ni|hao")

    snapshot = bridge.handleBackspace()
    XCTAssertEqual(snapshot.editingText, "nhao", "backspace deletes the letter before the caret, not the last one")
    XCTAssertEqual(snapshot.caretPosition, 1)

    snapshot = bridge.moveCaretRight()
    XCTAssertEqual(snapshot.caretPosition, 2)
    _ = bridge.cancel()
  }

  func testSegmentEditsTakeTheSpellingApartASyllableAtATime() {
    let bridge = MetasequoiaInputSessionBridge(stateRoot: state)
    var snapshot = MetasequoiaInputSnapshot()
    for letter in "nihaoshijie" { snapshot = bridge.handleCharacter(String(letter)) }
    XCTAssertEqual(snapshot.caretPosition, 11)

    snapshot = bridge.moveCaretLeftBySegment()
    XCTAssertTrue(snapshot.isHandled)
    XCTAssertEqual(snapshot.caretPosition, 8, "one step lands on the boundary before jie")
    snapshot = bridge.moveCaretRightBySegment()
    XCTAssertEqual(snapshot.caretPosition, 11)

    snapshot = bridge.segmentBackspace()
    XCTAssertTrue(snapshot.isHandled)
    XCTAssertEqual(snapshot.editingText, "nihaoshi", "the whole last syllable goes, not one letter")
    for _ in 0..<3 { snapshot = bridge.segmentBackspace() }
    XCTAssertEqual(snapshot.editingText, "")
    XCTAssertTrue(snapshot.candidates.isEmpty)
    _ = bridge.cancel()
  }

  func testOnlyALetteredPinyinSpellingIsEditedBySyllable() {
    XCTAssertEqual(ChineseInputScheme.allCases.filter(\.editsBySyllable),
                   [.quanpin, .shuangpin, .ziranma, .microsoft, .shoudao])
  }

  func testOnlyAQuickFlickMovesBySyllable() {
    XCTAssertFalse(SpaceCursorMovement.movesBySegment(velocity: 300))
    XCTAssertTrue(SpaceCursorMovement.movesBySegment(velocity: -1200))
    XCTAssertFalse(SpaceCursorMovement.movesBySegment(velocity: .nan))
  }

  func testHomeEndAndForwardDeleteActInsideTheSpelling() {
    let bridge = MetasequoiaInputSessionBridge(stateRoot: state)
    var snapshot = MetasequoiaInputSnapshot()
    for letter in "nihao" { snapshot = bridge.handleCharacter(String(letter)) }
    snapshot = bridge.moveCaretToStart()
    XCTAssertTrue(snapshot.isHandled)
    XCTAssertEqual(snapshot.caretPosition, 0)
    snapshot = bridge.deleteForward()
    XCTAssertEqual(snapshot.editingText, "ihao", "the letter after the caret goes")
    XCTAssertEqual(snapshot.caretPosition, 0)
    snapshot = bridge.moveCaretToEnd()
    XCTAssertEqual(snapshot.caretPosition, 4)
    _ = bridge.cancel()
  }

  /// 26 键全拼与九键组字时，不再在输入法左上角显示铅笔编辑按钮，也不会弹出放大拼写编辑条；空格移动光标后仍会在读音区显示光标位置但仅作静态文本。
  @MainActor
  func testTypingDoesNotShowTopLeftSpellingEditor() throws {
    enableAllInputSchemes()
    let previous = InputSchemePreference.scheme
    defer { InputSchemePreference.scheme = previous }
    for scheme in [ChineseInputScheme.quanpin, .nineKey] {
      InputSchemePreference.scheme = scheme
      let controller = KeyboardViewController()
      controller.loadViewIfNeeded()
      controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: KeyboardViewController.defaultKeyboardHeight)
      controller.viewWillAppear(false)
      controller.view.layoutIfNeeded()
      let preedit = try XCTUnwrap(descendants(controller.view).first {
        $0.accessibilityIdentifier == "preeditButton"
      } as? UIButton)
      let height = try XCTUnwrap(controller.view.constraints.first { $0.identifier == "keyboardHeight" })
      let closedHeight = height.constant
      XCTAssertNil(descendants(controller.view).first { $0 is CompositionEditorBar })
      XCTAssertNotEqual(preedit.accessibilityLabel, "编辑拼写")

      if scheme == .quanpin {
        for letter in "NIHAO" { try key(letter, in: controller).sendActions(for: .primaryActionTriggered) }
      } else {
        for digit in "64426" {
          try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "nineKey\(digit)" } as? UIButton)
            .sendActions(for: .primaryActionTriggered)
        }
      }
      controller.view.layoutIfNeeded()
      XCTAssertTrue(preedit.isHidden, "\(scheme) inline reading collapses without a pencil button")
      XCTAssertNil(preedit.configuration?.image, "\(scheme) must not show a top-left pencil icon")
      XCTAssertNotEqual(preedit.accessibilityLabel, "编辑拼写")
      XCTAssertFalse(preedit.accessibilityTraits.contains(.button))

      preedit.sendActions(for: .primaryActionTriggered)
      XCTAssertEqual(height.constant, closedHeight, "tapping preedit must not grow the keyboard")
      XCTAssertNil(descendants(controller.view).first { $0 is CompositionEditorBar })
      controller.viewDidDisappear(false)
    }
  }

  /// 读音单独一行时，它和候选行之间的皮肤行距也归读音；拼音选择条下面那段缝不归读音（#10591，与 Android 相同）。
  @MainActor
  func testTheGapBelowASeparateReadingRowOpensTheEditor() {
    let row = KeyboardViewController.ReadingRowView(frame: CGRect(x: 0, y: 0, width: 300, height: 14))
    XCTAssertTrue(row.hits(CGPoint(x: 290, y: 7)))
    XCTAssertFalse(row.hits(CGPoint(x: 20, y: 16)), "no gap, nothing below the row")
    row.hitBottomExtension = 6
    XCTAssertTrue(row.hits(CGPoint(x: 20, y: 16)))
    XCTAssertTrue(row.hits(CGPoint(x: 290, y: 19.5)))
    XCTAssertFalse(row.hits(CGPoint(x: 20, y: 20)), "the candidate row starts after the gap")
    let strip = UIView(frame: CGRect(x: 150, y: 0, width: 150, height: 14))
    row.addSubview(strip)
    row.bandLimit = strip
    XCTAssertTrue(row.hits(CGPoint(x: 100, y: 16)))
    XCTAssertFalse(row.hits(CGPoint(x: 200, y: 16)), "the gap under the spelling strip is not the reading's")
    strip.isHidden = true
    XCTAssertTrue(row.hits(CGPoint(x: 200, y: 16)))
  }

  private func key(_ letter: Character, in controller: KeyboardViewController) throws -> UIButton {
    try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "字母 \(letter)" } as? UIButton)
  }

  private func descendants(_ root: UIView) -> [UIView] {
    root.subviews + root.subviews.flatMap(descendants)
  }

  func testOnlyAnAsciiSpellingWithAnInnerCaretIsSplit() {
    XCTAssertEqual(MetasequoiaInputSnapshot(editingText: "nihao", caretPosition: 0).editingTextWithCaret, "|nihao")
    XCTAssertNil(MetasequoiaInputSnapshot(editingText: "nihao", caretPosition: 5).editingTextWithCaret)
    XCTAssertNil(MetasequoiaInputSnapshot(editingText: "nihao", caretPosition: 9).editingTextWithCaret)
    XCTAssertNil(MetasequoiaInputSnapshot(editingText: "にほ", caretPosition: 1).editingTextWithCaret)
  }
}
