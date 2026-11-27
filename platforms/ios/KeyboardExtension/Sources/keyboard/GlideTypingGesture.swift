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
  /// 按下键是否允许纵向直接起滑（当同键启用了同向角标纵滑时收紧）。
  var allowsVerticalGlide: @MainActor (Int, CGPoint, CGPoint) -> Bool = { _, _, _ in true }
  /// 按下时刻是否正处于快速点按打字节律内（26 键连打时提高起滑门槛防误触）。
  var isRapidTyping: @MainActor () -> Bool = { false }
  /// 按下键是否已触发角标符号或长按弹窗；一旦触发立即放弃滑行判定，避免横移拖选时误抢手势。
  var shouldAbortBeforeStarting: @MainActor (Int) -> Bool = { _ in false }
  var onBegan: @MainActor () -> Void = {}
  /// 滑行开始后每次移动都带着到目前为止的全部采样，用来画轨迹。
  var onMoved: @MainActor ([GlideTyping.Sample]) -> Void = { _ in }
  /// 抬手：这一笔的全部采样，以及按下时取的字母键矩形。
  var onEnded: @MainActor ([GlideTyping.Sample], [CGRect]) -> Void = { _, _ in }
  /// 系统打断了滑行（来电、键盘收起等），什么都不发送。
  var onCancelled: @MainActor () -> Void = {}

  /// 系统预测的下一帧触点（仅用于轨迹笔尖视觉超前补偿，从不写入解码采样 `samples`）。
  private(set) var predictedPoints: [CGPoint] = []
  /// 当前这一笔起手时快照到的 26 字母键矩形，供实时预览读取。
  var currentFrames: [CGRect] { frames }
  /// 当前这一笔已累计的轨迹弧长（pt），增量维护，供 120Hz 实时预览以 O(1) 读取而无需每帧重扫全部采样。
  private(set) var cumulativePathLength: CGFloat = 0
  private var tracked: UITouch?
  private var downKey = 0
  private var downLocation = CGPoint.zero
  private var downTime: TimeInterval = 0
  private var startedInGap = false
  private var rapidTypingAtDown = false
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
      // 滑行开始前又落下一根手指：放弃这次判定，两根手指照常打字。
      // 若刚进入滑行不到 80–90ms 且路径很短时第二指立刻落下，大概率是双指快打 rollover 误起滑行，直接取消本次滑行让位给正常打字。
      if isGliding {
        let elapsedMs = (touches.first?.timestamp ?? downTime) - downTime
        let isNineKey = GlideTyping.isNineKeyFrames(frames)
        let refSpan = frames.filter { !$0.isEmpty }.map { isNineKey ? min($0.width, $0.height) : $0.width }.min() ?? 0
        let isEarlyRollover: Bool
        if isNineKey {
          isEarlyRollover = elapsedMs < 0.08
            && refSpan > 0
            && cumulativePathLength < refSpan * 0.85
        } else {
          isEarlyRollover = elapsedMs < 0.09
            && refSpan > 0
            && cumulativePathLength < refSpan * 1.35
        }
        if isEarlyRollover {
          state = .cancelled
          unfinished = false
          onCancelled()
        } else {
          for touch in touches { ignore(touch, for: event) }
        }
      } else {
        state = .failed
      }
      return
    }
    guard touches.count == 1, let touch = touches.first, let view, let hit = touch.view,
          isArmed() else {
      state = .failed
      return
    }
    let direct = letterIndex(hit)
    // 落在 Shift/退格/空格/123/回车等非字母按钮上时立刻短路，避免对每个功能键按下都触发 26 次坐标换算。
    if direct == nil && (hit is UIButton) {
      state = .failed
      return
    }
    let frames = keyFrames()
    guard frames.count == GlideTyping.letters.count else {
      state = .failed
      return
    }
    let location = touch.location(in: view)
    let gapPadding: CGFloat = GlideTyping.isNineKeyFrames(frames) ? 10 : GlideTyping.twentySixKeyGapPadding
    let key: Int
    if let direct {
      key = direct
      startedInGap = false
    } else if let snapped = GlideTyping.nearestKeyIndex(at: location, in: frames, maxGapPadding: gapPadding) {
      // 拇指落在两枚字母键之间的键缝时吸附到最近字母键起滑。
      key = snapped
      startedInGap = true
    } else {
      state = .failed
      return
    }
    tracked = touch
    downKey = key
    downLocation = location
    downTime = touch.timestamp
    rapidTypingAtDown = isRapidTyping()
    self.frames = frames
    cumulativePathLength = 0
    samples = [GlideTyping.Sample(x: downLocation.x, y: downLocation.y, milliseconds: 0)]
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesMoved(touches, with: event)
    guard let touch = tracked, touches.contains(touch), let view else { return }
    // 合并的触摸带着两帧之间的全部采样，快速滑过一个键时也不会漏掉它。
    for sample in event.coalescedTouches(for: touch) ?? [touch] { record(sample, in: view) }
    predictedPoints = (event.predictedTouches(for: touch) ?? []).prefix(2).map { $0.location(in: view) }
    if isGliding {
      state = .changed
      onMoved(samples)
    } else if state == .possible {
      if shouldAbortBeforeStarting(downKey) {
        state = .failed
        return
      }
      let current = touch.location(in: view)
      let allowVertical = allowsVerticalGlide(downKey, downLocation, current)
      let elapsed = touch.timestamp - downTime
      let velocity: CGFloat = elapsed >= 0.014
        ? hypot(current.x - downLocation.x, current.y - downLocation.y) / CGFloat(elapsed)
        : 0
      if GlideTyping.startsGlide(downKey: downKey, down: downLocation, current: current, frames: frames,
                                 allowsVerticalGlide: allowVertical,
                                 rapidTyping: rapidTypingAtDown,
                                 startedInGap: startedInGap,
                                 velocity: velocity) {
        state = .began
        unfinished = true
        onBegan()
        onMoved(samples)
      }
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
    if GlideTyping.isAccidentalShortSlip(samples: samples, frames: frames, pathLength: cumulativePathLength) {
      state = .cancelled
      unfinished = false
      onCancelled()
      return
    }
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
    startedInGap = false
    rapidTypingAtDown = false
    frames = []
    samples = []
    predictedPoints = []
    cumulativePathLength = 0
  }

  private func record(_ touch: UITouch, in view: UIView) {
    let point = touch.location(in: view)
    let elapsed = max(0, (touch.timestamp - downTime) * 1_000)
    if let last = samples.last {
      if last.x == point.x, last.y == point.y, last.milliseconds == elapsed { return }
      let dx = point.x - last.x
      let dy = point.y - last.y
      if dx.isFinite, dy.isFinite {
        cumulativePathLength += hypot(dx, dy)
      }
    }
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
  func draw(_ samples: [GlideTyping.Sample], predicted: [CGPoint] = [], color: UIColor) {
    shape.removeAnimation(forKey: "fade")
    geometry.reset()
    // 轨迹只展示最近 `windowLength`（150pt）的弧长：逆向截取末尾窗口再做平滑，避免长词滑行时每帧 O(N²) 重建整段历史。
    let tailBudget = SwipeTrailGeometry.windowLength + 24
    var startIndex = samples.count
    var accumulated: CGFloat = 0
    if !samples.isEmpty {
      startIndex = samples.count - 1
      var prev = samples[startIndex]
      while startIndex > 0, accumulated < tailBudget {
        startIndex -= 1
        let cur = samples[startIndex]
        accumulated += hypot(prev.x - cur.x, prev.y - cur.y)
        prev = cur
      }
    }
    var windowPoints: [CGPoint] = []
    windowPoints.reserveCapacity((samples.count - startIndex) + predicted.count)
    for index in startIndex..<samples.count {
      windowPoints.append(CGPoint(x: samples[index].x, y: samples[index].y))
    }
    for point in predicted where point.x.isFinite && point.y.isFinite {
      windowPoints.append(point)
    }
    geometry.replace(with: SwipeTrailGeometry.smoothed(windowPoints))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shape.opacity = 1
    CATransaction.commit()
    redraw()
  }

  /// 抬手后重画一次冻结帧，并以「向笔尖收束 + 透明度渐隐」组合动画消散（0.18s 舒缓出曲线、动画键 "fade"），
  /// 模型透明度立即置 0。淡出途中开始新的一笔时 `draw` 会把动画移走。
  func fadeOut() {
    guard !geometry.isEmpty else { return }
    let startPath = geometry.path()
    let endPath = geometry.retractedPath()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shape.path = startPath
    shape.opacity = 0
    CATransaction.commit()

    let curve = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0

    let retract = CABasicAnimation(keyPath: "path")
    retract.fromValue = startPath
    retract.toValue = endPath

    let group = CAAnimationGroup()
    group.animations = [fade, retract]
    group.duration = 0.18
    group.timingFunction = curve
    group.isRemovedOnCompletion = false
    group.fillMode = .forwards
    shape.add(group, forKey: "fade")
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

/// 滑行途中音节拐点与驻留锚定检测器：
/// - 仅在手指发生明显折转（夹角 >= 68°，即 `cos <= 0.37`）或在某键上短暂驻留（`>= 85ms` 且位移受限）时触发；
/// - 直线匀速掠过的中间过路键绝不误触发；
/// - 带 `65ms` 最小时间门控与同键去重，供键盘主控对拐点目标键施加轻柔脉冲高亮与微触感反馈。
struct GlideInflectionTracker: Equatable {
  /// 最小折转余弦阈值（约 68° 转向）。
  static let cornerCosineThreshold: CGFloat = 0.37
  /// 计算折转向量的最小弦长（pt），过滤原地高频微抖。
  static let minimumChordLength: CGFloat = 12
  /// 判定键内驻留的最短持续时间（毫秒）。
  static let dwellDurationMs: Double = 85
  /// 驻留判定的最大活动半径（pt）。
  static let dwellRadius: CGFloat = 11
  /// 两次拐点锚定反馈之间的最小冷却间隔（毫秒）。
  static let minimumCooldownMs: Double = 65

  private(set) var lastAnchoredKey: Int?
  private(set) var lastAnchorTimeMs: Double = -.infinity

  mutating func reset(initialKey: Int? = nil) {
    lastAnchoredKey = initialKey
    lastAnchorTimeMs = -.infinity
  }

  /// 检查最新采样是否在某个新按键上形成了有效拐点或驻留锚定；命中时返回该键下标（26 键为 `0..<26`，九键为其代表槽位下标）。
  mutating func detectAnchor(samples: [GlideTyping.Sample], frames: [CGRect]) -> Int? {
    guard samples.count >= 4,
          frames.count == GlideTyping.letters.count,
          let latest = samples.last else { return nil }
    guard latest.milliseconds - lastAnchorTimeMs >= Self.minimumCooldownMs else { return nil }

    let latestPoint = CGPoint(x: latest.x, y: latest.y)
    guard let currentKey = GlideTyping.keyIndex(at: latestPoint, in: frames),
          currentKey != lastAnchoredKey else { return nil }

    let isNineKey = GlideTyping.isNineKeyFrames(frames)
    let nineKeyMinSide = isNineKey
      ? (frames.first(where: { !$0.isEmpty }).map { min($0.width, $0.height) } ?? 49)
      : 0
    let effectiveDwellRadius: CGFloat = isNineKey
      ? max(14, nineKeyMinSide * 0.30)
      : Self.dwellRadius
    let effectiveChordLength: CGFloat = isNineKey
      ? max(18, nineKeyMinSide * 0.42)
      : Self.minimumChordLength

    // 1. 键内驻留判定：最近 85ms 内的采样全部停留在有效驻留半径以内。
    var dwellCandidate = false
    for index in stride(from: samples.count - 2, through: 0, by: -1) {
      let sample = samples[index]
      if hypot(latest.x - sample.x, latest.y - sample.y) > effectiveDwellRadius {
        break
      }
      if latest.milliseconds - sample.milliseconds >= Self.dwellDurationMs {
        dwellCandidate = true
        break
      }
    }
    if dwellCandidate {
      lastAnchoredKey = currentKey
      lastAnchorTimeMs = latest.milliseconds
      return currentKey
    }

    // 2. 明显拐弯判定：以最新采样为出射点，向前回溯找到距离 >= effectiveChordLength 的拐点顶点与入射锚点。
    var vertexIndex: Int?
    for index in stride(from: samples.count - 2, through: 1, by: -1) {
      let dist = hypot(latest.x - samples[index].x, latest.y - samples[index].y)
      if dist >= effectiveChordLength {
        vertexIndex = index
        break
      }
    }
    guard let vIdx = vertexIndex, vIdx >= 1 else { return nil }
    let vertex = samples[vIdx]
    let vertexPoint = CGPoint(x: vertex.x, y: vertex.y)
    guard let vertexKey = GlideTyping.keyIndex(at: vertexPoint, in: frames),
          vertexKey != lastAnchoredKey else { return nil }

    var entryIndex: Int?
    for index in stride(from: vIdx - 1, through: 0, by: -1) {
      let dist = hypot(vertex.x - samples[index].x, vertex.y - samples[index].y)
      if dist >= effectiveChordLength {
        entryIndex = index
        break
      }
    }
    guard let eIdx = entryIndex else { return nil }
    let entry = samples[eIdx]
    let inDx = vertex.x - entry.x
    let inDy = vertex.y - entry.y
    let outDx = latest.x - vertex.x
    let outDy = latest.y - vertex.y
    let inLen = hypot(inDx, inDy)
    let outLen = hypot(outDx, outDy)
    guard inLen > 0.5, outLen > 0.5 else { return nil }
    let cosine = (inDx * outDx + inDy * outDy) / (inLen * outLen)
    guard cosine <= Self.cornerCosineThreshold else { return nil }

    lastAnchoredKey = vertexKey
    lastAnchorTimeMs = latest.milliseconds
    return vertexKey
  }
}
