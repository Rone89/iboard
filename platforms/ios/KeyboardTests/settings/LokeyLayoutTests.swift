import UIKit
import XCTest

@MainActor
final class LokeyLayoutTests: XCTestCase {
  private var savedStyle = TouchKeyLayoutStyle.mirrored
  private var savedTwentySixDocValue: Any?
  private var savedNumberRowDocValue: Any?
  private var savedScheme = InputSchemePreference.scheme
  private var savedKeySpacing = KeyboardLayoutPreference.keySpacing
  private var savedRowSpacing = KeyboardLayoutPreference.rowSpacing
  private var savedHeightAdjustment = KeyboardLayoutPreference.heightAdjustment
  private var savedHideLanguage = KeyboardLayoutPreference.hideLanguageKey

  override func setUp() {
    super.setUp()
    savedStyle = TouchKeyLayoutStyle.mirrored
    let document = MetasequoiaInputSessionBridge.loadSharedPreferences()
    savedTwentySixDocValue = document?[TouchKeyLayoutStyle.twentySixKeyDocumentKey]
    savedNumberRowDocValue = document?[TouchKeyLayoutStyle.numberRowDocumentKey]
    savedScheme = InputSchemePreference.scheme
    savedKeySpacing = KeyboardLayoutPreference.keySpacing
    savedRowSpacing = KeyboardLayoutPreference.rowSpacing
    savedHeightAdjustment = KeyboardLayoutPreference.heightAdjustment
    savedHideLanguage = KeyboardLayoutPreference.hideLanguageKey
    KeyboardLayoutPreference.resetToDefaults()
    KeyboardLayoutPreference.hideLanguageKey = false
    InputSchemePreference.enabledSchemes = ChineseInputScheme.allCases
    InputSchemePreference.scheme = .quanpin
    _ = InputSchemePreference.update { selection in
      selection.enabled = ChineseInputScheme.allCases
      selection.scheme = .quanpin
    }
    _ = MetasequoiaInputSessionBridge.updateSharedPreferences { doc in
      doc[TouchKeyLayoutStyle.twentySixKeyDocumentKey] = TouchTwentySixKeyStyle.lokey.rawValue
      doc[TouchKeyLayoutStyle.numberRowDocumentKey] = false
    }
    TouchKeyLayoutStyle.mirrored = TouchKeyLayoutStyle(twentySixKey: .lokey)
  }

  override func tearDown() {
    _ = MetasequoiaInputSessionBridge.updateSharedPreferences { doc in
      doc[TouchKeyLayoutStyle.twentySixKeyDocumentKey] = savedTwentySixDocValue
      doc[TouchKeyLayoutStyle.numberRowDocumentKey] = savedNumberRowDocValue
    }
    TouchKeyLayoutStyle.mirrored = savedStyle
    InputSchemePreference.scheme = savedScheme
    KeyboardLayoutPreference.keySpacing = savedKeySpacing
    KeyboardLayoutPreference.rowSpacing = savedRowSpacing
    KeyboardLayoutPreference.heightAdjustment = savedHeightAdjustment
    KeyboardLayoutPreference.hideLanguageKey = savedHideLanguage
    super.tearDown()
  }

  // MARK: - 1. 屏幕分档与高度表（含 iOS 26 hostTopPadding 扣减）

  func testScreenProfileClassificationAndBaseHeightsMatchLokeySpec() {
    let mini = LokeyScreenProfile.resolve(containerWidth: 375, screenSize: CGSize(width: 375, height: 812), landscape: false)
    let compact = LokeyScreenProfile.resolve(containerWidth: 393, screenSize: CGSize(width: 393, height: 852), landscape: false)
    let maxP = LokeyScreenProfile.resolve(containerWidth: 430, screenSize: CGSize(width: 430, height: 932), landscape: false)
    let landscape = LokeyScreenProfile.resolve(containerWidth: 852, screenSize: CGSize(width: 852, height: 393), landscape: true)
    let duoCover = LokeyScreenProfile.resolve(containerWidth: 460, screenSize: CGSize(width: 460, height: 900), landscape: false)
    let duoPortrait = LokeyScreenProfile.resolve(containerWidth: 700, screenSize: CGSize(width: 700, height: 900), landscape: false)
    let duoLandscape = LokeyScreenProfile.resolve(containerWidth: 900, screenSize: CGSize(width: 900, height: 700), landscape: true)

    XCTAssertEqual(mini, .miniPortrait)
    XCTAssertEqual(compact, .compactPortrait)
    XCTAssertEqual(maxP, .maxPortrait)
    XCTAssertEqual(landscape, .landscape)
    XCTAssertEqual(duoCover, .duoCover)
    XCTAssertEqual(duoPortrait, .duoUnfoldedPortrait)
    XCTAssertEqual(duoLandscape, .duoUnfoldedLandscape)

    XCTAssertEqual(LokeyGridMetrics.forProfile(.miniPortrait).baseTotalHeight, 239.0, accuracy: 0.01)
    XCTAssertEqual(LokeyGridMetrics.forProfile(.compactPortrait).baseTotalHeight, 250.0, accuracy: 0.01)
    XCTAssertEqual(LokeyGridMetrics.forProfile(.maxPortrait).baseTotalHeight, 268.5, accuracy: 0.01)
    XCTAssertEqual(LokeyGridMetrics.forProfile(.landscape).baseTotalHeight, 197.5, accuracy: 0.01)
    XCTAssertEqual(LokeyGridMetrics.forProfile(.duoUnfoldedPortrait).baseTotalHeight, 300.0, accuracy: 0.01)
    XCTAssertEqual(LokeyGridMetrics.forProfile(.duoUnfoldedLandscape).baseTotalHeight, 265.0, accuracy: 0.01)

    // 折叠屏宽横屏超过 860pt 时把键区限宽至 781pt 并居中。
    let wideDuo = LokeyGridMetrics.forProfile(.duoUnfoldedLandscape, containerWidth: 900)
    XCTAssertEqual(wideDuo.horizontalMargin, (900 - 781) * 0.5, accuracy: 0.01)
  }

  func testHostTopPaddingDeductionClampsAtSeventeenAndPreservesFloor() {
    let maxMetrics = LokeyGridMetrics.forProfile(.maxPortrait)
    let standardTop = KeyboardViewController.topRowHeight(glossLines: 0)

    XCTAssertEqual(
      LokeyLayoutMetrics.keyboardHeight(topRow: standardTop, standardTopRow: standardTop, rows: 4, metrics: maxMetrics, hostTopPadding: 0),
      268.5, accuracy: 0.01)
    XCTAssertEqual(
      LokeyLayoutMetrics.keyboardHeight(topRow: standardTop, standardTopRow: standardTop, rows: 4, metrics: maxMetrics, hostTopPadding: 10),
      258.5, accuracy: 0.01)
    // 超出顶栏可扣减余量（44 - 31 = 13pt）时按实际顶栏缩减量 13pt 扣减总高，绝不压扁 4 排 45pt 键帽。
    XCTAssertEqual(
      LokeyLayoutMetrics.keyboardHeight(topRow: standardTop, standardTopRow: standardTop, rows: 4, metrics: maxMetrics, hostTopPadding: 17),
      255.5, accuracy: 0.01)
    XCTAssertEqual(
      LokeyLayoutMetrics.keyboardHeight(topRow: standardTop, standardTopRow: standardTop, rows: 4, metrics: maxMetrics, hostTopPadding: 25),
      255.5, accuracy: 0.01)
    // 顶栏扣减后保底 31pt。
    XCTAssertEqual(
      LokeyLayoutMetrics.effectiveTopRowHeight(baseTopRow: standardTop, standardTopRow: standardTop, metrics: maxMetrics, hostTopPadding: 17),
      31.0, accuracy: 0.01)
    // 横屏不扣减 hostTopPadding。
    let landscapeMetrics = LokeyGridMetrics.forProfile(.landscape)
    XCTAssertEqual(
      LokeyLayoutMetrics.keyboardHeight(topRow: standardTop, standardTopRow: standardTop, rows: 4, metrics: landscapeMetrics, hostTopPadding: 14),
      197.5, accuracy: 0.01)
  }

  // MARK: - 2. 26 键几何与底行对称度量

  func testProMaxMetricsMatchLokeyGeometry() {
    let metrics = LokeyGridMetrics.forProfile(.maxPortrait)
    XCTAssertEqual(metrics.horizontalMargin, 6.5, accuracy: 0.001)
    XCTAssertEqual(metrics.horizontalGap, 6.25, accuracy: 0.001)
    XCTAssertEqual(metrics.verticalGap, 11.0, accuracy: 0.001)
    XCTAssertEqual(metrics.topGap, 4.5, accuracy: 0.001)
    XCTAssertEqual(metrics.bottomInset, 7.0, accuracy: 0.001)
    XCTAssertEqual(metrics.cornerRadius, 9.0, accuracy: 0.001)
    XCTAssertEqual(metrics.keyHeight, 45.0, accuracy: 0.01)

    let keysWidth: CGFloat = 430 - 2 * metrics.horizontalMargin // 417
    let (keyW, _) = LokeyLayoutMetrics.letterKeyMetrics(keysWidth: keysWidth, keySpacing: metrics.horizontalGap)
    XCTAssertEqual(keyW, 36.075, accuracy: 0.001)

    let third = LokeyLayoutMetrics.thirdRowEdgeLayout(keysWidth: keysWidth, keySpacing: metrics.horizontalGap)
    XCTAssertEqual(third.width, 36.075 * 1.348, accuracy: 0.01)
    XCTAssertEqual(third.gap, 14.86, accuracy: 0.05)

    // 无地球键时左右严格对称：123 + hGap + 中/英 == 换行。
    let bottomNoGlobe = LokeyLayoutMetrics.bottomRowWidths(
      keysWidth: keysWidth, keySpacing: metrics.horizontalGap, globe: false, profile: .maxPortrait)
    XCTAssertEqual(bottomNoGlobe.returnWidth, 99.5625, accuracy: 0.01)
    XCTAssertEqual(bottomNoGlobe.layerWidth + metrics.horizontalGap + bottomNoGlobe.languageWidth,
                   bottomNoGlobe.returnWidth, accuracy: 0.01)

    // 带地球键时左三键与单颗字母同宽。
    let bottomGlobe = LokeyLayoutMetrics.bottomRowWidths(
      keysWidth: keysWidth, keySpacing: metrics.horizontalGap, globe: true, profile: .maxPortrait)
    XCTAssertEqual(bottomGlobe.layerWidth, keyW, accuracy: 0.01)
    XCTAssertEqual(bottomGlobe.globeWidth, keyW, accuracy: 0.01)
    XCTAssertEqual(bottomGlobe.languageWidth, keyW, accuracy: 0.01)
  }

  // MARK: - 3. 123 / #+= 符号层键表

  func testLokeySymbolLayerTablesHaveSixPunctuationsAndFullwidthBrackets() {
    let zh123 = SymbolLayerLayout.characterRows(more: false, chinese: true, lokey: true)
    XCTAssertEqual(zh123[0], ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
    XCTAssertEqual(zh123[2], ["。", "，", "、", "？", "！", "."])
    // 中文 123 第 6 标点半角 `.` 按字面输出，不被引擎翻成全角 `。`。
    XCTAssertEqual(SymbolLayerLayout.input(for: ".", chinese: true, chinesePunctuation: true), .literal("."))

    let zhMore = SymbolLayerLayout.characterRows(more: true, chinese: true, lokey: true)
    XCTAssertEqual(Array(zhMore[0].prefix(4)), ["【", "】", "｛", "｝"])
    XCTAssertEqual(zhMore[2], ["…", "，", "、", "？", "！", "’"])

    let en123 = SymbolLayerLayout.characterRows(more: false, chinese: false, lokey: true)
    XCTAssertEqual(en123[2], [".", ",", "?", "!", "'", "-"])
    let enMore = SymbolLayerLayout.characterRows(more: true, chinese: false, lokey: true)
    XCTAssertEqual(enMore[2], [".", ",", "?", "!", "'", "`"])
  }

  // MARK: - 4. 组字态/空闲态边缘防误触与顶排防吞直通策略

  func testEdgeRemapPolicyDifferentiatesComposingAndIdleThresholds() {
    // 构造 430pt Pro Max 下的模拟布局矩形
    let keyA = CGRect(x: 27.66, y: 104.5, width: 36.075, height: 45)
    let keyL = CGRect(x: 366.26, y: 104.5, width: 36.075, height: 45)
    let keyShift = CGRect(x: 6.5, y: 160.5, width: 48.63, height: 45)
    let keyDelete = CGRect(x: 374.87, y: 160.5, width: 48.63, height: 45)
    let bottomLetters = (0..<7).map { i in
      CGRect(x: 70.0 + CGFloat(i) * 42.325, y: 160.5, width: 36.075, height: 45)
    }
    let frames = LokeyEdgeRemapPolicy.LayoutFrames(
      keyA: keyA, keyL: keyL, keyShift: keyShift, keyDelete: keyDelete, bottomLetters: bottomLetters)

    // 1) Shift 右侧 15pt（距 Z 左沿 15pt）：组字态（阈值 18pt）判给 Z，空闲态（阈值 11pt）保持 Shift。
    let nearShiftRight = CGPoint(x: bottomLetters[0].minX - 15.0, y: 185)
    XCTAssertEqual(LokeyEdgeRemapPolicy.remap(point: nearShiftRight, initial: .shift, isComposing: true, frames: frames), .bottomLetter(0))
    XCTAssertNil(LokeyEdgeRemapPolicy.remap(point: nearShiftRight, initial: .shift, isComposing: false, frames: frames))

    // 2) Shift 上沿（距 A 底沿 14pt）：组字态（阈值 16pt）判给 A，空闲态（阈值 10.5pt）保持 Shift。
    let nearShiftTop = CGPoint(x: keyA.minX, y: keyA.maxY + 14.0)
    XCTAssertEqual(LokeyEdgeRemapPolicy.remap(point: nearShiftTop, initial: .shift, isComposing: true, frames: frames), .keyA)
    XCTAssertNil(LokeyEdgeRemapPolicy.remap(point: nearShiftTop, initial: .shift, isComposing: false, frames: frames))

    // 3) ⌫ 键帽内部点按绝不重映射。
    let insideDelete = CGPoint(x: keyDelete.midX, y: keyDelete.midY)
    XCTAssertNil(LokeyEdgeRemapPolicy.remap(point: insideDelete, initial: .delete, isComposing: true, frames: frames))

    // 4) ⌫ 左侧外部空隙（距 M 右沿 10pt）：组字态（12pt）判给 M，空闲态（8.5pt）保持 ⌫。
    let nearDeleteLeft = CGPoint(x: bottomLetters[6].maxX + 10.0, y: 185)
    XCTAssertEqual(LokeyEdgeRemapPolicy.remap(point: nearDeleteLeft, initial: .delete, isComposing: true, frames: frames), .bottomLetter(6))
    XCTAssertNil(LokeyEdgeRemapPolicy.remap(point: nearDeleteLeft, initial: .delete, isComposing: false, frames: frames))

    // 5) ⌫ 上方外部空隙（距 L 底沿 10pt，x 在 L 中心偏左）：组字态（11pt）判给 L，空闲态（8.5pt）保持 ⌫。
    let nearDeleteTop = CGPoint(x: keyL.midX, y: keyL.maxY + 10.0)
    XCTAssertEqual(LokeyEdgeRemapPolicy.remap(point: nearDeleteTop, initial: .delete, isComposing: true, frames: frames), .keyL)
    XCTAssertNil(LokeyEdgeRemapPolicy.remap(point: nearDeleteTop, initial: .delete, isComposing: false, frames: frames))

    // 6) 底排空格键上沿（距 Z..M 底沿 12.5pt）：组字态（13.5pt）重映射到最近字母 B，空闲态（10.5pt）保持空格。
    let bFrame = bottomLetters[4]
    let nearSpaceTop = CGPoint(x: bFrame.midX, y: bFrame.maxY + 12.5)
    XCTAssertEqual(LokeyEdgeRemapPolicy.remap(point: nearSpaceTop, initial: .bottomRow(.space), isComposing: true, frames: frames), .bottomLetter(4))
    XCTAssertNil(LokeyEdgeRemapPolicy.remap(point: nearSpaceTop, initial: .bottomRow(.space), isComposing: false, frames: frames))

    // 7) 底排 123/换行在 Z..M 横向范围外（如最左端 x=20）绝不重映射。
    let farLeftLayer = CGPoint(x: 20, y: bottomLetters[0].maxY + 12.0)
    XCTAssertNil(LokeyEdgeRemapPolicy.remap(point: farLeftLayer, initial: .bottomRow(.layer), isComposing: true, frames: frames))
  }

  func testTopRowPassThroughRoutesSeamAndEmptyBarToTopLettersWithoutStealingControls() {
    let topRowFrames = (0..<10).map { i in
      CGRect(x: 6.5 + CGFloat(i) * 42.325, y: 48.5, width: 36.075, height: 45)
    }
    let topBarFrame = CGRect(x: 6.5, y: 0, width: 417, height: 44)

    // 1) 落在顶栏与第一排之间的 4.5pt 缝隙：直通水平最近的字母（如 E，index 2）。
    let inGap = CGPoint(x: topRowFrames[2].midX, y: 46.0)
    XCTAssertEqual(
      LokeyTopRowPassThroughPolicy.targetTopRowIndex(
        point: inGap, topRowFrames: topRowFrames, topBarFrame: topBarFrame,
        hitInteractiveControl: false, hitScrollableCandidateStrip: false),
      2)

    // 2) 落在候选滚动条底沿 10pt 内非按钮处：直通最近的字母（如 T，index 4）。
    let inBottomSeam = CGPoint(x: topRowFrames[4].midX, y: 39.0)
    XCTAssertEqual(
      LokeyTopRowPassThroughPolicy.targetTopRowIndex(
        point: inBottomSeam, topRowFrames: topRowFrames, topBarFrame: topBarFrame,
        hitInteractiveControl: false, hitScrollableCandidateStrip: true),
      4)

    // 3) 落在候选滚动条中上部（高于底沿 10pt）：不抢夺，保留滑动候选词手势。
    let inScrollMiddle = CGPoint(x: topRowFrames[4].midX, y: 20.0)
    XCTAssertNil(
      LokeyTopRowPassThroughPolicy.targetTopRowIndex(
        point: inScrollMiddle, topRowFrames: topRowFrames, topBarFrame: topBarFrame,
        hitInteractiveControl: false, hitScrollableCandidateStrip: true))

    // 4) 命中交互控件（工具栏按钮 / 候选按钮）：绝不抢夺。
    XCTAssertNil(
      LokeyTopRowPassThroughPolicy.targetTopRowIndex(
        point: inBottomSeam, topRowFrames: topRowFrames, topBarFrame: topBarFrame,
        hitInteractiveControl: true, hitScrollableCandidateStrip: false))
  }

  // MARK: - 5. 真键盘视图集成验证

  @MainActor
  func testDefaultPhoneKeyboardRendersLokeyLayoutAndSymbolLayerAndHitRouting() throws {
    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    let expectedHeight = LokeyGridMetrics.forProfile(.maxPortrait).baseTotalHeight
    controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: expectedHeight)
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()

    let descendants = allSubviews(in: controller.view)
    let toggle = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "layoutToggleButton" } as? UIButton)
    let emoji = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "layerEmojiKey" } as? UIButton)
    let space = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "spaceKey" } as? UIButton)
    let enter = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "returnKey" } as? UIButton)
    let language = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "bottomLanguageKey" } as? UIButton)
    let shift = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "shiftButton" } as? UIButton)
    let delete = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "letterDeleteKey" } as? UIButton)
    let keyQ = try XCTUnwrap(descendants.first { ($0 as? UIButton)?.configuration?.title?.lowercased() == "q" } as? UIButton)
    let keyZ = try XCTUnwrap(descendants.first { ($0 as? UIButton)?.configuration?.title?.lowercased() == "z" } as? UIButton)
    let keyM = try XCTUnwrap(descendants.first { ($0 as? UIButton)?.configuration?.title?.lowercased() == "m" } as? UIButton)

    // 对称 4 键底行：123 | 中/英 | 空格 | 换行（隐藏底行表情键）
    XCTAssertFalse(language.isHidden, "iOS 原生 26 键底行应显示中/英键")
    XCTAssertTrue(emoji.isHidden, "iOS 原生 26 键底行不应显示表情键")
    let toggleFrame = toggle.convert(toggle.bounds, to: controller.view)
    let languageFrame = language.convert(language.bounds, to: controller.view)
    let enterFrame = enter.convert(enter.bounds, to: controller.view)
    if !controller.needsInputModeSwitchKey {
      let leftClusterWidth = languageFrame.maxX - toggleFrame.minX
      XCTAssertEqual(leftClusterWidth, enterFrame.width, accuracy: 1.0, "底行左侧 123+中/英 与右侧换行应严格对称")
      XCTAssertEqual(languageFrame.width, toggleFrame.width, accuracy: 0.5, "中/英键应与 123 等宽，不能被拉长挤扁空格")
    }
    XCTAssertGreaterThan(space.bounds.width, 190, "空格应占据底行中央剩余宽幅")
    // 中/英键的定宽约束必须为 required（1000），避免与隐藏 splitSpace 的 999 等宽约束打平
    let activeLanguageWidth = language.constraints.first { $0.isActive && $0.firstAttribute == .width && $0.secondItem == nil }
    XCTAssertEqual(activeLanguageWidth?.priority, .required, "iOS 原生中/英键定宽约束必须为 .required (1000)")

    // 9pt 连续圆角（对齐 iOS 原生键盘）& 第三排约 14.9pt 宽缓冲
    XCTAssertEqual(keyQ.configuration?.background.cornerRadius ?? 0, 9.0, accuracy: 0.01)
    let shiftFrame = shift.convert(shift.bounds, to: controller.view)
    let zFrame = keyZ.convert(keyZ.bounds, to: controller.view)
    let mFrame = keyM.convert(keyM.bounds, to: controller.view)
    let deleteFrame = delete.convert(delete.bounds, to: controller.view)
    XCTAssertEqual(zFrame.minX - shiftFrame.maxX, 14.86, accuracy: 0.6)
    XCTAssertEqual(deleteFrame.minX - mFrame.maxX, 14.86, accuracy: 0.6)

    // 顶栏与 Q 之间缝隙命中直通 Q
    let qFrame = keyQ.convert(keyQ.bounds, to: controller.view)
    let seamAboveQ = CGPoint(x: qFrame.midX, y: qFrame.minY - 2.0)
    let seamHit = controller.view.hitTest(seamAboveQ, with: nil)
    XCTAssertTrue(seamHit === keyQ, "顶栏与第一排缝隙应直通 Q 键")

    // 第三排边缘防误触实测：空闲态下距 Z 左沿 8pt（<=11pt）判给 Z、距 M 右沿 7pt（<=8.5pt）判给 M，⌫ 键帽内部直击保留 ⌫
    let nearZ = CGPoint(x: zFrame.minX - 8.0, y: zFrame.midY)
    XCTAssertTrue(controller.view.hitTest(nearZ, with: nil) === keyZ, "Shift↔Z 缓冲内靠近 Z 侧应优先判给 Z")
    let nearM = CGPoint(x: mFrame.maxX + 7.0, y: mFrame.midY)
    XCTAssertTrue(controller.view.hitTest(nearM, with: nil) === keyM, "M↔⌫ 缓冲内靠近 M 侧应优先判给 M")
    let insideDelete = CGPoint(x: deleteFrame.midX, y: deleteFrame.midY)
    XCTAssertTrue(controller.view.hitTest(insideDelete, with: nil) === delete, "⌫ 键帽内部点按绝不被重映射")

    // 切到 123 层：第 3 排显示 6 颗标点（含半角 `.`），底行保持对称 4 键
    toggle.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()
    let updatedDescendants = allSubviews(in: controller.view)
    let sixthPunct = try XCTUnwrap(updatedDescendants.first { $0.accessibilityIdentifier == "symbolLayerKey2_5" } as? UIButton)
    XCTAssertFalse(sixthPunct.isHidden)
    XCTAssertEqual(sixthPunct.configuration?.title, ".")
    XCTAssertFalse(language.isHidden)
    XCTAssertTrue(emoji.isHidden)

    // 再切到 #+= 层：首排前四键为全角 `【 】 ｛ ｝`
    let moreToggle = try XCTUnwrap(updatedDescendants.first { $0.accessibilityIdentifier == "symbolLayerToggle" } as? UIButton)
    moreToggle.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()
    let bracket0 = try XCTUnwrap(updatedDescendants.first { $0.accessibilityIdentifier == "symbolLayerKey0_0" } as? UIButton)
    let bracket2 = try XCTUnwrap(updatedDescendants.first { $0.accessibilityIdentifier == "symbolLayerKey0_2" } as? UIButton)
    XCTAssertEqual(bracket0.configuration?.title, "【")
    XCTAssertEqual(bracket2.configuration?.title, "｛")

    controller.viewDidDisappear(false)
  }

  @MainActor
  func testSwitchingBackToStandardStyleRestoresStandardRowAndSymbolLayer() throws {
    _ = MetasequoiaInputSessionBridge.updateSharedPreferences { doc in
      doc[TouchKeyLayoutStyle.twentySixKeyDocumentKey] = TouchTwentySixKeyStyle.standard.rawValue
    }
    TouchKeyLayoutStyle.mirrored = TouchKeyLayoutStyle(twentySixKey: .standard)

    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: KeyboardViewController.defaultKeyboardHeight)
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()

    let descendants = allSubviews(in: controller.view)
    let language = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "bottomLanguageKey" } as? UIButton)
    let comma = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "quickPunctuationKey" } as? UIButton)
    let toggle = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "layoutToggleButton" } as? UIButton)
    let keyQ = try XCTUnwrap(descendants.first { ($0 as? UIButton)?.configuration?.title?.lowercased() == "q" } as? UIButton)

    XCTAssertFalse(language.isHidden, "切回标准样式后应恢复中/英键")
    XCTAssertFalse(comma.isHidden, "切回标准样式后应恢复逗号键")
    XCTAssertEqual(keyQ.configuration?.background.cornerRadius ?? 0, SystemKeyboardTokens.cornerRadius, accuracy: 0.01)

    // 切回标准样式应恢复第 6 颗隐藏与 9pt 圆角
    toggle.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()
    let sixthPunct = try XCTUnwrap(allSubviews(in: controller.view).first { $0.accessibilityIdentifier == "symbolLayerKey2_5" } as? UIButton)
    XCTAssertTrue(sixthPunct.isHidden, "标准样式 123 第 3 排应恢复为 5 颗标点，隐藏第 6 颗")

    controller.viewDidDisappear(false)
  }

  @MainActor
  func testLokeyVisualStyleMatchesSpecInLightAndDarkAndHidesAllCornerHints() throws {
    let savedCornerHints = KeyboardLayoutPreference.letterCornerHints
    let savedTheme = GlobalThemePreference.selected
    let savedDocTheme = MetasequoiaInputSessionBridge.loadSharedPreferences()?["global_theme"]
    defer {
      KeyboardLayoutPreference.letterCornerHints = savedCornerHints
      _ = MetasequoiaInputSessionBridge.updateSharedPreferences { doc in
        doc["global_theme"] = savedDocTheme
      }
      GlobalThemePreference.mirror(["global_theme": savedTheme])
      KeyboardTheme.reload(MetasequoiaInputSessionBridge.loadSharedPreferences(), dark: false, force: true)
    }
    KeyboardLayoutPreference.letterCornerHints = true

    for themeId in [GlobalThemeCatalog.systemId, GlobalThemeCatalog.nativeId] {
      _ = MetasequoiaInputSessionBridge.updateSharedPreferences { doc in
        doc["global_theme"] = themeId
      }
      GlobalThemePreference.mirror(["global_theme": themeId])
      KeyboardTheme.reload(MetasequoiaInputSessionBridge.loadSharedPreferences(), dark: false, force: true)

      let controller = KeyboardViewController()
      let height = LokeyGridMetrics.forProfile(.maxPortrait).baseTotalHeight
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: height))
      window.overrideUserInterfaceStyle = .light
      window.rootViewController = controller
      controller.loadViewIfNeeded()
      window.isHidden = false
      defer { window.isHidden = true }
      controller.viewWillAppear(false)
      controller.viewIsAppearing(false)
      window.layoutIfNeeded()

      let descendants = allSubviews(in: controller.view)
      let keyQ = try XCTUnwrap(descendants.first { ($0 as? UIButton)?.configuration?.title?.lowercased() == "q" } as? KeyboardKeyButton)
      let toggle = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "layoutToggleButton" } as? KeyboardKeyButton)
      let language = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "bottomLanguageKey" } as? KeyboardKeyButton)
      let shift = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "shiftButton" } as? KeyboardKeyButton)
      let delete = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "letterDeleteKey" } as? KeyboardKeyButton)
      let enter = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "returnKey" } as? KeyboardKeyButton)

      // 1) 浅色模式：字母键、功能键（含中/英键）与默认换行统一纯白 #FFFFFF，扁平无阴影、无描边、7pt 连续圆角、无缩放按压
      for key in [keyQ, toggle, language, shift, delete, enter] {
        let bg = try XCTUnwrap(key.configuration?.background.backgroundColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        bg.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1.0, accuracy: 0.02, "\(themeId) light \(key.accessibilityIdentifier ?? "")")
        XCTAssertEqual(g, 1.0, accuracy: 0.02, "\(themeId) light \(key.accessibilityIdentifier ?? "")")
        XCTAssertEqual(b, 1.0, accuracy: 0.02, "\(themeId) light \(key.accessibilityIdentifier ?? "")")
        XCTAssertEqual(a, 1.0, accuracy: 0.02, "\(themeId) light \(key.accessibilityIdentifier ?? "")")
        XCTAssertEqual(key.layer.shadowOpacity, 0, "\(themeId) Lokey 键帽不应绘制底部阴影")
        XCTAssertEqual(key.configuration?.background.strokeWidth ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(key.configuration?.cornerStyle, .fixed, "\(themeId) 键帽圆角应固定为 .fixed，避免小字号 Dynamic Type 缩水")
        XCTAssertEqual(key.configuration?.background.cornerRadius ?? 0, 9.0, accuracy: 0.01)
        XCTAssertEqual(key.pressFeedback, .lokeyKey)
        XCTAssertTrue(key.usesLokeyPreviewStyle)
      }

      // 1b) 系统最小动态字号（.extraSmall）下真实 layer.cornerRadius 仍必须保持 9.0pt，不被 .dynamic 缩水
      window.traitOverrides.preferredContentSizeCategory = .extraSmall
      keyQ.setNeedsUpdateConfiguration()
      keyQ.updateConfiguration()
      window.layoutIfNeeded()
      XCTAssertEqual(keyQ.layer.cornerRadius, 9.0, accuracy: 0.01, "\(themeId) XS 动态字号下键帽真实圆角不能缩水")
      window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)

      // 2) 全部 26 个字母键不显示任何角标（包括顶排 Q–P）
      for ch in "qwertyuiopasdfghjklzxcvbnm" {
        let letterKey = try XCTUnwrap(descendants.first {
          ($0 as? UIButton)?.configuration?.title?.lowercased() == String(ch)
        } as? KeyboardKeyButton, "找不到字母键 \(ch)")
        XCTAssertNil(letterKey.cornerHint, "Lokey 样式下字母 \(ch) 不应携带角标")
        let cornerLabel = letterKey.subviews.first { $0.accessibilityIdentifier == "letterCornerHint" } as? UILabel
        XCTAssertTrue(cornerLabel?.isHidden ?? true, "Lokey 样式下字母 \(ch) 不应显示角标标签")
      }

      // 3) 切换深色模式：键帽统一透底 white 15.5%，激活 Shift 为实心纯白配黑色图标
      window.overrideUserInterfaceStyle = .dark
      controller.overrideUserInterfaceStyle = .dark
      KeyboardTheme.reload(MetasequoiaInputSessionBridge.loadSharedPreferences(), dark: true, force: true)
      controller.viewIsAppearing(false)
      window.layoutIfNeeded()

      for key in [keyQ, toggle, language, shift, delete, enter] {
        let bg = try XCTUnwrap(key.configuration?.background.backgroundColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        bg.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1.0, accuracy: 0.02, "\(themeId) dark \(key.accessibilityIdentifier ?? "")")
        XCTAssertEqual(a, 0.155, accuracy: 0.015, "\(themeId) dark alpha \(key.accessibilityIdentifier ?? "")")
        XCTAssertEqual(key.layer.shadowOpacity, 0)
      }

      // 点按 Shift 激活大写态：实心纯白 + 黑色图标
      shift.sendActions(for: .primaryActionTriggered)
      window.layoutIfNeeded()
      var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
      shift.configuration?.background.backgroundColor?.getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
      XCTAssertEqual(sr, 1.0, accuracy: 0.02)
      XCTAssertEqual(sa, 1.0, accuracy: 0.02)
      var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
      shift.configuration?.baseForegroundColor?.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
      XCTAssertEqual(fr, 0.0, accuracy: 0.02)
      XCTAssertEqual(fg, 0.0, accuracy: 0.02)
      XCTAssertEqual(fb, 0.0, accuracy: 0.02)

      controller.viewDidDisappear(false)
    }

    // 4) 气泡底座圆角与 Lokey 1.54× 放大几何
    let keyFrame = CGRect(x: 6.5, y: 60, width: 36.075, height: 45)
    let geom = KeyPressPreviewView.geometry(
      key: keyFrame, in: CGRect(x: 0, y: 0, width: 430, height: 268.5),
      wide: false, lokey: true)
    XCTAssertEqual(geom.head.width, 36.075 * 1.54, accuracy: 0.1)
    XCTAssertEqual(geom.head.height, 52.0, accuracy: 0.1)
    let calloutPath = KeyPressPreviewView.path(for: geom, bottomRadius: 9.0)
    XCTAssertFalse(calloutPath.isEmpty)
  }

  @MainActor
  func testLokeyBottomRowSpacingAndToolbarEmojiRestored() throws {
    XCTAssertEqual(TouchTwentySixKeyStyle.platformDefault, .lokey)
    XCTAssertEqual(TouchTwentySixKeyStyle.lokey.title, "iOS 原生")
    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    let expectedHeight = LokeyGridMetrics.forProfile(.maxPortrait).baseTotalHeight
    controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: expectedHeight)
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()

    let descendants = allSubviews(in: controller.view)
    let toggle = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "layoutToggleButton" } as? UIButton)
    let language = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "bottomLanguageKey" } as? UIButton)
    let actionRow = try XCTUnwrap(toggle.superview as? UIStackView)
    let toolbarEmoji = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "emojiShortcut" } as? UIButton)

    // 底行键距必须是 6.25pt，不再被 6.0pt 覆写
    XCTAssertEqual(actionRow.spacing, 6.25, accuracy: 0.01)
    if !controller.needsInputModeSwitchKey {
      let toggleFrame = toggle.convert(toggle.bounds, to: controller.view)
      let languageFrame = language.convert(language.bounds, to: controller.view)
      XCTAssertEqual(languageFrame.minX - toggleFrame.maxX, 6.25, accuracy: 0.5)
    }

    // 底行改为中/英键后，顶栏表情按钮按用户偏好正常显示（不再去重隐藏）
    let pinnedEmoji = TouchToolbarPreference(in: MetasequoiaInputSessionBridge.loadSharedPreferences()).emoji
    XCTAssertEqual(toolbarEmoji.isHidden, !pinnedEmoji, "iOS 原生 26 键底行展示中/英键，顶栏 ☺ 应按用户偏好显示")

    _ = MetasequoiaInputSessionBridge.updateSharedPreferences { doc in
      doc[TouchKeyLayoutStyle.twentySixKeyDocumentKey] = TouchTwentySixKeyStyle.standard.rawValue
    }
    TouchKeyLayoutStyle.mirrored = TouchKeyLayoutStyle(twentySixKey: .standard)
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()
    XCTAssertEqual(actionRow.spacing, 6.0, accuracy: 0.01)
    XCTAssertEqual(toolbarEmoji.isHidden, !pinnedEmoji, "切回标准样式后顶栏 ☺ 仍按用户偏好显示")

    controller.viewDidDisappear(false)
  }

  @MainActor
  func testLokeyEnglishContinuityAndLongPress123OpensSymbolPanel() throws {
    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    let expectedHeight = LokeyGridMetrics.forProfile(.maxPortrait).baseTotalHeight
    controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: expectedHeight)
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()

    let descendants = allSubviews(in: controller.view)
    let toggle = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "layoutToggleButton" } as? UIButton)
    let emoji = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "layerEmojiKey" } as? UIButton)
    let language = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "bottomLanguageKey" } as? UIButton)
    let enter = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "returnKey" } as? UIButton)
    let shift = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "shiftButton" } as? UIButton)
    let keyQ = try XCTUnwrap(descendants.first { ($0 as? UIButton)?.configuration?.title?.lowercased() == "q" } as? KeyboardKeyButton)
    let keyZ = try XCTUnwrap(descendants.first { ($0 as? UIButton)?.configuration?.title?.lowercased() == "z" } as? UIButton)
    let actionRow = try XCTUnwrap(toggle.superview as? UIStackView)

    XCTAssertNotEqual(enter.configuration?.title, "return")
    XCTAssertNotNil(enter.configuration?.image, "中文空闲态默认换行键展示回车图标")

    // 点按底行中/英键切换到英文模式
    XCTAssertEqual(language.configuration?.title, "中")
    language.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()

    XCTAssertEqual(language.configuration?.title, "英", "切换到英文模式后中/英键应显示「英」")
    XCTAssertEqual(enter.configuration?.title, "return", "点按中/英键应切换至英文模式")
    XCTAssertEqual(actionRow.spacing, 6.25, accuracy: 0.01, "英文 26 键应保持 6.25pt 键距不跳变")
    XCTAssertEqual(keyQ.configuration?.background.cornerRadius ?? 0, 9.0, accuracy: 0.01, "英文 26 键应保持 9pt 圆角")
    XCTAssertEqual(keyQ.layer.shadowOpacity, 0, "英文 26 键应保持无阴影")
    XCTAssertEqual(language.configuration?.background.cornerRadius ?? 0, 9.0, accuracy: 0.01, "切换后中/英键应保持 9pt 圆角")
    XCTAssertEqual(language.configuration?.cornerStyle, .fixed, "切换后中/英键应保持 .fixed 圆角")
    XCTAssertFalse(language.isHidden, "英文模式底行保持中/英键")
    XCTAssertTrue(emoji.isHidden, "英文模式底行不显示表情键")
    XCTAssertNil(keyQ.cornerHint, "英文模式同样不显示角标")
    let shiftFrame = shift.convert(shift.bounds, to: controller.view)
    let zFrame = keyZ.convert(keyZ.bounds, to: controller.view)
    XCTAssertEqual(zFrame.minX - shiftFrame.maxX, 14.86, accuracy: 0.6, "英文 Lokey 第三排应保持 14.86pt 缓冲")

    // 英文 123 符号层保持 6 颗标点（含第 6 颗 `-`）
    toggle.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()
    let sixthPunct = try XCTUnwrap(allSubviews(in: controller.view).first { $0.accessibilityIdentifier == "symbolLayerKey2_5" } as? UIButton)
    XCTAssertFalse(sixthPunct.isHidden)
    XCTAssertEqual(sixthPunct.configuration?.title, "-")
    toggle.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()

    // 再次点按中/英键切回中文模式
    language.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()
    XCTAssertEqual(language.configuration?.title, "中")
    XCTAssertNotEqual(enter.configuration?.title, "return", "再次点按中/英键应切回中文模式")
    XCTAssertNotNil(enter.configuration?.image, "切回中文模式后默认换行键恢复回车图标")

    // 长按 123 打开符号面板，不改变中英文状态
    let holdGesture = try XCTUnwrap(toggle.gestureRecognizers?.first { $0.name == "layoutToggleSymbolsHold" } as? UILongPressGestureRecognizer)
    let fakeHold = LokeyTestLongPressGestureRecognizer(state: .began)
    XCTAssertTrue(controller.gestureRecognizerShouldBegin(holdGesture))
    controller.perform(NSSelectorFromString("handleLayoutToggleHold:"), with: fakeHold)
    controller.view.layoutIfNeeded()
    XCTAssertEqual(language.configuration?.title, "中", "长按 123 打开符号面板，不应切换语言")
    XCTAssertTrue(allSubviews(in: controller.view).contains { $0 is KeyboardSymbolPanelView }, "长按 123 应打开符号面板")

    controller.viewDidDisappear(false)
  }

  @MainActor
  func testLokeyReturnKeyRespectsAutoEnableAndProMax440Metrics() {
    // 微信等启用 enablesReturnKeyAutomatically 的空输入框下，发送键不高亮刺眼蓝；输入文字或组字确认时再亮蓝。
    XCTAssertFalse(ReturnKeyStylePolicy.usesActionAccent(
      isNativeSkin: true, confirmsComposition: false, returnKeyType: .send,
      enablesReturnKeyAutomatically: true, hasText: false))
    XCTAssertTrue(ReturnKeyStylePolicy.usesActionAccent(
      isNativeSkin: true, confirmsComposition: false, returnKeyType: .send,
      enablesReturnKeyAutomatically: true, hasText: true))
    XCTAssertTrue(ReturnKeyStylePolicy.usesActionAccent(
      isNativeSkin: true, confirmsComposition: true, returnKeyType: .send,
      enablesReturnKeyAutomatically: true, hasText: false))

    // 440pt iPhone 18 Pro Max 实测几何对齐 Lokey 0.9.5 真机数据
    let profile = LokeyScreenProfile.resolve(containerWidth: 440, screenSize: CGSize(width: 440, height: 956), landscape: false)
    XCTAssertEqual(profile, .maxPortrait)
    let m = LokeyGridMetrics.forProfile(profile, containerWidth: 440)
    XCTAssertEqual(m.horizontalMargin, 6.5, accuracy: 0.01)
    XCTAssertEqual(m.horizontalGap, 6.25, accuracy: 0.01)
    XCTAssertEqual(m.verticalGap, 11.0, accuracy: 0.01)
    XCTAssertEqual(m.keyHeight, 45.0, accuracy: 0.01)
    XCTAssertEqual(m.baseTotalHeight, 268.5, accuracy: 0.01)
    let keysWidth = 440 - 2 * m.horizontalMargin
    let bottom = LokeyLayoutMetrics.bottomRowWidths(keysWidth: keysWidth, keySpacing: m.horizontalGap, globe: false, profile: profile)
    XCTAssertEqual(bottom.returnWidth, 102.06, accuracy: 0.05)
    XCTAssertEqual(bottom.layerWidth, 47.91, accuracy: 0.05)
    XCTAssertEqual(bottom.languageWidth, 47.91, accuracy: 0.05)
    let spaceWidth = keysWidth - bottom.layerWidth - bottom.languageWidth - bottom.returnWidth - 3 * m.horizontalGap
    XCTAssertEqual(spaceWidth, 210.38, accuracy: 0.05)
  }

  @MainActor
  func testLokeySymbolLayerSpacingFontsAndReturnKeyVisualTokens() throws {
    // 1) 验证 LokeyVisualStyle 禁用态与动作蓝精准对齐反汇编色值
    let dark = UITraitCollection(userInterfaceStyle: .dark)
    let light = UITraitCollection(userInterfaceStyle: .light)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0

    LokeyVisualStyle.disabledKeyFill.resolvedColor(with: dark).getRed(&r, green: &g, blue: &b, alpha: &a)
    XCTAssertEqual(r, 1.0, accuracy: 0.01)
    XCTAssertEqual(a, 0.10, accuracy: 0.005)
    LokeyVisualStyle.disabledKeyFill.resolvedColor(with: light).getRed(&r, green: &g, blue: &b, alpha: &a)
    XCTAssertEqual(r, 191.0 / 255.0, accuracy: 0.01)
    XCTAssertEqual(g, 192.0 / 255.0, accuracy: 0.01)
    XCTAssertEqual(b, 196.0 / 255.0, accuracy: 0.01)

    LokeyVisualStyle.disabledForeground.resolvedColor(with: dark).getRed(&r, green: &g, blue: &b, alpha: &a)
    XCTAssertEqual(r, 1.0, accuracy: 0.01)
    XCTAssertEqual(a, 0.32, accuracy: 0.005)
    LokeyVisualStyle.disabledForeground.resolvedColor(with: light).getRed(&r, green: &g, blue: &b, alpha: &a)
    XCTAssertEqual(r, 164.0 / 255.0, accuracy: 0.01)
    XCTAssertEqual(g, 165.0 / 255.0, accuracy: 0.01)
    XCTAssertEqual(b, 170.0 / 255.0, accuracy: 0.01)

    LokeyVisualStyle.actionBackground.resolvedColor(with: dark).getRed(&r, green: &g, blue: &b, alpha: &a)
    XCTAssertEqual(r, 0.039, accuracy: 0.01)
    XCTAssertEqual(g, 0.518, accuracy: 0.01)
    XCTAssertEqual(b, 1.0, accuracy: 0.01)
    LokeyVisualStyle.actionBackground.resolvedColor(with: light).getRed(&r, green: &g, blue: &b, alpha: &a)
    XCTAssertEqual(r, 0.0, accuracy: 0.01)
    XCTAssertEqual(g, 0.478, accuracy: 0.01)
    XCTAssertEqual(b, 1.0, accuracy: 0.01)

    // 2) 字母大写字号：Lokey 22.5pt，标准 22.0pt；小写统一 25.0pt
    XCTAssertEqual(KeyboardViewController.letterFontSize(.phone, uppercase: false, lokey: true), 25.0, accuracy: 0.01)
    XCTAssertEqual(KeyboardViewController.letterFontSize(.phone, uppercase: true, lokey: true), 22.5, accuracy: 0.01)
    XCTAssertEqual(KeyboardViewController.letterFontSize(.phone, uppercase: true, lokey: false), 22.0, accuracy: 0.01)

    // 3) 真实控制器首次懒建 123 / #+= 层：三排键距必须为 6.25pt（非 6.0pt），三排字符均为 22.0pt，功能键字号对齐 Lokey
    let controller = KeyboardViewController()
    let expectedHeight = LokeyGridMetrics.forProfile(.maxPortrait).baseTotalHeight
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: expectedHeight))
    window.overrideUserInterfaceStyle = .dark
    window.rootViewController = controller
    controller.loadViewIfNeeded()
    window.isHidden = false
    defer { window.isHidden = true }
    controller.viewWillAppear(false)
    controller.viewIsAppearing(false)
    window.layoutIfNeeded()

    let initialDescendants = allSubviews(in: controller.view)
    let toggle = try XCTUnwrap(initialDescendants.first { $0.accessibilityIdentifier == "layoutToggleButton" } as? UIButton)
    XCTAssertEqual(toggle.titleLabel?.font.pointSize ?? 0, 16.0, accuracy: 0.05, "字母页 123 切换键应为 16.0pt")

    // 切入 123 层触发 ensureSymbolLayerRows 懒建
    toggle.sendActions(for: .primaryActionTriggered)
    window.layoutIfNeeded()
    let symDescendants = allSubviews(in: controller.view)
    for rowIndex in 0..<3 {
      let row = try XCTUnwrap(symDescendants.first { $0.accessibilityIdentifier == "symbolLayerRow\(rowIndex)" } as? UIStackView)
      XCTAssertEqual(row.spacing, 6.25, accuracy: 0.01, "123 第 \(rowIndex) 排懒建键距必须为 Lokey 6.25pt")
    }
    let keyRow0 = try XCTUnwrap(symDescendants.first { $0.accessibilityIdentifier == "symbolLayerKey0_0" } as? UIButton)
    let keyRow1 = try XCTUnwrap(symDescendants.first { $0.accessibilityIdentifier == "symbolLayerKey1_0" } as? UIButton)
    let keyRow2 = try XCTUnwrap(symDescendants.first { $0.accessibilityIdentifier == "symbolLayerKey2_0" } as? UIButton)
    let keyRow2Last = try XCTUnwrap(symDescendants.first { $0.accessibilityIdentifier == "symbolLayerKey2_5" } as? UIButton)
    let moreToggle = try XCTUnwrap(symDescendants.first { $0.accessibilityIdentifier == "symbolLayerToggle" } as? UIButton)
    let symDelete = try XCTUnwrap(symDescendants.first { $0.accessibilityIdentifier == "symbolLayerDeleteKey" } as? UIButton)

    XCTAssertEqual(keyRow0.titleLabel?.font.pointSize ?? 0, 22.0, accuracy: 0.05, "123 第一排数字应为 22.0pt")
    XCTAssertEqual(keyRow1.titleLabel?.font.pointSize ?? 0, 22.0, accuracy: 0.05, "123 第二排符号应为 22.0pt")
    XCTAssertEqual(keyRow2.titleLabel?.font.pointSize ?? 0, 22.0, accuracy: 0.05, "123 第三排标点应为 22.0pt")
    XCTAssertEqual(moreToggle.titleLabel?.font.pointSize ?? 0, 13.8, accuracy: 0.05, "123 第三排 #+= 键应为 13.8pt")
    XCTAssertEqual(toggle.titleLabel?.font.pointSize ?? 0, 15.8, accuracy: 0.05, "123 底行 拼音 键应为 15.8pt")

    // 验证第三排两侧内缓冲 11.25pt（6.25 + 5.0）与侧键宽约 48.63pt
    let moreFrame = moreToggle.convert(moreToggle.bounds, to: controller.view)
    let firstPunctFrame = keyRow2.convert(keyRow2.bounds, to: controller.view)
    let lastPunctFrame = keyRow2Last.convert(keyRow2Last.bounds, to: controller.view)
    let delFrame = symDelete.convert(symDelete.bounds, to: controller.view)
    XCTAssertEqual(moreFrame.width, 48.63, accuracy: 0.5)
    XCTAssertEqual(delFrame.width, 48.63, accuracy: 0.5)
    XCTAssertEqual(firstPunctFrame.minX - moreFrame.maxX, 11.25, accuracy: 0.5)
    XCTAssertEqual(delFrame.minX - lastPunctFrame.maxX, 11.25, accuracy: 0.5)

    // 切到 #+= 层：左侧切换键变为 "123"（16.0pt），三排字符保持 22.0pt
    moreToggle.sendActions(for: .primaryActionTriggered)
    window.layoutIfNeeded()
    XCTAssertEqual(moreToggle.configuration?.title, "123")
    XCTAssertEqual(moreToggle.titleLabel?.font.pointSize ?? 0, 16.0, accuracy: 0.05, "#+= 页的 123 切换键应为 16.0pt")
    XCTAssertEqual(keyRow0.titleLabel?.font.pointSize ?? 0, 22.0, accuracy: 0.05)

    // 切回标准样式时，已建的 123 层应即时恢复 6.0pt 键距与 20pt/18pt 标准字号
    _ = MetasequoiaInputSessionBridge.updateSharedPreferences { doc in
      doc[TouchKeyLayoutStyle.twentySixKeyDocumentKey] = TouchTwentySixKeyStyle.standard.rawValue
    }
    TouchKeyLayoutStyle.mirrored = TouchKeyLayoutStyle(twentySixKey: .standard)
    controller.viewWillAppear(false)
    window.layoutIfNeeded()
    let row0After = try XCTUnwrap(symDescendants.first { $0.accessibilityIdentifier == "symbolLayerRow0" } as? UIStackView)
    XCTAssertEqual(row0After.spacing, 6.0, accuracy: 0.01)
    XCTAssertEqual(keyRow0.titleLabel?.font.pointSize ?? 0, 20.0, accuracy: 0.05)
    XCTAssertEqual(keyRow1.titleLabel?.font.pointSize ?? 0, 18.0, accuracy: 0.05)

    controller.viewDidDisappear(false)
  }

  @MainActor
  func testLiquidGlassHostTopPaddingCompressesTopBarForTwentySixAndNineKey() throws {
    // 1) 宿主顶距判定规则：safeAreaTop == 0 时默认返回 0（与 Lokey 0.9.5 正式版一致，避免在 0pt 宿主里压死顶栏），
    //    仅在宿主通过 safeAreaTop 明确上报（>0.5pt）或测试注入时才扣减；横屏/iPad 始终不扣减。
    XCTAssertEqual(
      LokeyLayoutMetrics.resolvedHostTopPadding(
        safeAreaTop: 0, isPhonePortrait: true, isLiquidGlassKeyboard: true, isKeyboardExtensionProcess: true),
      0.0, accuracy: 0.01)
    XCTAssertEqual(
      LokeyLayoutMetrics.resolvedHostTopPadding(
        safeAreaTop: 0, isPhonePortrait: false, isLiquidGlassKeyboard: true, isKeyboardExtensionProcess: true),
      0.0, accuracy: 0.01)
    XCTAssertEqual(
      LokeyLayoutMetrics.resolvedHostTopPadding(
        safeAreaTop: 0, isPhonePortrait: true, isLiquidGlassKeyboard: true, isKeyboardExtensionProcess: false),
      0.0, accuracy: 0.01)
    XCTAssertEqual(
      LokeyLayoutMetrics.resolvedHostTopPadding(
        safeAreaTop: 12, isPhonePortrait: true, isLiquidGlassKeyboard: true, isKeyboardExtensionProcess: false),
      12.0, accuracy: 0.01)
    XCTAssertEqual(
      LokeyLayoutMetrics.resolvedHostTopPadding(
        safeAreaTop: 24, isPhonePortrait: true, isLiquidGlassKeyboard: true, isKeyboardExtensionProcess: true),
      17.0, accuracy: 0.01)

    // 2) 通用模式顶栏扣减：单行 42pt 压至 31pt，释义增量保留，缩小的候选栏不被反向撑大
    XCTAssertEqual(LokeyLayoutMetrics.compactGeneralTopRowHeight(baseTopRow: 42, standardTopRow: 42, hostTopPadding: 17), 31, accuracy: 0.01)
    XCTAssertEqual(LokeyLayoutMetrics.compactGeneralTopRowHeight(baseTopRow: 56, standardTopRow: 42, hostTopPadding: 17), 45, accuracy: 0.01)
    XCTAssertEqual(LokeyLayoutMetrics.compactGeneralTopRowHeight(baseTopRow: 21, standardTopRow: 42, hostTopPadding: 17), 21, accuracy: 0.01)

    // 3) 默认（safeAreaTop == 0）下 26 键保持完整 44pt 顶栏与 45pt 键高，不强压也不做负向光学上移
    let savedScheme = InputSchemePreference.scheme
    defer { InputSchemePreference.scheme = savedScheme }
    InputSchemePreference.scheme = .quanpin
    do {
      let controller = KeyboardViewController()
      controller.loadViewIfNeeded()
      let defaultHeight = LokeyGridMetrics.forProfile(.maxPortrait).baseTotalHeight
      controller.view.frame = CGRect(x: 0, y: 0, width: 440, height: defaultHeight)
      controller.viewWillAppear(false)
      controller.view.layoutIfNeeded()
      let descendants = allSubviews(in: controller.view)
      let strip = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "candidateStrip" })
      let keyQ = try XCTUnwrap(descendants.first { ($0 as? UIButton)?.configuration?.title?.lowercased() == "q" } as? UIButton)
      let brand = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "moreShortcut" } as? KeyboardBrandMarkButton)
      XCTAssertEqual(strip.bounds.height, 44.0, accuracy: 0.5, "默认 0pt 宿主顶距下 26 键顶栏应恢复 44pt")
      XCTAssertEqual(keyQ.bounds.height, 45.0, accuracy: 0.5, "默认 26 键键帽高度应保持 45pt")
      XCTAssertEqual(brand.verticalOpticalOffset, 0.0, accuracy: 0.01)
      controller.viewDidDisappear(false)
    }

    // 4) 当宿主明确上报 17pt 顶距时，26 键与 9 键顶栏压至 31pt、图标维持 1.0 全尺寸居中且 26 键键帽仍保持 45pt 不被压扁
    for scheme in [ChineseInputScheme.quanpin, .nineKey] {
      InputSchemePreference.scheme = scheme
      let controller = KeyboardViewController()
      controller.overrideHostTopPaddingForTesting = 17.0
      controller.loadViewIfNeeded()
      let height: CGFloat = scheme == .quanpin ? 255.5 : 268.5
      controller.view.frame = CGRect(x: 0, y: 0, width: 440, height: height)
      controller.viewWillAppear(false)
      controller.view.layoutIfNeeded()

      let descendants = allSubviews(in: controller.view)
      let strip = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "candidateStrip" })
      let emoji = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "emojiShortcut" } as? KeyboardToolbarButton)
      let brand = try XCTUnwrap(descendants.first { $0.accessibilityIdentifier == "moreShortcut" } as? KeyboardBrandMarkButton)

      let stripFrame = strip.convert(strip.bounds, to: controller.view)
      XCTAssertEqual(stripFrame.minY, 0.0, accuracy: 0.5, "\(scheme) 顶部应贴紧 y=0，不再叠加 2pt 内边距")
      XCTAssertEqual(stripFrame.height, 31.0, accuracy: 0.5, "\(scheme) 17pt 宿主顶距下顶栏应压至 31pt")
      XCTAssertEqual(emoji.contentScaleBaseline, 31.0, accuracy: 0.01)
      XCTAssertEqual(KeyboardToolbarButton.contentScale(rowHeight: 31.0, baseline: emoji.contentScaleBaseline), 1.0, accuracy: 0.01)
      XCTAssertEqual(emoji.verticalOpticalOffset, 0.0, accuracy: 0.01)
      XCTAssertEqual(brand.contentScaleBaseline, 31.0, accuracy: 0.01)
      XCTAssertEqual(brand.verticalOpticalOffset, 0.0, accuracy: 0.01)
      if scheme == .quanpin {
        let keyQ = try XCTUnwrap(descendants.first { ($0 as? UIButton)?.configuration?.title?.lowercased() == "q" } as? UIButton)
        XCTAssertEqual(keyQ.bounds.height, 45.0, accuracy: 0.5, "即使扣减 17pt 宿主顶距，26 键 4 排键帽也应保持 45pt 不被压扁")
      }

      controller.viewDidDisappear(false)
    }
  }

  private func allSubviews(in root: UIView) -> [UIView] {
    root.subviews + root.subviews.flatMap { allSubviews(in: $0) }
  }
}

private final class LokeyTestLongPressGestureRecognizer: UILongPressGestureRecognizer {
  private let mockedState: UIGestureRecognizer.State
  init(state: UIGestureRecognizer.State) {
    self.mockedState = state
    super.init(target: nil, action: nil)
  }
  override var state: UIGestureRecognizer.State {
    get { mockedState }
    set {}
  }
}
