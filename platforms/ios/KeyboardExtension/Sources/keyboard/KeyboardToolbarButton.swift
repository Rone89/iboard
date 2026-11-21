import UIKit

/// 工具栏使用官方路径绘制 26pt 图标（收起箭头为 25pt），通过 UIButton 原生图像提供给系统键盘宿主。
/// 图像覆盖整个按钮，图标居中，透明边缘也属于点击区域；按压只缩小图标和底板，原生图像边界保持不变。
final class KeyboardToolbarButton: UIButton {
  static let iconSide: CGFloat = 26
  static let collapseIconSide: CGFloat = 25
  static let padSide: CGFloat = 40
  static let nativeGlassPadSide: CGFloat = 36
  static let padRadius: CGFloat = 12
  static let pressScale: CGFloat = 0.92
  static let pressDuration: TimeInterval = 0.1
  static let activeDuration: TimeInterval = 0.15
  private static let disabledAlpha: CGFloat = 0.4

  /// 图标、底板和标志跟着工具栏这一行缩小的倍数：行高到 `topRowMinimumHeight`（42pt）时是 1；「候选栏大小」调小、这一行更矮时按行高等比缩小，不再伸出这一行被裁掉。行更高时保持设计尺寸，与 Android 跟随候选栏时按钮最高 44 dp 一致（#10137）。
  static func contentScale(rowHeight: CGFloat) -> CGFloat {
    guard rowHeight > 0 else { return 1 }
    return min(1, rowHeight / KeyboardViewController.topRowMinimumHeight)
  }

  let icon: KeyboardIcon
  private let pad = UIView()
  private var renderedSize = CGSize.zero
  private var skin = KeyboardTheme.current

  var activePadCornerRadius: CGFloat { pad.layer.cornerRadius }
  var activePadBorderWidth: CGFloat { pad.layer.borderWidth }

  /// 对应面板打开时显示底板和强调色。
  var isActive = false {
    didSet {
      guard isActive != oldValue else { return }
      updateActive(animated: window != nil)
      accessibilityTraits = isActive ? [.button, .selected] : .button
    }
  }

  init(icon: KeyboardIcon, accessibilityLabel: String) {
    self.icon = icon
    super.init(frame: .zero)
    backgroundColor = .clear
    pad.isUserInteractionEnabled = false
    pad.layer.cornerRadius = Self.padRadius
    pad.layer.cornerCurve = .continuous
    addSubview(pad)
    self.accessibilityLabel = accessibilityLabel
    accessibilityTraits = .button
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: KeyboardToolbarButton, _: UITraitCollection) in
      button.tintColor = button.iconColor
      button.updateActiveBorder()
    }
    renderIcon(size: CGSize(width: Self.padSide, height: Self.padSide))
    apply(skin: skin)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(skin: KeyboardTheme) {
    self.skin = skin
    updateActive(animated: false)
    setNeedsLayout()
  }

  override var isHighlighted: Bool {
    didSet {
      guard isHighlighted != oldValue else { return }
      animatePress(scale: isHighlighted && isEnabled ? Self.pressScale : 1)
    }
  }

  override var isEnabled: Bool {
    didSet {
      alpha = isEnabled ? 1 : Self.disabledAlpha
      if !isEnabled { animatePress(scale: 1) }
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      pad.resetKeyboardPressAnimationAfterWindowRemoval()
      imageView?.resetKeyboardPressAnimationAfterWindowRemoval()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if bounds.width > 0, bounds.height > 0, renderedSize != bounds.size {
      renderIcon(size: bounds.size)
      super.layoutSubviews()
    }
    let scale = Self.contentScale(rowHeight: bounds.height)
    let usesGlassPill = skin.isNative && SystemKeyboardTokens.drawsLiquidGlassKeyboard
    let baseSide = usesGlassPill ? Self.nativeGlassPadSide : Self.padSide
    let side = min(baseSide * scale, bounds.width, bounds.height)
    pad.bounds = CGRect(x: 0, y: 0, width: side, height: side)
    pad.center = CGPoint(x: bounds.midX, y: bounds.midY)
    pad.layer.cornerRadius = usesGlassPill ? side / 2 : min(Self.padRadius * scale, side / 2)
  }

  /// UIKit 的跨进程键盘命中使用按钮的原生内容；仅挂 CAShapeLayer 的空按钮在真机上收不到触摸。
  private func renderIcon(size: CGSize) {
    let rowScale = Self.contentScale(rowHeight: size.height)
    func glyph(scale: CGFloat) -> UIImage {
      let side = (icon == .collapse ? Self.collapseIconSide : Self.iconSide) * rowScale * scale
      let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
      return UIGraphicsImageRenderer(size: size).image { _ in
        let path = icon.path(in: rect)
        UIColor.black.set()
        if icon.isFilled {
          path.fill()
        } else {
          path.lineWidth = icon.lineWidth * side / KeyboardIcon.viewBox
          path.lineCapStyle = .round
          path.lineJoinStyle = .round
          path.stroke()
        }
      }.withRenderingMode(.alwaysTemplate)
    }
    renderedSize = size
    let normal = glyph(scale: 1)
    setImage(normal, for: .normal)
    setImage(normal, for: .disabled)
    setImage(glyph(scale: Self.pressScale), for: .highlighted)
  }

  private func animatePress(scale: CGFloat) {
    // 按下 0ms 即时缩放，松手保留回弹过渡；高亮图像只缩小内部路径，原生 imageView 的边界始终覆盖整格。
    KeyPressMotion.animate(pad, scale: scale, duration: scale < 1 ? 0 : Self.pressDuration)
  }

  private var iconColor: UIColor {
    isActive ? skin.accent : skin.secondary
  }

  /// 绘制与工具栏其他 26pt 描边图标同风格（同线宽、同圆角、模板着色）的圆角方框文字图标，供中英文切换（`中`/`A`）等文字开关使用。
  static func badgeImage(text: String, side: CGFloat = iconSide) -> UIImage {
    let size = CGSize(width: side, height: side)
    return UIGraphicsImageRenderer(size: size).image { _ in
      let inset = side * (3.0 / 26.0)
      let box = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
      let lineWidth = side * (1.75 / 26.0)
      let radius = side * (5.2 / 26.0)
      let strokePath = UIBezierPath(roundedRect: box, cornerRadius: radius)
      strokePath.lineWidth = lineWidth
      strokePath.lineJoinStyle = .round
      UIColor.black.setStroke()
      strokePath.stroke()

      let isASCII = text.unicodeScalars.allSatisfy(\.isASCII)
      let fontSize = side * (isASCII ? 13.0 / 26.0 : 12.0 / 26.0)
      let font = UIFont.systemFont(ofSize: fontSize, weight: isASCII ? .semibold : .medium)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: UIColor.black,
      ]
      let measured = (text as NSString).size(withAttributes: attributes)
      let drawRect = CGRect(
        x: (side - measured.width) / 2,
        y: (side - measured.height) / 2,
        width: measured.width,
        height: measured.height
      )
      (text as NSString).draw(in: drawRect, withAttributes: attributes)
    }.withRenderingMode(.alwaysTemplate)
  }

  private func updateActiveBorder() {
    let usesGlassBorder = isActive && skin.isNative && SystemKeyboardTokens.drawsLiquidGlassKeyboard
    pad.layer.borderWidth = usesGlassBorder ? 0.5 : 0
    pad.layer.borderColor = usesGlassBorder ? skin.calloutBorder.resolvedColor(with: traitCollection).cgColor : nil
  }

  private func updateActive(animated: Bool) {
    let background = isActive ? skin.toolbarActiveBackground : .clear
    updateActiveBorder()
    guard animated else {
      pad.backgroundColor = background
      tintColor = iconColor
      return
    }
    UIView.animate(withDuration: Self.activeDuration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
      self.pad.backgroundColor = background
      self.tintColor = self.iconColor
    }
  }
}
