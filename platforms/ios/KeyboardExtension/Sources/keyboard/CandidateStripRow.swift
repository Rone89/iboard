import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 候选栏垂直轻滑手势：未展开时向下轻滑展开候选面板，已展开时向上轻滑收起；
/// 锁定首个达到阈值的方向，避免横向浏览候选后手指上下偏移误触。
final class CandidateStripVerticalSwipeRecognizer: UIGestureRecognizer {
  enum Direction: Equatable {
    case down
    case up
  }

  static let activationDistance: CGFloat = 6
  var allowsDownward: () -> Bool = { true }
  var allowsUpward: () -> Bool = { false }
  private(set) var recognizedDirection: Direction?
  private(set) var isDirectionLockedOut = false
  private var trackedTouch: UITouch?
  private var startLocation = CGPoint.zero

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
    recognizedDirection = nil
    isDirectionLockedOut = false
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard state == .possible, !isDirectionLockedOut,
          let touch = trackedTouch, touches.contains(touch) else { return }
    evaluate(touch: touch, ended: false)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard state == .possible else { return }
    if !isDirectionLockedOut, let touch = trackedTouch, touches.contains(touch) {
      evaluate(touch: touch, ended: true)
    } else {
      reject()
    }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    if state == .possible { reject() }
  }

  override func reset() {
    super.reset()
    trackedTouch = nil
    recognizedDirection = nil
    isDirectionLockedOut = false
  }

  private func reject() {
    isDirectionLockedOut = true
    state = .failed
  }

  private func evaluate(touch: UITouch, ended: Bool) {
    let location = touch.location(in: view)
    let dx = abs(location.x - startLocation.x)
    let dy = location.y - startLocation.y
    guard max(dx, abs(dy)) >= Self.activationDistance else {
      if ended { reject() }
      return
    }
    if dy > dx, allowsDownward() {
      recognizedDirection = .down
      state = .recognized
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
