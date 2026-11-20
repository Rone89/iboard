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
    super.tearDown()
  }

  func testToggleOnTakesTheLastSyllableOffAtOnce() throws {
    let document = Document()
    let controller = try makeKeyboard(document)
    TouchBackspaceSyllablePreference.isEnabled = true

    for letter in "MEIYOU" { try key(letter, in: controller).sendActions(for: .primaryActionTriggered) }
    XCTAssertEqual(document.spelling, "meiyou")

    try deleteKey(in: controller).sendActions(for: .touchUpInside)
    XCTAssertEqual(document.spelling, "mei", "一次 ⌫ 删掉整个 you，不是字母 y")
  }

  func testToggleOffStillTakesOneLetterOff() throws {
    let document = Document()
    let controller = try makeKeyboard(document)
    TouchBackspaceSyllablePreference.isEnabled = false

    for letter in "MEIYOU" { try key(letter, in: controller).sendActions(for: .primaryActionTriggered) }
    XCTAssertEqual(document.spelling, "meiyou")

    try deleteKey(in: controller).sendActions(for: .touchUpInside)
    XCTAssertEqual(document.spelling, "meiyo", "开关关闭时照旧按字母删")
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
