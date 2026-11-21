import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 候选栏垂直轻滑手势：未展开时向下轻滑展开候选面板，已展开时向上轻滑收起；
/// 锁定首个达到阈值的方向，避免横向浏览候选后手指上下偏移误触。
final class CandidateStripVerticalSwipeRecognizer: UIGestureRecognizer {
  enum Direction: Equatable {
    case down
    case up
  }

  static let activationDistance: CGFloat = 4
  var allowsDownward: () -> Bool = { true }
  var allowsUpward: () -> Bool = { false }
  /// 为 true 时，向下滑动进入交互式拖拽（`.began` -> `.changed` -> `.ended`），让候选面板 1:1 跟随手指渐显。
  var interactiveDownward = false
  private(set) var recognizedDirection: Direction?
  private(set) var isDirectionLockedOut = false
  private(set) var translationY: CGFloat = 0
  private(set) var velocityY: CGFloat = 0
  private var trackedTouch: UITouch?
  private var startLocation = CGPoint.zero
  private var lastLocation = CGPoint.zero
  private var lastTimestamp: TimeInterval = 0

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    name = "candidateStripVerticalSwipe"
    cancelsTouchesInView = true
    delaysTouchesBegan = false
    delaysTouchesEnded = true
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
      reject()
      return
    }
    trackedTouch = touch
    startLocation = touch.location(in: view)
    lastLocation = startLocation
    lastTimestamp = event.timestamp
    translationY = 0
    velocityY = 0
    recognizedDirection = nil
    isDirectionLockedOut = false
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = trackedTouch, touches.contains(touch) else { return }
    if state == .began || state == .changed {
      updateInteractiveMotion(touch: touch, timestamp: event.timestamp)
      state = .changed
      return
    }
    guard state == .possible, !isDirectionLockedOut else { return }
    evaluate(touch: touch, timestamp: event.timestamp, ended: false)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    if state == .began || state == .changed {
      if let touch = trackedTouch, touches.contains(touch) {
        updateInteractiveMotion(touch: touch, timestamp: event.timestamp)
      }
      state = .ended
      return
    }
    guard state == .possible else { return }
    if !isDirectionLockedOut, let touch = trackedTouch, touches.contains(touch) {
      evaluate(touch: touch, timestamp: event.timestamp, ended: true)
    } else {
      reject()
    }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    if state == .began || state == .changed {
      state = .cancelled
      return
    }
    if state == .possible { reject() }
  }

  override func reset() {
    super.reset()
    trackedTouch = nil
    recognizedDirection = nil
    isDirectionLockedOut = false
    translationY = 0
    velocityY = 0
  }

  private func reject() {
    isDirectionLockedOut = true
    state = .failed
  }

  private func updateInteractiveMotion(touch: UITouch, timestamp: TimeInterval) {
    let location = touch.location(in: view)
    translationY = max(0, location.y - startLocation.y)
    let dt = timestamp - lastTimestamp
    if dt > 0.001 {
      velocityY = (location.y - lastLocation.y) / dt
    }
    lastLocation = location
    lastTimestamp = timestamp
  }

  private func evaluate(touch: UITouch, timestamp: TimeInterval, ended: Bool) {
    let location = touch.location(in: view)
    let dx = abs(location.x - startLocation.x)
    let dy = location.y - startLocation.y
    guard max(dx, abs(dy)) >= Self.activationDistance else {
      if ended { reject() }
      return
    }
    if dy > dx, allowsDownward() {
      recognizedDirection = .down
      if interactiveDownward && !ended {
        updateInteractiveMotion(touch: touch, timestamp: timestamp)
        state = .began
      } else {
        state = .recognized
      }
    } else if -dy > dx, allowsUpward() {
      recognizedDirection = .up
      state = .recognized
    } else {
      reject()
    }
  }
}

/// 候选按钮的内容宽度独立求解，横向栈只排列不带文字的容器。
@MainActor
final class CandidateStripRow {
  let stack = UIStackView()
  private(set) var buttons: [KeyboardKeyButton] = []
  private var trailingConstraints: [NSLayoutConstraint] = []

  /// 画布的装饰留白让位于实际文字行高，避免手算字体回退和多行排版。
  var naturalContentHeight: CGFloat {
    buttons.lazy.filter { !$0.isHidden }.map { $0.intrinsicContentSize.height }.max() ?? 0
  }

  func add(_ button: KeyboardKeyButton) {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    button.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(button)
    let trailing = button.trailingAnchor.constraint(equalTo: container.trailingAnchor)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      button.topAnchor.constraint(equalTo: container.topAnchor),
      button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      trailing,
    ])
    buttons.append(button)
    trailingConstraints.append(trailing)
    stack.addArrangedSubview(container)
  }

  func setHidden(_ hidden: Bool, at index: Int) {
    let container = stack.arrangedSubviews[index]
    guard container.isHidden != hidden else { return }
    // 隐藏容器会被栈设为零宽；先断开右边界，按钮自己的固有宽度无需一并归零。
    trailingConstraints[index].isActive = !hidden
    buttons[index].isHidden = hidden
    container.isHidden = hidden
  }
}
