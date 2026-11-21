import CoreGraphics
import Foundation

/// 参照精确的滑行轨迹几何，1:1 复刻 Y 键盘的 `SwipeTrailView`（ZhiME 0.0.1）。
/// 本文件自 GlideKeyboard（MIT，Copyright (c) 2026 GlideKeyboard contributors）
/// 移植进 iBoard（GPLv3）；常量与构造步骤逐字来自对成品二进制的逆向转录，
/// 证据地址见 GlideKeyboard 的 docs/GLIDE_TRAIL_REFERENCE_AND_PLAN.md §1。
/// （2026-11-11 修正：边缘法线用**中心差分** p[next] − p[prev]，对应参照
/// `max(0, i-1)` 的索引掩码 0x1004847e8——最早的转录误读成前向差分，会把
/// 笔尖塌掉、弯道掏空；见该文档 §10。）
///
/// 纯显示用途，与 GlideTrailRenderer 一样不喂解码器：交给 Rust GlideBeam 的
/// 采样点仍是手势记录的那一份，本结构不参与。
///
/// 保留的参照特征：
/// - 尺寸是绝对点值，从不按键宽缩放；
/// - 不做曲线平滑：保留的采样点之间是直线段；
/// - 线性弧长收窄：尾端是尖（s = 0），到笔尖达到满宽 W，笔尖以半径 W/2 的
///   半圆帽封口；
/// - 少于两个点时不画（没有单点圆盘）。
struct SwipeTrailGeometry {
  /// 满生长时的带宽，单位点。参照：`fmov d1, #22`。
  static let maxWidth: CGFloat = 22
  /// 色带从 0 长到 `maxWidth` 经过的路径长度。
  static let growthLength: CGFloat = 40
  /// 弧长只保留最近的这一段。
  static let windowLength: CGFloat = 150
  /// 距上一个保留点小于该值的采样被丢弃。
  static let minSpacing: CGFloat = 2
  /// 法线分母的下限，守住退化的笔尖。
  static let normalEpsilon: CGFloat = 0.001

  private(set) var points: [CGPoint] = []

  var isEmpty: Bool { points.isEmpty }
  var count: Int { points.count }

  mutating func reset() {
    points.removeAll(keepingCapacity: true)
  }

  /// 追加一个采样。参照丢弃与上一个保留点距离严格小于 `minSpacing` 的采样
  /// （恰好 2 会保留），然后裁剪弧长窗口。
  mutating func append(_ point: CGPoint) {
    guard point.x.isFinite, point.y.isFinite else { return }
    if let last = points.last {
      let distance = hypot(point.x - last.x, point.y - last.y)
      guard distance >= Self.minSpacing else { return }
    }
    points.append(point)
    trim()
  }

  /// 参照裁剪（0x1004845e4）：从最新点向前走、累加段长；第一个累计长度超过
  /// `windowLength` 的索引成为新起点。保留的路径因此不超过窗口；恰好等于
  /// 窗口的路径整体保留。
  private mutating func trim() {
    guard points.count >= 2 else { return }
    var cumulative: CGFloat = 0
    var index = points.count - 1
    while index >= 1 {
      let previous = points[index - 1]
      let current = points[index]
      cumulative += hypot(current.x - previous.x, current.y - previous.y)
      if cumulative > Self.windowLength {
        points.removeSubrange(0..<index)
        return
      }
      index -= 1
    }
  }

  /// 保留点的总弧长 L。
  var totalLength: CGFloat {
    guard points.count >= 2 else { return 0 }
    var length: CGFloat = 0
    for index in 1..<points.count {
      let previous = points[index - 1]
      let current = points[index]
      length += hypot(current.x - previous.x, current.y - previous.y)
    }
    return length
  }

  /// 当前带宽 W = min(L / 40, 1) × 22：随笔画生长，路径满 40pt 后稳定在
  /// 22pt。不随速度变化。
  var bandWidth: CGFloat {
    min(totalLength / Self.growthLength, 1) * Self.maxWidth
  }

  /// 每个保留点的累计弧位 s[i]，s[0] = 0。
  func arcPositions() -> [CGFloat] {
    var positions: [CGFloat] = []
    positions.reserveCapacity(points.count)
    var cumulative: CGFloat = 0
    for index in points.indices {
      if index > 0 {
        let previous = points[index - 1]
        let current = points[index]
        cumulative += hypot(current.x - previous.x, current.y - previous.y)
      }
      positions.append(cumulative)
    }
    return positions
  }

  /// 色带左右边缘。每点的半宽是 W × s[i] / L × 0.5（参照的运算次序）：从
  /// 尖尾（s = 0）到笔尖满宽的线性收窄。法线用中心差分
  /// p[min(i+1, n-1)] − p[max(0, i-1)]（参照 `0x1004847e8` 的索引掩码），
  /// 笔尖因此保持最后一段的方向、色带在该处达到满宽——下面的圆弧在那段
  /// 满宽上叠加圆形笔头。
  func edges() -> (left: [CGPoint], right: [CGPoint]) {
    let n = points.count
    guard n >= 2 else { return ([], []) }
    let length = totalLength
    guard length > 0 else { return ([], []) }
    let width = bandWidth
    var left: [CGPoint] = []
    var right: [CGPoint] = []
    left.reserveCapacity(n)
    right.reserveCapacity(n)
    var arc: CGFloat = 0
    for index in 0..<n {
      let current = points[index]
      if index > 0 {
        let previous = points[index - 1]
        arc += hypot(current.x - previous.x, current.y - previous.y)
      }
      let previous = points[max(0, index - 1)]
      let next = points[min(index + 1, n - 1)]
      let dx = next.x - previous.x
      let dy = next.y - previous.y
      let divisor = max(hypot(dx, dy), Self.normalEpsilon)
      let nx = -dy / divisor
      let ny = dx / divisor
      let half = width * arc / length * 0.5
      left.append(CGPoint(x: current.x + nx * half, y: current.y + ny * half))
      right.append(CGPoint(x: current.x - nx * half, y: current.y - ny * half))
    }
    return (left, right)
  }

  /// Chaikin 拐角平滑：保留首尾端点不变，将折线尖角切圆以消除急转弯棱角，供屏幕轨迹渲染使用。
  static func smoothed(_ points: [CGPoint], iterations: Int = 1) -> [CGPoint] {
    guard points.count >= 3, iterations > 0 else { return points }
    var current = points
    for _ in 0..<iterations {
      guard current.count >= 3 else { break }
      var next: [CGPoint] = [current[0]]
      next.reserveCapacity(current.count * 2)
      for index in 0..<(current.count - 1) {
        let a = current[index]
        let b = current[index + 1]
        if index > 0 {
          next.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
        }
        if index < current.count - 2 {
          next.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
        }
      }
      next.append(current[current.count - 1])
      current = next
    }
    return current
  }

  /// 填充的色带路径，构造步骤与参照的重画完全一致（0x1004846cc）：左边缘
  /// 尾→头、半圆笔帽、右边缘 头→尾、闭合。少于两个点（或零长度）时参照
  /// 不画，这里同样。
  func path() -> CGPath {
    let n = points.count
    guard n >= 2, totalLength > 0 else { return CGMutablePath() }
    let (left, right) = edges()
    let tip = points[n - 1]
    // θ 指向左边缘（中心差分法线 × W/2），θ+π 指向右边缘；圆弧在两者之间
    // 扫出圆形笔头。边缘已是满宽时弧的起止与边缘端点重合——没有连接弦。
    let theta = atan2(left[n - 1].y - tip.y, left[n - 1].x - tip.x)
    let path = CGMutablePath()
    path.addLines(between: left)
    path.addArc(center: tip, radius: bandWidth / 2,
                startAngle: theta, endAngle: theta + .pi, clockwise: true)
    path.addLines(between: Array(right.reversed()))
    path.closeSubpath()
    return path
  }
}
