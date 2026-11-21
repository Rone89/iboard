import XCTest

final class KeyboardKitParityEnhancementTests: XCTestCase {
  func testQuickPunctuationOptionsDeduplicatesPreservingOrder() {
    XCTAssertEqual(
      KeyHoldCalloutPolicy.quickPunctuationOptions(symbols: ["，", "。", "，", "？", "", "！"]),
      ["，", "。", "？", "！"]
    )
  }

  func testPeriodOptionsByKeyboardType() {
    XCTAssertEqual(
      KeyHoldCalloutPolicy.periodOptions(keyboardType: .URL, handwriting: false),
      [".com", ".cn", ".net", ".org", ".edu"]
    )
    XCTAssertEqual(
      KeyHoldCalloutPolicy.periodOptions(keyboardType: .emailAddress, handwriting: false),
      [".com", ".cn", ".net", ".org", "@"]
    )
    XCTAssertTrue(KeyHoldCalloutPolicy.periodOptions(keyboardType: .URL, handwriting: true).isEmpty)
    XCTAssertTrue(KeyHoldCalloutPolicy.periodOptions(keyboardType: .default, handwriting: false).isEmpty)
    XCTAssertTrue(KeyHoldCalloutPolicy.commitsDirectText(".com"))
    XCTAssertFalse(KeyHoldCalloutPolicy.commitsDirectText("。"))
  }

  func testSymbolLayerOptionsCoverNumericCurrencyAndDashVariants() {
    XCTAssertEqual(KeyHoldCalloutPolicy.symbolLayerOptions(for: "0", chinese: true), ["0", "°"])
    XCTAssertEqual(KeyHoldCalloutPolicy.symbolLayerOptions(for: "-", chinese: true), ["-", "—", "–", "•"])
    XCTAssertEqual(KeyHoldCalloutPolicy.symbolLayerOptions(for: "/", chinese: false), ["/", "\\"])
    XCTAssertEqual(KeyHoldCalloutPolicy.symbolLayerOptions(for: "$", chinese: false), ["$", "￥", "€", "£", "¥"])
    XCTAssertTrue(KeyHoldCalloutPolicy.symbolLayerOptions(for: "#", chinese: false).isEmpty)
  }

  func testReturnKeyStylePolicyDistinguishesNativeDefaultFromActionOrConfirm() {
    XCTAssertFalse(ReturnKeyStylePolicy.usesActionAccent(isNativeSkin: true, confirmsComposition: false, returnKeyType: .default))
    XCTAssertTrue(ReturnKeyStylePolicy.usesActionAccent(isNativeSkin: true, confirmsComposition: true, returnKeyType: .default))
    XCTAssertTrue(ReturnKeyStylePolicy.usesActionAccent(isNativeSkin: true, confirmsComposition: false, returnKeyType: .search))
    XCTAssertTrue(ReturnKeyStylePolicy.usesActionAccent(isNativeSkin: true, confirmsComposition: false, returnKeyType: .send))
    XCTAssertTrue(ReturnKeyStylePolicy.usesActionAccent(isNativeSkin: false, confirmsComposition: false, returnKeyType: .default))
  }

  func testUrlAndEmailBottomPolicy() {
    XCTAssertEqual(KeyboardContextBottomPolicy.quickPunctuationFace(keyboardType: .URL, customQuickPunctuation: false), "/")
    XCTAssertEqual(KeyboardContextBottomPolicy.quickPunctuationFace(keyboardType: .emailAddress, customQuickPunctuation: false), "@")
    XCTAssertNil(KeyboardContextBottomPolicy.quickPunctuationFace(keyboardType: .URL, customQuickPunctuation: true))
    XCTAssertNil(KeyboardContextBottomPolicy.quickPunctuationFace(keyboardType: .default, customQuickPunctuation: false))
    XCTAssertTrue(KeyboardContextBottomPolicy.showsIndependentPeriodKey(keyboardType: .URL))
    XCTAssertTrue(KeyboardContextBottomPolicy.showsIndependentPeriodKey(keyboardType: .emailAddress))
    XCTAssertFalse(KeyboardContextBottomPolicy.showsIndependentPeriodKey(keyboardType: .default))
  }

  func testBackspaceRepeatPolicyAccelerationAndWordDeletion() {
    XCTAssertEqual(BackspaceRepeatPolicy.interval(forStep: 1), BackspaceRepeatPolicy.fastInterval)
    XCTAssertEqual(BackspaceRepeatPolicy.interval(forStep: 15), BackspaceRepeatPolicy.fastInterval)
    XCTAssertEqual(BackspaceRepeatPolicy.interval(forStep: 16), BackspaceRepeatPolicy.acceleratedInterval)

    XCTAssertFalse(BackspaceRepeatPolicy.deletesWord(step: 20, hasComposition: true, composesInPlace: false, isChineseMode: false, hasInk: false))
    XCTAssertFalse(BackspaceRepeatPolicy.deletesWord(step: 20, hasComposition: false, composesInPlace: false, isChineseMode: true, hasInk: false))
    XCTAssertFalse(BackspaceRepeatPolicy.deletesWord(step: 10, hasComposition: false, composesInPlace: false, isChineseMode: false, hasInk: false))
    XCTAssertTrue(BackspaceRepeatPolicy.deletesWord(step: 18, hasComposition: false, composesInPlace: false, isChineseMode: false, hasInk: false))

    XCTAssertEqual(BackspaceRepeatPolicy.wordDeleteCount(beforeCursor: nil), 1)
    XCTAssertEqual(BackspaceRepeatPolicy.wordDeleteCount(beforeCursor: ""), 1)
    XCTAssertEqual(BackspaceRepeatPolicy.wordDeleteCount(beforeCursor: "hello world"), 5)
    XCTAssertEqual(BackspaceRepeatPolicy.wordDeleteCount(beforeCursor: "hello world  "), 7)
    XCTAssertEqual(BackspaceRepeatPolicy.wordDeleteCount(beforeCursor: "don't"), 5)
    XCTAssertEqual(BackspaceRepeatPolicy.wordDeleteCount(beforeCursor: "hello\n"), 1)
  }

  @MainActor
  func testUrlContextExposesSlashAndPeriodOnPhoneBottomRow() throws {
    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: KeyboardViewController.defaultKeyboardHeight)
    controller.view.layoutIfNeeded()

    controller.applyInputContext(keyboardType: .URL, documentIdentifier: UUID())
    controller.view.layoutIfNeeded()

    let descendants = allSubviews(in: controller.view)
    let quick = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "quickPunctuationKey" } as? UIButton)
    let period = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "bottomPeriodKey" } as? UIButton)
    XCTAssertEqual(quick.configuration?.title, "/")
    XCTAssertNil(quick.menu)
    XCTAssertFalse(period.isHidden)
    XCTAssertEqual(period.configuration?.title, ".")
    controller.viewDidDisappear(false)
  }

  @MainActor
  func testToolbarButtonUsesCapsulePillOnNativeLiquidGlass() {
    let button = KeyboardToolbarButton(icon: .toolbarEmoji, accessibilityLabel: "表情")
    button.frame = CGRect(x: 0, y: 0, width: 42, height: 42)
    button.apply(skin: .resolvedForTests(id: GlobalThemeCatalog.nativeId))
    button.isActive = true
    button.setNeedsLayout()
    button.layoutIfNeeded()
    XCTAssertEqual(button.activePadCornerRadius, KeyboardToolbarButton.nativeGlassPadSide / 2)
    XCTAssertEqual(button.activePadBorderWidth, 0.5)
  }

  @MainActor
  func testToolbarLanguageShortcutTogglesChineseAndEnglish() throws {
    let previous = TouchToolbarLocalPreference.language
    defer { TouchToolbarLocalPreference.language = previous }
    TouchToolbarLocalPreference.language = true

    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: KeyboardViewController.defaultKeyboardHeight)
    controller.view.layoutIfNeeded()

    let button = try XCTUnwrap(allSubviews(in: controller.view).first { $0.accessibilityIdentifier == "languageShortcut" } as? UIButton)
    XCTAssertFalse(button.isHidden)
    XCTAssertEqual(
      button.configuration?.baseForegroundColor?.resolvedColor(with: controller.traitCollection),
      KeyboardTheme.current.secondary.resolvedColor(with: controller.traitCollection)
    )
    let initialTitle = button.configuration?.title
    button.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()
    let toggledTitle = button.configuration?.title
    XCTAssertNotEqual(initialTitle, toggledTitle)
    XCTAssertTrue(toggledTitle == "英" || initialTitle == "英")
    controller.viewDidDisappear(false)
  }

  func testQuickPasteToolbarPolicyHidesAfterHandledAndShowsOnNewCopy() throws {
    let suiteName = "QuickPasteToolbarPolicyTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertFalse(QuickPasteToolbarPolicy.shouldShow(changeCount: 0, hasStrings: true, hasImages: true, defaults: defaults))
    XCTAssertFalse(QuickPasteToolbarPolicy.shouldShow(changeCount: 3, hasStrings: false, hasImages: false, defaults: defaults))
    XCTAssertTrue(QuickPasteToolbarPolicy.shouldShow(changeCount: 3, hasStrings: true, hasImages: false, defaults: defaults))
    XCTAssertTrue(QuickPasteToolbarPolicy.shouldShow(changeCount: 3, hasStrings: false, hasImages: true, defaults: defaults))

    QuickPasteToolbarPolicy.markHandled(changeCount: 3, defaults: defaults)
    XCTAssertFalse(QuickPasteToolbarPolicy.shouldShow(changeCount: 3, hasStrings: true, hasImages: true, defaults: defaults))

    XCTAssertTrue(QuickPasteToolbarPolicy.shouldShow(changeCount: 4, hasStrings: false, hasImages: true, defaults: defaults))
    XCTAssertEqual(QuickPasteToolbarPolicy.truncatedTextPreview("你好世界"), "你好世界")
    XCTAssertEqual(QuickPasteToolbarPolicy.truncatedTextPreview("你好世界啊再见"), "你好世界啊…")
    XCTAssertEqual(QuickPasteToolbarPolicy.truncatedTextPreview("  第一行\n第二行内容 "), "第一行 第…")
  }

  @MainActor
  func testQuickPasteToolbarButtonHasCompactIntrinsicSize() {
    let button = QuickPasteToolbarButton()
    button.apply(skin: .resolvedForTests(id: "native"))
    let baseSize = button.intrinsicContentSize
    XCTAssertGreaterThan(baseSize.width, 40)
    XCTAssertLessThan(baseSize.width, 100)
    XCTAssertEqual(baseSize.height, KeyboardToolbarButton.padSide)

    button.configure(preview: .text(preview: "你好世界啊…", fullText: "你好世界啊再见"))
    XCTAssertGreaterThan(button.intrinsicContentSize.width, baseSize.width)

    let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
      UIColor.systemBlue.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    }
    button.configure(preview: .image(image))
    XCTAssertGreaterThan(button.intrinsicContentSize.width, baseSize.width)
  }

  @MainActor
  func testSystemLexiconStoreMatchesInputAndPreedit() {
    let store = SystemLexiconStore()
    store.setEntriesForTests([
      .init(userInput: "omw", documentText: "On my way!"),
      .init(userInput: "yx", documentText: "ray@example.com"),
      .init(userInput: "YX", documentText: "ray@example.com"),
    ])

    XCTAssertEqual(store.matches(forInput: "omw"), ["On my way!"])
    XCTAssertEqual(store.matches(forInput: "OMW"), ["On my way!"])
    XCTAssertEqual(store.matches(forInput: "yx", preedit: "y'x"), ["ray@example.com"])
    XCTAssertEqual(store.matches(forInput: "", preedit: "y'x"), ["ray@example.com"])
    XCTAssertEqual(store.matches(forInput: "abc"), [])
  }

  @MainActor
  private func allSubviews(in view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { allSubviews(in: $0) }
  }
}

private extension KeyboardTheme {
  static func resolvedForTests(id: String) -> KeyboardTheme {
    resolve(id, document: nil)
  }
}
