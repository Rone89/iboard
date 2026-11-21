import UIKit

/// 工具栏左上角品牌按钮：与 iBoard 桌面应用图标（`AppIcon` / `AppIconDark`）统一的液态玻璃 `iB` 键帽标志。
/// 使用原生 `UIButton` 满格图像保留系统键盘全格命中（绝不对 `imageView` 做 transform 缩放），随行高和明暗外观自适应重绘。
final class KeyboardBrandMarkButton: UIButton {
  static let discSide: CGFloat = 36
  static let markSide: CGFloat = 24
  static let pressScale: CGFloat = 0.92
  private static let disabledAlpha: CGFloat = 0.4

  private var renderedSize = CGSize.zero
  private var renderedDark: Bool?
  private var renderedActive: Bool?
  private var skin = KeyboardTheme.current

  var isActive = false {
    didSet {
      guard isActive != oldValue else { return }
      accessibilityTraits = isActive ? [.button, .selected] : .button
      renderIfNeeded(force: true)
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    accessibilityLabel = "功能"
    accessibilityTraits = .button
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: KeyboardBrandMarkButton, _: UITraitCollection) in
      button.renderIfNeeded(force: true)
    }
    apply(skin: KeyboardTheme.current)
    imageView?.accessibilityIdentifier = "keyboardBrandIcon"
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 换皮肤或明暗变化时同步重绘液态玻璃 `iB` 键帽（激活态光环取当前皮肤强调色）。
  func apply(skin: KeyboardTheme) {
    self.skin = skin
    renderIfNeeded(force: true)
  }

  override var isEnabled: Bool {
    didSet {
      alpha = isEnabled ? 1 : Self.disabledAlpha
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      imageView?.resetKeyboardPressAnimationAfterWindowRemoval()
    } else {
      renderIfNeeded(force: false)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if bounds.width > 0, bounds.height > 0, renderedSize != bounds.size {
      renderIfNeeded(force: true)
      super.layoutSubviews()
    }
  }

  private func renderIfNeeded(force: Bool) {
    let size = bounds.width > 0 && bounds.height > 0 ? bounds.size : CGSize(width: Self.discSide, height: Self.discSide)
    let isDark = traitCollection.userInterfaceStyle == .dark
    guard force || renderedSize != size || renderedDark != isDark || renderedActive != isActive else { return }
    renderMark(size: size, isDark: isDark)
  }

  /// 图像覆盖整个按钮，液态玻璃 `iB` 键帽在中央绘制，透明部分保留整格点击范围。
  private func renderMark(size: CGSize, isDark: Bool) {
    let accent = skin.accent.resolvedColor(with: traitCollection)
    func glyph(scale: CGFloat) -> UIImage {
      // 和工具栏其他按钮一样随行高缩小（`KeyboardToolbarButton.contentScale`），「候选栏大小」调小时标志不伸出这一行。
      let slot = min(Self.discSide * KeyboardToolbarButton.contentScale(rowHeight: size.height), size.width, size.height) * scale
      let mark = slot * Self.markSide / Self.discSide
      let markRect = CGRect(x: (size.width - mark) / 2, y: (size.height - mark) / 2, width: mark, height: mark)
      return UIGraphicsImageRenderer(size: size).image { rendererContext in
        IBoardBrandMarkRenderer.draw(
          in: markRect,
          context: rendererContext.cgContext,
          isDark: isDark,
          isActive: isActive,
          accent: accent
        )
      }.withRenderingMode(.alwaysOriginal)
    }
    renderedSize = size
    renderedDark = isDark
    renderedActive = isActive
    let normal = glyph(scale: 1)
    setImage(normal, for: .normal)
    setImage(normal, for: .disabled)
    setImage(glyph(scale: Self.pressScale), for: .highlighted)
  }
}

/// CoreGraphics 矢量绘制 iBoard 液态玻璃 `iB` 键帽（对齐 `AppIcon.png` 亮色深海蓝字标与 `AppIconDark.png` 暗色冰蓝字标）。
enum IBoardBrandMarkRenderer {
  static func draw(
    in rect: CGRect,
    context: CGContext,
    isDark: Bool,
    isActive: Bool,
    accent: UIColor
  ) {
    guard rect.width > 1, rect.height > 1 else { return }
    let keycapRect = CGRect(
      x: rect.minX,
      y: rect.minY + rect.height * 0.06,
      width: rect.width,
      height: rect.height * 0.88
    )
    let cornerRadius = keycapRect.height * 0.30
    let keycapPath = UIBezierPath(roundedRect: keycapRect, cornerRadius: cornerRadius)

    // 1. 柔和键帽底影，建立微浮雕层次。
    context.saveGState()
    let shadowColor = isDark
      ? UIColor(white: 0, alpha: 0.38).cgColor
      : UIColor(red: 0.08, green: 0.22, blue: 0.45, alpha: 0.20).cgColor
    context.setShadow(offset: CGSize(width: 0, height: max(0.75, rect.height * 0.04)), blur: max(1.2, rect.height * 0.07), color: shadowColor)
    (isDark
      ? UIColor(red: 0.29, green: 0.34, blue: 0.43, alpha: 1)
      : UIColor(red: 0.80, green: 0.87, blue: 0.97, alpha: 1)).setFill()
    keycapPath.fill()
    context.restoreGState()

    // 2. 液态玻璃垂直渐变底色 + 左上角斜向高光折射。
    context.saveGState()
    keycapPath.addClip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let topColor: UIColor = isDark
      ? UIColor(red: 0.41, green: 0.46, blue: 0.55, alpha: 1)
      : UIColor(red: 0.94, green: 0.97, blue: 1.00, alpha: 1)
    let bottomColor: UIColor = isDark
      ? UIColor(red: 0.24, green: 0.28, blue: 0.36, alpha: 1)
      : UIColor(red: 0.72, green: 0.80, blue: 0.93, alpha: 1)
    if let gradient = CGGradient(
      colorsSpace: colorSpace,
      colors: [topColor.cgColor, bottomColor.cgColor] as CFArray,
      locations: [0, 1]
    ) {
      context.drawLinearGradient(
        gradient,
        start: CGPoint(x: keycapRect.midX, y: keycapRect.minY),
        end: CGPoint(x: keycapRect.midX, y: keycapRect.maxY),
        options: []
      )
    }

    // 斜向玻璃微反光带，呼应 AppIcon 键帽表面光影。
    let sheenTop = UIColor(white: 1, alpha: isDark ? 0.16 : 0.34)
    let sheenMid = UIColor(white: 1, alpha: 0.0)
    if let sheen = CGGradient(
      colorsSpace: colorSpace,
      colors: [sheenTop.cgColor, sheenMid.cgColor] as CFArray,
      locations: [0, 0.72]
    ) {
      context.drawLinearGradient(
        sheen,
        start: CGPoint(x: keycapRect.minX, y: keycapRect.minY),
        end: CGPoint(x: keycapRect.maxX, y: keycapRect.maxY),
        options: []
      )
    }

    // 顶部细镜面高光线（Liquid Glass specular rim）。
    let innerHighlight = UIBezierPath(
      roundedRect: keycapRect.insetBy(dx: 0.5, dy: 0.5),
      cornerRadius: max(1, cornerRadius - 0.5)
    )
    UIColor(white: 1, alpha: isDark ? 0.34 : 0.78).setStroke()
    innerHighlight.lineWidth = max(0.6, rect.width * 0.032)
    innerHighlight.stroke()
    context.restoreGState()

    // 3. 外沿描边（展开功能菜单激活态用皮肤强调色环）。
    context.saveGState()
    let borderColor: UIColor = isActive
      ? accent
      : (isDark
        ? UIColor(white: 1, alpha: 0.28)
        : UIColor(red: 0.42, green: 0.56, blue: 0.78, alpha: 0.52))
    borderColor.setStroke()
    keycapPath.lineWidth = isActive ? max(1.25, rect.width * 0.055) : max(0.55, rect.width * 0.026)
    keycapPath.stroke()
    context.restoreGState()

    // 4. 居中绘制圆角粗体 `iB` 字标（亮色深海蓝带微凹光，暗色冰天蓝）。
    let fontSize = keycapRect.height * 0.62
    let baseFont = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
    let font: UIFont
    if let rounded = baseFont.fontDescriptor.withDesign(.rounded) {
      font = UIFont(descriptor: rounded, size: fontSize)
    } else {
      font = baseFont
    }
    let kern = -fontSize * 0.04
    let glyphColor: UIColor = isDark
      ? UIColor(red: 0.56, green: 0.74, blue: 1.00, alpha: 1)
      : UIColor(red: 0.04, green: 0.29, blue: 0.56, alpha: 1)
    let embossColor: UIColor = isDark
      ? UIColor(white: 0, alpha: 0.35)
      : UIColor(white: 1, alpha: 0.50)

    let text = "iB" as NSString
    let mainAttrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: glyphColor,
      .kern: kern,
    ]
    let embossAttrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: embossColor,
      .kern: kern,
    ]
    let textSize = text.size(withAttributes: mainAttrs)
    let origin = CGPoint(
      x: keycapRect.midX - textSize.width / 2,
      y: keycapRect.midY - textSize.height / 2 + keycapRect.height * 0.01
    )
    let embossOffset = CGPoint(x: origin.x, y: origin.y + max(0.4, rect.height * 0.02))
    text.draw(at: embossOffset, withAttributes: embossAttrs)
    text.draw(at: origin, withAttributes: mainAttrs)
  }
}
