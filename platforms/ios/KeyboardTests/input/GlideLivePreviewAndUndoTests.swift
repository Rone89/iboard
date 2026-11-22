import ObjectiveC
import UIKit
import XCTest

/// 滑行实时候选预览（节流门控、只读原子会话预览、预览条渲染）与滑后退格一键撤整词测试。
@MainActor
final class GlideLivePreviewAndUndoTests: XCTestCase {
  private var storedGlide: Any?
  private var storedBilingual: Any?
  private var storedScheme = InputSchemePreference.scheme

  override func setUp() {
    super.setUp()
    enableAllInputSchemes()
    storedScheme = InputSchemePreference.scheme
    storedGlide = KeyboardLayoutPreference.defaults.object(forKey: KeyboardLayoutPreference.glideTypingKey)
    storedBilingual = KeyboardLayoutPreference.defaults.object(forKey: KeyboardLayoutPreference.bilingualGlideKey)
    KeyboardLayoutPreference.bilingualGlide = false
    InputSchemePreference.scheme = .quanpin
  }

  override func tearDown() {
    InputSchemePreference.scheme = storedScheme
    if let storedGlide { KeyboardLayoutPreference.defaults.set(storedGlide, forKey: KeyboardLayoutPreference.glideTypingKey) }
    else { KeyboardLayoutPreference.defaults.removeObject(forKey: KeyboardLayoutPreference.glideTypingKey) }
    if let storedBilingual { KeyboardLayoutPreference.defaults.set(storedBilingual, forKey: KeyboardLayoutPreference.bilingualGlideKey) }
    else { KeyboardLayoutPreference.defaults.removeObject(forKey: KeyboardLayoutPreference.bilingualGlideKey) }
    super.tearDown()
  }

  func testLivePreviewPolicyThrottlesAndSupportsDwellRefresh() {
    // 采样不足或路径太短不解码。
    XCTAssertFalse(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 3, pathLength: 40, deltaFromLast: 40, now: 1.0, lastDecodeTime: -.infinity, inFlight: false))
    XCTAssertFalse(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 5, pathLength: 12, deltaFromLast: 12, now: 1.0, lastDecodeTime: -.infinity, inFlight: false))
    // 已有在途异步解码时不叠加请求。
    XCTAssertFalse(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 6, pathLength: 60, deltaFromLast: 30, now: 1.0, lastDecodeTime: -.infinity, inFlight: true))
    // 首次满足门槛立刻放行。
    XCTAssertTrue(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 4, pathLength: 28, deltaFromLast: 28, now: 1.0, lastDecodeTime: -.infinity, inFlight: false))
    // 间隔不足 85ms 拒绝。
    XCTAssertFalse(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 8, pathLength: 60, deltaFromLast: 25, now: 1.05, lastDecodeTime: 1.0, inFlight: false))
    // 超过 85ms 且位移达标放行。
    XCTAssertTrue(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 8, pathLength: 60, deltaFromLast: 18, now: 1.10, lastDecodeTime: 1.0, inFlight: false))
    // 位移不足但尾键停顿超过 180ms 仍允许补刷新一次。
    XCTAssertFalse(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 8, pathLength: 60, deltaFromLast: 4, now: 1.10, lastDecodeTime: 1.0, inFlight: false))
    XCTAssertTrue(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 8, pathLength: 60, deltaFromLast: 4, now: 1.20, lastDecodeTime: 1.0, inFlight: false))
  }

  func testKeyPathPreviewDeduplicatesVisitedLetters() {
    let frames = Self.syntheticFrames
    let samples = Self.stroke("nihao", in: frames)
    let path = GlideLivePreviewPolicy.keyPathPreview(samples: samples, frames: frames)
    XCTAssertTrue(path.hasPrefix("n"))
    XCTAssertTrue(path.hasSuffix("o"))
    XCTAssertFalse(path.contains("nn"))
  }

  func testGlideUndoTrackerHandlesPreCommitAndPostCommitBoundaries() {
    var tracker = GlideUndoTracker()
    let docA = UUID()
    let docB = UUID()

    // 刚滑行解出的组字，退格一次消费整段。
    tracker.markGlideDecoded()
    XCTAssertTrue(tracker.consumeActiveGlideComposition())
    XCTAssertFalse(tracker.consumeActiveGlideComposition())

    // 滑行组字整词上屏（长度 >= 2），紧接着退格返回整词。
    tracker.markGlideDecoded()
    tracker.recordCommittedIfFromGlide(text: "你好", stillComposing: false, document: docA)
    XCTAssertEqual(tracker.consumeCommittedUndo(beforeCursor: "前言你好", document: docA), "你好")
    XCTAssertNil(tracker.consumeCommittedUndo(beforeCursor: "前言你好", document: docA), "一次消费后即清空")

    // 文档切换或光标前后缀不匹配时不误删。
    tracker.markGlideDecoded()
    tracker.recordCommittedIfFromGlide(text: "你好", stillComposing: false, document: docA)
    XCTAssertNil(tracker.consumeCommittedUndo(beforeCursor: "前言你好", document: docB))

    tracker.markGlideDecoded()
    tracker.recordCommittedIfFromGlide(text: "你好", stillComposing: false, document: docA)
    XCTAssertNil(tracker.consumeCommittedUndo(beforeCursor: "其他文字", document: docA))

    // 单字不进入整词撤回，部分选词不进入整词撤回。
    tracker.markGlideDecoded()
    tracker.recordCommittedIfFromGlide(text: "你", stillComposing: false, document: docA)
    XCTAssertNil(tracker.lastCommittedGlide)

    tracker.markGlideDecoded()
    tracker.recordCommittedIfFromGlide(text: "你好", stillComposing: true, document: docA)
    XCTAssertNil(tracker.lastCommittedGlide)
  }

  func testAtomicSessionPreviewReturnsCandidatesAndLeavesSessionClean() throws {
    let state = FileManager.default.temporaryDirectory
      .appendingPathComponent("msime-glide-preview-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let bridge = MetasequoiaInputSessionBridge(stateRoot: state)
    _ = bridge.switch(toShuangpin: false)

    let request = try XCTUnwrap(GlideTyping.request(frames: Self.syntheticFrames, samples: Self.stroke("nihao", in: Self.syntheticFrames)))
    let expectation = expectation(description: "atomic glide preview")
    var result: MetasequoiaGlidePreview?
    bridge.previewGlideAsync(request) { preview in
      result = preview
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 5)

    let preview = try XCTUnwrap(result)
    XCTAssertFalse(preview.reading.isEmpty)
    XCTAssertFalse(preview.candidates.isEmpty)
    // 原子预览结束后会话必须已被干净取消，不能残留组字。
    let current = bridge.handleBackspace()
    XCTAssertFalse(current.isHandled)
    XCTAssertTrue(current.preedit.isEmpty)
    XCTAssertTrue(current.editingText.isEmpty)
  }

  func testGlidePreviewBarDisplaysAndClearsCleanly() {
    let bar = GlideLivePreviewBar(frame: CGRect(x: 0, y: 0, width: 390, height: 42))
    XCTAssertTrue(bar.isHidden)
    bar.update(MetasequoiaGlidePreview(reading: "ni'hao", candidates: ["你好", "你号", "尼豪"]))
    XCTAssertFalse(bar.isHidden)
    XCTAssertEqual(bar.currentPreview?.candidates.first, "你好")
    bar.clear()
    XCTAssertTrue(bar.isHidden)
    XCTAssertNil(bar.currentPreview)
  }

  /// 滑行实时预览条展示时必须同步隐藏底层工具栏（含未粘贴胶囊与快捷按钮）和候选区，避免原生液态玻璃透明底板上两层文字叠画；滑行结束后恢复。
  func testGlideLivePreviewHidesShortcutBarWhileVisible() throws {
    let document = FakeDocument(text: "")
    let controller = try makeKeyboard(document)
    let glide = try XCTUnwrap(descendants(controller.view)
      .compactMap { ($0 as? KeyAreaStackView)?.gestureRecognizers?.first { $0 is GlideTypingGestureRecognizer } as? GlideTypingGestureRecognizer }
      .first)
    let previewBar = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "glideLivePreviewBar" })
    let moreShortcut = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "moreShortcut" })
    let shortcutBar = try XCTUnwrap(moreShortcut.superview)
    let quickPaste = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "quickPasteShortcut" })
    let preeditButton = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "preeditButton" })
    let readingRow = try XCTUnwrap(preeditButton.superview)

    // 1. 空闲态（即使存在未粘贴胶囊）：展示滑行实时预览条时工具栏必须整体隐藏，清空后恢复。
    quickPaste.isHidden = false
    XCTAssertTrue(previewBar.isHidden)
    XCTAssertFalse(shortcutBar.isHidden)

    controller.setGlideLivePreview(MetasequoiaGlidePreview(reading: "m'y'j", candidates: ["每一句", "每一集", "没有吗"]))
    XCTAssertFalse(previewBar.isHidden)
    XCTAssertTrue(shortcutBar.isHidden, "实时预览条显示期间工具栏必须隐藏，避免与粘贴胶囊叠画")
    XCTAssertTrue(readingRow.isHidden)

    controller.setGlideLivePreview(nil)
    XCTAssertTrue(previewBar.isHidden)
    XCTAssertFalse(shortcutBar.isHidden, "结束滑行预览后应恢复空闲工具栏")

    // 2. 已有组字态：滑行实时预览条同样必须隐藏读音行与候选区，取消后恢复。
    let frames = glide.keyFrames()
    glide.onEnded(Self.stroke("ni", in: frames), frames)
    XCTAssertFalse(readingRow.isHidden)
    XCTAssertTrue(shortcutBar.isHidden)

    controller.setGlideLivePreview(MetasequoiaGlidePreview(reading: "hao", candidates: ["好"]))
    XCTAssertFalse(previewBar.isHidden)
    XCTAssertTrue(shortcutBar.isHidden)
    XCTAssertTrue(readingRow.isHidden, "实时预览条显示期间读音行必须隐藏，避免与预览文字叠画")

    controller.setGlideLivePreview(nil)
    XCTAssertTrue(previewBar.isHidden)
    XCTAssertFalse(readingRow.isHidden, "清空滑行预览后应恢复原有组字读音行")
    XCTAssertTrue(shortcutBar.isHidden)
  }

  func testSingleBackspaceAfterGlideClearsWholeCompositionAndUndoesCommittedWord() throws {
    let document = FakeDocument(text: "前言")
    let controller = try makeKeyboard(document)
    let glide = try XCTUnwrap(descendants(controller.view)
      .compactMap { ($0 as? KeyAreaStackView)?.gestureRecognizers?.first { $0 is GlideTypingGestureRecognizer } as? GlideTypingGestureRecognizer }
      .first)
    let frames = glide.keyFrames()
    let delete = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "删除" } as? UIButton)

    // 1. 滑行出组字后立刻轻点一次 ⌫：直接整段清空，不必按 5 次。
    glide.onEnded(Self.stroke("nihao", in: frames), frames)
    XCTAssertEqual(document.markedText.replacingOccurrences(of: "'", with: ""), "nihao")
    delete.sendActions(for: .touchUpInside)
    XCTAssertEqual(document.markedText, "", "滑后立即点一次退格应一次清掉整段滑行组字")
    XCTAssertEqual(document.text, "前言")

    // 2. 再次滑行并用空格上屏整词，然后紧接着轻点一次 ⌫：一次退掉整个上屏词，并露出撤销胶囊。
    glide.onEnded(Self.stroke("nihao", in: frames), frames)
    let space = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "spaceKey" } as? UIButton)
    space.sendActions(for: .primaryActionTriggered)
    let afterCommit = document.text
    XCTAssertTrue(afterCommit.hasPrefix("前言"))
    let committedWord = String(afterCommit.dropFirst("前言".count))
    XCTAssertGreaterThanOrEqual(committedWord.count, 2)

    delete.sendActions(for: .touchUpInside)
    XCTAssertEqual(document.text, "前言", "滑后上屏多字词紧接着按一次退格应一键撤整词")

    // 工具栏撤销胶囊可再一键恢复刚才撤掉的滑行整词。
    let undoButton = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "undoDeleteShortcut" } as? UIButton)
    XCTAssertFalse(undoButton.isHidden)
    undoButton.sendActions(for: .primaryActionTriggered)
    XCTAssertEqual(document.text, afterCommit)
  }

  // MARK: - 合成键盘与夹具

  private nonisolated static let syntheticFrames: [CGRect] = {
    let rows: [(String, CGFloat)] = [("qwertyuiop", 0), ("asdfghjkl", 0.5), ("zxcvbnm", 1.5)]
    var frames = [CGRect](repeating: .null, count: 26)
    for (row, (letters, indent)) in rows.enumerated() {
      for (column, letter) in letters.unicodeScalars.enumerated() {
        let index = Int(letter.value - UnicodeScalar("a").value)
        frames[index] = CGRect(x: (CGFloat(column) + indent) * 36, y: CGFloat(row) * 48, width: 30, height: 40)
      }
    }
    return frames
  }()

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

  private final class FakeDocument: NSObject, UITextDocumentProxy {
    var text: String
    private(set) var markedText = ""
    var documentIdentifier = UUID()
    var isSecureTextEntry: Bool = false

    init(text: String) { self.text = text }

    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { nil }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !text.isEmpty }

    func insertText(_ inserted: String) {
      markedText = ""
      text += inserted
    }
    func deleteBackward() {
      if !text.isEmpty { text.removeLast() }
    }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ marked: String, selectedRange: NSRange) { markedText = marked }
    func unmarkText() {
      if !markedText.isEmpty { text += markedText }
      markedText = ""
    }
  }

  private static let proxySelector = #selector(getter: UIInputViewController.textDocumentProxy)

  private func makeKeyboard(_ document: FakeDocument) throws -> KeyboardViewController {
    KeyboardLayoutPreference.glideTyping = true
    GlideEnginePreference.choice = .msime
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

  private func descendants(_ root: UIView) -> [UIView] {
    root.subviews + root.subviews.flatMap(descendants)
  }
}
