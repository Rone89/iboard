import UIKit

/// Lokey 0.9.5 组字态/空闲态边缘防误触重映射策略（对应 `LokeyKeyboard.appex` `0x1001c77f8`）。
///
/// 纯几何决策层，不直接耦合 UIKit 视图层级，便于单测逐项锁死阈值：
/// - `Shift`：上沿靠 `A`（组字 16pt / 空闲 10.5pt，且 `x >= A.minX - 6`）重映射到 `A`；右沿靠 `Z`（组字 18pt / 空闲 11pt）重映射到 `Z`。
/// - `⌫`：点在键帽矩形内部时绝不抢走删除；点在外部缓冲隙且上沿靠 `L`（过 `L.midX + 4` 时 9.7/7.5pt，否则 11/8.5pt，且 `x <= L.maxX + 4`）重映射到 `L`；左沿靠 `M`（组字 12pt / 空闲 8.5pt）重映射到 `M`。
/// - 底排上沿：`x` 落在 `[Z.minX - 10, M.maxX + 10]` 且 `y <= row2.maxY + thresh`（`123`/`中/英`/`☺`/`换行` 为 16.5/13pt，空格/其余为 13.5/10.5pt）时重映射到水平最近的 `Z..M`。
enum LokeyEdgeRemapPolicy {
  /// 初步命中的按键角色。
  enum InitialTarget: Equatable {
    case shift
    case delete
    case bottomRow(TouchBottomRowLayout.Slot)
    case other
  }

  /// 重映射后的目标字母键。
  enum RemappedKey: Equatable {
    case keyA
    case keyL
    /// 第三排 7 颗字母键（`0 = Z` … `6 = M`）。
    case bottomLetter(Int)
  }

  /// 统一在同一坐标系下的关键键帽布局矩形（不受按压缩放 `transform` 影响）。
  struct LayoutFrames: Equatable {
    let keyA: CGRect
    let keyL: CGRect
    let keyShift: CGRect
    let keyDelete: CGRect
    /// 第三排 7 颗字母键 `Z..M`。
    let bottomLetters: [CGRect]
  }

  /// 根据当前是否组字（`isComposing`）判断是否将边缘误触重映射到相邻字母键；返回 `nil` 表示保持原命中键。
  static func remap(
    point: CGPoint,
    initial: InitialTarget,
    isComposing: Bool,
    frames: LayoutFrames
  ) -> RemappedKey? {
    guard frames.bottomLetters.count == 7 else { return nil }
    let zFrame = frames.bottomLetters[0]
    let mFrame = frames.bottomLetters[6]

    switch initial {
    case .shift:
      guard !frames.keyA.isEmpty, !zFrame.isEmpty else { return nil }
      let upThreshold: CGFloat = isComposing ? 16.0 : 10.5
      if point.y <= frames.keyA.maxY + upThreshold, point.x >= frames.keyA.minX - 6.0 {
        return .keyA
      }
      let rightThreshold: CGFloat = isComposing ? 18.0 : 11.0
      if point.x >= zFrame.minX - rightThreshold {
        return .bottomLetter(0)
      }
      return nil

    case .delete:
      guard !frames.keyDelete.isEmpty, !frames.keyL.isEmpty, !mFrame.isEmpty else { return nil }
      // 直接点在 ⌫ 键帽内部时绝不重映射，保证正常删除响应准确。
      if frames.keyDelete.contains(point) { return nil }
      let upThreshold: CGFloat
      if point.x > frames.keyL.midX + 4.0 {
        upThreshold = isComposing ? 9.7 : 7.5
      } else {
        upThreshold = isComposing ? 11.0 : 8.5
      }
      if point.y <= frames.keyL.maxY + upThreshold, point.x <= frames.keyL.maxX + 4.0 {
        return .keyL
      }
      let leftThreshold: CGFloat = isComposing ? 12.0 : 8.5
      if point.x <= mFrame.maxX + leftThreshold {
        return .bottomLetter(6)
      }
      return nil

    case .bottomRow(let slot):
      guard !zFrame.isEmpty, !mFrame.isEmpty else { return nil }
      guard point.x >= zFrame.minX - 10.0, point.x <= mFrame.maxX + 10.0 else { return nil }
      let isEdgeFunction = slot == .layer || slot == .emoji || slot == .language || slot == .returnKey
      let upThreshold: CGFloat
      if isEdgeFunction {
        upThreshold = isComposing ? 16.5 : 13.0
      } else {
        upThreshold = isComposing ? 13.5 : 10.5
      }
      guard point.y <= zFrame.maxY + upThreshold else { return nil }
      guard let nearest = nearestHorizontally(x: point.x, in: frames.bottomLetters) else { return nil }
      return .bottomLetter(nearest)

    case .other:
      return nil
    }
  }

  /// 在一行键帽矩形中选出水平距离 `x` 最近的下标（落在 `[minX, maxX]` 内距离为 0）。
  static func nearestHorizontally(x: CGFloat, in frames: [CGRect]) -> Int? {
    var best: (index: Int, distance: CGFloat)?
    for (index, frame) in frames.enumerated() where !frame.isEmpty {
      let distance: CGFloat
      if x < frame.minX {
        distance = frame.minX - x
      } else if x > frame.maxX {
        distance = x - frame.maxX
      } else {
        distance = 0
      }
      if distance < (best?.distance ?? .infinity) {
        best = (index, distance)
      }
    }
    return best?.index
  }
}

/// Lokey 顶排 `Q–P` 防吞点直通策略（对应 `KeyGridView.pointInside` 顶部 `-44pt` 外扩 + 候选栏底沿透传）：
/// 触摸落在顶栏与第一排字母之间的缝隙，或落在顶栏底部空白沿/非按钮区域（且距第一排顶边不超过 `maxPassThroughHeight`）时，
/// 直接路由到水平最近的 `Q–P` 字母键，避免快打顶排字母被顶栏吞掉；真正命中工具栏按钮、候选词按钮或候选滚动条上中部时绝不抢夺。
enum LokeyTopRowPassThroughPolicy {
  /// 与 Lokey `KeyGridView.pointInside` 字母页 `-44pt` 一致的最大向上透传范围。
  static let maxPassThroughHeight: CGFloat = 44.0
  /// 顶栏内部允许直接透传给 `Q–P` 的底沿高度（pt）：即使候选滚动条存在，底沿非按钮缝隙仍直通顶排字母。
  static let candidateBarBottomSeamHeight: CGFloat = 10.0

  /// 判断落在顶栏或顶栏与第一排间隙里的触摸是否应透传给第一排字母键，命中时返回对应 `Q–P` 下标。
  static func targetTopRowIndex(
    point: CGPoint,
    topRowFrames: [CGRect],
    topBarFrame: CGRect,
    hitInteractiveControl: Bool,
    hitScrollableCandidateStrip: Bool
  ) -> Int? {
    guard !hitInteractiveControl, !topRowFrames.isEmpty else { return nil }
    let validTopY = topRowFrames.filter { !$0.isEmpty }.map(\.minY).min()
    guard let rowTopY = validTopY else { return nil }
    // 触摸必须位于第一排顶边上方，且不超过 44pt 向上透传上限。
    guard point.y < rowTopY, point.y >= rowTopY - maxPassThroughHeight else { return nil }

    // 落在顶栏底边与第一排顶边之间的纯缝隙（topGap）中：直接路由给最近 Q–P。
    if !topBarFrame.isEmpty && point.y >= topBarFrame.maxY {
      return LokeyEdgeRemapPolicy.nearestHorizontally(x: point.x, in: topRowFrames)
    }

    // 落在顶栏内部但未点中任何交互按钮：
    // 若在候选滚动条内部，仅底沿 seam 区域（默认 10pt）透传，保留上方滑动候选词的手势；
    // 若未命中滚动条（工具栏空白处/候选栏右侧空白区），在 44pt 范围内直接透传给 Q–P。
    if !topBarFrame.isEmpty && topBarFrame.contains(point) {
      if hitScrollableCandidateStrip {
        guard point.y >= topBarFrame.maxY - candidateBarBottomSeamHeight else { return nil }
      }
      return LokeyEdgeRemapPolicy.nearestHorizontally(x: point.x, in: topRowFrames)
    }

    return nil
  }
}

/// 挂接在 `KeyAreaStackView` 上的 Lokey 触控路由器：统一处理顶排防吞直通与组字态边缘防误触重映射。
final class LokeyTouchHitRouter {
  weak var topBarView: UIView?
  weak var candidateScrollView: UIView?
  var isActive: () -> Bool = { false }
  var isComposing: () -> Bool = { false }
  /// 顶排 10 颗字母键（`Q–P`）。
  var topRowKeys: () -> [UIControl] = { [] }
  /// 边缘重映射涉及的关键键位。
  var edgeKeys: () -> (
    keyA: UIControl?,
    keyL: UIControl?,
    keyShift: UIControl?,
    keyDelete: UIControl?,
    bottomLetters: [UIControl]
  ) = { (nil, nil, nil, nil, []) }
  /// 识别底排按键对应的槽位（非底排键返回 `nil`）。
  var bottomRowSlot: (UIControl) -> TouchBottomRowLayout.Slot? = { _ in nil }

  /// 尝试将落在顶栏底沿空白处或顶栏/键区缝隙里的触摸透传给最近的 `Q–P` 键。
  func passThroughTopRowKey(for hit: UIView?, at point: CGPoint, in container: UIView) -> UIControl? {
    guard isActive() else { return nil }
    let keys = topRowKeys().filter { !$0.isHidden && $0.isEnabled && $0.isUserInteractionEnabled }
    guard !keys.isEmpty else { return nil }

    let topBarFrame: CGRect
    if let topBar = topBarView, !topBar.isHidden {
      topBarFrame = topBar.convert(topBar.bounds, to: container)
    } else {
      topBarFrame = .zero
    }

    let hitInteractiveControl = Self.hasInteractiveControlAncestor(hit, stoppingAt: container)
    let hitScrollableStrip: Bool
    if let hit, let scroll = candidateScrollView, !scroll.isHidden, scroll.alpha > 0.01 {
      hitScrollableStrip = hit === scroll || hit.isDescendant(of: scroll)
    } else {
      hitScrollableStrip = false
    }

    let frames = keys.map { KeyAreaStackView.layoutFrame(of: $0, in: container) }
    guard let index = LokeyTopRowPassThroughPolicy.targetTopRowIndex(
      point: point,
      topRowFrames: frames,
      topBarFrame: topBarFrame,
      hitInteractiveControl: hitInteractiveControl,
      hitScrollableCandidateStrip: hitScrollableStrip
    ) else { return nil }
    return keys[index]
  }

  /// 对已命中的按键（含空隙路由命中的按键）执行 Lokey 上下文边缘防误触重映射。
  func remapIfNeeded(hit control: UIControl, at point: CGPoint, in container: UIView) -> UIControl {
    guard isActive() else { return control }
    let keys = edgeKeys()
    guard let keyA = keys.keyA, let keyL = keys.keyL,
          let keyShift = keys.keyShift, let keyDelete = keys.keyDelete,
          keys.bottomLetters.count == 7 else { return control }

    let initial: LokeyEdgeRemapPolicy.InitialTarget
    if control === keyShift {
      initial = .shift
    } else if control === keyDelete {
      initial = .delete
    } else if let slot = bottomRowSlot(control) {
      initial = .bottomRow(slot)
    } else {
      return control
    }

    let frames = LokeyEdgeRemapPolicy.LayoutFrames(
      keyA: KeyAreaStackView.layoutFrame(of: keyA, in: container),
      keyL: KeyAreaStackView.layoutFrame(of: keyL, in: container),
      keyShift: KeyAreaStackView.layoutFrame(of: keyShift, in: container),
      keyDelete: KeyAreaStackView.layoutFrame(of: keyDelete, in: container),
      bottomLetters: keys.bottomLetters.map { KeyAreaStackView.layoutFrame(of: $0, in: container) }
    )

    guard let remapped = LokeyEdgeRemapPolicy.remap(
      point: point,
      initial: initial,
      isComposing: isComposing(),
      frames: frames
    ) else { return control }

    let candidate: UIControl
    switch remapped {
    case .keyA: candidate = keyA
    case .keyL: candidate = keyL
    case .bottomLetter(let index): candidate = keys.bottomLetters[index]
    }
    return (!candidate.isHidden && candidate.isEnabled && candidate.isUserInteractionEnabled) ? candidate : control
  }

  private static func hasInteractiveControlAncestor(_ view: UIView?, stoppingAt root: UIView) -> Bool {
    var cursor = view
    while let node = cursor, node !== root {
      if let control = node as? UIControl, control.isEnabled && control.isUserInteractionEnabled {
        return true
      }
      cursor = node.superview
    }
    return false
  }
}
