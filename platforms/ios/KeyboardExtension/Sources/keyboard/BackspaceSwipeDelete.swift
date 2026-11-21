import CoreGraphics
import Foundation
import UIKit

/// 退格键左滑删除的文本切分策略与单次手势状态机。
///
/// 规则兼顾中英文与安全性：
/// - 正在组字时，左滑一次清空当前整段组字，绝不跨边界继续删掉已上屏正文；
/// - 非组字状态下，每次跨过步进距离按词或中文短句分块删除光标前文本，并按原始文档顺序累积被删片段，供工具栏「撤销删除」胶囊一键恢复；
/// - 密码/一次性验证码等凭据输入框里不缓存被删文本，避免隐私内容进入工具栏预览或内存撤回缓冲。
enum BackspaceSwipeDeletePolicy {
  /// 进入左滑触发首次分块删除所需的最小左移距离（pt）。
  static let horizontalTriggerDistance: CGFloat = 28
  /// 首次触发后，继续向左拖动每跨越该距离再删一块（pt）。
  static let stepDistance: CGFloat = 28
  /// 快速左甩抬手时，未达完整触发距离也能按甩动触发一次分块删除的最小距离与速度。
  static let flickMinDistance: CGFloat = 16
  static let flickMinVelocity: CGFloat = 320
  /// 判定手势起滑为「明确向左水平滑」的最小左向速度与水平/垂直速度比。
  static let minStartVelocityX: CGFloat = 80
  static let horizontalDominanceRatio: CGFloat = 1.4
  /// 单次连续左滑最多触发的分块步数，防止异常手势一次清空长文。
  static let maxStepsPerSwipe = 12
  /// 单次中文/非拉丁语分块删除的字符上限（遇到标点、空白或换行会提前停住）。
  static let maxIdeographChunkCharacters = 12
  /// 单次连续标点删除上限。
  static let maxPunctuationChunkCharacters = 4
  /// 工具栏「撤销删除」胶囊预览文本的最大字符数。
  static let maxUndoPreviewCharacters = 4

  /// 判断退格键上的拖拽速度是否满足「向左水平滑」起始条件。
  static func shouldBegin(velocity: CGPoint) -> Bool {
    guard velocity.x.isFinite, velocity.y.isFinite else { return false }
    guard velocity.x <= -minStartVelocityX else { return false }
    return abs(velocity.x) > abs(velocity.y) * horizontalDominanceRatio
  }

  /// 计算光标前文本末尾应被一次左滑删除的片段；光标前为空时返回 `nil`。
  static func chunkToDelete(beforeCursor: String?) -> String? {
    guard let beforeCursor, !beforeCursor.isEmpty else { return nil }
    let chars = Array(beforeCursor)
    var index = chars.count

    // 换行单独作为一块，避免一次左滑误跨段落。
    if chars[index - 1].isNewline {
      return String(chars[index - 1])
    }

    // 先吞掉末尾连续的空格或制表符（上限防止极端长空白一次删过头）。
    var trailingSpaces = 0
    while index > 0 && isInlineSpace(chars[index - 1]) && trailingSpaces < maxIdeographChunkCharacters {
      index -= 1
      trailingSpaces += 1
    }

    guard index > 0 else {
      return String(chars[(chars.count - trailingSpaces)...])
    }

    let pivot = chars[index - 1]
    if pivot.isNewline {
      return trailingSpaces > 0 ? String(chars[index...]) : String(pivot)
    }

    if isAsciiWordCharacter(pivot) {
      while index > 0 && isAsciiWordCharacter(chars[index - 1]) {
        index -= 1
      }
      return String(chars[index...])
    }

    if isPunctuationOrSymbol(pivot) {
      var count = 0
      while index > 0 && isPunctuationOrSymbol(chars[index - 1]) && count < maxPunctuationChunkCharacters {
        index -= 1
        count += 1
      }
      return String(chars[index...])
    }

    // 中文/假名/韩文等非拉丁连续正文：向左删到标点、空白、换行或 ASCII 词边界为止，受单块上限约束。
    var ideographCount = 0
    while index > 0 && ideographCount < maxIdeographChunkCharacters {
      let candidate = chars[index - 1]
      if candidate.isNewline || isInlineSpace(candidate) || isAsciiWordCharacter(candidate) || isPunctuationOrSymbol(candidate) {
        break
      }
      index -= 1
      ideographCount += 1
    }
    if ideographCount > 0 {
      return String(chars[index...])
    }
    return String(chars[(chars.count - max(1, trailingSpaces))...])
  }

  /// 生成用于工具栏「撤销删除」胶囊的紧凑摘要（单行，超出截断并加省略号）。
  static func undoPreviewText(_ deletedText: String, maxCharacters: Int = maxUndoPreviewCharacters) -> String {
    QuickPasteToolbarPolicy.truncatedTextPreview(deletedText, maxCharacters: maxCharacters)
  }

  private static func isInlineSpace(_ character: Character) -> Bool {
    character == " " || character == "\t"
  }

  private static func isAsciiWordCharacter(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { scalar in
      guard scalar.isASCII else { return false }
      return CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "_"
    }
  }

  private static func isPunctuationOrSymbol(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { scalar in
      CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
    }
  }
}

/// 一次可恢复的退格左滑删除记录。
struct BackspaceUndoRecord: Equatable {
  let deletedText: String
  let document: UUID?

  var previewText: String {
    BackspaceSwipeDeletePolicy.undoPreviewText(deletedText)
  }
}

/// 跟踪单次退格键左滑手势的步进与累积删除文本。
struct BackspaceSwipeDeleteSession {
  private(set) var isActive = false
  private(set) var triggeredStepCount = 0
  private(set) var clearedComposition = false
  private(set) var deletedText = ""
  private var document: UUID?
  private var startX: CGFloat = 0

  mutating func begin(at x: CGFloat, document: UUID?) {
    guard x.isFinite else {
      cancel()
      return
    }
    isActive = true
    triggeredStepCount = 0
    clearedComposition = false
    deletedText = ""
    self.document = document
    startX = x
  }

  /// 根据当前手指位置计算本次回调新跨越的分块步数。
  mutating func advance(to x: CGFloat) -> Int {
    guard isActive, x.isFinite, !clearedComposition else { return 0 }
    let leftward = startX - x
    guard leftward >= BackspaceSwipeDeletePolicy.horizontalTriggerDistance else { return 0 }
    let extraSteps = Int((leftward - BackspaceSwipeDeletePolicy.horizontalTriggerDistance) / BackspaceSwipeDeletePolicy.stepDistance)
    let targetSteps = min(BackspaceSwipeDeletePolicy.maxStepsPerSwipe, 1 + max(0, extraSteps))
    let delta = max(0, targetSteps - triggeredStepCount)
    triggeredStepCount += delta
    return delta
  }

  /// 抬手时若尚未触发步进，但满足快速左甩的距离与速度，则补触发一次删除。
  mutating func shouldTriggerFlickOnEnd(at x: CGFloat, velocityX: CGFloat) -> Bool {
    guard isActive, !clearedComposition, triggeredStepCount == 0 else { return false }
    guard x.isFinite, velocityX.isFinite else { return false }
    let leftward = startX - x
    guard leftward >= BackspaceSwipeDeletePolicy.flickMinDistance,
          velocityX <= -BackspaceSwipeDeletePolicy.flickMinVelocity else { return false }
    triggeredStepCount = 1
    return true
  }

  mutating func markClearedComposition() {
    clearedComposition = true
  }

  /// 按原始文档从左到右的顺序前置累积每次删除的片段。
  mutating func recordDeletedChunk(_ chunk: String) {
    guard !chunk.isEmpty else { return }
    deletedText = chunk + deletedText
  }

  mutating func finish(allowsUndoRecord: Bool) -> BackspaceUndoRecord? {
    let record: BackspaceUndoRecord?
    if allowsUndoRecord, !deletedText.isEmpty {
      record = BackspaceUndoRecord(deletedText: deletedText, document: document)
    } else {
      record = nil
    }
    cancel()
    return record
  }

  mutating func cancel() {
    isActive = false
    triggeredStepCount = 0
    clearedComposition = false
    deletedText = ""
    document = nil
    startX = 0
  }
}

/// 放在工具栏左侧品牌键旁边的「撤销删除」胶囊按钮，视觉与「一键粘贴」胶囊保持一致。
final class UndoDeleteToolbarButton: UIButton {
  private static let pillHeight: CGFloat = 30
  private static let horizontalPadding: CGFloat = 10
  private static let iconSide: CGFloat = 13
  private static let itemSpacing: CGFloat = 4
  private static let previewSpacing: CGFloat = 5

  private let pad = UIView()
  private let iconView = UIImageView()
  private let labelView = UILabel()
  private let previewLabel = UILabel()
  private var skin = KeyboardTheme.current
  private var previewText: String = ""

  init() {
    super.init(frame: .zero)
    backgroundColor = .clear
    accessibilityIdentifier = "undoDeleteShortcut"
    accessibilityLabel = "撤销删除"
    accessibilityTraits = .button

    pad.isUserInteractionEnabled = false
    pad.layer.cornerCurve = .continuous
    addSubview(pad)

    let symbolConfig = UIImage.SymbolConfiguration(pointSize: Self.iconSide, weight: .semibold)
    iconView.image = UIImage(systemName: "arrow.uturn.backward", withConfiguration: symbolConfig)
    iconView.contentMode = .scaleAspectFit
    iconView.isUserInteractionEnabled = false
    pad.addSubview(iconView)

    labelView.text = "撤销"
    labelView.font = .systemFont(ofSize: 13, weight: .medium)
    labelView.isUserInteractionEnabled = false
    pad.addSubview(labelView)

    previewLabel.font = .systemFont(ofSize: 12, weight: .regular)
    previewLabel.lineBreakMode = .byTruncatingTail
    previewLabel.isUserInteractionEnabled = false
    previewLabel.isHidden = true
    pad.addSubview(previewLabel)

    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: UndoDeleteToolbarButton, _: UITraitCollection) in
      button.apply(skin: button.skin)
    }
    apply(skin: skin)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(record: BackspaceUndoRecord?) {
    if let record {
      let summary = record.previewText
      previewText = summary
      previewLabel.text = summary
      previewLabel.isHidden = summary.isEmpty
      accessibilityValue = summary.isEmpty ? nil : summary
    } else {
      previewText = ""
      previewLabel.text = nil
      previewLabel.isHidden = true
      accessibilityValue = nil
    }
    invalidateIntrinsicContentSize()
    setNeedsLayout()
  }

  override var intrinsicContentSize: CGSize {
    let titleWidth = ceil(labelView.intrinsicContentSize.width)
    var width = Self.horizontalPadding * 2 + Self.iconSide + Self.itemSpacing + titleWidth
    if !previewText.isEmpty {
      width += Self.previewSpacing + ceil(previewLabel.intrinsicContentSize.width)
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
    let spacing = Self.itemSpacing * scale
    let titleWidth = ceil(labelView.intrinsicContentSize.width) * scale

    iconView.frame = CGRect(
      x: padH,
      y: (pillHeight - iconSide) / 2,
      width: iconSide,
      height: iconSide
    )
    let labelX = padH + iconSide + spacing
    labelView.frame = CGRect(x: labelX, y: 0, width: titleWidth, height: pillHeight)

    if !previewLabel.isHidden {
      let previewX = labelX + titleWidth + Self.previewSpacing * scale
      let availableWidth = max(0, pillWidth - previewX - padH)
      previewLabel.frame = CGRect(x: previewX, y: 0, width: availableWidth, height: pillHeight)
    }
  }

  func apply(skin: KeyboardTheme) {
    self.skin = skin
    pad.backgroundColor = skin.toolbarActiveBackground
    pad.layer.borderWidth = 0.5
    pad.layer.borderColor = skin.calloutBorder.resolvedColor(with: traitCollection).cgColor
    let foreground = skin.keyForeground
    iconView.tintColor = foreground
    labelView.textColor = foreground
    previewLabel.textColor = skin.secondary
  }
}
