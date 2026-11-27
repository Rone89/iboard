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
    let toggle = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "layoutToggleButton" } as? UIButton)
    let space = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "spaceKey" } as? UIButton)
    let quick = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "quickPunctuationKey" } as? UIButton)
    let period = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "bottomPeriodKey" } as? UIButton)
    let enter = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "returnKey" } as? UIButton)
    XCTAssertFalse(quick.isHidden)
    XCTAssertEqual(quick.configuration?.title, "/")
    XCTAssertNil(quick.menu)
    XCTAssertFalse(period.isHidden)
    XCTAssertEqual(period.configuration?.title, ".")
    assertOrderedNonOverlapping([toggle, space, quick, period, enter], in: controller.view)
    controller.viewDidDisappear(false)
  }

  @MainActor
  func testEmailContextLaysOutBottomRowWithoutCollapseOrOverlap() throws {
    let originalHideLanguageKey = KeyboardLayoutPreference.hideLanguageKey
    defer { KeyboardLayoutPreference.hideLanguageKey = originalHideLanguageKey }
    KeyboardLayoutPreference.hideLanguageKey = true

    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: KeyboardViewController.defaultKeyboardHeight)
    controller.view.layoutIfNeeded()

    controller.applyInputContext(keyboardType: .emailAddress, documentIdentifier: UUID())
    controller.view.layoutIfNeeded()

    let descendants = allSubviews(in: controller.view)
    let toggle = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "layoutToggleButton" } as? UIButton)
    let space = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "spaceKey" } as? UIButton)
    let quick = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "quickPunctuationKey" } as? UIButton)
    let period = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "bottomPeriodKey" } as? UIButton)
    let enter = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "returnKey" } as? UIButton)

    XCTAssertFalse(quick.isHidden)
    XCTAssertEqual(quick.configuration?.title, "@")
    XCTAssertFalse(period.isHidden)
    XCTAssertEqual(period.configuration?.title, ".")
    assertOrderedNonOverlapping([toggle, space, quick, period, enter], in: controller.view)
    XCTAssertGreaterThan(space.bounds.width, 100)

    // 切到 123 层时，独立 `.` 键必须隐藏且底行各键正常排布不重叠。
    toggle.sendActions(for: .touchUpInside)
    controller.view.layoutIfNeeded()
    XCTAssertTrue(period.isHidden)
    assertOrderedNonOverlapping([toggle, space, enter], in: controller.view)
    controller.viewDidDisappear(false)
  }

  func testTouchBottomRowLayoutUrlOrEmailContextPreservesTotalWeightAndLanguageOrder() {
    let english = TouchBottomRowLayout.englishTwentySixKey(globe: false, language: false)
    let adjustedEnglish = TouchBottomRowLayout.withUrlOrEmailContext(english, includeContextPunctuation: true)
    XCTAssertEqual(adjustedEnglish.map(\.slot), [.layer, .space, .comma, .period, .returnKey])
    XCTAssertEqual(adjustedEnglish.reduce(0) { $0 + $1.weight }, 10.0, accuracy: 0.001)

    for style in TouchTwentySixKeyStyle.allCases {
      let base = TouchBottomRowLayout.twentySixKey(style, globe: false, language: true)
      let adjusted = TouchBottomRowLayout.withUrlOrEmailContext(base, includeContextPunctuation: true)
      XCTAssertTrue(adjusted.contains(where: { $0.slot == .comma }), "\(style)")
      XCTAssertTrue(adjusted.contains(where: { $0.slot == .period }), "\(style)")
      XCTAssertEqual(adjusted.reduce(0) { $0 + $1.weight }, 10.0, accuracy: 0.001, "\(style)")
      let leftLang = TouchBottomRowLayout.languageBeforeSpace(adjusted)
      let languageIndex = leftLang.firstIndex(where: { $0.slot == .language })
      let spaceIndex = leftLang.firstIndex(where: { $0.slot == .space })
      XCTAssertNotNil(spaceIndex, "\(style)")
      XCTAssertNotNil(languageIndex, "\(style)")
      if let languageIndex, let spaceIndex {
        XCTAssertLessThan(languageIndex, spaceIndex, "\(style)")
      }
      XCTAssertEqual(leftLang.reduce(0) { $0 + $1.weight }, 10.0, accuracy: 0.001, "\(style)")
    }
  }

  @MainActor
  private func assertOrderedNonOverlapping(_ buttons: [UIButton], in root: UIView,
                                           file: StaticString = #filePath, line: UInt = #line) {
    var previousMaxX: CGFloat = -1
    for button in buttons {
      XCTAssertFalse(button.isHidden, "\(button.accessibilityIdentifier ?? "") 不应隐藏", file: file, line: line)
      let frame = button.convert(button.bounds, to: root)
      XCTAssertGreaterThan(frame.width, 20, "\(button.accessibilityIdentifier ?? "") 宽度异常: \(frame)", file: file, line: line)
      XCTAssertGreaterThan(frame.height, 20, "\(button.accessibilityIdentifier ?? "") 高度异常: \(frame)", file: file, line: line)
      if previousMaxX >= 0 {
        XCTAssertGreaterThanOrEqual(frame.minX, previousMaxX - 0.5,
                                    "\(button.accessibilityIdentifier ?? "") 与左侧按键重叠: \(frame) vs \(previousMaxX)",
                                    file: file, line: line)
      }
      previousMaxX = frame.maxX
    }
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
    let initialValue = button.accessibilityValue
    let initialImage = try XCTUnwrap(button.configuration?.image)
    XCTAssertNil(button.configuration?.title)
    button.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()
    let toggledValue = button.accessibilityValue
    let toggledImage = try XCTUnwrap(button.configuration?.image)
    XCTAssertNotEqual(initialValue, toggledValue)
    XCTAssertTrue(toggledValue == "英文输入" || initialValue == "英文输入")
    XCTAssertNotEqual(initialImage.pngData(), toggledImage.pngData())
    controller.viewDidDisappear(false)
  }

  func testQuickPasteToolbarPolicyHidesAfterHandledAndShowsOnNewCopy() throws {
    let suiteName = "QuickPasteToolbarPolicyTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertFalse(QuickPasteToolbarPolicy.shouldShow(changeCount: 0, hasStrings: true, hasImages: true, defaults: defaults))
    XCTAssertFalse(QuickPasteToolbarPolicy.shouldShow(changeCount: 3, hasStrings: false, hasImages: false, defaults: defaults))
    XCTAssertTrue(QuickPasteToolbarPolicy.shouldShow(changeCount: 3, hasStrings: true, hasImages: false, defaults: defaults))
    // 剪贴板含图片（无论是否附带文件名/链接字符串）一律不在键盘上提示一键粘贴。
    XCTAssertFalse(QuickPasteToolbarPolicy.shouldShow(changeCount: 3, hasStrings: false, hasImages: true, defaults: defaults))
    XCTAssertFalse(QuickPasteToolbarPolicy.shouldShow(changeCount: 3, hasStrings: true, hasImages: true, defaults: defaults))

    XCTAssertFalse(QuickPasteToolbarPolicy.isUnhandled(changeCount: 0, defaults: defaults))
    XCTAssertTrue(QuickPasteToolbarPolicy.isUnhandled(changeCount: 3, defaults: defaults))
    QuickPasteToolbarPolicy.markHandled(changeCount: 3, defaults: defaults)
    XCTAssertFalse(QuickPasteToolbarPolicy.isUnhandled(changeCount: 3, defaults: defaults))
    XCTAssertFalse(QuickPasteToolbarPolicy.shouldShow(changeCount: 3, hasStrings: true, hasImages: false, defaults: defaults))

    XCTAssertTrue(QuickPasteToolbarPolicy.shouldShow(changeCount: 4, hasStrings: true, hasImages: false, defaults: defaults))
    XCTAssertFalse(QuickPasteToolbarPolicy.shouldShow(changeCount: 4, hasStrings: false, hasImages: true, defaults: defaults))
    XCTAssertEqual(QuickPasteToolbarPolicy.truncatedTextPreview("你好世界"), "你好世界")
    XCTAssertEqual(QuickPasteToolbarPolicy.truncatedTextPreview("你好世界啊再"), "你好世界啊再")
    XCTAssertEqual(QuickPasteToolbarPolicy.truncatedTextPreview("你好世界啊再见"), "你好世界啊再…")
    XCTAssertEqual(QuickPasteToolbarPolicy.truncatedTextPreview("  第一行\n第二行内容 "), "第一行 第二…")
  }

  @MainActor
  func testQuickPasteToolbarButtonHasCompactIntrinsicSize() {
    let button = QuickPasteToolbarButton()
    button.apply(skin: .resolvedForTests(id: "native"))
    let baseSize = button.intrinsicContentSize
    XCTAssertGreaterThan(baseSize.width, 40)
    XCTAssertLessThan(baseSize.width, 70)
    XCTAssertEqual(baseSize.height, KeyboardToolbarButton.padSide)
    // 仅展示粘贴图标、内容预览与右侧关闭按钮，不再显示多余的「粘贴」文字标签。
    XCTAssertFalse(allSubviews(in: button).compactMap { $0 as? UILabel }.contains { $0.text == "粘贴" })

    var pastedCount = 0
    var dismissedCount = 0
    button.addAction(UIAction { _ in pastedCount += 1 }, for: .primaryActionTriggered)
    button.onDismiss = { dismissedCount += 1 }
    button.dismissButton.sendActions(for: .primaryActionTriggered)
    XCTAssertEqual(dismissedCount, 1)
    XCTAssertEqual(pastedCount, 0, "点击关闭按钮不能顺带触发粘贴")

    button.configure(preview: .text(preview: "你好世界啊再…", fullText: "你好世界啊再见"))
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
  func testCoreHapticsEngineProfilesAndCooldown() {
    // 跟随系统不走 CoreHaptics 脉冲表，交由原生 UIImpactFeedbackGenerator。
    XCTAssertTrue(KeyboardHapticsEngine.pulses(for: .system, event: .key(.standard)).isEmpty)

    // 轻/中/强三档普通键强度递增，强档使用双脉冲模拟机械段落。
    let lightStd = KeyboardHapticsEngine.pulses(for: .light, event: .key(.standard))
    let medStd = KeyboardHapticsEngine.pulses(for: .medium, event: .key(.standard))
    let strongStd = KeyboardHapticsEngine.pulses(for: .strong, event: .key(.standard))
    XCTAssertEqual(lightStd.count, 1)
    XCTAssertEqual(medStd.count, 1)
    XCTAssertEqual(strongStd.count, 2)
    XCTAssertLessThan(lightStd[0].intensity, medStd[0].intensity)
    XCTAssertLessThan(medStd[0].intensity, strongStd[0].intensity)

    // 空格/回车比字母键更沉稳（更低 sharpness、更高 intensity）。
    let medSpace = KeyboardHapticsEngine.pulses(for: .medium, event: .key(.space))
    XCTAssertGreaterThan(medSpace[0].intensity, medStd[0].intensity)
    XCTAssertLessThan(medSpace[0].sharpness, medStd[0].sharpness)

    // 12ms 防抖冷却门控。
    XCTAssertFalse(KeyboardHapticsEngine.allowsTrigger(now: 1.005, last: 1.000))
    XCTAssertTrue(KeyboardHapticsEngine.allowsTrigger(now: 1.015, last: 1.000))

    // 硬件不支持 CoreHaptics 时安全返回 false，预热也安全为空操作，交由调用方回退 UIImpactFeedbackGenerator。
    let unsupported = KeyboardHapticsEngine(supportsCoreHaptics: false)
    unsupported.warmUp(strength: .medium)
    XCTAssertFalse(unsupported.play(strength: .medium, event: .key(.standard), now: 10.0))
  }

  @MainActor
  func testBrandMarkButtonRendersAdaptiveCommandIconForLightDarkAndActive() throws {
    XCTAssertEqual(KeyboardBrandMarkButton.symbolName, "command")
    let button = KeyboardBrandMarkButton(frame: CGRect(x: 0, y: 0, width: 42, height: 42))
    button.traitOverrides.userInterfaceStyle = .light
    button.updateTraitsIfNeeded()
    button.apply(skin: .resolvedForTests(id: GlobalThemeCatalog.nativeId))
    button.layoutIfNeeded()
    let lightImage = try XCTUnwrap(button.image(for: .normal))
    XCTAssertEqual(lightImage.size, CGSize(width: 42, height: 42))
    XCTAssertEqual(button.imageView?.accessibilityIdentifier, "keyboardBrandIcon")

    button.traitOverrides.userInterfaceStyle = .dark
    button.updateTraitsIfNeeded()
    button.apply(skin: .resolvedForTests(id: GlobalThemeCatalog.nativeId))
    let darkImage = try XCTUnwrap(button.image(for: .normal))
    XCTAssertNotEqual(lightImage.pngData(), darkImage.pngData(), "亮暗色 command 图标应随外观自适应着色")

    button.isActive = true
    let activeImage = try XCTUnwrap(button.image(for: .normal))
    XCTAssertNotEqual(darkImage.pngData(), activeImage.pngData(), "展开功能菜单激活态应绘制强调色与底托")
  }

  @MainActor
  func testNativeFirstCandidateChipUsesLiquidGlassCapsuleStroke() throws {
    let previousDoc = MetasequoiaInputSessionBridge.loadSharedPreferences()
    let previousFollows = CandidatePalette.defaults.object(forKey: CandidatePalette.followsDesktopKey)
    defer {
      if let previousDoc {
        _ = MetasequoiaInputSessionBridge.updateSharedPreferences { $0 = previousDoc }
      }
      CandidatePalette.defaults.set(previousFollows, forKey: CandidatePalette.followsDesktopKey)
      KeyboardTheme.reload(previousDoc)
    }
    XCTAssertTrue(GlobalThemePreference.save(GlobalThemeCatalog.nativeId))
    KeyboardTheme.reload(MetasequoiaInputSessionBridge.loadSharedPreferences())
    CandidatePalette.defaults.set(false, forKey: CandidatePalette.followsDesktopKey)

    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: KeyboardViewController.defaultKeyboardHeight)
    controller.viewWillAppear(false)
    controller.render(MetasequoiaInputSnapshot(
      isHandled: true, preedit: "nihao", candidates: ["你好", "你号"],
      candidateGlosses: ["", ""], candidateAnnotations: ["", ""],
      candidateSources: [0, 0], candidatePageCount: 1, editingText: "nihao", caretPosition: 5))
    controller.view.layoutIfNeeded()

    let first = try XCTUnwrap(allSubviews(in: controller.view).first {
      $0.accessibilityIdentifier == "candidate-1" && !$0.isHidden
    } as? UIButton)
    let second = try XCTUnwrap(allSubviews(in: controller.view).first {
      $0.accessibilityIdentifier == "candidate-2" && !$0.isHidden
    } as? UIButton)
    XCTAssertEqual(first.configuration?.background.cornerRadius, 15)
    XCTAssertEqual(first.configuration?.background.strokeWidth, 0.5)
    XCTAssertEqual(second.configuration?.background.strokeWidth, 0)
    controller.viewDidDisappear(false)
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
