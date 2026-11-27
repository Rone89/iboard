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
      sampleCount: 4, pathLength: 24, deltaFromLast: 24, now: 1.0, lastDecodeTime: -.infinity, inFlight: false))
    // 间隔不足 55ms 拒绝。
    XCTAssertFalse(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 8, pathLength: 60, deltaFromLast: 25, now: 1.04, lastDecodeTime: 1.0, inFlight: false))
    // 超过 55ms 且位移达标（>= 10pt）放行。
    XCTAssertTrue(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 8, pathLength: 60, deltaFromLast: 12, now: 1.07, lastDecodeTime: 1.0, inFlight: false))
    // 位移不足但尾键停顿超过 140ms 仍允许补刷新一次。
    XCTAssertFalse(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 8, pathLength: 60, deltaFromLast: 4, now: 1.08, lastDecodeTime: 1.0, inFlight: false))
    XCTAssertTrue(GlideLivePreviewPolicy.shouldDecode(
      sampleCount: 8, pathLength: 60, deltaFromLast: 4, now: 1.16, lastDecodeTime: 1.0, inFlight: false))
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

  func testGlideCompositionOriginTrackerTracksMixedAndPartialCommitBoundaries() {
    var origin = GlideCompositionOriginTracker()

    // 点按 + 滑行混打，部分选词切掉前缀后仍保留滑行来源。
    origin.reconcile(editingText: "ni", newOrigin: .typed)
    XCTAssertFalse(origin.isGlideBeforeCaret())
    origin.reconcile(editingText: "ni'hao", newOrigin: .glide)
    XCTAssertTrue(origin.isGlideBeforeCaret())
    XCTAssertEqual(origin.origins, [.typed, .typed, .glide, .glide, .glide])

    // 选掉前段「你」剩下 `hao`：仍保留 `.glide`。
    origin.reconcile(editingText: "hao", newOrigin: nil)
    XCTAssertEqual(origin.origins, [.glide, .glide, .glide])
    XCTAssertTrue(origin.isGlideBeforeCaret())

    // 滑行后再点按字母，尾部变 `.typed`，退完点按字母后自动回到 `.glide`。
    origin.reconcile(editingText: "haoa", newOrigin: .typed)
    XCTAssertFalse(origin.isGlideBeforeCaret())
    origin.reconcile(editingText: "hao", newOrigin: nil)
    XCTAssertTrue(origin.isGlideBeforeCaret())

    // 中间光标偏移校验。
    origin.reconcile(editingText: "ni'hao", newOrigin: nil)
    origin.clear()
    origin.reconcile(editingText: "ni", newOrigin: .typed)
    origin.reconcile(editingText: "ni'hao", newOrigin: .glide)
    XCTAssertEqual(GlideCompositionOriginTracker.caretLetterOffset(in: "ni|'hao"), 2)
    XCTAssertFalse(origin.isGlideBeforeCaret(caretLetterOffset: 2))
    XCTAssertTrue(origin.isGlideBeforeCaret(caretLetterOffset: 5))
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

  /// 只读 `"preview": true` 通道在已有未提交组字时也能实时返回中文候选，且绝不改动或清空原组字（支撑连滑实时预览）。
  func testReadOnlyPreviewPreservesActiveComposition() throws {
    let state = FileManager.default.temporaryDirectory
      .appendingPathComponent("msime-glide-ro-preview-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let bridge = MetasequoiaInputSessionBridge(stateRoot: state)
    _ = bridge.switch(toShuangpin: false)

    // 先建立一段活跃组字 `ni`。
    let firstReq = try XCTUnwrap(GlideTyping.request(frames: Self.syntheticFrames, samples: Self.stroke("ni", in: Self.syntheticFrames)))
    let firstSnap = bridge.glide(firstReq)
    XCTAssertTrue(firstSnap.isHandled)
    XCTAssertEqual(firstSnap.editingText, "ni")

    // 在 `ni` 组字保持活跃期间，对下一笔 `hao` 发起只读实时预览。
    let previewReq = try XCTUnwrap(GlideTyping.request(
      frames: Self.syntheticFrames,
      samples: Self.stroke("hao", in: Self.syntheticFrames),
      preview: true
    ))
    let expectation = expectation(description: "read-only glide preview")
    var result: MetasequoiaGlidePreview?
    bridge.previewGlideAsync(previewReq) { preview in
      result = preview
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 5)

    let preview = try XCTUnwrap(result)
    XCTAssertEqual(preview.reading, "hao")
    XCTAssertGreaterThan(preview.candidates.count, 4, "滑行实时预览应返回一整页候选词，不再被截断在前 4 个")

    // 原组字 `ni` 必须完好保留，再滑一笔 `hao` 应正确拼接成 `ni'hao`。
    let secondReq = try XCTUnwrap(GlideTyping.request(frames: Self.syntheticFrames, samples: Self.stroke("hao", in: Self.syntheticFrames)))
    let combined = bridge.glide(secondReq)
    XCTAssertTrue(combined.isHandled)
    XCTAssertEqual(combined.editingText, "ni'hao")
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

  /// 滑行实时预览直接渲染为正式候选栏词块，期间隐藏工具栏（含未粘贴胶囊）与展开按钮并拦截误触，结束或取消后恢复空闲工具栏或原有组字候选。
  func testGlideLivePreviewRendersAsCandidateChipsAndHidesShortcutBar() throws {
    let document = FakeDocument(text: "")
    let controller = try makeKeyboard(document)
    let glide = try XCTUnwrap(descendants(controller.view)
      .compactMap { ($0 as? KeyAreaStackView)?.gestureRecognizers?.first { $0 is GlideTypingGestureRecognizer } as? GlideTypingGestureRecognizer }
      .first)
    let moreShortcut = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "moreShortcut" })
    let shortcutBar = try XCTUnwrap(moreShortcut.superview)
    let quickPaste = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "quickPasteShortcut" })
    let expandButton = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "expandCandidates" })

    func visibleCandidateTitles() -> [String] {
      descendants(controller.view)
        .compactMap { view -> (Int, String)? in
          guard let button = view as? UIButton, !button.isHidden,
                let id = button.accessibilityIdentifier, id.hasPrefix("candidate-"),
                let index = Int(id.dropFirst("candidate-".count)),
                let title = button.configuration?.title, !title.isEmpty else { return nil }
          return (index, title)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    // 1. 空闲态（即使存在未粘贴胶囊）：滑行预览直接以正式候选词块形式展示（支持完整一页，不再限 4 个），工具栏与展开按钮隐藏，点击预览词块不会误上屏。
    quickPaste.isHidden = false
    XCTAssertFalse(shortcutBar.isHidden)
    XCTAssertEqual(visibleCandidateTitles(), [])

    let previewWords = ["每一句", "每一集", "没有吗", "没一句", "某一集"]
    controller.setGlideLivePreview(MetasequoiaGlidePreview(reading: "m'y'j", candidates: previewWords))
    controller.view.layoutIfNeeded()
    XCTAssertTrue(shortcutBar.isHidden, "滑行实时预览显示期间工具栏必须隐藏，避免与粘贴胶囊叠画")
    XCTAssertTrue(expandButton.isHidden, "滑行实时预览期间不显示候选展开箭头")
    XCTAssertEqual(visibleCandidateTitles(), previewWords, "滑行实时预览应直接渲染到正式候选词块上")

    let firstChip = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "candidate-1" } as? UIButton)
    firstChip.sendActions(for: .primaryActionTriggered)
    XCTAssertEqual(document.text, "", "滑行实时预览词块只读展示，点击不得误上屏")

    controller.setGlideLivePreview(nil)
    controller.view.layoutIfNeeded()
    XCTAssertFalse(shortcutBar.isHidden, "结束滑行预览后应恢复空闲工具栏")
    XCTAssertEqual(visibleCandidateTitles(), [])

    // 2. 已有组字态：滑行预览临时在正式候选栏展示当前滑行词块，不破坏原组字；取消预览后立即还原原候选。
    let frames = glide.keyFrames()
    glide.onEnded(Self.stroke("ni", in: frames), frames)
    controller.view.layoutIfNeeded()
    let originalCandidates = visibleCandidateTitles()
    XCTAssertFalse(originalCandidates.isEmpty)
    XCTAssertTrue(shortcutBar.isHidden)
    let originalMarked = document.markedText

    controller.setGlideLivePreview(MetasequoiaGlidePreview(reading: "hao", candidates: ["好", "号", "豪"]))
    controller.view.layoutIfNeeded()
    XCTAssertTrue(shortcutBar.isHidden)
    XCTAssertEqual(visibleCandidateTitles(), ["好", "号", "豪"])
    XCTAssertEqual(document.markedText, originalMarked, "只读滑行预览不得改动输入框里的原有组字")

    controller.setGlideLivePreview(nil)
    controller.view.layoutIfNeeded()
    XCTAssertEqual(visibleCandidateTitles(), originalCandidates, "取消滑行预览后应还原原有组字候选")
    XCTAssertTrue(shortcutBar.isHidden)
  }

  /// 抬手正式提交时，与预览相同的首选词块平滑接管不重复触发切换动画，且接管后可正常点击上屏。
  func testGlideLivePreviewHandsOffSmoothlyOnCommit() throws {
    let previousStyle = CandidateTransitionPreference.style
    CandidateTransitionPreference.style = .rise
    defer { CandidateTransitionPreference.style = previousStyle }

    let document = FakeDocument(text: "")
    let controller = try makeKeyboard(document)
    let glide = try XCTUnwrap(descendants(controller.view)
      .compactMap { ($0 as? KeyAreaStackView)?.gestureRecognizers?.first { $0 is GlideTypingGestureRecognizer } as? GlideTypingGestureRecognizer }
      .first)
    let frames = glide.keyFrames()

    // 先显示与抬手后首选一致的预览词，再清空已挂动画以观察抬手瞬间是否发生重复重播。
    controller.setGlideLivePreview(MetasequoiaGlidePreview(reading: "ni'hao", candidates: ["你好", "占位词"]))
    controller.view.layoutIfNeeded()
    let firstChip = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "candidate-1" } as? UIButton)
    XCTAssertEqual(firstChip.configuration?.title, "你好")
    firstChip.layer.removeAllAnimations()
    firstChip.titleLabel?.layer.removeAllAnimations()

    glide.onEnded(Self.stroke("nihao", in: frames), frames)
    controller.view.layoutIfNeeded()

    XCTAssertEqual(firstChip.configuration?.title, "你好")
    XCTAssertNil(
      firstChip.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey),
      "首选候选词气泡外层不应重播切换动画"
    )
    XCTAssertNil(
      CandidateStripTransitionAnimator.animationTargetLayer(for: firstChip)
        .animation(forKey: CandidateStripTransitionAnimator.animationKey),
      "抬手后首选词与实时预览一致时应平滑保持静止，不重复播切换动画"
    )
    firstChip.sendActions(for: .primaryActionTriggered)
    XCTAssertEqual(document.text, "你好", "抬手交接完成后点击候选词应正常上屏")
  }

  func testSingleBackspaceAfterGlideDeletesCharacterByCharacter() throws {
    let document = FakeDocument(text: "前言")
    let controller = try makeKeyboard(document)
    let glide = try XCTUnwrap(descendants(controller.view)
      .compactMap { ($0 as? KeyAreaStackView)?.gestureRecognizers?.first { $0 is GlideTypingGestureRecognizer } as? GlideTypingGestureRecognizer }
      .first)
    let frames = glide.keyFrames()
    let delete = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "删除" } as? UIButton)

    // 1. 滑行出组字后轻点 ⌫：默认逐字母回删（nihao -> niha -> nih），不再一次清空整段滑行组字。
    glide.onEnded(Self.stroke("nihao", in: frames), frames)
    XCTAssertEqual(document.markedText.replacingOccurrences(of: "'", with: ""), "nihao")
    delete.sendActions(for: .touchUpInside)
    XCTAssertEqual(document.markedText.replacingOccurrences(of: "'", with: ""), "niha", "滑后轻点一次退格应逐字母删掉末尾 o")
    delete.sendActions(for: .touchUpInside)
    XCTAssertEqual(document.markedText.replacingOccurrences(of: "'", with: ""), "nih", "再次退格继续逐字母删掉 a")
    XCTAssertEqual(document.text, "前言")

    // 清空残余组字。
    while !document.markedText.isEmpty {
      delete.sendActions(for: .touchUpInside)
    }

    // 2. 再次滑行并用空格上屏多字词后轻点 ⌫：逐字删除末尾一个汉字，不再整词一键撤回。
    glide.onEnded(Self.stroke("nihao", in: frames), frames)
    let space = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "spaceKey" } as? UIButton)
    space.sendActions(for: .primaryActionTriggered)
    let afterCommit = document.text
    XCTAssertTrue(afterCommit.hasPrefix("前言"))
    let committedWord = String(afterCommit.dropFirst("前言".count))
    XCTAssertGreaterThanOrEqual(committedWord.count, 2)

    delete.sendActions(for: .touchUpInside)
    XCTAssertEqual(document.text, String(afterCommit.dropLast()), "滑后上屏多字词按一次退格应只删除末尾 1 个字")
    delete.sendActions(for: .touchUpInside)
    XCTAssertEqual(document.text, String(afterCommit.dropLast(2)), "再按一次退格继续逐字删除前 1 个字")
  }

  func testNativeNineKeyTopBarDisplaysLiveGlidePreviewReadingAndRestoresSpellings() throws {
    let previousStyle = TouchKeyLayoutStyle.mirrored
    defer { TouchKeyLayoutStyle.mirrored = previousStyle }
    InputSchemePreference.scheme = .nineKey
    TouchKeyLayoutStyle.mirrored = TouchKeyLayoutStyle(nineKey: .iosNative)

    let document = FakeDocument(text: "")
    let controller = try makeKeyboard(document)
    let topBar = try XCTUnwrap(descendants(controller.view).first {
      $0.accessibilityIdentifier == "iosNativeNineKeyTopSpellingBar"
    })
    let previewLabel = try XCTUnwrap(descendants(controller.view).first {
      $0.accessibilityIdentifier == "iosNativeNineKeyTopSpellingBar_previewReading"
    } as? UILabel)

    XCTAssertTrue(previewLabel.isHidden)
    controller.setGlideLivePreview(MetasequoiaGlidePreview(reading: "wo'men", candidates: ["我们", "我门"]))
    controller.view.layoutIfNeeded()
    XCTAssertFalse(topBar.isHidden, "滑行拖动期间原生九键常驻顶栏应保持可见")
    XCTAssertFalse(previewLabel.isHidden, "滑行拖动期间顶栏应显示实时拼音串")
    XCTAssertEqual(previewLabel.text, "wo'men")

    controller.setGlideLivePreview(nil)
    controller.view.layoutIfNeeded()
    XCTAssertTrue(previewLabel.isHidden, "结束滑行预览后应隐藏实时拼音预览标签")
  }

  func testNineKeySingleBackspaceUndoesLastGlideStrokeCleanly() throws {
    let previousStyle = TouchKeyLayoutStyle.mirrored
    defer { TouchKeyLayoutStyle.mirrored = previousStyle }
    InputSchemePreference.scheme = .nineKey
    TouchKeyLayoutStyle.mirrored = TouchKeyLayoutStyle(nineKey: .iosNative)

    let document = FakeDocument(text: "前缀")
    let controller = try makeKeyboard(document)
    let glide = try XCTUnwrap(descendants(controller.view)
      .compactMap { ($0 as? KeyAreaStackView)?.gestureRecognizers?.first { $0 is GlideTypingGestureRecognizer } as? GlideTypingGestureRecognizer }
      .first)
    let frames = glide.keyFrames()
    XCTAssertTrue(GlideTyping.isNineKeyFrames(frames))
    let delete = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "删除" } as? UIButton)

    func nineKeyStroke(_ digits: [Int]) throws -> [GlideTyping.Sample] {
      let centers = try digits.map { digit -> CGPoint in
        let idx = try XCTUnwrap(GlideTyping.nineKeyRepresentativeIndex(forDigit: digit))
        return CGPoint(x: frames[idx].midX, y: frames[idx].midY)
      }
      var samples: [GlideTyping.Sample] = []
      func add(_ point: CGPoint) {
        samples.append(GlideTyping.Sample(x: point.x, y: point.y, milliseconds: Double(samples.count) * 10))
      }
      for (from, to) in zip(centers, centers.dropFirst()) {
        let steps = max(1, Int((hypot(to.x - from.x, to.y - from.y) / 8).rounded(.up)))
        for step in 0..<steps {
          let t = CGFloat(step) / CGFloat(steps)
          add(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        }
      }
      if let last = centers.last { add(last) }
      return samples
    }

    // 1. 空态单笔九键滑行后轻点一次 ⌫：整笔清空，不误删已有正文。
    glide.onEnded(try nineKeyStroke([6, 4, 2, 6]), frames)
    XCTAssertFalse(document.markedText.isEmpty, "单笔九键滑行应产生组字")
    delete.sendActions(for: .touchUpInside)
    XCTAssertEqual(document.markedText, "", "单笔九键滑行后轻点一次退格应一键清空整笔")
    XCTAssertEqual(document.text, "前缀", "撤销滑行组字不得误删已有正文")

    // 2. 连滑两笔（先滑 9→6，再滑 6→3→6）后轻点一次 ⌫：仅退掉最新一笔并自动清理末尾分词符 `'`，完整保留第一笔。
    glide.onEnded(try nineKeyStroke([9, 6]), frames)
    let afterFirstStroke = document.markedText
    XCTAssertFalse(afterFirstStroke.isEmpty)
    glide.onEnded(try nineKeyStroke([6, 3, 6]), frames)
    XCTAssertGreaterThan(document.markedText.count, afterFirstStroke.count)
    delete.sendActions(for: .touchUpInside)
    XCTAssertEqual(document.markedText, afterFirstStroke, "连滑后轻点一次退格应仅撤回最新一笔并完整保留上一笔")
    XCTAssertFalse(document.markedText.hasSuffix("'"), "撤回连滑笔后不能残留末尾分词符")
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
