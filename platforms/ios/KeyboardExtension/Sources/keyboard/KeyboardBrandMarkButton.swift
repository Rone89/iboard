import UIKit

/// 工具栏左上角功能入口按钮：使用 SF Symbol `timelapse` 图标，与工具栏其他图标保持一致的配色、缩放与激活态胶囊底托。
/// 图像覆盖整个按钮，透明边缘保留整格系统键盘点击范围，按压仅在图像内部缩放（不对 `imageView` 做 transform）。
final class KeyboardBrandMarkButton: UIButton {
  static let discSide: CGFloat = 36
  static let markSide: CGFloat = 24
  static let symbolName = "timelapse"
  static let pressScale: CGFloat = 0.92
  private static let disabledAlpha: CGFloat = 0.4

  private var renderedSize = CGSize.zero
  private var renderedDark: Bool?
  private var renderedActive: Bool?
  private var renderedSkinID: String?
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

  /// 换皮肤或明暗变化时同步重绘 `timelapse` 图标与激活态底托。
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
    guard force || renderedSize != size || renderedDark != isDark
            || renderedActive != isActive || renderedSkinID != skin.id else { return }
    renderMark(size: size, isDark: isDark)
  }

  /// 图像覆盖整个按钮，SF Symbol `timelapse` 居中绘制，透明部分保留整格点击范围。
  private func renderMark(size: CGSize, isDark: Bool) {
    let foreground = (isActive ? skin.accent : skin.secondary).resolvedColor(with: traitCollection)
    let activePadFill = skin.toolbarActiveBackground.resolvedColor(with: traitCollection)
    let activePadBorder = skin.calloutBorder.resolvedColor(with: traitCollection)
    let usesGlassPill = skin.isNative && SystemKeyboardTokens.drawsLiquidGlassKeyboard

    func glyph(scale: CGFloat) -> UIImage {
      let rowScale = KeyboardToolbarButton.contentScale(rowHeight: size.height)
      let padBase = usesGlassPill ? KeyboardToolbarButton.nativeGlassPadSide : KeyboardToolbarButton.padSide
      let padSide = min(padBase * rowScale, size.width, size.height) * scale
      let symbolSide = min(Self.markSide * rowScale, size.width, size.height) * scale
      let symbolConfig = UIImage.SymbolConfiguration(pointSize: symbolSide * 0.86, weight: .medium)
      let symbol = UIImage(systemName: Self.symbolName, withConfiguration: symbolConfig)?
        .withTintColor(foreground, renderingMode: .alwaysOriginal)

      return UIGraphicsImageRenderer(size: size).image { _ in
        if isActive {
          let padRect = CGRect(
            x: (size.width - padSide) / 2,
            y: (size.height - padSide) / 2,
            width: padSide,
            height: padSide
          )
          let radius = usesGlassPill ? padSide / 2 : min(KeyboardToolbarButton.padRadius * rowScale, padSide / 2)
          let padPath = UIBezierPath(roundedRect: padRect, cornerRadius: radius)
          activePadFill.setFill()
          padPath.fill()
          if usesGlassPill {
            activePadBorder.setStroke()
            padPath.lineWidth = 0.5
            padPath.stroke()
          }
        }
        if let symbol {
          let imageSize = symbol.size
          let fit = min(1, symbolSide / max(imageSize.width, imageSize.height, 1))
          let drawW = imageSize.width * fit
          let drawH = imageSize.height * fit
          let drawRect = CGRect(
            x: (size.width - drawW) / 2,
            y: (size.height - drawH) / 2,
            width: drawW,
            height: drawH
          )
          symbol.draw(in: drawRect)
        }
      }.withRenderingMode(.alwaysOriginal)
    }

    renderedSize = size
    renderedDark = isDark
    renderedActive = isActive
    renderedSkinID = skin.id
    let normal = glyph(scale: 1)
    setImage(normal, for: .normal)
    setImage(normal, for: .disabled)
    setImage(glyph(scale: Self.pressScale), for: .highlighted)
  }
}
