import CoreGraphics
import Foundation
import UIKit

typealias MetasequoiaGlidePreview = MetasequoiaInputSessionBridge.GlideLivePreview

/// 滑行实时候选预览的节流策略与兜底键序提取。
///
/// 保持纯值函数与零 UIKit 状态，便于单测直接覆盖所有边界。
enum GlideLivePreviewPolicy {
  /// 两次实时预览解码之间的最小时间间隔（秒），兼顾跟手性与 120Hz 轨迹渲染流畅度。
  static let minimumInterval: TimeInterval = 0.085
  /// 手指停留在尾键略作停顿时的刷新间隔（秒），即使位移不大也能补出最终词预览。
  static let dwellRefreshInterval: TimeInterval = 0.18
  /// 开始实时预览前的最少采样点数。
  static let minimumSamples = 4
  /// 开始实时预览前的最小累计路径长度（pt）。
  static let minimumPathLength: CGFloat = 24
  /// 距上次预览采样点至少再移动该距离才立即触发新一轮解码（pt）。
  static let minimumDeltaDistance: CGFloat = 14
  /// 实时预览栏最多展示的候选词个数。
  static let maxVisibleCandidates = 4

  /// 计算轨迹总弧长（pt）。
  static func pathLength(of samples: [GlideTyping.Sample]) -> CGFloat {
    guard samples.count >= 2 else { return 0 }
    var total: CGFloat = 0
    for index in 1..<samples.count {
      let prev = samples[index - 1]
      let cur = samples[index]
      let dx = cur.x - prev.x
      let dy = cur.y - prev.y
      guard dx.isFinite, dy.isFinite else { continue }
      total += hypot(dx, dy)
    }
    return total
  }

  /// 判断本次 `onMoved` 回调是否应该发起一轮异步预览解码。
  static func shouldDecode(
    sampleCount: Int,
    pathLength: CGFloat,
    deltaFromLast: CGFloat,
    now: TimeInterval,
    lastDecodeTime: TimeInterval,
    inFlight: Bool
  ) -> Bool {
    guard !inFlight else { return false }
    guard sampleCount >= minimumSamples, pathLength >= minimumPathLength else { return false }
    let elapsed = now - lastDecodeTime
    guard elapsed >= minimumInterval else { return false }
    if lastDecodeTime == -.infinity { return true }
    return deltaFromLast >= minimumDeltaDistance || elapsed >= dwellRefreshInterval
  }

  /// 在已有未提交组字且未使用 GlideBeam 时，基于轨迹经过的键位中心快速生成去重字母串，零开销零会话副作用。
  static func keyPathPreview(
    samples: [GlideTyping.Sample],
    frames: [CGRect],
    maxLetters: Int = 24
  ) -> String {
    guard frames.count == GlideTyping.letters.count, !samples.isEmpty else { return "" }
    var letters: [Character] = []
    letters.reserveCapacity(min(maxLetters, 12))
    var lastIndex: Int?
    for sample in samples {
      guard let index = GlideTyping.keyIndex(at: CGPoint(x: sample.x, y: sample.y), in: frames) else {
        continue
      }
      if index != lastIndex {
        lastIndex = index
        letters.append(GlideTyping.letters[index])
        if letters.count >= maxLetters { break }
      }
    }
    return String(letters)
  }
}

/// 滑后退格一键撤整词状态跟踪器：
/// 1. 刚滑行解出组字且用户尚未敲单字母或移动拼音光标时，轻点 ⌫ 一次清空整段滑行组字；
/// 2. 滑行组字通过候选/空格/回车整词上屏（长度 >= 2）后，若紧接着的下一个动作是轻点 ⌫ 且光标前文本确实以该词结尾，一次退掉刚才上屏的整个词。
struct GlideUndoTracker: Equatable {
  struct CommittedGlide: Equatable {
    let text: String
    let document: UUID?
  }

  private(set) var hasActiveGlideComposition = false
  private(set) var lastCommittedGlide: CommittedGlide?

  /// 标记当前组字刚由滑行输入产出。
  mutating func markGlideDecoded() {
    hasActiveGlideComposition = true
    lastCommittedGlide = nil
  }

  /// 用户点按单字母或移动组字光标后，本次组字转回常规逐字/逐音节编辑。
  mutating func clearActiveGlideComposition() {
    hasActiveGlideComposition = false
  }

  /// 若当前组字仍为刚滑行产出的整词，消费该标记并返回 `true`，由调用方一次清空整段组字。
  mutating func consumeActiveGlideComposition() -> Bool {
    guard hasActiveGlideComposition else { return false }
    hasActiveGlideComposition = false
    return true
  }

  /// 当组字完成上屏时，若该组字源自滑行且完整上屏多字词，记下它供紧接着的一次 ⌫ 一键撤回。
  mutating func recordCommittedIfFromGlide(text: String, stillComposing: Bool, document: UUID?) {
    guard hasActiveGlideComposition else { return }
    hasActiveGlideComposition = false
    guard !stillComposing, text.count >= 2 else {
      lastCommittedGlide = nil
      return
    }
    lastCommittedGlide = CommittedGlide(text: text, document: document)
  }

  /// 紧接着的一次 ⌫ 校验文档身份与光标前后缀：匹配则消费并返回整词文本，否则清空并返回 `nil`。
  mutating func consumeCommittedUndo(beforeCursor: String?, document: UUID?) -> String? {
    guard let last = lastCommittedGlide else { return nil }
    lastCommittedGlide = nil
    guard last.document == document,
          let beforeCursor,
          beforeCursor.hasSuffix(last.text) else {
      return nil
    }
    return last.text
  }

  mutating func clearAll() {
    hasActiveGlideComposition = false
    lastCommittedGlide = nil
  }
}

/// 滑行过程中覆盖在顶栏上的实时候选预览条，不改变顶栏高度、不拦截触摸。
final class GlideLivePreviewBar: UIView {
  private let contentStack = UIStackView()
  private let readingLabel = UILabel()
  private let primaryPill = UIView()
  private let primaryLabel = UILabel()
  private var secondaryLabels: [UILabel] = []
  private let trailingSpacer = UIView()
  private var skin = KeyboardTheme.current
  private(set) var currentPreview: MetasequoiaGlidePreview?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isHidden = true
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    accessibilityIdentifier = "glideLivePreviewBar"

    contentStack.axis = .horizontal
    contentStack.alignment = .center
    contentStack.spacing = 10
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentStack)

    readingLabel.font = .systemFont(ofSize: 13, weight: .medium)
    readingLabel.lineBreakMode = .byTruncatingHead
    readingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    readingLabel.setContentHuggingPriority(.required, for: .horizontal)
    readingLabel.accessibilityIdentifier = "glideLivePreviewReading"

    primaryPill.layer.cornerCurve = .continuous
    primaryPill.layer.cornerRadius = 14
    primaryPill.layer.borderWidth = 0.5
    primaryPill.translatesAutoresizingMaskIntoConstraints = false

    primaryLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    primaryLabel.lineBreakMode = .byTruncatingTail
    primaryLabel.translatesAutoresizingMaskIntoConstraints = false
    primaryLabel.accessibilityIdentifier = "glideLivePreviewPrimary"
    primaryPill.addSubview(primaryLabel)
    NSLayoutConstraint.activate([
      primaryLabel.leadingAnchor.constraint(equalTo: primaryPill.leadingAnchor, constant: 11),
      primaryLabel.trailingAnchor.constraint(equalTo: primaryPill.trailingAnchor, constant: -11),
      primaryLabel.topAnchor.constraint(equalTo: primaryPill.topAnchor, constant: 4),
      primaryLabel.bottomAnchor.constraint(equalTo: primaryPill.bottomAnchor, constant: -4),
    ])

    contentStack.addArrangedSubview(readingLabel)
    contentStack.addArrangedSubview(primaryPill)

    for index in 0..<(GlideLivePreviewPolicy.maxVisibleCandidates - 1) {
      let label = UILabel()
      label.font = .systemFont(ofSize: 16, weight: .regular)
      label.lineBreakMode = .byTruncatingTail
      label.isHidden = true
      label.accessibilityIdentifier = "glideLivePreviewSecondary-\(index)"
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      secondaryLabels.append(label)
      contentStack.addArrangedSubview(label)
    }

    trailingSpacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
    trailingSpacer.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
    contentStack.addArrangedSubview(trailingSpacer)

    NSLayoutConstraint.activate([
      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      contentStack.topAnchor.constraint(equalTo: topAnchor),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: GlideLivePreviewBar, _: UITraitCollection) in
      bar.apply(skin: bar.skin, stripBackground: bar.backgroundColor)
    }
    apply(skin: skin, stripBackground: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(_ preview: MetasequoiaGlidePreview?) {
    guard let preview, !preview.isEmpty else {
      clear()
      return
    }
    currentPreview = preview
    readingLabel.text = preview.reading
    readingLabel.isHidden = preview.reading.isEmpty

    if let first = preview.candidates.first, !first.isEmpty {
      primaryLabel.text = first
      primaryPill.isHidden = false
    } else {
      primaryLabel.text = nil
      primaryPill.isHidden = true
    }

    let rest = Array(preview.candidates.dropFirst())
    for (index, label) in secondaryLabels.enumerated() {
      if rest.indices.contains(index), !rest[index].isEmpty {
        label.text = rest[index]
        label.isHidden = false
      } else {
        label.text = nil
        label.isHidden = true
      }
    }
    isHidden = false
  }

  func clear() {
    currentPreview = nil
    readingLabel.text = nil
    primaryLabel.text = nil
    for label in secondaryLabels {
      label.text = nil
      label.isHidden = true
    }
    isHidden = true
  }

  func apply(skin: KeyboardTheme, stripBackground: UIColor?) {
    self.skin = skin
    backgroundColor = stripBackground ?? skin.background
    readingLabel.textColor = skin.secondary
    primaryPill.backgroundColor = skin.toolbarActiveBackground
    primaryPill.layer.borderColor = skin.calloutBorder.resolvedColor(with: traitCollection).cgColor
    primaryLabel.textColor = skin.keyForeground
    for label in secondaryLabels {
      label.textColor = skin.secondary
    }
  }
}
