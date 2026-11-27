import UIKit

/// 键与键之间的空隙归谁：落在空隙里的触摸交给离它最近、而且这段空隙够得着的那个键。
///
/// 键是排在 `UIStackView` 里的一个个独立按钮，行内的键间距、行与行之间的行距，以及居中字母行两侧的 `layoutMargins` 都不属于任何按钮。落在这些地方的触摸由 stack view 自己接住然后丢掉，快打时手指常常正好落在两键之间，于是这一键就没了。这里只决定命中归属，不改布局和绘制，与 Android 的 `KeyboardKeyArea` 是同一件事。
enum KeyGapRouting {
  /// `frames` 里离 `point` 最近、且距离不超过 `reach` 的那一个的下标；一样近时取靠前的那个，空矩形不参与。
  static func nearest(to point: CGPoint, in frames: [CGRect], reach: CGFloat) -> Int? {
    var best: (index: Int, distance: CGFloat)?
    for (index, frame) in frames.enumerated() where !frame.isEmpty {
      let distance = distance(from: point, to: frame)
      guard distance <= reach, distance < (best?.distance ?? .infinity) else { continue }
      best = (index, distance)
    }
    return best?.index
  }

  /// `point` 到 `frame` 的最短距离，在矩形里面为 0。
  static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
    let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
    let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
    return (dx * dx + dy * dy).squareRoot()
  }

  /// 紧挨在中/英右边的回车让给中/英的宽度。两键之间拿不准的触摸算成中/英：误按中/英，再按一下就回来了；误按回车，消息就发出去了。回车约是中/英的两倍宽，让出这一点不影响正常按它。与 Android 的 `KeyboardActionRow.RETURN_YIELD_DP`、鸿蒙的 `KeyboardGeometry.RETURN_YIELD_VP` 是同一个值。
  static let returnYield: CGFloat = 6

  /// `point` 是否落在 `yielding` 让给 `receiver` 的那一段里：两键之间的整段键距，加上 `yielding` 键帽左侧 `yield` 宽。只在两键同一行、`receiver` 紧挨在左边（中间不超过一个键距再加 1pt 取整）时成立；坐标都在同一个容器里。键距原本按最近的键各分一半，靠 `yielding` 的那一半也在这里让出去。
  static func yieldsToLeft(_ point: CGPoint, yielding: CGRect, receiver: CGRect, spacing: CGFloat, yield: CGFloat) -> Bool {
    guard yield > 0, !yielding.isEmpty, !receiver.isEmpty else { return false }
    let gap = yielding.minX - receiver.maxX
    guard gap >= -0.5, gap <= max(spacing, 0) + 1 else { return false }
    guard receiver.minY < yielding.maxY, yielding.minY < receiver.maxY else { return false }
    return point.x >= receiver.maxX && point.x < yielding.minX + yield
      && point.y >= yielding.minY && point.y <= yielding.maxY
  }

  /// 一个 stack view 里的空隙最远能归到多远的键：间距的一半（两侧的键各分一半），排列用的边距（居中字母行两侧的空白归最外侧的键）整段都算，再加 1pt 吸收像素取整。
  static func reach(spacing: CGFloat, axis: NSLayoutConstraint.Axis, margins: UIEdgeInsets?) -> CGFloat {
    var reach = max(spacing, 0) / 2
    if let margins {
      reach = max(reach, axis == .horizontal ? max(margins.left, margins.right) : max(margins.top, margins.bottom))
    }
    return reach + 1
  }

  /// 外周安全边距扩展：当触摸落在所有可见按键外框之外的左/右内边距或底边距里（例如标准竖屏 6pt 边距而用户把行距调到 4pt 时），
  /// 允许命中外侧边缘键，避免屏幕边缘出现点击盲区。分隔中缝与行内空隙仍在键框包围盒内部，不会触发外扩。
  static func outerEdgeReach(at point: CGPoint, in frames: [CGRect], baseReach: CGFloat, edgePadding: CGFloat = 12) -> CGFloat {
    let valid = frames.filter { !$0.isEmpty }
    guard let minX = valid.map(\.minX).min(),
          let maxX = valid.map(\.maxX).max(),
          let minY = valid.map(\.minY).min(),
          let maxY = valid.map(\.maxY).max() else { return baseReach }
    let inHorizontalEdge = (point.x < minX || point.x > maxX) && point.y >= minY && point.y <= maxY + edgePadding
    let inBottomEdge = point.y > maxY && point.x >= minX - edgePadding && point.x <= maxX + edgePadding
    return (inHorizontalEdge || inBottomEdge) ? max(baseReach, edgePadding) : baseReach
  }
}

/// 键区的根 stack view。默认命中是键区里某个 stack view 自身（也就是触摸落在键距、行距或行边距里）时，改为交给 `KeyGapRouting` 选出的键；UIKit 随后把这次触摸的整个序列都送给那个键，键上的长按、空格滑动等手势也照常参与。
///
/// 候选栏、手写区这类不是键的子树放进 `gapRoutingExclusions`，落在它们里面的命中原样返回，它们的按钮也不会被选来接空隙里的触摸。面板和弹层加在键盘根视图上而不在这里，盖住键区时先命中的是它们自己。
final class KeyAreaStackView: UIStackView {
  var gapRoutingExclusions: [UIView] = []
  /// 允许扩展到键盘外框内边距里的命中范围（对应 `KeyboardFormFactor.padding` 的左/右/底边，顶部为 0 避免抢占候选栏上方）。
  var outerHitInsets: UIEdgeInsets = .zero
  /// 把键帽左侧 `KeyGapRouting.returnYield` 让给紧挨在左边的 `yieldReceiver` 的键：底行的回车让给中/英。两者不相邻（别的布局把中/英挪走或藏起来）时不起作用。
  weak var yieldingKey: UIControl?
  weak var yieldReceiver: UIControl?
  /// 叠在键区上、不在任何一行里的键：九键「右侧大回车」的回车（`tallReturnKey`）叠在按键列上，跨着右列第三格和底行。空隙的候选只从命中的那个 stack view 里收，收不到它，于是它与 中/英、九宫格 9 键和右列中间键之间的键距里靠它那一半没有键接；这里列出的键显示着时也参与每一段空隙的归属，与行内的键一样按最近、够得着来分。
  var overlayKeys: [UIControl] = []
  /// 滑行输入或横滑光标进行中：新落下的手指一律命中键区自己而不是键，它们什么都不输入，挂在键区上的手势仍能结束或取消当前触摸。
  var suppressesKeyHits = false
  /// Lokey 26 键样式下的顶排防吞点直通与组字态边缘防误触路由器；非 Lokey 样式时不起作用。
  var lokeyTouchRouter: LokeyTouchHitRouter?

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let expanded = CGRect(
      x: bounds.minX - outerHitInsets.left,
      y: bounds.minY - outerHitInsets.top,
      width: bounds.width + outerHitInsets.left + outerHitInsets.right,
      height: bounds.height + outerHitInsets.top + outerHitInsets.bottom
    )
    return expanded.contains(point)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    var hit = super.hitTest(point, with: event)
    if hit == nil, self.point(inside: point, with: event) { hit = self }
    if suppressesKeyHits, hit != nil { return self }
    // Lokey 顶排防吞直通：顶栏底沿空白处或顶栏与首排缝隙直接透传给 Q–P，避免快打被顶栏吞掉。
    if let router = lokeyTouchRouter, let topKey = router.passThroughTopRowKey(for: hit, at: point, in: self) {
      return topKey
    }
    if let hit, let receiver = yieldedReceiver(at: point, hit: hit) { return receiver }
    guard let gap = hit as? UIStackView, !isExcluded(gap) else {
      guard bounds.contains(point) else { return nil }
      if let router = lokeyTouchRouter, let control = Self.enclosingControl(of: hit, stoppingAt: self) {
        return router.remapIfNeeded(hit: control, at: point, in: self)
      }
      return hit
    }
    var keys: [UIControl] = []
    collectKeys(in: gap, into: &keys)
    for key in overlayKeys where acceptsGapTouches(key) && !keys.contains(where: { $0 === key }) {
      keys.append(key)
    }
    let fallback: UIView? = bounds.contains(point) ? hit : nil
    guard !keys.isEmpty else { return fallback }
    let frames = keys.map { Self.layoutFrame(of: $0, in: gap) }
    // 第三排等带自定义宽间距（如 `⇧↔Z`、`M↔⌫`）的横排需要按最大可见间距计算够得着的范围，避免中间出现点击盲区。
    let visible = gap.arrangedSubviews.filter { !$0.isHidden }
    let maxCustomSpacing = visible.dropLast()
      .map { gap.customSpacing(after: $0) }
      .filter { $0 != UIStackView.spacingUseDefault && $0.isFinite }
      .max() ?? 0
    let baseReach = KeyGapRouting.reach(
      spacing: max(gap.spacing, maxCustomSpacing), axis: gap.axis,
      margins: gap.isLayoutMarginsRelativeArrangement ? gap.layoutMargins : nil)
    let local = convert(point, to: gap)
    let outerPadding = max(12, max(outerHitInsets.left, max(outerHitInsets.right, outerHitInsets.bottom)) + 2)
    let reach = KeyGapRouting.outerEdgeReach(at: local, in: frames, baseReach: baseReach, edgePadding: outerPadding)
    guard let index = KeyGapRouting.nearest(to: local, in: frames, reach: reach) else { return fallback }
    // 顶栏和第一排之间的间隔比行距还窄时，整段间隔都在第一排的够得着范围内；离候选栏这类非键区域更近的点仍然不交给键，空隙两侧各归一半。
    let keyDistance = KeyGapRouting.distance(from: local, to: frames[index])
    let closerToExcluded = gapRoutingExclusions.contains { excluded in
      !excluded.isHidden && excluded.isDescendant(of: gap)
        && KeyGapRouting.distance(from: local, to: excluded.convert(excluded.bounds, to: gap)) < keyDistance
    }
    if closerToExcluded { return fallback }
    let resolved = keys[index]
    return lokeyTouchRouter?.remapIfNeeded(hit: resolved, at: point, in: self) ?? resolved
  }

  private static func enclosingControl(of view: UIView?, stoppingAt root: UIView) -> UIControl? {
    var cursor = view
    while let node = cursor, node !== root {
      if let control = node as? UIControl { return control }
      cursor = node.superview
    }
    return nil
  }

  /// 命中的是让出的键（或它所在行的空隙）、触摸落在它让出的那一段里，而接收的键就在同一行里可用时，返回接收的键。按布局位置判断，按下动画的缩放不算在内。
  private func yieldedReceiver(at point: CGPoint, hit: UIView) -> UIView? {
    guard let yielding = yieldingKey, let receiver = yieldReceiver, let row = yielding.superview as? UIStackView,
          receiver.superview === row, hit === yielding || hit.isDescendant(of: yielding) || hit === row,
          !yielding.isHidden, !receiver.isHidden, receiver.alpha > 0.01, receiver.isUserInteractionEnabled,
          receiver.isEnabled else { return nil }
    let yields = KeyGapRouting.yieldsToLeft(
      convert(point, to: row), yielding: Self.layoutFrame(of: yielding, in: row),
      receiver: Self.layoutFrame(of: receiver, in: row), spacing: row.spacing, yield: KeyGapRouting.returnYield)
    return yields ? receiver : nil
  }

  private func isExcluded(_ view: UIView) -> Bool {
    gapRoutingExclusions.contains { view.isDescendant(of: $0) }
  }

  /// 叠着的键能不能接空隙里的触摸：在键区里、没被排除，它自己可交互、已启用，而且它和到键区之间的每一层都显示着。
  private func acceptsGapTouches(_ key: UIControl) -> Bool {
    guard key.isEnabled, key.isUserInteractionEnabled, key.isDescendant(of: self), !isExcluded(key) else { return false }
    var node: UIView? = key
    while let view = node, view !== self {
      if view.isHidden || view.alpha <= 0.01 { return false }
      node = view.superview
    }
    return true
  }

  /// 能接触摸的键：可见、可交互、已启用；不进入被排除的子树，也不进入键自己的子视图。
  private func collectKeys(in view: UIView, into keys: inout [UIControl]) {
    for subview in view.subviews
    where !subview.isHidden && subview.alpha > 0.01 && subview.isUserInteractionEnabled
      && !gapRoutingExclusions.contains(where: { $0 === subview }) {
      if let control = subview as? UIControl {
        if control.isEnabled { keys.append(control) }
      } else {
        collectKeys(in: subview, into: &keys)
      }
    }
  }

  /// 键在布局里占的位置。按下时 `KeyboardKeyButton` 把自己缩到 0.94，`frame` 和默认命中都随之缩小，而空隙的归属要按布局算，所以用不受 `transform` 影响的 `center` 与 `bounds`。
  static func layoutFrame(of key: UIView, in container: UIView) -> CGRect {
    guard let superview = key.superview else { return .null }
    let size = key.bounds.size
    let frame = CGRect(
      x: key.center.x - size.width / 2, y: key.center.y - size.height / 2, width: size.width, height: size.height)
    return superview.convert(frame, to: container)
  }
}
