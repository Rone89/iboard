import ObjectiveC
import UIKit
import XCTest

/// 英文输入辅助（双击空格自动句号 + 一键退格撤回、常见无歧义缩写撇号兜底、自动空格后标点回贴）测试。
@MainActor
final class EnglishTypingAssistTests: XCTestCase {
  func testContractionFallbackHandlesCommonContractionsAndSkipsAmbiguousWords() {
    XCTAssertEqual(EnglishTypingAssistPolicy.contractionFallback(for: "dont"), "don't")
    XCTAssertEqual(EnglishTypingAssistPolicy.contractionFallback(for: "Dont"), "Don't")
    XCTAssertEqual(EnglishTypingAssistPolicy.contractionFallback(for: "im"), "I'm")
    XCTAssertEqual(EnglishTypingAssistPolicy.contractionFallback(for: "ive"), "I've")
    XCTAssertEqual(EnglishTypingAssistPolicy.contractionFallback(for: "couldnt"), "couldn't")
    // 真实实词绝不误改。
    for ambiguous in ["its", "were", "well", "hell", "shell", "ill", "wed", "hello"] {
      XCTAssertNil(EnglishTypingAssistPolicy.contractionFallback(for: ambiguous), ambiguous)
    }
  }

  func testDoubleSpacePeriodConditionAndTrackerWindow() {
    XCTAssertTrue(EnglishTypingAssistPolicy.canConvertDoubleSpaceToPeriod(beforeCursor: "hello "))
    XCTAssertTrue(EnglishTypingAssistPolicy.canConvertDoubleSpaceToPeriod(beforeCursor: "test2 "))
    XCTAssertFalse(EnglishTypingAssistPolicy.canConvertDoubleSpaceToPeriod(beforeCursor: "hello"))
    XCTAssertFalse(EnglishTypingAssistPolicy.canConvertDoubleSpaceToPeriod(beforeCursor: "hello. "))
    XCTAssertFalse(EnglishTypingAssistPolicy.canConvertDoubleSpaceToPeriod(beforeCursor: "hello  "))
    XCTAssertFalse(EnglishTypingAssistPolicy.canConvertDoubleSpaceToPeriod(beforeCursor: " "))

    var tracker = EnglishTypingAssistTracker()
    let doc = UUID()
    tracker.recordSingleSpace(now: 10.0, document: doc, autoInserted: true)
    // 超出 0.45s 窗口不触发。
    XCTAssertFalse(tracker.shouldTriggerDoubleSpacePeriod(now: 10.6, beforeCursor: "hello ", document: doc))
    // 窗口内同文档触发。
    XCTAssertTrue(tracker.shouldTriggerDoubleSpacePeriod(now: 10.25, beforeCursor: "hello ", document: doc))

    // 记录句号后，紧接着退格可撤销回单空格；只生效一次。
    tracker.recordDoubleSpacePeriodApplied(document: doc)
    XCTAssertTrue(tracker.consumeDoubleSpacePeriodUndo(beforeCursor: "hello. ", document: doc))
    XCTAssertFalse(tracker.consumeDoubleSpacePeriodUndo(beforeCursor: "hello. ", document: doc))
  }

  func testAutoSpacePullbackForPunctuation() {
    var tracker = EnglishTypingAssistTracker()
    let doc = UUID()
    tracker.recordSingleSpace(now: 1.0, document: doc, autoInserted: true)
    XCTAssertTrue(tracker.consumeAutoSpacePullback(for: ",", beforeCursor: "hello ", document: doc))
    XCTAssertFalse(tracker.consumeAutoSpacePullback(for: ",", beforeCursor: "hello ", document: doc))

    // 手动输入的空格不触发标点回贴。
    tracker.recordSingleSpace(now: 2.0, document: doc, autoInserted: false)
    XCTAssertFalse(tracker.consumeAutoSpacePullback(for: ".", beforeCursor: "hello ", document: doc))
  }

  func testControllerDoubleSpacePeriodAndImmediateBackspaceRevert() throws {
    let document = FakeEnglishDocument(text: "hello")
    let controller = try makeEnglishKeyboard(document)
    let space = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "spaceKey" } as? UIButton)
    let delete = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "删除" } as? UIButton)

    // 第一次空格 -> "hello "，第二次快速空格 -> "hello. "
    space.sendActions(for: .primaryActionTriggered)
    XCTAssertEqual(document.text, "hello ")
    space.sendActions(for: .primaryActionTriggered)
    XCTAssertEqual(document.text, "hello. ")

    // 紧接着按一次退格一键还原回 "hello "
    delete.sendActions(for: .touchUpInside)
    XCTAssertEqual(document.text, "hello ")
  }

  func testControllerPullsPunctuationAcrossAutoInsertedSpace() throws {
    let document = FakeEnglishDocument(text: "hello")
    let controller = try makeEnglishKeyboard(document)
    let space = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "spaceKey" } as? UIButton)

    // 边界提交带出自动空格 -> "hello "
    space.sendActions(for: .primaryActionTriggered)
    XCTAssertEqual(document.text, "hello ")

    // 紧接着点常用标点 `,` 或 `.` 自动回贴消除多余前导空格
    let comma = try XCTUnwrap(descendants(controller.view).first {
      ($0 as? UIButton)?.accessibilityIdentifier == "quickPunctuationKey"
    } as? UIButton)
    comma.sendActions(for: .primaryActionTriggered)
    XCTAssertFalse(document.text.contains(" ,") || document.text.contains(" ."), "实际文本: \(document.text)")
  }

  // MARK: - 夹具

  private final class FakeEnglishDocument: NSObject, UITextDocumentProxy {
    var text: String
    var documentIdentifier = UUID()
    var keyboardType: UIKeyboardType = .default
    var autocorrectionType: UITextAutocorrectionType = .yes
    var autocapitalizationType: UITextAutocapitalizationType = .sentences
    var isSecureTextEntry: Bool = false

    init(text: String) { self.text = text }

    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { nil }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !text.isEmpty }

    func insertText(_ inserted: String) { text += inserted }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ marked: String, selectedRange: NSRange) {}
    func unmarkText() {}
  }

  private static let proxySelector = #selector(getter: UIInputViewController.textDocumentProxy)

  private func makeEnglishKeyboard(_ document: FakeEnglishDocument) throws -> KeyboardViewController {
    enableAllInputSchemes()
    let previousScheme = InputSchemePreference.scheme
    let previousSuggestions = EnglishSuggestionsPreference.isEnabled
    addTeardownBlock {
      InputSchemePreference.scheme = previousScheme
      EnglishSuggestionsPreference.isEnabled = previousSuggestions
    }
    InputSchemePreference.scheme = .quanpin
    EnglishSuggestionsPreference.isEnabled = true

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
    // 切换到英文模式。
    let lang = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "bottomLanguageKey" } as? UIButton)
    lang.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()
    return controller
  }

  private func descendants(_ root: UIView) -> [UIView] {
    root.subviews + root.subviews.flatMap(descendants)
  }
}
