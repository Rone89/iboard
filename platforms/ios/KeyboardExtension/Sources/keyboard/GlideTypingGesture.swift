import UIKit

/// 键区上的滑行输入手势（#5347）。挂在 `KeyAreaStackView` 上，看得到键区里每一根手指的整个触摸序列。
///
/// 一根落在字母键上的手指在滑到另一个字母键、且横向走过足够距离之前（`GlideTyping.startsGlide`），手势一直停在 `.possible`，按键照常收到全部触摸，轻点、键帽放大等都不受影响；`delaysTouchesEnded` 关掉，所以抬手也不会被推迟。一旦判定为滑行，手势进入 `.began`，`cancelsTouchesInView` 让 UIKit 取消原来那个键的触摸：它不上屏、不留高亮，放大预览也随之收起。滑行开始前第二根手指落下，这次手势失败，两根手指照常打字；滑行开始后落下的手指一律忽略。
final class GlideTypingGestureRecognizer: UIGestureRecognizer {
  /// 此刻能否开始滑行（设置打开、显示的是全拼 26 键字母层等），手指按下时问一次。
  var isArmed: @MainActor () -> Bool = { false }
  /// 触摸命中的视图属于哪个字母键（`GlideTyping.letters` 里的下标），不是字母键时为 nil。
  var letterIndex: @MainActor (UIView) -> Int? = { _ in nil }
  /// 二十六个字母键在手势所在视图坐标里的布局矩形，按 a..z 排列；按下时取一次，整笔滑行都用它。
  var keyFrames: @MainActor () -> [CGRect] = { [] }
  var onBegan: @MainActor () -> Void = {}
  /// 滑行开始后每次移动都带着到目前为止的全部采样，用来画轨迹。
  var onMoved: @MainActor ([GlideTyping.Sample]) -> Void = { _ in }
  /// 抬手：这一笔的全部采样，以及按下时取的字母键矩形。
  var onEnded: @MainActor ([GlideTyping.Sample], [CGRect]) -> Void = { _, _ in }
  /// 系统打断了滑行（来电、键盘收起等），什么都不发送。
  var onCancelled: @MainActor () -> Void = {}

  private var tracked: UITouch?
  private var downKey = 0
  private var downLocation = CGPoint.zero
  private var downTime: TimeInterval = 0
  private var frames: [CGRect] = []
  private var samples: [GlideTyping.Sample] = []
  /// 滑行已经开始、还没有交给 `onEnded` 或 `onCancelled`。手势不经过抬手或系统取消就被重置时（例如被停用）据此补一次 `onCancelled`，键区不会一直挡着新的手指。
  private var unfinished = false

  init() {
    super.init(target: nil, action: nil)
    cancelsTouchesInView = true
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }

  private var isGliding: Bool { state == .began || state == .changed }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    guard tracked == nil else {
      // 滑行开始前又落下一根手指：放弃这次判定，两根手指照常打字。滑行开始后落下的手指不参与。
      if isGliding {
        for touch in touches { ignore(touch, for: event) }
      } else {
        state = .failed
      }
      return
    }
    guard touches.count == 1, let touch = touches.first, let view, let hit = touch.view,
          isArmed(), let key = letterIndex(hit) else {
      state = .failed
      return
    }
    let frames = keyFrames()
    guard frames.count == GlideTyping.letters.count else {
      state = .failed
      return
    }
    tracked = touch
    downKey = key
    downLocation = touch.location(in: view)
    downTime = touch.timestamp
    self.frames = frames
    samples = [GlideTyping.Sample(x: downLocation.x, y: downLocation.y, milliseconds: 0)]
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesMoved(touches, with: event)
    guard let touch = tracked, touches.contains(touch), let view else { return }
    // 合并的触摸带着两帧之间的全部采样，快速滑过一个键时也不会漏掉它。
    for sample in event.coalescedTouches(for: touch) ?? [touch] { record(sample, in: view) }
    if isGliding {
      state = .changed
      onMoved(samples)
    } else if state == .possible,
              GlideTyping.startsGlide(downKey: downKey, down: downLocation, current: touch.location(in: view), frames: frames) {
      state = .began
      unfinished = true
      onBegan()
      onMoved(samples)
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesEnded(touches, with: event)
    guard let touch = tracked, touches.contains(touch) else { return }
    guard isGliding else {
      state = .failed
      return
    }
    if let view { record(touch, in: view) }
    state = .ended
    unfinished = false
    onEnded(samples, frames)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesCancelled(touches, with: event)
    guard let touch = tracked, touches.contains(touch) else { return }
    guard isGliding else {
      state = .failed
      return
    }
    state = .cancelled
    unfinished = false
    onCancelled()
  }

  override func reset() {
    super.reset()
    if unfinished {
      unfinished = false
      onCancelled()
    }
    tracked = nil
    frames = []
    samples = []
  }

  private func record(_ touch: UITouch, in view: UIView) {
    let point = touch.location(in: view)
    let elapsed = max(0, (touch.timestamp - downTime) * 1_000)
    if let last = samples.last, last.x == point.x, last.y == point.y, last.milliseconds == elapsed { return }
    GlideTyping.appendBounded(
      GlideTyping.Sample(x: point.x, y: point.y, milliseconds: elapsed), to: &samples)
  }
}

/// 滑行时跟着手指画在键盘上的轨迹：1:1 复刻 Y 键盘的 `SwipeTrailView`
/// （几何见 `SwipeTrailGeometry`，自 GlideKeyboard MIT 移植）——单一
/// `CAShapeLayer`、固定半透明灰填充、无描边、随明暗不变。抬手淡出冻结帧。
/// 不接触摸，也不进无障碍树。
final class GlideTrailView: UIView {
  private let shape = CAShapeLayer()

  private(set) var geometry = SwipeTrailGeometry()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    accessibilityElementsHidden = true
    accessibilityIdentifier = "glideTrail"
    // 参照初始化：UIColor(white: 0.66, alpha: 0.32)，从不改变。
    shape.fillColor = UIColor(white: 0.66, alpha: 0.32).cgColor
    shape.strokeColor = nil
    shape.fillRule = .nonZero
    layer.addSublayer(shape)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    shape.frame = bounds
  }

  /// 是否正画着一条轨迹（淡出中的也算）。
  var hasTrail: Bool { !geometry.isEmpty }

  /// `color` 为调用点兼容保留、不使用：参照的填充固定为灰，明暗一致
  /// （GlideKeyboard 移植时保留了同样的参照特征）。每个采样进几何后按
  /// 参照裁剪重建色带；<2pt 的密采样被丢弃，超过 150pt 的旧尾巴滑出窗口。
  ///
  /// iBoard 没有 GK 的 begin(at:)，draw 就是每一笔的入口：先按参照
  /// clearStroke 的次序移走上一笔的淡出动画、恢复不透明度。淡出动画
  /// `isRemovedOnCompletion = false` + `fillMode = .forwards`，不清的话它
  /// 会把新一笔的展示层永久压在透明度 0 上——轨迹看起来就丢了。
  func draw(_ samples: [GlideTyping.Sample], color: UIColor) {
    shape.removeAnimation(forKey: "fade")
    geometry.reset()
    for sample in samples { geometry.append(CGPoint(x: sample.x, y: sample.y)) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shape.opacity = 1
    CATransaction.commit()
    redraw()
  }

  /// 抬手后重画一次冻结帧再淡出：透明度 1→0、0.4s easeOut、动画键 "fade"，
  /// 模型透明度立即置 0。淡出途中开始新的一笔时 `draw` 会把动画移走。
  func fadeOut() {
    guard !geometry.isEmpty else { return }
    redraw()
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    fade.duration = 0.4
    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    fade.isRemovedOnCompletion = false
    fade.fillMode = .forwards
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shape.opacity = 0
    CATransaction.commit()
    shape.add(fade, forKey: "fade")
  }

  /// 立刻清空，不做动画（滑行被系统打断时）。
  func clear() {
    shape.removeAnimation(forKey: "fade")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shape.opacity = 1
    shape.path = nil
    CATransaction.commit()
    geometry.reset()
  }

  /// 重建色带路径；隐式动画关闭，色带不在采样之间漂移。
  private func redraw() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shape.path = geometry.path()
    CATransaction.commit()
  }
}
