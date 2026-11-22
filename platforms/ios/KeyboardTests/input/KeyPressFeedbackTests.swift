import XCTest
import UIKit

/// 按键反馈在按下时发、松手不重复（#10768）：按键记下这次按下已经反馈过，松手时执行的动作在 `KeyboardKeyButton.releasing` 里就不再出声；没有经过按下的激活（`sendActions`、读屏）照常出声。
@MainActor
final class KeyPressFeedbackTests: XCTestCase {
  override func setUp() {
    super.setUp()
    enableAllInputSchemes()
  }

  private func nodes(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(nodes) }

  private func key(labelled label: String, in controller: UIViewController) throws -> KeyboardKeyButton {
    try XCTUnwrap(nodes(controller.view).first { $0.accessibilityLabel == label } as? KeyboardKeyButton,
                  "No key labelled \(label).")
  }

  private func makeController(_ scheme: ChineseInputScheme) -> KeyboardViewController {
    let previous = InputSchemePreference.scheme
    addTeardownBlock { InputSchemePreference.scheme = previous }
    InputSchemePreference.scheme = scheme
    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 414, height: KeyboardViewController.defaultKeyboardHeight)
    controller.view.layoutIfNeeded()
    return controller
  }

  func testReleaseOfAPressThatFedBackIsSilent() {
    let key = KeyboardKeyButton(type: .system)
    XCTAssertTrue(key.beginPressFeedback())
    var silenced: Bool?
    KeyboardKeyButton.releasing(key) { silenced = KeyboardKeyButton.releasingPressThatFedBack }
    XCTAssertEqual(silenced, true)
    XCTAssertFalse(KeyboardKeyButton.releasingPressThatFedBack, "the scope ends with the release")
  }

  /// 一次按下只抵一次松手：同一个键之后再有松手（例如这一下被手势接管后又在手势结束时上屏）不再被吞掉。
  func testReleaseConsumesThePress() {
    let key = KeyboardKeyButton(type: .system)
    XCTAssertTrue(key.beginPressFeedback())
    KeyboardKeyButton.releasing(key) {}
    var silenced: Bool?
    KeyboardKeyButton.releasing(key) { silenced = KeyboardKeyButton.releasingPressThatFedBack }
    XCTAssertEqual(silenced, false)
  }

  /// 没有按下就执行的动作（`sendActions`、读屏激活）以及候选、面板这类不在按下时反馈的按钮，动作里照常出声。
  func testActivationWithoutAPressStillFeedsBack() {
    XCTAssertFalse(KeyboardKeyButton.releasingPressThatFedBack)
    var silenced: [Bool] = []
    KeyboardKeyButton.releasing(KeyboardKeyButton(type: .system)) { silenced.append(KeyboardKeyButton.releasingPressThatFedBack) }
    KeyboardKeyButton.releasing(UIButton(type: .system)) { silenced.append(KeyboardKeyButton.releasingPressThatFedBack) }
    KeyboardKeyButton.releasing(nil) { silenced.append(KeyboardKeyButton.releasingPressThatFedBack) }
    XCTAssertEqual(silenced, [false, false, false])
  }

  func testNestedReleaseRestoresTheOuterOne() {
    let pressed = KeyboardKeyButton(type: .system)
    XCTAssertTrue(pressed.beginPressFeedback())
    var seen: [Bool] = []
    KeyboardKeyButton.releasing(pressed) {
      KeyboardKeyButton.releasing(KeyboardKeyButton(type: .system)) { seen.append(KeyboardKeyButton.releasingPressThatFedBack) }
      seen.append(KeyboardKeyButton.releasingPressThatFedBack)
    }
    XCTAssertEqual(seen, [false, true])
  }

  /// 能滚动的容器里按下可能是在开始滚动，反馈留到松手；放得下、滚不动的容器照样按下即反馈。
  func testKeysInScrollableContentWaitForTheRelease() {
    XCTAssertTrue(KeyboardKeyButton.scrolls(contentSize: CGSize(width: 40, height: 120), boundsSize: CGSize(width: 40, height: 100)))
    XCTAssertTrue(KeyboardKeyButton.scrolls(contentSize: CGSize(width: 140, height: 40), boundsSize: CGSize(width: 100, height: 40)))
    XCTAssertFalse(KeyboardKeyButton.scrolls(contentSize: CGSize(width: 40, height: 100), boundsSize: CGSize(width: 40, height: 100)))
    XCTAssertFalse(KeyboardKeyButton.scrolls(contentSize: CGSize(width: 40, height: 100.4), boundsSize: CGSize(width: 40, height: 100)))

    let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 40, height: 100))
    let key = KeyboardKeyButton(type: .system)
    scroll.addSubview(key)
    scroll.contentSize = CGSize(width: 40, height: 100)
    XCTAssertFalse(key.sitsInScrollableContent)
    scroll.contentSize = CGSize(width: 40, height: 200)
    XCTAssertTrue(key.sitsInScrollableContent)
    scroll.isScrollEnabled = false
    XCTAssertFalse(key.sitsInScrollableContent)
  }

  /// 每次按下都重写标记：滚得动的容器里按下不在当时反馈，也要清掉上一次被取消的触摸留下的标记，否则这次松手的动作不出声，这一下就什么反馈都没有。
  func testPressInScrollableContentClearsAStaleMark() {
    let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 40, height: 100))
    let key = KeyboardKeyButton(type: .system)
    scroll.addSubview(key)
    scroll.contentSize = CGSize(width: 40, height: 100)
    XCTAssertTrue(key.beginPressFeedback())
    // 这次触摸被取消（手势接管、系统取消），标记留在键上；之后容器变得滚得动，同一个键再按下。
    scroll.contentSize = CGSize(width: 40, height: 200)
    XCTAssertFalse(key.beginPressFeedback())
    XCTAssertFalse(key.pressFedBack)
    var silenced: Bool?
    KeyboardKeyButton.releasing(key) { silenced = KeyboardKeyButton.releasingPressThatFedBack }
    XCTAssertEqual(silenced, false)
  }

  /// 九键候选面板右栏的 ⌫ 也是 `makeKey` 造的、按下就反馈，要按退格类出声；它的动作里删笔画、删拼音时的退格声在松手里不再出声。
  func testNineKeyPanelDeleteSoundsAsBackspace() throws {
    let columns = KeyboardNineKeyPanelColumns(makeKey: { title, label, _ in
      let button = KeyboardKeyButton(type: .system)
      button.setTitle(title, for: .normal)
      button.accessibilityLabel = label
      return button
    })
    let classes = try Dictionary(uniqueKeysWithValues: columns.trailing.arrangedSubviews.map { view in
      let key = try XCTUnwrap(view as? KeyboardKeyButton)
      return (try XCTUnwrap(key.accessibilityIdentifier), key.pressSoundClass)
    })
    XCTAssertEqual(classes["candidatePanelDelete"], .backspace)
    for identifier in ["candidatePanelBack", "candidatePanelClear", "candidatePanelStrokeToggle", "candidatePanelSingleToggle"] {
      XCTAssertEqual(classes[identifier], .standard, identifier)
    }
  }

  /// 键盘按键都在按下时反馈，空格、退格和回车按自己的声音类别出声。
  func testKeyboardKeysFeedBackOnPress() throws {
    let controller = makeController(.quanpin)
    let pressActions = { (button: UIButton) in button.actions(forTarget: controller, forControlEvent: .touchDown) ?? [] }
    for label in ["字母 Q", "字母 M", "大写", "空格", "删除", "换行"] {
      XCTAssertTrue(pressActions(try key(labelled: label, in: controller)).contains("keyPressFeedback:"), label)
    }
    XCTAssertEqual(try key(labelled: "字母 Q", in: controller).pressSoundClass, .standard)
    XCTAssertEqual(try key(labelled: "空格", in: controller).pressSoundClass, .space)
    XCTAssertEqual(try key(labelled: "删除", in: controller).pressSoundClass, .backspace)
    XCTAssertEqual(try key(labelled: "换行", in: controller).pressSoundClass, .enter)
  }

  /// 双指快打防颠倒：26 键字母键开启 `supportsRollover`，Shift/空格/退格/回车不开启；先行键在后续键按下瞬间按序提交且不重复反馈。
  func testKeyRolloverCommitsPreviousLetterInOrderWithoutDoubleFeedback() throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
    let first = KeyboardKeyButton(type: .system)
    let second = KeyboardKeyButton(type: .system)
    first.supportsRollover = true
    second.supportsRollover = true
    window.addSubview(first)
    window.addSubview(second)

    var sequence: [String] = []
    var firstSilenced: Bool?
    first.addAction(UIAction { _ in
      sequence.append("n")
      firstSilenced = KeyboardKeyButton.releasingPressThatFedBack
    }, for: .primaryActionTriggered)
    second.addAction(UIAction { _ in
      sequence.append("i")
    }, for: .primaryActionTriggered)

    XCTAssertTrue(first.beginPressFeedback())
    first.isHighlighted = true
    first.registerActiveRolloverForPress()
    // 第二根手指按下 i 时冲刷先行键 n，确保按按下顺序先提交 n 且沿用按下反馈不二次出声。
    KeyboardKeyButton.flushActiveRollover(except: second)
    XCTAssertEqual(sequence, ["n"])
    XCTAssertEqual(firstSilenced, true)
    XCTAssertTrue(first.committedByRollover)
    XCTAssertFalse(first.isHighlighted)
    // 同一次按压不能被重复抢跑提交。
    XCTAssertFalse(first.commitByRollover())
    XCTAssertEqual(sequence, ["n"])

    // 手指滑出按键取消高亮后，不再触发抢跑提交。
    second.isHighlighted = false
    second.registerActiveRolloverForPress()
    KeyboardKeyButton.flushActiveRollover(except: first)
    XCTAssertEqual(sequence, ["n"])

    // 功能键不作为抢跑先行键（保留按住 Shift 再按字母的组合行为）。
    let controller = makeController(.quanpin)
    XCTAssertTrue(try key(labelled: "字母 Q", in: controller).supportsRollover)
    XCTAssertTrue(try key(labelled: "字母 M", in: controller).supportsRollover)
    XCTAssertFalse(try key(labelled: "大写", in: controller).supportsRollover)
    XCTAssertFalse(try key(labelled: "空格", in: controller).supportsRollover)
    XCTAssertFalse(try key(labelled: "删除", in: controller).supportsRollover)
    XCTAssertFalse(try key(labelled: "换行", in: controller).supportsRollover)
  }

  /// 长按多选气泡横向拖选切换高亮项时，只在索引真实变化时触发回调。
  func testCalloutNotifiesHighlightChangesDuringDragSelection() {
    let skin = KeyboardTheme.current
    let callout = KeyActionCalloutView(options: ["，", "。", "？"], skin: skin) { _ in }
    callout.frame = CGRect(x: 0, y: 0, width: 130, height: 48)
    callout.layoutIfNeeded()
    var seen: [Int?] = []
    callout.onHighlightChanged = { seen.append($0) }
    let trigger = UIView(frame: CGRect(x: 40, y: 54, width: 40, height: 40))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    window.addSubview(callout)
    window.addSubview(trigger)
    callout.layoutIfNeeded()

    callout.beginDrag(at: CGPoint(x: 20, y: 24))
    callout.trackDrag(at: CGPoint(x: 65, y: 24), ended: false, triggerKey: trigger, onCommit: { _ in }, onCancel: {})
    callout.trackDrag(at: CGPoint(x: 66, y: 24), ended: false, triggerKey: trigger, onCommit: { _ in }, onCancel: {})
    callout.trackDrag(at: CGPoint(x: 110, y: 24), ended: false, triggerKey: trigger, onCommit: { _ in }, onCancel: {})
    XCTAssertEqual(seen, [1, 2])
  }

  /// 系统自定义短语索引支持大小写与拼音分词撇号归一化，并保持首次出现顺序且去重。
  func testSystemLexiconIndexedMatching() {
    let store = SystemLexiconStore()
    store.setEntriesForTests([
      .init(userInput: "OMW", documentText: "在路上了"),
      .init(userInput: "omw", documentText: "在路上了"),
      .init(userInput: "omw", documentText: "On my way!"),
      .init(userInput: "nihao", documentText: "你好呀"),
    ])
    XCTAssertEqual(store.matches(forInput: "omw"), ["在路上了", "On my way!"])
    XCTAssertEqual(store.matches(forInput: "", preedit: "ni'hao"), ["你好呀"])
    XCTAssertEqual(store.matches(forInput: "omw", preedit: "ni'hao"), ["在路上了", "On my way!", "你好呀"])
    store.setEntriesForTests([])
    XCTAssertEqual(store.matches(forInput: "omw"), [])
  }
}
