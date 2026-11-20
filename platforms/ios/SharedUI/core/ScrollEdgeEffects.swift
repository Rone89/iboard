import SwiftUI
import UIKit

/// Keyboard panels are too short for the system edge veil introduced in iOS 26.
extension UIScrollView {
  func disableEdgeEffects() {
    guard #available(iOS 26.0, *) else { return }
    for effect in [topEdgeEffect, bottomEdgeEffect, leftEdgeEffect, rightEdgeEffect] {
      effect.isHidden = true
    }
  }
}

extension View {
  @ViewBuilder func disablingScrollEdgeEffects() -> some View {
    if #available(iOS 26.0, *) { scrollEdgeEffectHidden(true, for: .all) } else { self }
  }
}

/// 滚动视图顶部与底部的多段缓动渐隐遮罩：仅在内容溢出且离开端点时生效，随滚动实时消融裁剪边缘。
@MainActor
final class VerticalScrollEdgeMask {
  private let maskLayer = CAGradientLayer()
  private var lastKey: (Int, Int)?
  private let edgeHeight: CGFloat
  private let rampDistance: CGFloat

  init(edgeHeight: CGFloat = 22, rampDistance: CGFloat = 14) {
    self.edgeHeight = edgeHeight
    self.rampDistance = rampDistance
  }

  func update(for scrollView: UIScrollView, contentHeight: CGFloat? = nil) {
    let bounds = scrollView.bounds
    let height = bounds.height
    guard height > 1, bounds.width > 0 else {
      clear(from: scrollView)
      return
    }
    let resolvedHeight = contentHeight ?? scrollView.contentSize.height
    let offsetY = scrollView.contentOffset.y
    let topStrength = min(1, max(0, offsetY / rampDistance))
    let remainingBottom = max(0, resolvedHeight - height - offsetY)
    let bottomStrength = min(1, max(0, remainingBottom / rampDistance))
    guard topStrength > 0.005 || bottomStrength > 0.005 else {
      clear(from: scrollView)
      return
    }

    let maxSpan = min(edgeHeight, height * 0.16)
    let topFraction = Double((maxSpan * topStrength) / height)
    let bottomFraction = Double((maxSpan * bottomStrength) / height)

    var stops: [(Double, CGFloat)] = []
    if topFraction > 0.0005 {
      stops.append((0, 0))
      stops.append((topFraction * 0.28, 0.16))
      stops.append((topFraction * 0.56, 0.52))
      stops.append((topFraction * 0.82, 0.86))
      stops.append((topFraction, 1))
    } else {
      stops.append((0, 1))
    }
    if bottomFraction > 0.0005 {
      stops.append((1 - bottomFraction, 1))
      stops.append((1 - bottomFraction * 0.82, 0.86))
      stops.append((1 - bottomFraction * 0.56, 0.52))
      stops.append((1 - bottomFraction * 0.28, 0.16))
      stops.append((1, 0))
    } else {
      stops.append((1, 1))
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    maskLayer.frame = bounds
    let key = (Int((topStrength * 200).rounded()), Int((bottomStrength * 200).rounded()))
    if lastKey == nil || lastKey! != key {
      lastKey = key
      maskLayer.colors = stops.map { UIColor.black.withAlphaComponent($0.1).cgColor }
      maskLayer.locations = stops.map { NSNumber(value: $0.0) }
    }
    if scrollView.layer.mask !== maskLayer {
      scrollView.layer.mask = maskLayer
    }
    CATransaction.commit()
  }

  private func clear(from scrollView: UIScrollView) {
    lastKey = nil
    if scrollView.layer.mask === maskLayer {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      scrollView.layer.mask = nil
      CATransaction.commit()
    }
  }
}

/// 布局和滚动时自动更新上下渐隐遮罩的通用滚动视图。
final class EdgeMaskedScrollView: UIScrollView {
  private let edgeMask = VerticalScrollEdgeMask()

  override func layoutSubviews() {
    super.layoutSubviews()
    edgeMask.update(for: self)
  }
}
