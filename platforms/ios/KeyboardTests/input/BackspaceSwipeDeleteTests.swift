import ObjectiveC
import UIKit
import XCTest

/// 退格键左滑按词/短句删除、工具栏「撤销删除」胶囊，以及光标棘轮/删除/撤销 CoreHaptics 脉冲测试。
@MainActor
final class BackspaceSwipeDeleteTests: XCTestCase {
  func testSwipeBeginPolicyRequiresClearLeftwardHorizontalVelocity() {
    XCTAssertTrue(BackspaceSwipeDeletePolicy.shouldBegin(velocity: CGPoint(x: -180, y: 10)))
    XCTAssertFalse(BackspaceSwipeDeletePolicy.shouldBegin(velocity: CGPoint(x: 180, y: 0)))
    XCTAssertFalse(BackspaceSwipeDeletePolicy.shouldBegin(velocity: CGPoint(x: -50, y: 0)))
    XCTAssertFalse(BackspaceSwipeDeletePolicy.shouldBegin(velocity: CGPoint(x: -120, y: 120)))
    XCTAssertFalse(BackspaceSwipeDeletePolicy.shouldBegin(velocity: CGPoint(x: -CGFloat.infinity, y: 0)))
    XCTAssertFalse(BackspaceSwipeDeletePolicy.shouldBegin(velocity: CGPoint(x: CGFloat.nan, y: 0)))
  }

  func testChunkToDeleteHandlesEnglishChinesePunctuationAndNewlines() {
    XCTAssertNil(BackspaceSwipeDeletePolicy.chunkToDelete(beforeCursor: nil))
    XCTAssertNil(BackspaceSwipeDeletePolicy.chunkToDelete(beforeCursor: ""))
    XCTAssertEqual(BackspaceSwipeDeletePolicy.chunkToDelete(beforeCursor: "hello world"), "world")
    XCTAssertEqual(BackspaceSwipeDeletePolicy.chunkToDelete(beforeCursor: "hello world  "), "world  ")
    XCTAssertEqual(BackspaceSwipeDeletePolicy.chunkToDelete(beforeCursor: "don't"), "don't")
    XCTAssertEqual(BackspaceSwipeDeletePolicy.chunkToDelete(beforeCursor: "今天天气不错，我们去公园"), "我们去公园")
    XCTAssertEqual(BackspaceSwipeDeletePolicy.chunkToDelete(beforeCursor: "今天天气不错，"), "，")
    XCTAssertEqual(BackspaceSwipeDeletePolicy.chunkToDelete(beforeCursor: "苹果Apple"), "Apple")
    XCTAssertEqual(BackspaceSwipeDeletePolicy.chunkToDelete(beforeCursor: "第一行\n"), "\n")
    XCTAssertEqual(BackspaceSwipeDeletePolicy.chunkToDelete(beforeCursor: "测试。。。"), "。。。")
    // 超长无标点中文段受单块 12 字上限约束，避免误清空整段。
    let longClause = "一二三四五六七八九十甲乙丙丁戊"
    XCTAssertEqual(BackspaceSwipeDeletePolicy.chunkToDelete(beforeCursor: longClause)?.count, 12)
  }

  func testSwipeSessionAccumulatesChunksInOriginalDocumentOrderAndSupportsFlick() {
    var session = BackspaceSwipeDeleteSession()
    let doc = UUID()
    session.begin(at: 0, document: doc)
    XCTAssertEqual(session.advance(to: -10), 0)
    XCTAssertEqual(session.advance(to: -30), 1)
    session.recordDeletedChunk("world")
    XCTAssertEqual(session.advance(to: -60), 1)
    session.recordDeletedChunk("hello ")
    let record = session.finish(allowsUndoRecord: true)
    XCTAssertEqual(record, BackspaceUndoRecord(deletedText: "hello world", document: doc))
    XCTAssertEqual(record?.previewText, "hell…")

    // 快速左甩即使未到 28pt 也在抬手时触发一步。
    session.begin(at: 0, document: doc)
    XCTAssertTrue(session.shouldTriggerFlickOnEnd(at: -18, velocityX: -400))
    session.recordDeletedChunk("公园")
    // 凭据输入框不保留撤回记录。
    XCTAssertNil(session.finish(allowsUndoRecord: false))
  }

  func testCoreHapticsCursorTickSwipeDeleteAndUndoProfiles() {
    XCTAssertTrue(KeyboardHapticsEngine.pulses(for: .system, event: .cursorTick).isEmpty)
    XCTAssertTrue(KeyboardHapticsEngine.pulses(for: .system, event: .swipeDelete).isEmpty)
    XCTAssertTrue(KeyboardHapticsEngine.pulses(for: .system, event: .undo).isEmpty)

    let lightTick = KeyboardHapticsEngine.pulses(for: .light, event: .cursorTick)
    let medTick = KeyboardHapticsEngine.pulses(for: .medium, event: .cursorTick)
    let strongTick = KeyboardHapticsEngine.pulses(for: .strong, event: .cursorTick)
    XCTAssertEqual(lightTick.count, 1)
    XCTAssertEqual(medTick.count, 1)
    XCTAssertEqual(strongTick.count, 1)
    XCTAssertGreaterThan(lightTick[0].sharpness, 0.9)
    XCTAssertLessThan(lightTick[0].intensity, medTick[0].intensity)
    XCTAssertLessThan(medTick[0].intensity, strongTick[0].intensity)

    XCTAssertEqual(KeyboardHapticsEngine.pulses(for: .medium, event: .swipeDelete).count, 2)
    XCTAssertEqual(KeyboardHapticsEngine.pulses(for: .medium, event: .undo).count, 2)
  }

  func testSwipeDeleteShowsUndoPillAndRestoresDeletedText() throws {
    let document = FakeDocument(text: "今天天气不错，我们去公园")
    let controller = try makeKeyboard(document)
    let delete = try deleteKey(in: controller)
    let pan = try XCTUnwrap(delete.gestureRecognizers?.first { $0.name == "backspaceSwipeDelete" } as? UIPanGestureRecognizer)
    XCTAssertTrue(pan.cancelsTouchesInView)

    let mockPan = MockSwipePan()
    mockPan.name = "backspaceSwipeDelete"
    mockPan.velocityValue = CGPoint(x: -240, y: 0)
    XCTAssertTrue(controller.gestureRecognizerShouldBegin(mockPan))

    try dispatchSwipe(.began, x: 0, velocityX: -240, pan: mockPan, to: controller)
    try dispatchSwipe(.changed, x: -32, velocityX: -240, pan: mockPan, to: controller)
    try dispatchSwipe(.ended, x: -32, velocityX: -200, pan: mockPan, to: controller)

    XCTAssertEqual(document.text, "今天天气不错，")
    let undoButton = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "undoDeleteShortcut" } as? UIButton)
    XCTAssertFalse(undoButton.isHidden)
    XCTAssertEqual(undoButton.accessibilityValue, "我们去公…")

    // 点按撤销胶囊完整恢复刚才删掉的文本并收起胶囊。
    undoButton.sendActions(for: .primaryActionTriggered)
    XCTAssertEqual(document.text, "今天天气不错，我们去公园")
    XCTAssertTrue(undoButton.isHidden)
  }

  func testSwipeDeleteDuringCompositionClearsOnlyCompositionAndKeepsCommittedText() throws {
    let document = FakeDocument(text: "你好")
    let controller = try makeKeyboard(document)
    for letter in "SHIJIE" {
      let key = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "字母 \(letter)" } as? UIButton)
      key.sendActions(for: .primaryActionTriggered)
    }
    XCTAssertEqual(document.markedText.replacingOccurrences(of: "'", with: ""), "shijie")

    let mockPan = MockSwipePan()
    mockPan.name = "backspaceSwipeDelete"
    try dispatchSwipe(.began, x: 0, velocityX: -300, pan: mockPan, to: controller)
    try dispatchSwipe(.changed, x: -36, velocityX: -300, pan: mockPan, to: controller)
    try dispatchSwipe(.changed, x: -90, velocityX: -300, pan: mockPan, to: controller)
    try dispatchSwipe(.ended, x: -90, velocityX: -200, pan: mockPan, to: controller)

    XCTAssertEqual(document.markedText, "")
    XCTAssertEqual(document.text, "你好", "清空组字后同一次左滑绝不能跨边界删掉已上屏正文")
    let undoButton = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "undoDeleteShortcut" } as? UIButton)
    XCTAssertTrue(undoButton.isHidden)
  }

  func testTypingNewTextDismissesUndoDeletePill() throws {
    let document = FakeDocument(text: "hello world")
    let controller = try makeKeyboard(document)
    let mockPan = MockSwipePan()
    mockPan.name = "backspaceSwipeDelete"
    try dispatchSwipe(.began, x: 0, velocityX: -300, pan: mockPan, to: controller)
    try dispatchSwipe(.changed, x: -32, velocityX: -300, pan: mockPan, to: controller)
    try dispatchSwipe(.ended, x: -32, velocityX: -100, pan: mockPan, to: controller)

    XCTAssertEqual(document.text, "hello ")
    let undoButton = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "undoDeleteShortcut" } as? UIButton)
    XCTAssertFalse(undoButton.isHidden)

    // 任意后续普通退格或新输入都应立刻清掉旧撤销胶囊。
    try deleteKey(in: controller).sendActions(for: .touchUpInside)
    XCTAssertTrue(undoButton.isHidden)
  }

  // MARK: - 测试夹具

  private final class FakeDocument: NSObject, UITextDocumentProxy {
    var text: String
    private(set) var markedText = ""
    var documentIdentifier = UUID()
    var isSecureTextEntry: Bool = false

    init(text: String) {
      self.text = text
    }

    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { nil }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !text.isEmpty }

    func insertText(_ inserted: String) { text += inserted }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ marked: String, selectedRange: NSRange) { markedText = marked }
    func unmarkText() { markedText = "" }
  }

  private final class MockSwipePan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var translationX: CGFloat = 0
    var velocityValue = CGPoint(x: -240, y: 0)
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: translationX, y: 0) }
    override func velocity(in view: UIView?) -> CGPoint { velocityValue }
  }

  private static let proxySelector = #selector(getter: UIInputViewController.textDocumentProxy)

  private func makeKeyboard(_ document: FakeDocument) throws -> KeyboardViewController {
    enableAllInputSchemes()
    let previousScheme = InputSchemePreference.scheme
    addTeardownBlock { InputSchemePreference.scheme = previousScheme }
    InputSchemePreference.scheme = .quanpin

    let inherited = try XCTUnwrap(class_getInstanceMethod(UIInputViewController.self, Self.proxySelector))
    let original = method_getImplementation(inherited)
    let block: @convention(block) (AnyObject) -> AnyObject = { _ in document }
    let replacement = imp_implementationWithBlock(block)
    if !class_addMethod(KeyboardViewController.self, Self.proxySelector, replacement, method_getTypeEncoding(inherited)) {
      method_setImplementation(try XCTUnwrap(class_getInstanceMethod(KeyboardViewController.self, Self.proxySelector)), replacement)
    }
    addTeardownBlock {
      if let own = class_getInstanceMethod(KeyboardViewController.self, Self.proxySelector) {
        method_setImplementation(own, original)
      }
      imp_removeBlock(replacement)
    }

    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: KeyboardViewController.defaultKeyboardHeight)
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()
    return controller
  }

  private func deleteKey(in controller: KeyboardViewController) throws -> UIButton {
    try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "删除" } as? UIButton)
  }

  private func dispatchSwipe(_ state: UIGestureRecognizer.State, x: CGFloat, velocityX: CGFloat,
                             pan: MockSwipePan, to controller: KeyboardViewController) throws {
    let selector = NSSelectorFromString("handleBackspaceSwipePan:")
    XCTAssertTrue(controller.responds(to: selector))
    pan.phase = state
    pan.translationX = x
    pan.velocityValue = CGPoint(x: velocityX, y: 0)
    controller.perform(selector, with: pan)
  }

  private func descendants(_ root: UIView) -> [UIView] {
    root.subviews + root.subviews.flatMap(descendants)
  }
}
