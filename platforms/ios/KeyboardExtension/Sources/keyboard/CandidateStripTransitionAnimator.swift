import QuartzCore
import UIKit

/// 候选栏单个词块切换动画的纯参数描述（便于单测断言各样式参数）。
struct CandidateTransitionSpec: Equatable {
  let effectiveStyle: CandidateTransitionStyle
  let translationX: CGFloat
  let translationY: CGFloat
  let fromScale: CGFloat
  let fromOpacity: Float
  let motionDuration: CFTimeInterval
  let fadeDuration: CFTimeInterval
  let stagger: CFTimeInterval
  /// 级联延迟的最大步数上限：超出该序号的词块照常播放动画，只封顶延迟避免后排候选显得拖沓。
  let maxStaggerStep: Int
  let usesSpring: Bool
  let springStiffness: CGFloat
  let springDamping: CGFloat
  let springInitialVelocity: CGFloat
}

/// 候选栏词语切换动画器。
///
/// 通过纯 `CALayer` 表现层 `CAAnimationGroup` 驱动过渡：
/// - 模型层的 `frame`、`transform`、`alpha` 始终处于最终落位，快速打字中途点击候选不会丢命中，也不会干扰展开面板的可见范围计算；
/// - 仅对文字实际发生变化的词块（或从空/隐藏态重新出现时）按可见顺序做轻微级联，音标/释义晚到或换肤重涂不会误触重播；
/// - 同一图层以固定 key 覆盖添加动画，高速连打时自动平滑替换上一轮未播完的过渡。
@MainActor
final class CandidateStripTransitionAnimator {
  static let animationKey = "msime.candidateWordTransition"

  private var lastDisplayedWords: [String] = []
  private var wasShowingStrip = false
  private var wasShowingGlidePreview = false
  /// 当前这一笔滑行手势中已经播放过入场动画的槽位集合：同一笔滑行内的后续 55ms 预览刷新与抬手交接不再重复重置动画，消除高频抽搐。
  private var animatedInCurrentGlide: Set<Int> = []

  /// 新一笔滑行起手时调用，允许该笔滑行首次出现候选时正常播放一次入场过渡。
  func beginGlideStroke() {
    animatedInCurrentGlide.removeAll()
    wasShowingGlidePreview = false
  }

  /// 纵向切换样式（`.rise` / `.drop`）共用的高刚度近临界阻尼弹簧参数，保证上升与下落手感严格一致。
  private static let verticalTranslationDistance: CGFloat = 20

  private static func verticalSpringSpec(
    effectiveStyle: CandidateTransitionStyle,
    translationY: CGFloat
  ) -> CandidateTransitionSpec {
    CandidateTransitionSpec(
      effectiveStyle: effectiveStyle,
      translationX: 0,
      translationY: translationY,
      fromScale: 1,
      fromOpacity: 0,
      motionDuration: 0.14,
      fadeDuration: 0.10,
      stagger: 0.008,
      maxStaggerStep: 5,
      usesSpring: true,
      springStiffness: 680,
      springDamping: 50.0,
      springInitialVelocity: 8.0
    )
  }

  /// 根据用户样式与系统「减弱动态效果」计算实际动画参数；`.none` 返回 `nil`。
  static func spec(for style: CandidateTransitionStyle, reduceMotion: Bool) -> CandidateTransitionSpec? {
    let effective = style.resolved(reduceMotion: reduceMotion)
    switch effective {
    case .none:
      return nil
    case .rise:
      return verticalSpringSpec(effectiveStyle: .rise, translationY: verticalTranslationDistance)
    case .drop:
      return verticalSpringSpec(effectiveStyle: .drop, translationY: -verticalTranslationDistance)
    case .slide:
      return CandidateTransitionSpec(
        effectiveStyle: .slide,
        translationX: 22,
        translationY: 0,
        fromScale: 1,
        fromOpacity: 0,
        motionDuration: 0.15,
        fadeDuration: 0.10,
        stagger: 0.008,
        maxStaggerStep: 5,
        usesSpring: true,
        springStiffness: 640,
        springDamping: 48.5,
        springInitialVelocity: 8.0
      )
    case .scale:
      return CandidateTransitionSpec(
        effectiveStyle: .scale,
        translationX: 0,
        translationY: 0,
        fromScale: 0.88,
        fromOpacity: 0,
        motionDuration: 0.14,
        fadeDuration: 0.10,
        stagger: 0.008,
        maxStaggerStep: 5,
        usesSpring: true,
        springStiffness: 700,
        springDamping: 45.0,
        springInitialVelocity: 8.0
      )
    case .fade:
      return CandidateTransitionSpec(
        effectiveStyle: .fade,
        translationX: 0,
        translationY: 0,
        fromScale: 1,
        fromOpacity: 0,
        motionDuration: 0.11,
        fadeDuration: 0.11,
        stagger: 0.008,
        maxStaggerStep: 5,
        usesSpring: false,
        springStiffness: 0,
        springDamping: 0,
        springInitialVelocity: 0
      )
    }
  }

  /// 计算本轮需要播放切换动画的候选槽位下标：
  /// 候选条从隐藏或空列表出现时全部变化；持续组字期间仅对词面发生改变或新出现的槽位触发。
  static func changedOffsets(previous: [String], current: [String], stripWasHidden: Bool) -> [Int] {
    guard !current.isEmpty else { return [] }
    if stripWasHidden || previous.isEmpty {
      return Array(current.indices)
    }
    var changed: [Int] = []
    changed.reserveCapacity(current.count)
    for index in current.indices where !previous.indices.contains(index) || previous[index] != current[index] {
      changed.append(index)
    }
    return changed
  }

  /// 候选栏收起、键盘消失或内存告警时重置追踪态并清理残留动画。
  func reset(buttons: [UIView]) {
    lastDisplayedWords = []
    wasShowingStrip = false
    wasShowingGlidePreview = false
    animatedInCurrentGlide.removeAll()
    for view in buttons {
      view.layer.removeAnimation(forKey: Self.animationKey)
      if let button = view as? UIButton {
        button.titleLabel?.layer.removeAnimation(forKey: Self.animationKey)
      }
    }
  }

  /// 返回候选按钮的动画目标图层：直接作用于按钮整块 `button.layer`，
  /// 让首选的选中气泡、胶囊描边、选中条与首个候选词文字完全同步运动、绝不分离。
  static func animationTargetLayer(for button: UIButton) -> CALayer {
    button.layer
  }

  /// 比对前后候选词，对发生变化的可见词块整块图层施加对应样式的表现层动画（选中气泡与首个候选词保持一致）。
  func animateIfNeeded(
    words: [String],
    buttons: [UIButton],
    scrollView: UIScrollView,
    style: CandidateTransitionStyle,
    stripVisible: Bool,
    suppressed: Bool,
    isGlidePreview: Bool = false,
    reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled
  ) {
    guard stripVisible, !words.isEmpty else {
      reset(buttons: buttons)
      return
    }
    if isGlidePreview && !wasShowingGlidePreview {
      animatedInCurrentGlide.removeAll()
    } else if !isGlidePreview && !wasShowingGlidePreview {
      animatedInCurrentGlide.removeAll()
    }
    let handingOffFromGlidePreview = wasShowingGlidePreview && !isGlidePreview
    let changed = Self.changedOffsets(previous: lastDisplayedWords, current: words, stripWasHidden: !wasShowingStrip)
    lastDisplayedWords = words
    wasShowingStrip = true
    wasShowingGlidePreview = isGlidePreview

    guard let spec = Self.spec(for: style, reduceMotion: reduceMotion) else {
      for button in buttons {
        button.layer.removeAnimation(forKey: Self.animationKey)
        button.titleLabel?.layer.removeAnimation(forKey: Self.animationKey)
      }
      return
    }
    guard !suppressed, !changed.isEmpty else { return }

    // 滑行实时预览在拖拽途中已完成候选栏入场过渡时，抬手正式落词交接不再令后排槽位二次跳动。
    if handingOffFromGlidePreview && !animatedInCurrentGlide.isEmpty {
      animatedInCurrentGlide.removeAll()
      return
    }

    // 不按布局前坐标裁切视口：长词切短词时，第 5 个及以后的词块在 `scrollView` 重排前仍保留旧的屏外坐标，
    // 按旧 `frame` 过滤会漏掉当帧刚滑入视口的后排候选。单页候选数至多 9 个，全部挂载轻量 GPU 动画即可，仅封顶级联延迟步数。
    var animatedIndex = 0
    for offset in changed {
      guard buttons.indices.contains(offset) else { continue }
      let button = buttons[offset]
      guard !button.isHidden else { continue }
      if isGlidePreview {
        if animatedInCurrentGlide.contains(offset) {
          continue
        }
        animatedInCurrentGlide.insert(offset)
      }
      let targetLayer = Self.animationTargetLayer(for: button)
      button.titleLabel?.layer.removeAnimation(forKey: Self.animationKey)
      let isInterrupting = targetLayer.animation(forKey: Self.animationKey) != nil
      let delay = isInterrupting ? 0 : CFTimeInterval(min(animatedIndex, spec.maxStaggerStep)) * spec.stagger
      let group = Self.makeAnimationGroup(spec: spec, delay: delay, layer: targetLayer, isInterrupting: isInterrupting)
      targetLayer.add(group, forKey: Self.animationKey)
      animatedIndex += 1
    }
  }

  /// 为指定图层构造表现层 `CAAnimationGroup`。
  static func makeAnimationGroup(
    spec: CandidateTransitionSpec,
    delay: CFTimeInterval,
    layer: CALayer,
    isInterrupting: Bool = false
  ) -> CAAnimationGroup {
    var animations: [CAAnimation] = []
    let motionScale: CGFloat = isInterrupting ? 0.55 : 1.0
    let startOpacity: Float = isInterrupting
      ? max(layer.presentation()?.opacity ?? 0.65, 0.55)
      : spec.fromOpacity

    let smoothEase = CAMediaTimingFunction(controlPoints: 0.22, 0.68, 0.28, 1.0)
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = startOpacity
    opacity.toValue = Float(1.0)
    opacity.duration = spec.fadeDuration
    opacity.timingFunction = smoothEase
    opacity.fillMode = .both
    animations.append(opacity)

    if spec.translationY != 0 {
      animations.append(makeMotionAnimation(
        keyPath: "transform.translation.y",
        fromValue: spec.translationY * motionScale,
        toValue: CGFloat(0),
        spec: spec
      ))
    }
    if spec.translationX != 0 {
      animations.append(makeMotionAnimation(
        keyPath: "transform.translation.x",
        fromValue: spec.translationX * motionScale,
        toValue: CGFloat(0),
        spec: spec
      ))
    }
    if spec.fromScale != 1 {
      let startScale = isInterrupting ? (1.0 - (1.0 - spec.fromScale) * motionScale) : spec.fromScale
      animations.append(makeMotionAnimation(
        keyPath: "transform.scale",
        fromValue: startScale,
        toValue: CGFloat(1.0),
        spec: spec
      ))
    }

    let group = CAAnimationGroup()
    group.animations = animations
    group.duration = animations.map(\.duration).max() ?? spec.motionDuration
    group.isRemovedOnCompletion = true
    if delay > 0 {
      group.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
      group.fillMode = .backwards
    }
    return group
  }

  private static func makeMotionAnimation(
    keyPath: String,
    fromValue: Any,
    toValue: Any,
    spec: CandidateTransitionSpec
  ) -> CAAnimation {
    if spec.usesSpring {
      let spring = CASpringAnimation(keyPath: keyPath)
      spring.fromValue = fromValue
      spring.toValue = toValue
      spring.stiffness = spec.springStiffness
      spring.damping = spec.springDamping
      spring.mass = 1.0
      // `CASpringAnimation.initialVelocity` 按 `toValue - fromValue` 归一化，正值在 `.rise`（+20->0）与 `.drop`（-20->0）下均沿目标方向加速。
      spring.initialVelocity = spec.springInitialVelocity
      spring.duration = min(spring.settlingDuration, spec.motionDuration + 0.04)
      spring.fillMode = .both
      return spring
    }
    let basic = CABasicAnimation(keyPath: keyPath)
    basic.fromValue = fromValue
    basic.toValue = toValue
    basic.duration = spec.motionDuration
    basic.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 0.0, 0.25, 1.0)
    basic.fillMode = .both
    return basic
  }
}
