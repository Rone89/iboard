import QuartzCore
import UIKit
import XCTest

/// 候选栏词语切换动画偏好、参数映射、槽位差异判定、表现层动画器以及键盘主控端到端接线测试。
@MainActor
final class CandidateTransitionTests: XCTestCase {
  private var previousStyle: CandidateTransitionStyle = CandidateTransitionPreference.defaultStyle
  private var savedScheme: ChineseInputScheme?

  override func setUp() {
    super.setUp()
    previousStyle = CandidateTransitionPreference.style
    savedScheme = InputSchemePreference.scheme
  }

  override func tearDown() {
    CandidateTransitionPreference.style = previousStyle
    if let savedScheme { InputSchemePreference.scheme = savedScheme }
    super.tearDown()
  }

  // MARK: - 偏好与减弱动态效果映射

  func testPreferencePersistsAllStylesAndFallsBackToDefault() {
    for style in CandidateTransitionStyle.allCases {
      CandidateTransitionPreference.style = style
      XCTAssertEqual(CandidateTransitionPreference.style, style)
      XCTAssertFalse(style.title.isEmpty)
    }

    XCTAssertEqual(CandidateTransitionPreference.parse(nil), CandidateTransitionPreference.defaultStyle)
    XCTAssertEqual(CandidateTransitionPreference.parse("unknown_style"), CandidateTransitionPreference.defaultStyle)

    XCTAssertEqual(CandidateTransitionStyle.none.resolved(reduceMotion: true), .none)
    for style in [CandidateTransitionStyle.rise, .drop, .slide, .scale, .fade] {
      XCTAssertEqual(style.resolved(reduceMotion: true), .fade, "\(style) 在减弱动态效果下应柔化为淡入")
      XCTAssertEqual(style.resolved(reduceMotion: false), style)
    }
  }

  func testSpecParametersMatchEachStyle() throws {
    XCTAssertNil(CandidateStripTransitionAnimator.spec(for: .none, reduceMotion: false))
    XCTAssertNil(CandidateStripTransitionAnimator.spec(for: .none, reduceMotion: true))

    let rise = try XCTUnwrap(CandidateStripTransitionAnimator.spec(for: .rise, reduceMotion: false))
    XCTAssertEqual(rise.effectiveStyle, .rise)
    XCTAssertGreaterThanOrEqual(rise.translationY, 18)
    XCTAssertLessThanOrEqual(rise.translationY, 24)
    XCTAssertEqual(rise.translationX, 0)
    XCTAssertEqual(rise.fromScale, 1)
    XCTAssertTrue(rise.usesSpring)
    XCTAssertLessThanOrEqual(rise.motionDuration, 0.16)
    XCTAssertLessThanOrEqual(rise.fadeDuration, 0.12)
    XCTAssertLessThanOrEqual(rise.stagger, 0.010)
    XCTAssertGreaterThanOrEqual(rise.springStiffness, 600)
    XCTAssertGreaterThanOrEqual(rise.springDamping / (2 * sqrt(rise.springStiffness)), 0.90, "上升动效应接近临界阻尼以保持利落收敛")
    XCTAssertGreaterThan(rise.springInitialVelocity, 0, "上升动效应带正向初速度消除静止起步滞后")

    let drop = try XCTUnwrap(CandidateStripTransitionAnimator.spec(for: .drop, reduceMotion: false))
    XCTAssertEqual(drop.effectiveStyle, .drop)
    XCTAssertEqual(drop.translationY, -rise.translationY, "下落行程应与上升严格镜像")
    XCTAssertEqual(drop.translationX, rise.translationX)
    XCTAssertEqual(drop.fromScale, rise.fromScale)
    XCTAssertEqual(drop.fromOpacity, rise.fromOpacity)
    XCTAssertEqual(drop.motionDuration, rise.motionDuration)
    XCTAssertEqual(drop.fadeDuration, rise.fadeDuration)
    XCTAssertEqual(drop.stagger, rise.stagger)
    XCTAssertEqual(drop.maxStaggerStep, rise.maxStaggerStep)
    XCTAssertEqual(drop.usesSpring, rise.usesSpring)
    XCTAssertEqual(drop.springStiffness, rise.springStiffness)
    XCTAssertEqual(drop.springDamping, rise.springDamping)
    XCTAssertEqual(drop.springInitialVelocity, rise.springInitialVelocity, "下落与上升应共享同一正向归一化初速度")

    let slide = try XCTUnwrap(CandidateStripTransitionAnimator.spec(for: .slide, reduceMotion: false))
    XCTAssertEqual(slide.effectiveStyle, .slide)
    XCTAssertGreaterThan(slide.translationX, 0)
    XCTAssertEqual(slide.translationY, 0)

    let scale = try XCTUnwrap(CandidateStripTransitionAnimator.spec(for: .scale, reduceMotion: false))
    XCTAssertEqual(scale.effectiveStyle, .scale)
    XCTAssertLessThan(scale.fromScale, 1)
    XCTAssertGreaterThanOrEqual(scale.fromScale, 0.88)
    XCTAssertGreaterThanOrEqual(scale.springDamping / (2 * sqrt(scale.springStiffness)), 0.75, "弹出动效应柔和舒展、避免生硬回弹")
    XCTAssertEqual(scale.translationX, 0)
    XCTAssertEqual(scale.translationY, 0)

    let fade = try XCTUnwrap(CandidateStripTransitionAnimator.spec(for: .fade, reduceMotion: false))
    XCTAssertEqual(fade.effectiveStyle, .fade)
    XCTAssertEqual(fade.translationX, 0)
    XCTAssertEqual(fade.translationY, 0)
    XCTAssertEqual(fade.fromScale, 1)
    XCTAssertFalse(fade.usesSpring)

    let reduced = try XCTUnwrap(CandidateStripTransitionAnimator.spec(for: .slide, reduceMotion: true))
    XCTAssertEqual(reduced.effectiveStyle, .fade)
    XCTAssertEqual(reduced.translationX, 0)
  }

  // MARK: - 槽位差异与纯 CALayer 动画

  func testChangedOffsetsOnlyReturnsModifiedSlotsAndHandlesHiddenToVisible() {
    XCTAssertEqual(
      CandidateStripTransitionAnimator.changedOffsets(previous: [], current: ["你", "年", "能"], stripWasHidden: true),
      [0, 1, 2]
    )
    XCTAssertEqual(
      CandidateStripTransitionAnimator.changedOffsets(previous: ["你", "年", "能"], current: ["你", "拟", "泥"], stripWasHidden: false),
      [1, 2],
      "未变化的首词不应重复触发切换动画"
    )
    XCTAssertEqual(
      CandidateStripTransitionAnimator.changedOffsets(previous: ["你", "拟", "泥"], current: ["你", "拟", "泥"], stripWasHidden: false),
      [],
      "仅音标/释义或皮肤刷新而候选词不变时不应误触重播"
    )
    XCTAssertEqual(
      CandidateStripTransitionAnimator.changedOffsets(previous: ["你"], current: ["你"], stripWasHidden: true),
      [0],
      "候选栏从隐藏态重新出现时应播放入场过渡"
    )
    XCTAssertEqual(
      CandidateStripTransitionAnimator.changedOffsets(previous: ["你"], current: [], stripWasHidden: false),
      []
    )
  }

  func testAnimatorAttachesExpectedLayerAnimationsWithoutMutatingModelLayer() throws {
    let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 42))
    let buttons = (0..<4).map { index -> UIButton in
      let button = UIButton(frame: CGRect(x: CGFloat(index) * 70, y: 0, width: 64, height: 42))
      button.setTitle("词\(index)", for: .normal)
      scrollView.addSubview(button)
      return button
    }
    let animator = CandidateStripTransitionAnimator()
    let targetLayer: (UIButton) -> CALayer = { CandidateStripTransitionAnimator.animationTargetLayer(for: $0) }
    let clearAll: () -> Void = {
      buttons.forEach {
        $0.layer.removeAllAnimations()
        $0.titleLabel?.layer.removeAllAnimations()
      }
    }

    // 上升动画：首次出现时所有可见词块整块图层（选中气泡与文字同步）都带 opacity + transform.translation.y(>0)，且 titleLabel 不叠加二次动画。
    animator.animateIfNeeded(
      words: ["你", "年", "能"], buttons: buttons, scrollView: scrollView,
      style: .rise, stripVisible: true, suppressed: false, reduceMotion: false
    )
    XCTAssertNil(buttons[0].titleLabel?.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey), "文字图层不应叠加重复动画")
    let riseGroup = try XCTUnwrap(targetLayer(buttons[0]).animation(forKey: CandidateStripTransitionAnimator.animationKey) as? CAAnimationGroup)
    let riseMotion = try XCTUnwrap(riseGroup.animations?.first { ($0 as? CAPropertyAnimation)?.keyPath == "transform.translation.y" } as? CASpringAnimation)
    let riseOpacity = try XCTUnwrap(riseGroup.animations?.first { ($0 as? CAPropertyAnimation)?.keyPath == "opacity" } as? CABasicAnimation)
    let riseFromY = try XCTUnwrap(riseMotion.fromValue as? CGFloat)
    XCTAssertGreaterThan(riseFromY, 0)
    XCTAssertEqual(buttons[0].alpha, 1, "纯表现层动画不得修改模型层 alpha")
    XCTAssertEqual(buttons[0].transform, .identity, "纯表现层动画不得修改模型层 transform")
    XCTAssertNil(targetLayer(buttons[3]).animation(forKey: CandidateStripTransitionAnimator.animationKey), "超出词数的槽位不应挂动画")

    // 清掉旧动画，验证仅发生变化的槽位才触发动画（槽位 0 保持 "你" 不动），且下落弹簧与上升严格镜像对等。
    clearAll()
    animator.animateIfNeeded(
      words: ["你", "拟", "泥"], buttons: buttons, scrollView: scrollView,
      style: .drop, stripVisible: true, suppressed: false, reduceMotion: false
    )
    XCTAssertNil(targetLayer(buttons[0]).animation(forKey: CandidateStripTransitionAnimator.animationKey), "词面未变的槽位 0 不应重播动画")
    let dropGroup = try XCTUnwrap(targetLayer(buttons[1]).animation(forKey: CandidateStripTransitionAnimator.animationKey) as? CAAnimationGroup)
    let dropMotion = try XCTUnwrap(dropGroup.animations?.first { ($0 as? CAPropertyAnimation)?.keyPath == "transform.translation.y" } as? CASpringAnimation)
    let dropOpacity = try XCTUnwrap(dropGroup.animations?.first { ($0 as? CAPropertyAnimation)?.keyPath == "opacity" } as? CABasicAnimation)
    let dropFromY = try XCTUnwrap(dropMotion.fromValue as? CGFloat)
    XCTAssertEqual(dropFromY, -riseFromY, accuracy: 0.001, "下落位移起点应与上升镜像")
    XCTAssertEqual((dropMotion.toValue as? CGFloat) ?? 1, 0, accuracy: 0.001)
    XCTAssertEqual(dropMotion.stiffness, riseMotion.stiffness)
    XCTAssertEqual(dropMotion.damping, riseMotion.damping)
    XCTAssertEqual(dropMotion.mass, riseMotion.mass)
    XCTAssertEqual(dropMotion.initialVelocity, riseMotion.initialVelocity)
    XCTAssertEqual(dropMotion.duration, riseMotion.duration, accuracy: 0.001)
    XCTAssertEqual(dropOpacity.duration, riseOpacity.duration, accuracy: 0.001)

    // 横移与弹出动画分别使用 transform.translation.x 与 transform.scale。
    clearAll()
    animator.animateIfNeeded(
      words: ["明", "天", "见"], buttons: buttons, scrollView: scrollView,
      style: .slide, stripVisible: true, suppressed: false, reduceMotion: false
    )
    let slideGroup = try XCTUnwrap(targetLayer(buttons[0]).animation(forKey: CandidateStripTransitionAnimator.animationKey) as? CAAnimationGroup)
    let slideMotion = try XCTUnwrap(slideGroup.animations?.first { ($0 as? CAPropertyAnimation)?.keyPath == "transform.translation.x" } as? CABasicAnimation)
    XCTAssertGreaterThan((slideMotion.fromValue as? CGFloat) ?? 0, 0)

    clearAll()
    animator.animateIfNeeded(
      words: ["好", "的", "呀"], buttons: buttons, scrollView: scrollView,
      style: .scale, stripVisible: true, suppressed: false, reduceMotion: false
    )
    let scaleGroup = try XCTUnwrap(targetLayer(buttons[0]).animation(forKey: CandidateStripTransitionAnimator.animationKey) as? CAAnimationGroup)
    let scaleMotion = try XCTUnwrap(scaleGroup.animations?.first { ($0 as? CAPropertyAnimation)?.keyPath == "transform.scale" } as? CABasicAnimation)
    XCTAssertLessThan((scaleMotion.fromValue as? CGFloat) ?? 1, 1)

    // 淡入动画只含 opacity。
    clearAll()
    animator.animateIfNeeded(
      words: ["谢", "谢"], buttons: buttons, scrollView: scrollView,
      style: .fade, stripVisible: true, suppressed: false, reduceMotion: false
    )
    let fadeGroup = try XCTUnwrap(targetLayer(buttons[0]).animation(forKey: CandidateStripTransitionAnimator.animationKey) as? CAAnimationGroup)
    XCTAssertEqual(fadeGroup.animations?.compactMap { ($0 as? CAPropertyAnimation)?.keyPath }, ["opacity"])

    // 关闭样式清除残留动画且不添加新动画。
    animator.animateIfNeeded(
      words: ["再", "见"], buttons: buttons, scrollView: scrollView,
      style: .none, stripVisible: true, suppressed: false, reduceMotion: false
    )
    XCTAssertTrue(buttons.allSatisfy {
      $0.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey) == nil
        && $0.titleLabel?.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey) == nil
    })

    // 展开面板抑制态不添加动画。
    animator.animateIfNeeded(
      words: ["测", "试"], buttons: buttons, scrollView: scrollView,
      style: .rise, stripVisible: true, suppressed: true, reduceMotion: false
    )
    XCTAssertTrue(buttons.allSatisfy {
      $0.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey) == nil
        && $0.titleLabel?.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey) == nil
    })
  }

  /// 长词切短词时，第 5–9 个词块在 scrollView 重排前可能仍停留在旧的屏外坐标；所有非隐藏词块都应获得切换动画，不得只动前 4 个。
  func testAnimatorAnimatesAllNineCandidatesEvenWithStaleOffscreenFrames() {
    let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 42))
    let buttons = (0..<9).map { index -> UIButton in
      // 模拟上一轮宽词排版留下的旧坐标：前 4 个在 320pt 视口内，后 5 个在视口右侧以外。
      let button = UIButton(frame: CGRect(x: CGFloat(index) * 90, y: 0, width: 84, height: 42))
      button.setTitle("词\(index)", for: .normal)
      scrollView.addSubview(button)
      return button
    }
    let animator = CandidateStripTransitionAnimator()
    let words = ["你", "拟", "泥", "逆", "尼", "妮", "腻", "匿", "呢"]

    animator.animateIfNeeded(
      words: words, buttons: buttons, scrollView: scrollView,
      style: .rise, stripVisible: true, suppressed: false, reduceMotion: false
    )

    for (index, button) in buttons.enumerated() {
      XCTAssertNotNil(
        button.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey),
        "第 \(index + 1) 个候选词（含气泡）应同步播放切换动画"
      )
      XCTAssertNil(
        button.titleLabel?.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey),
        "第 \(index + 1) 个候选词文字层不应叠加二次动画"
      )
    }
  }

  /// 同一笔滑行手势内：首次实时预览进入时播放一次入场动画，后续 55ms 拖拽刷新以及抬手正式落词交接不得反复重播，消除滑行时的「鬼畜」抽搐。
  func testGlidePreviewAnimatesOncePerStrokeWithoutMidDragOrLiftoffStrobing() {
    let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 42))
    let buttons = (0..<4).map { index -> UIButton in
      let button = UIButton(frame: CGRect(x: CGFloat(index) * 70, y: 0, width: 64, height: 42))
      scrollView.addSubview(button)
      return button
    }
    let animator = CandidateStripTransitionAnimator()
    let clearAll = {
      buttons.forEach { $0.layer.removeAllAnimations() }
    }

    animator.beginGlideStroke()
    // 1. 滑行首帧预览：播放一次入场动画。
    animator.animateIfNeeded(
      words: ["那", "你", "年", "能"], buttons: buttons, scrollView: scrollView,
      style: .rise, stripVisible: true, suppressed: false, isGlidePreview: true, reduceMotion: false
    )
    XCTAssertTrue(buttons.allSatisfy { $0.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey) != nil })

    // 2. 同一笔滑行途中后续 55ms 刷新词面：已播过入场的槽位不得重新挂载动画。
    clearAll()
    animator.animateIfNeeded(
      words: ["你好", "你哈", "你还", "女孩"], buttons: buttons, scrollView: scrollView,
      style: .rise, stripVisible: true, suppressed: false, isGlidePreview: true, reduceMotion: false
    )
    XCTAssertTrue(
      buttons.allSatisfy { $0.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey) == nil },
      "滑行拖拽途中的高频预览更新不得反复重置重播动画"
    )

    // 3. 抬手正式落词交接（isGlidePreview 变回 false）：整栏平滑接管，后排候选也不得二次跳动。
    animator.animateIfNeeded(
      words: ["你好", "你", "您好", "尼好"], buttons: buttons, scrollView: scrollView,
      style: .rise, stripVisible: true, suppressed: false, isGlidePreview: false, reduceMotion: false
    )
    XCTAssertTrue(
      buttons.allSatisfy { $0.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey) == nil },
      "抬手交接瞬间整栏应平滑落地，不得二次弹跳"
    )

    // 4. 下一笔新滑行（或普通按键输入）：重新允许入场动画。
    animator.beginGlideStroke()
    animator.animateIfNeeded(
      words: ["今天", "今年", "今晚", "今日"], buttons: buttons, scrollView: scrollView,
      style: .rise, stripVisible: true, suppressed: false, isGlidePreview: true, reduceMotion: false
    )
    XCTAssertTrue(
      buttons.allSatisfy { $0.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey) != nil },
      "开启新一笔滑行后首次预览应正常播放一次入场动画"
    )
  }

  // MARK: - 键盘主控端到端接线

  func testKeyboardViewControllerTriggersAnimationAccordingToPreference() throws {
    enableAllInputSchemes()
    InputSchemePreference.scheme = .quanpin
    CandidateTransitionPreference.style = .slide

    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: KeyboardViewController.defaultKeyboardHeight)
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()

    let keyN = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "字母 N" } as? UIButton)
    keyN.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()

    let firstChip = try XCTUnwrap(
      descendants(controller.view).first { $0.accessibilityIdentifier == "candidate-1" && !$0.isHidden } as? UIButton,
      "输入 N 后候选栏应出现候选词块"
    )
    XCTAssertNotNil(
      firstChip.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey),
      "开启横移样式时首选选中气泡应与第一个候选词同步播放切换动画"
    )
    XCTAssertNil(
      firstChip.titleLabel?.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey),
      "首词文字层不应叠加重复动画导致与气泡错位"
    )

    // 切换为「关闭」后重新出现，再输入新字母不应再挂载切换动画。
    controller.viewWillDisappear(false)
    CandidateTransitionPreference.style = .none
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()
    for view in descendants(controller.view) {
      view.layer.removeAnimation(forKey: CandidateStripTransitionAnimator.animationKey)
    }

    let keyW = try XCTUnwrap(descendants(controller.view).first { $0.accessibilityLabel == "字母 W" } as? UIButton)
    keyW.sendActions(for: .primaryActionTriggered)
    controller.view.layoutIfNeeded()

    let activeChips = descendants(controller.view).compactMap { view -> UIButton? in
      guard let button = view as? UIButton, !button.isHidden,
            button.accessibilityIdentifier?.hasPrefix("candidate-") == true else { return nil }
      return button
    }
    XCTAssertFalse(activeChips.isEmpty)
    XCTAssertTrue(
      activeChips.allSatisfy {
        $0.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey) == nil
          && $0.titleLabel?.layer.animation(forKey: CandidateStripTransitionAnimator.animationKey) == nil
      },
      "样式切为关闭后不应挂载候选词切换动画"
    )
    controller.viewWillDisappear(false)
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }
}
