import UIKit
import UIKit.UIGestureRecognizerSubclass
import XCTest

@MainActor
final class CandidateStripRowTests: XCTestCase {
  func testChangingWidthsAndVisibilityKeepsContentGeometry() {
    let row = CandidateStripRow()
    row.stack.axis = .horizontal
    row.stack.spacing = 11
    row.stack.translatesAutoresizingMaskIntoConstraints = false
    let viewport = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 42))
    viewport.addSubview(row.stack)
    NSLayoutConstraint.activate([
      row.stack.leadingAnchor.constraint(equalTo: viewport.contentLayoutGuide.leadingAnchor),
      row.stack.trailingAnchor.constraint(equalTo: viewport.contentLayoutGuide.trailingAnchor),
      row.stack.topAnchor.constraint(equalTo: viewport.contentLayoutGuide.topAnchor),
      row.stack.bottomAnchor.constraint(equalTo: viewport.contentLayoutGuide.bottomAnchor),
      row.stack.heightAnchor.constraint(equalTo: viewport.frameLayoutGuide.heightAnchor),
    ])
    var widths: [NSLayoutConstraint] = []
    for index in 0..<9 {
      let button = KeyboardKeyButton()
      var configuration = UIButton.Configuration.plain()
      configuration.title = "合成\n条目"
      button.configuration = configuration
      button.titleLineCount = 2
      button.accessibilityIdentifier = "candidate-\(index + 1)"
      let width = button.widthAnchor.constraint(equalToConstant: 100)
      width.priority = .init(999)
      width.isActive = true
      widths.append(width)
      row.add(button)
    }
    for update in 0..<180 {
      let visible = update % 10
      for index in row.buttons.indices {
        widths[index].constant = CGFloat(90 + (update + index) % 80)
        row.buttons[index].configuration?.title = update % 2 == 0 ? "合成\n条目" : "示例\n注释"
        row.setHidden(index >= visible, at: index)
      }
      viewport.setNeedsLayout()
      row.stack.setNeedsLayout()
      viewport.layoutIfNeeded()
      var previousEdge: CGFloat?
      for index in 0..<visible {
        let frame = row.buttons[index].convert(row.buttons[index].bounds, to: viewport)
        XCTAssertEqual(frame.width, widths[index].constant, accuracy: 1)
        XCTAssertEqual(frame.height, 42, accuracy: 1)
        if index == 0 {
          let target = viewport.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
          XCTAssertTrue(target === row.buttons[index] || target?.isDescendant(of: row.buttons[index]) == true,
                        "包装层不能拦截候选按钮的触摸")
        }
        if let previousEdge { XCTAssertEqual(frame.minX - previousEdge, 11, accuracy: 1) }
        previousEdge = frame.maxX
      }
      XCTAssertEqual(viewport.contentSize.width, previousEdge ?? 0, accuracy: 1)
      XCTAssertTrue(row.buttons.dropFirst(visible).allSatisfy(\.isHidden))
    }
  }

  /// 候选栏向下轻滑展开候选面板，展开后再向上轻滑收起；横向滚动后手指再下漂不会误触展开，短于阈值的点击和空闲工具栏均不触发。
  func testDownwardSwipeOnCandidateStripExpandsAndUpwardSwipeClosesPanel() throws {
    enableAllInputSchemes()
    let previous = InputSchemePreference.scheme
    defer { InputSchemePreference.scheme = previous }
    InputSchemePreference.scheme = .quanpin

    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: KeyboardViewController.keyboardHeight(letterKeys: true))
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()
    defer { controller.viewDidDisappear(false) }

    func descendants(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(descendants) }
    func view(_ identifier: String) throws -> UIView {
      try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == identifier }, identifier)
    }

    let strip = try view("candidateStrip")
    let installed = try XCTUnwrap(strip.gestureRecognizers?.compactMap { $0 as? CandidateStripVerticalSwipeRecognizer }.first)
    let scroll = try XCTUnwrap(descendants(strip).first { $0 is CandidateScrollView } as? CandidateScrollView)
    XCTAssertTrue(controller.gestureRecognizer(installed, shouldRecognizeSimultaneouslyWith: scroll.panGestureRecognizer),
                  "候选栏纵向轻滑必须能与横向滚动共存")

    // 空闲时（无候选）不接收触摸，避免拦截工具栏按钮。
    XCTAssertFalse(controller.gestureRecognizer(installed, shouldReceive: StripScriptedTouch(at: CGPoint(x: 40, y: 20), in: strip)))

    for letter in "NIHAO" {
      let key = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "字母 \(letter)" } as? UIButton)
      key.sendActions(for: .primaryActionTriggered)
    }
    controller.view.layoutIfNeeded()

    let firstCandidate = try view("candidate-1")
    let closePrediction = try view("closePrediction")
    XCTAssertTrue(controller.gestureRecognizer(installed, shouldReceive: StripScriptedTouch(at: CGPoint(x: 10, y: 10), in: firstCandidate)))
    XCTAssertFalse(controller.gestureRecognizer(installed, shouldReceive: StripScriptedTouch(at: CGPoint(x: 10, y: 10), in: closePrediction)))

    let handle = NSSelectorFromString("handleCandidateStripVerticalSwipe:")
    func driveSwipe(_ offsets: [CGPoint], liftAt: CGPoint? = nil) -> (recognized: Bool, lockedOut: Bool) {
      let recognizer = CandidateStripVerticalSwipeRecognizer(target: controller, action: handle)
      recognizer.allowsDownward = installed.allowsDownward
      recognizer.allowsUpward = installed.allowsUpward
      strip.addGestureRecognizer(recognizer)
      defer { strip.removeGestureRecognizer(recognizer) }
      let origin = CGPoint(x: strip.bounds.midX, y: strip.bounds.midY)
      let touch = StripScriptedTouch(at: origin, in: firstCandidate)
      recognizer.touchesBegan([touch], with: UIEvent())
      for offset in offsets {
        touch.point = CGPoint(x: origin.x + offset.x, y: origin.y + offset.y)
        recognizer.touchesMoved([touch], with: UIEvent())
        if recognizer.state == .recognized { break }
      }
      if recognizer.state == .possible {
        if let liftAt { touch.point = CGPoint(x: origin.x + liftAt.x, y: origin.y + liftAt.y) }
        recognizer.touchesEnded([touch], with: UIEvent())
      }
      let recognized = recognizer.state == .recognized
      let lockedOut = recognizer.isDirectionLockedOut || recognizer.state == .failed
      if recognized { controller.perform(handle, with: recognizer) }
      controller.view.layoutIfNeeded()
      return (recognized, lockedOut)
    }

    // 1. 轻微抖动（未到 6pt 阈值）：不展开。
    XCTAssertEqual(driveSwipe([CGPoint(x: 2, y: 3)]).lockedOut, true)
    XCTAssertNil(descendants(controller.view).first { $0 is KeyboardCandidatePanelView })

    // 2. 先横向滑再下漂：锁定为横向浏览，不展开。
    let horizontal = driveSwipe([CGPoint(x: 10, y: 2), CGPoint(x: 16, y: 28)])
    XCTAssertFalse(horizontal.recognized)
    XCTAssertTrue(horizontal.lockedOut)
    XCTAssertNil(descendants(controller.view).first { $0 is KeyboardCandidatePanelView })

    // 3. 尚未展开时上滑：不触发。
    let upWhileClosed = driveSwipe([CGPoint(x: 0, y: -12)])
    XCTAssertFalse(upWhileClosed.recognized)
    XCTAssertTrue(upWhileClosed.lockedOut)
    XCTAssertNil(descendants(controller.view).first { $0 is KeyboardCandidatePanelView })

    // 4. 候选栏轻幅下滑（7pt 即触发）：展开候选面板，展开箭头同步朝上。
    XCTAssertTrue(driveSwipe([CGPoint(x: 1, y: 7)]).recognized)
    let expandedPanel = try XCTUnwrap(descendants(controller.view).first { $0 is KeyboardCandidatePanelView } as? KeyboardCandidatePanelView)
    XCTAssertNotEqual(try view("expandCandidates").transform, .identity)
    XCTAssertEqual(expandedPanel.alpha, 1)

    // 5. 已展开时再次下滑不重复处理；向上轻滑收起候选面板。
    let downWhileOpen = driveSwipe([CGPoint(x: 0, y: 12)])
    XCTAssertFalse(downWhileOpen.recognized)
    XCTAssertTrue(downWhileOpen.lockedOut)
    XCTAssertNotNil(descendants(controller.view).first { $0 is KeyboardCandidatePanelView })
    XCTAssertTrue(driveSwipe([], liftAt: CGPoint(x: 0, y: -8)).recognized)
    XCTAssertNil(descendants(controller.view).first { $0 is KeyboardCandidatePanelView })
    XCTAssertEqual(try view("expandCandidates").transform, .identity)
  }

  /// 验证候选网格快速测宽排布及展开过渡方法：300+ 候选用时可控且不漏项，过渡准备与提交后恢复正常透明度与裁剪标志。
  func testCandidatePanelGridFastLayoutAndExpandTransition() throws {
    let candidates = (0..<320).map { index in index % 17 == 0 ? "长候选词\(index)" : "词\(index)" }
    let annotations = candidates.indices.map { index in
      index == 5
        ? KeyboardCandidateAnnotation(text: "annotation\nsecond line", accessibilityDescription: "annotation")
        : KeyboardCandidateAnnotation.none
    }
    let markers = candidates.indices.map { index in
      index == 0 ? [CandidateMarker(symbol: "pin.fill", spoken: "已置顶", pinned: true)] : []
    }
    let panel = KeyboardCandidatePanelView(
      candidates: candidates, preedit: "ci", annotations: annotations, markers: markers,
      showsHeader: false, display: { $0 }, onSelect: { _ in }, onClose: {})
    panel.frame = CGRect(x: 0, y: 0, width: 390, height: 220)
    panel.clipsToBounds = false
    panel.layoutIfNeeded()

    let collection = try XCTUnwrap(panel.subviews.first { $0 is UICollectionView } as? UICollectionView)
    XCTAssertEqual(collection.numberOfItems(inSection: 0), 320)
    let firstFrame = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame)
    let annotatedFrame = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 5, section: 0))?.frame)
    XCTAssertGreaterThanOrEqual(firstFrame.height, KeyboardCandidatePanelView.cellHeight)
    XCTAssertGreaterThan(annotatedFrame.height, firstFrame.height)

    panel.prepareExpandTransition()
    XCTAssertTrue(panel.clipsToBounds)
    XCTAssertEqual(panel.alpha, 0)
    XCTAssertNotEqual(collection.transform, .identity)

    panel.commitExpandTransition()
    XCTAssertEqual(panel.alpha, 1)
    XCTAssertEqual(collection.transform, .identity)

    panel.finishExpandTransition()
    XCTAssertFalse(panel.clipsToBounds)
  }

  /// 验证候选面板上下边缘渐隐遮罩：短列表不加遮罩；长列表在顶部只模糊底部、中段上下同时渐隐、滚到底部时底部恢复清晰。
  func testCandidatePanelTopAndBottomEdgeMaskFollowsScrollOffset() throws {
    let shortPanel = KeyboardCandidatePanelView(
      candidates: ["一", "二", "三", "四"], preedit: "yi",
      showsHeader: false, display: { $0 }, onSelect: { _ in }, onClose: {})
    shortPanel.frame = CGRect(x: 0, y: 0, width: 390, height: 220)
    shortPanel.layoutIfNeeded()
    let shortCollection = try XCTUnwrap(shortPanel.subviews.first { $0 is UICollectionView } as? UICollectionView)
    XCTAssertNil(shortCollection.layer.mask, "未溢出的短候选列表不需要边缘渐隐遮罩")

    let longPanel = KeyboardCandidatePanelView(
      candidates: (0..<120).map { "词\($0)" }, preedit: "ci",
      showsHeader: false, display: { $0 }, onSelect: { _ in }, onClose: {})
    longPanel.frame = CGRect(x: 0, y: 0, width: 390, height: 220)
    longPanel.layoutIfNeeded()
    let longCollection = try XCTUnwrap(longPanel.subviews.first { $0 is UICollectionView } as? UICollectionView)

    func edgeAlphas(_ collection: UICollectionView) throws -> (top: CGFloat, bottom: CGFloat) {
      let mask = try XCTUnwrap(collection.layer.mask as? CAGradientLayer)
      XCTAssertEqual(mask.frame, collection.bounds)
      let colors = try XCTUnwrap(mask.colors as? [CGColor])
      return (colors.first!.alpha, colors.last!.alpha)
    }

    // 1. 初始停在顶部：顶边完全清晰（alpha = 1），底边渐隐（alpha = 0）。
    let atTop = try edgeAlphas(longCollection)
    XCTAssertEqual(atTop.top, 1, accuracy: 0.01)
    XCTAssertEqual(atTop.bottom, 0, accuracy: 0.01)

    // 2. 滚到中段：顶边与底边均带渐隐（alpha 均为 0），使用初版 22pt 五段过渡带。
    longCollection.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
    longPanel.layoutIfNeeded()
    let inMiddle = try edgeAlphas(longCollection)
    XCTAssertEqual(inMiddle.top, 0, accuracy: 0.01)
    XCTAssertEqual(inMiddle.bottom, 0, accuracy: 0.01)
    let middleMask = try XCTUnwrap(longCollection.layer.mask as? CAGradientLayer)
    let locations = try XCTUnwrap(middleMask.locations?.map(\.doubleValue))
    // top: indices 0..4 (locations[4] = topFraction), bottom: indices 5..9 (locations[5] = 1 - bottomFraction)
    XCTAssertEqual(locations.count, 10)
    XCTAssertEqual(locations[4] * longCollection.bounds.height, 22.0, accuracy: 1.0)
    XCTAssertEqual((1 - locations[5]) * longCollection.bounds.height, 22.0, accuracy: 1.0)

    // 3. 滚到底部：顶边渐隐（alpha = 0），底边恢复清晰（alpha = 1）。
    let maxOffsetY = max(0, longCollection.contentSize.height - longCollection.bounds.height)
    longCollection.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: false)
    longPanel.layoutIfNeeded()
    let atBottom = try edgeAlphas(longCollection)
    XCTAssertEqual(atBottom.top, 0, accuracy: 0.01)
    XCTAssertEqual(atBottom.bottom, 1, accuracy: 0.01)
  }

  /// 打开候选面板后：候选栏仅保留视口内完整可见的候选词并锁定横滑，其余候选（含右侧未完整露出以及横滑前移出左侧的词）全部进入候选面板，面板不重复展示候选栏已有词，且点选面板候选能按全局索引精确上屏；收起面板后候选栏恢复完整分页与横滑。
  func testOpeningCandidatePanelKeepsOnlyVisibleStripCandidatesAndOmitsThemFromPanel() throws {
    enableAllInputSchemes()
    let previous = InputSchemePreference.scheme
    defer { InputSchemePreference.scheme = previous }
    InputSchemePreference.scheme = .quanpin

    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: KeyboardViewController.keyboardHeight(letterKeys: true))
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()
    defer { controller.viewDidDisappear(false) }

    func descendants(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(descendants) }
    func shownStripButtons() -> [(button: UIButton, title: String)] {
      descendants(controller.view).compactMap { $0 as? UIButton }
        .filter { chip in
          (chip.accessibilityIdentifier ?? "").hasPrefix("candidate-")
            && sequence(first: chip as UIView, next: \.superview).allSatisfy { !$0.isHidden }
        }
        .compactMap { chip in
          guard let raw = chip.configuration?.attributedTitle.map({ String($0.characters) }),
                let text = raw.split(separator: "\n").first.map(String.init) else { return nil }
          return (chip, text)
        }
    }

    for letter in "YI" {
      let key = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "字母 \(letter)" } as? UIButton)
      key.sendActions(for: .primaryActionTriggered)
    }
    controller.view.layoutIfNeeded()

    let scroll = try XCTUnwrap(descendants(controller.view).first { $0 is CandidateScrollView } as? CandidateScrollView)
    XCTAssertTrue(scroll.isScrollEnabled)
    let fullStrip = shownStripButtons()
    XCTAssertGreaterThan(fullStrip.count, 1)
    let hasOverflowPastRightEdge = fullStrip.contains {
      $0.button.convert($0.button.bounds, to: scroll).maxX > scroll.bounds.maxX + 1
    }
    XCTAssertTrue(hasOverflowPastRightEdge, "YI 默认分页应有超出候选栏宽度的候选项以验证裁切去重")

    // 1. 直接在默认起点打开面板：候选栏仅留完整可见的词，面板从第一个溢出词开始，无重复且面板首项不高亮。
    let expand = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "expandCandidates" } as? UIButton)
    expand.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()

    XCTAssertFalse(scroll.isScrollEnabled, "打开候选面板后候选栏锁定横向滚动")
    let keptStrip = shownStripButtons()
    XCTAssertLessThan(keptStrip.count, fullStrip.count, "候选栏应隐藏超出视口的末尾候选项")
    for item in keptStrip {
      let rect = item.button.convert(item.button.bounds, to: scroll)
      XCTAssertGreaterThanOrEqual(rect.minX, scroll.bounds.minX - 1)
      XCTAssertLessThanOrEqual(rect.maxX, scroll.bounds.maxX + 1)
    }

    let firstOverflowWord = fullStrip[keptStrip.count].title
    let panelFirst = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityIdentifier == "panelCandidate-1" } as? UIButton)
    let panelFirstTitle = panelFirst.configuration?.attributedTitle.map { String($0.characters) }?
      .split(separator: "\n").first.map(String.init)
    XCTAssertEqual(panelFirstTitle, firstOverflowWord, "候选面板首个词应紧接候选栏可见词之后")
    XCTAssertFalse(panelFirst.accessibilityTraits.contains(.selected), "首词在候选栏高亮时面板第一格不能误标为选中")

    let panelVisibleTitles = descendants(controller.view).compactMap { $0 as? UIButton }
      .filter { ($0.accessibilityIdentifier ?? "").hasPrefix("panelCandidate-") }
      .compactMap { $0.configuration?.attributedTitle.map { String($0.characters) }?.split(separator: "\n").first.map(String.init) }
    XCTAssertTrue(Set(keptStrip.map(\.title)).isDisjoint(with: Set(panelVisibleTitles)),
                  "候选面板不应包含候选栏已显示的候选词")

    // 2. 收起后恢复完整候选条与横滑能力。
    expand.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()
    XCTAssertTrue(scroll.isScrollEnabled)
    XCTAssertEqual(shownStripButtons().count, fullStrip.count)

    // 3. 若先向右横滑再打开面板：移出左侧的词（含原首选词）不再留在候选栏，改为进入候选面板。
    scroll.setContentOffset(CGPoint(x: 60, y: 0), animated: false)
    expand.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()
    let keptAfterScroll = shownStripButtons().map(\.title)
    XCTAssertFalse(keptAfterScroll.contains(fullStrip[0].title), "滑出可视区左边界的原首选词不应留在候选栏")
    let panelTitlesAfterScroll = descendants(controller.view).compactMap { $0 as? UIButton }
      .filter { ($0.accessibilityIdentifier ?? "").hasPrefix("panelCandidate-") }
      .compactMap { $0.configuration?.attributedTitle.map { String($0.characters) }?.split(separator: "\n").first.map(String.init) }
    XCTAssertEqual(panelTitlesAfterScroll.first, fullStrip[0].title, "滑出候选栏的词应进入候选面板最前")
  }
}

private final class StripScriptedTouch: UITouch {
  var point: CGPoint
  private weak var targetView: UIView?

  init(at point: CGPoint, in view: UIView?) {
    self.point = point
    self.targetView = view
    super.init()
  }

  override var view: UIView? { targetView }
  override func location(in view: UIView?) -> CGPoint { point }
}
