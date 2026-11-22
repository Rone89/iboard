import UIKit

/// 工具栏「一键粘贴」按钮的剪贴板预览内容。
enum QuickPastePreview: Equatable {
  case text(preview: String, fullText: String)
  case image(UIImage)
}

/// 工具栏「一键粘贴」按钮的显示策略：
/// 只读取 `UIPasteboard.general.hasStrings`、`hasImages` 和 `changeCount`，
/// 仅在检测到新复制的纯文本（不含图片）时显示按钮；用户点按后记录该 `changeCount`，同一条内容不再重复显示。
enum QuickPasteToolbarPolicy {
  static let handledChangeCountKey = "toolbar.quickPaste.handledChangeCount"
  static let maxPreviewCharacters = 6

  /// 先按轻量 `changeCount` 判断是否有尚未处理的剪贴板变更，避免在未复制新内容时发起跨进程 `hasStrings`/`hasImages` XPC 查询。
  static func isUnhandled(changeCount: Int, defaults: UserDefaults = .standard) -> Bool {
    guard changeCount > 0 else { return false }
    return defaults.object(forKey: handledChangeCountKey) as? Int != changeCount
  }

  static func shouldShow(
    changeCount: Int,
    hasStrings: Bool,
    hasImages: Bool = false,
    defaults: UserDefaults = .standard
  ) -> Bool {
    // iOS 键盘扩展无法通过 `UITextDocumentProxy` 直接插入图片；只要剪贴板包含图片（即使同时附带文件名或链接文本），
    // 一律不展示一键粘贴胶囊，也不再去读取剪贴板正文，避免无效提示与触发系统粘贴横幅。
    guard !hasImages, hasStrings else { return false }
    return isUnhandled(changeCount: changeCount, defaults: defaults)
  }

  static func markHandled(changeCount: Int, defaults: UserDefaults = .standard) {
    defaults.set(changeCount, forKey: handledChangeCountKey)
  }

  /// 生成用于工具栏展示的文本摘要：合并换行并取前 6 个字符，超出时末尾加省略号。
  static func truncatedTextPreview(_ text: String, maxCharacters: Int = maxPreviewCharacters) -> String {
    let singleLine = text
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard singleLine.count > maxCharacters else { return singleLine }
    return String(singleLine.prefix(maxCharacters)) + "…"
  }
}

/// 放在工具栏左侧品牌键旁边的「一键粘贴」胶囊按钮：仅展示粘贴图标加复制内容前 6 字摘要（超出加省略号）。
final class QuickPasteToolbarButton: UIButton {
  private static let pillHeight: CGFloat = 30
  private static let horizontalPadding: CGFloat = 10
  private static let iconSide: CGFloat = 14
  private static let previewSpacing: CGFloat = 5
  private static let thumbnailSide: CGFloat = 20

  private let pad = UIView()
  private let iconView = UIImageView()
  private let previewLabel = UILabel()
  private let previewImageView = UIImageView()
  private var skin = KeyboardTheme.current
  private var preview: QuickPastePreview?

  init() {
    super.init(frame: .zero)
    backgroundColor = .clear
    accessibilityIdentifier = "quickPasteShortcut"
    accessibilityLabel = "一键粘贴"
    accessibilityTraits = .button

    pad.isUserInteractionEnabled = false
    pad.layer.cornerCurve = .continuous
    addSubview(pad)

    let symbolConfig = UIImage.SymbolConfiguration(pointSize: Self.iconSide, weight: .medium)
    iconView.image = UIImage(systemName: "doc.on.clipboard", withConfiguration: symbolConfig)
    iconView.contentMode = .scaleAspectFit
    iconView.isUserInteractionEnabled = false
    pad.addSubview(iconView)

    previewLabel.font = .systemFont(ofSize: 13, weight: .medium)
    previewLabel.lineBreakMode = .byTruncatingTail
    previewLabel.isUserInteractionEnabled = false
    previewLabel.isHidden = true
    pad.addSubview(previewLabel)

    previewImageView.contentMode = .scaleAspectFill
    previewImageView.clipsToBounds = true
    previewImageView.layer.cornerRadius = 4
    previewImageView.layer.cornerCurve = .continuous
    previewImageView.isUserInteractionEnabled = false
    previewImageView.isHidden = true
    pad.addSubview(previewImageView)

    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: QuickPasteToolbarButton, _: UITraitCollection) in
      button.apply(skin: button.skin)
    }
    apply(skin: skin)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(preview: QuickPastePreview?) {
    self.preview = preview
    switch preview {
    case let .text(summary, _):
      previewLabel.text = summary
      previewLabel.isHidden = summary.isEmpty
      previewImageView.image = nil
      previewImageView.isHidden = true
      accessibilityValue = summary
    case let .image(image):
      previewLabel.text = nil
      previewLabel.isHidden = true
      previewImageView.image = image
      previewImageView.isHidden = false
      accessibilityValue = "图片"
    case nil:
      previewLabel.text = nil
      previewLabel.isHidden = true
      previewImageView.image = nil
      previewImageView.isHidden = true
      accessibilityValue = nil
    }
    invalidateIntrinsicContentSize()
    setNeedsLayout()
  }

  override var intrinsicContentSize: CGSize {
    var width = Self.horizontalPadding * 2 + Self.iconSide
    switch preview {
    case let .text(summary, _) where !summary.isEmpty:
      width += Self.previewSpacing + ceil(previewLabel.intrinsicContentSize.width)
    case .image:
      width += Self.previewSpacing + Self.thumbnailSide
    default:
      break
    }
    return CGSize(width: width, height: KeyboardToolbarButton.padSide)
  }

  override var isHighlighted: Bool {
    didSet {
      guard isHighlighted != oldValue else { return }
      let pressed = isHighlighted && isEnabled
      KeyPressMotion.animate(
        pad,
        scale: pressed ? KeyboardToolbarButton.pressScale : 1,
        duration: pressed ? 0 : KeyboardToolbarButton.pressDuration
      )
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      pad.resetKeyboardPressAnimationAfterWindowRemoval()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = KeyboardToolbarButton.contentScale(rowHeight: bounds.height)
    let pillHeight = min(Self.pillHeight * scale, bounds.height)
    let pillWidth = bounds.width
    pad.bounds = CGRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
    pad.center = CGPoint(x: bounds.midX, y: bounds.midY)
    pad.layer.cornerRadius = pillHeight / 2

    let padH = Self.horizontalPadding * scale
    let iconSide = Self.iconSide * scale

    let hasPreview = !previewImageView.isHidden || !previewLabel.isHidden
    let iconX = hasPreview ? padH : (pillWidth - iconSide) / 2
    iconView.frame = CGRect(
      x: iconX,
      y: (pillHeight - iconSide) / 2,
      width: iconSide,
      height: iconSide
    )

    let previewX = padH + iconSide + Self.previewSpacing * scale
    let availablePreviewWidth = max(0, pillWidth - previewX - padH)
    if !previewImageView.isHidden {
      let thumbSide = min(Self.thumbnailSide * scale, availablePreviewWidth, pillHeight - 6 * scale)
      previewImageView.frame = CGRect(
        x: previewX,
        y: (pillHeight - thumbSide) / 2,
        width: thumbSide,
        height: thumbSide
      )
      previewImageView.layer.cornerRadius = min(4 * scale, thumbSide / 2)
    } else if !previewLabel.isHidden {
      previewLabel.frame = CGRect(x: previewX, y: 0, width: availablePreviewWidth, height: pillHeight)
    }
  }

  func apply(skin: KeyboardTheme) {
    self.skin = skin
    pad.backgroundColor = skin.toolbarActiveBackground
    pad.layer.borderWidth = 0.5
    pad.layer.borderColor = skin.calloutBorder.resolvedColor(with: traitCollection).cgColor
    let foreground = skin.keyForeground
    iconView.tintColor = foreground
    previewLabel.textColor = foreground
  }
}
