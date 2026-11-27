import ObjectiveC
import UIKit
import XCTest

/// 「按音节回删」开关：打开后全拼 26 键组字里的单次 ⌫ 一次删掉最后一个完整音节（meiyou 退一格变 mei），关闭时照旧按字母删。组字真源在 Rust 会话，按音节路径就是长按 ⌫ 已有的 `segmentBackspace`（command 12，桥级行为在 CompositionCaretTests），这里验证的是开关接线和删除粒度。
@MainActor
final class BackspaceSyllableTests: XCTestCase {
  /// 测试宿主里的 `textDocumentProxy` 没有文档（见 EmailSuffixKeyboardTests）：行内预编辑写进输入框的标记文本（拼写分词）是这里能看到的组字真相，上屏和退格落在内存文本上。
  private final class Document: NSObject, UITextDocumentProxy {
    var text = ""
    private(set) var markedText = ""

    /// 标记文本去掉分词分隔符后的拼写：meiyou、mei，断言不钉分隔符的画法。
    var spelling: String { markedText.replacingOccurrences(of: "'", with: "") }

    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { nil }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier = UUID()
    var hasText: Bool { !text.isEmpty }

    func insertText(_ inserted: String) {
      text += inserted
    }
    func deleteBackward() {
      if !text.isEmpty { text.removeLast() }
    }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ marked: String, selectedRange: NSRange) {
      markedText = marked
    }
    func unmarkText() {
      markedText = ""
    }
  }

  private static let proxySelector = #selector(getter: UIInputViewController.textDocumentProxy)

  /// 让 `KeyboardViewController` 的 `textDocumentProxy` 返回 `document`，用例结束时换回父类的实现。
  private func attach(_ document: Document) throws {
    let inherited = try XCTUnwrap(class_getInstanceMethod(UIInputViewController.self, Self.proxySelector))
    let original = method_getImplementation(inherited)
    let block: @convention(block) (AnyObject) -> AnyObject = { _ in document }
    let replacement = imp_implementationWithBlock(block)
    method_setImplementation(try XCTUnwrap(class_getInstanceMethod(KeyboardViewController.self, Self.proxySelector)), replacement)
    addTeardownBlock {
      if let own = class_getInstanceMethod(KeyboardViewController.self, Self.proxySelector) {
        method_setImplementation(own, original)
      }
      imp_removeBlock(replacement)
    }
  }

  private func makeKeyboard(_ document: Document) throws -> KeyboardViewController {
    enableAllInputSchemes()
    let previousScheme = InputSchemePreference.scheme
    addTeardownBlock { InputSchemePreference.scheme = previousScheme }
    InputSchemePreference.scheme = .quanpin
    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: KeyboardViewController.defaultKeyboardHeight)
    controller.view.layoutIfNeeded()
    try attach(document)
    // 会话在键盘出现时才建（#10634），出现时读到的已经是这份文档。
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()
    return controller
  }

  private func key(_ letter: Character, in controller: KeyboardViewController) throws -> UIButton {
    try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "字母 \(letter)" } as? UIButton)
  }

  private func deleteKey(in controller: KeyboardViewController) throws -> UIButton {
    try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "删除" } as? UIButton,
                  "No delete key.")
  }

  private func descendants(_ root: UIView) -> [UIView] {
    root.subviews + root.subviews.flatMap(descendants)
  }

  override func tearDown() {
    TouchBackspaceSyllablePreference.isEnabled = false
    TouchBackspaceSyllablePreference.glideOnly = false
    super.tearDown()
  }

  func testToggleOnTakesTheLastSyllableOffAtOnce() throws {
    let document = Document()
    let controller = try makeKeyboard(document)
    TouchBackspaceSyllablePreference.isEnabled = true
    TouchBackspaceSyllablePreference.glideOnly = false

    for letter in "MEIYOU" { try key(letter, in: controller).sendActions(for: .primaryActionTriggered) }
    XCTAssertEqual(document.spelling, "meiyou")

    try deleteKey(in: controller).sendActions(for: .touchUpInside)
    XCTAssertEqual(document.spelling, "mei", "一次 ⌫ 删掉整个 you，不是字母 y")
  }

  func testToggleOffStillTakesOneLetterOff() throws {
    let document = Document()
    let controller = try makeKeyboard(document)
    TouchBackspaceSyllablePreference.isEnabled = false
    TouchBackspaceSyllablePreference.glideOnly = false

    for letter in "MEIYOU" { try key(letter, in: controller).sendActions(for: .primaryActionTriggered) }
    XCTAssertEqual(document.spelling, "meiyou")

    try deleteKey(in: controller).sendActions(for: .touchUpInside)
    XCTAssertEqual(document.spelling, "meiyo", "开关关闭时照旧按字母删")
  }

  func testGlideOnlyDeletesTypedByLetterAndGlidedBySyllable() throws {
    let previousGlide = KeyboardLayoutPreference.defaults.object(forKey: KeyboardLayoutPreference.glideTypingKey)
    let previousBilingual = KeyboardLayoutPreference.defaults.object(forKey: KeyboardLayoutPreference.bilingualGlideKey)
    let previousEngine = GlideEnginePreference.choice
    addTeardownBlock {
      if let previousGlide { KeyboardLayoutPreference.defaults.set(previousGlide, forKey: KeyboardLayoutPreference.glideTypingKey) }
      else { KeyboardLayoutPreference.defaults.removeObject(forKey: KeyboardLayoutPreference.glideTypingKey) }
      if let previousBilingual { KeyboardLayoutPreference.defaults.set(previousBilingual, forKey: KeyboardLayoutPreference.bilingualGlideKey) }
      else { KeyboardLayoutPreference.defaults.removeObject(forKey: KeyboardLayoutPreference.bilingualGlideKey) }
      GlideEnginePreference.choice = previousEngine
    }
    KeyboardLayoutPreference.glideTyping = true
    KeyboardLayoutPreference.bilingualGlide = false
    GlideEnginePreference.choice = .msime

    let document = Document()
    let controller = try makeKeyboard(document)
    TouchBackspaceSyllablePreference.isEnabled = true
    TouchBackspaceSyllablePreference.glideOnly = true

    // 1. 纯点按输入：仅滑行生效开启时，仍逐字母删除。
    for letter in "MEIYOU" { try key(letter, in: controller).sendActions(for: .primaryActionTriggered) }
    XCTAssertEqual(document.spelling, "meiyou")
    try deleteKey(in: controller).sendActions(for: .touchUpInside)
    XCTAssertEqual(document.spelling, "meiyo", "仅滑行生效时，逐键点按的字母仍按单字母回删")

    // 清空残余组字。
    while !document.spelling.isEmpty {
      try deleteKey(in: controller).sendActions(for: .touchUpInside)
    }

    // 2. 纯滑行输入多音节：按音节一次删一个音节，而不是一次清空整段或逐字母退。
    let glide = try XCTUnwrap(descendants(controller.view)
      .compactMap { ($0 as? KeyAreaStackView)?.gestureRecognizers?.first { $0 is GlideTypingGestureRecognizer } as? GlideTypingGestureRecognizer }
      .first)
    let frames = glide.keyFrames()
    glide.onEnded(Self.stroke("nihao", in: frames), frames)
    XCTAssertEqual(document.spelling, "nihao")
    try deleteKey(in: controller).sendActions(for: .touchUpInside)
    XCTAssertEqual(document.spelling, "ni", "滑行输入在仅滑行按音节回删下应一次删掉最后一个音节 hao")
    try deleteKey(in: controller).sendActions(for: .touchUpInside)
    XCTAssertEqual(document.spelling, "", "再次退格删掉剩余滑行音节 ni")

    // 3. 点按 + 滑行混打：末尾滑行音节按音节删，回到前面点按部分后自动切回单字母删。
    for letter in "NI" { try key(letter, in: controller).sendActions(for: .primaryActionTriggered) }
    glide.onEnded(Self.stroke("hao", in: frames), frames)
    XCTAssertEqual(document.spelling, "nihao")
    try deleteKey(in: controller).sendActions(for: .touchUpInside)
    XCTAssertEqual(document.spelling, "ni", "末尾滑行段 hao 一次按音节删掉")
    try deleteKey(in: controller).sendActions(for: .touchUpInside)
    XCTAssertEqual(document.spelling, "n", "退回点按段 ni 后恢复单字母回删")
  }

  private static func stroke(_ word: String, in frames: [CGRect]) -> [GlideTyping.Sample] {
    let centers = word.map { letter -> CGPoint in
      let frame = frames[GlideTyping.letters.firstIndex(of: letter)!]
      return CGPoint(x: frame.midX, y: frame.midY)
    }
    var samples: [GlideTyping.Sample] = []
    func add(_ point: CGPoint) {
      samples.append(GlideTyping.Sample(x: point.x, y: point.y, milliseconds: Double(samples.count) * 8))
    }
    for (from, to) in zip(centers, centers.dropFirst()) {
      let steps = max(1, Int((hypot(to.x - from.x, to.y - from.y) / 6).rounded(.up)))
      for step in 0..<steps {
        let t = CGFloat(step) / CGFloat(steps)
        add(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
      }
    }
    add(centers[centers.count - 1])
    return samples
  }

  func testWithoutACompositionBackspaceStillDeletesDocumentText() throws {
    let document = Document()
    document.insertText("abc")
    let controller = try makeKeyboard(document)
    TouchBackspaceSyllablePreference.isEnabled = true

    try deleteKey(in: controller).sendActions(for: .touchUpInside)
    XCTAssertEqual(document.text, "ab", "无组字时 ⌫ 照旧删正文，不受开关影响")
    XCTAssertEqual(document.spelling, "")
  }
}
