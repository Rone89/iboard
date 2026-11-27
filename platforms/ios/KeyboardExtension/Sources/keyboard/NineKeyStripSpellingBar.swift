import UIKit

/// 九键展开候选面板下「当前选中拼音」解析与「按一下切到下一个候选拼音」的纯规则。
enum NineKeySpellingCyclePolicy {
  /// 顶栏候选拼音条展示的一项：保留显示文本、引擎原始值与引擎真实下标的映射。
  struct DisplayedItem: Equatable {
    let title: String
    let raw: String
    let engineIndex: Int
  }

  /// 完整拼音音节（纯 ASCII 小写字母，如 `ni`、`ning`、`cai`）。
  static func isSyllable(_ choice: String) -> Bool {
    guard !choice.isEmpty else { return false }
    return choice.utf8.allSatisfy { (97...122).contains($0) }
  }

  /// 首字母限定项（单个 ASCII 大写字母，如 `M`、`N`、`O`）。
  static func isLetter(_ choice: String) -> Bool {
    guard choice.utf8.count == 1, let byte = choice.utf8.first else { return false }
    return (65...90).contains(byte)
  }

  /// 判断当前是否处于「单个未锁定数字键」状态（例如刚按 1 下 `5(JKL)` / `8(TUV)`，或锁定前段音节后末尾仅剩 1 个数字 `ni'5`）。
  static func isSingleUnlockedDigit(
    preedit: String,
    editingText: String,
    isBrowsing: Bool = false,
    browsingSingleDigit: Bool? = nil
  ) -> Bool {
    if isBrowsing, let browsingSingleDigit {
      return browsingSingleDigit
    }
    if editingText.count == 1 {
      return true
    }
    guard !preedit.isEmpty else { return false }
    let tail = preedit.split(separator: "'").last.map(String.init) ?? ""
    return tail.count == 1
  }

  /// 为 iOS 原生九键顶栏投影要展示的候选拼音列表：
  /// - 单键态（未锁定数字只有 1 位）与系统原生九键一致，仅展示当前键可作拼音起头的单字母（小写，如 `5`→`j | k | l`、`6`→`m | n | o`、`8`→`t`），不塞入 2+ 字母的未键入预测补全音节；
  /// - 2 键及以上保持引擎完整候选列表。
  static func nativeDisplayedItems(
    from spellings: [String],
    preedit: String,
    editingText: String,
    isBrowsing: Bool = false,
    browsingSingleDigit: Bool? = nil
  ) -> [DisplayedItem] {
    if isSingleUnlockedDigit(
      preedit: preedit,
      editingText: editingText,
      isBrowsing: isBrowsing,
      browsingSingleDigit: browsingSingleDigit
    ) {
      let letters = spellings.enumerated().compactMap { index, raw -> DisplayedItem? in
        guard isLetter(raw) else { return nil }
        return DisplayedItem(title: raw.lowercased(), raw: raw, engineIndex: index)
      }
      if !letters.isEmpty {
        return letters
      }
    }
    return spellings.enumerated().map { index, raw in
      DisplayedItem(title: raw, raw: raw, engineIndex: index)
    }
  }

  /// 将引擎原始选中下标映射到当前展示列表中的下标（单键态同时兼容 `o` / `O`、`a` / `A`、`e` / `E`）。
  static func displayedSelectedIndex(
    in items: [DisplayedItem],
    rawSelectedIndex: Int?,
    rawSpellings: [String]
  ) -> Int? {
    guard let rawSelectedIndex, rawSpellings.indices.contains(rawSelectedIndex) else { return nil }
    if let direct = items.firstIndex(where: { $0.engineIndex == rawSelectedIndex }) {
      return direct
    }
    let lowered = rawSpellings[rawSelectedIndex].lowercased()
    return items.firstIndex(where: { $0.title == lowered })
  }

  /// 参与「选拼音」原地循环切换的下标列表：
  /// 引擎侧 `browse_spelling` 已完整支持音节、大写首字母（原地筛选不缩表）与末尾数字（仅候选首位展示不误上屏），
  /// 因此顶栏可见的每一项全部按原顺序参与循环。
  static func cyclableIndices(in spellings: [String]) -> [Int] {
    Array(spellings.indices)
  }

  /// 计算当前在横向拼音条里应当显示选中容器的下标。
  ///
  /// 只有引擎真正处于「原地浏览」「全部锁定换选」或「首字母限定」状态时才高亮对应项；
  /// 未限定任何拼音时（如 `56` 下 `preedit == "56"`、`reading == "ko"`，下方混排 `口/空/扣/咯/控`）返回 `nil`，
  /// 绝不把未生效的首个音节（如 `lo`）伪装成已选中，同时让首次点按「选拼音」正好选中第 0 项。
  static func selectedIndex(
    in spellings: [String],
    preedit: String,
    reading: String = "",
    lastChosen: (spelling: String, spellings: [String], isBrowsing: Bool)? = nil
  ) -> Int? {
    guard !spellings.isEmpty else { return nil }
    let preeditParts = preedit.split(separator: "'").map(String.init).filter { !$0.isEmpty }
    let firstDigitPart = preeditParts.first { part in
      part.utf8.contains { (48...57).contains($0) }
    }
    let hasAnyDigits = firstDigitPart != nil
    let tailPart = preeditParts.last ?? ""
    let leadingInitialLetter: String? = {
      guard let part = firstDigitPart,
            let first = part.utf8.first,
            (97...122).contains(first) else { return nil }
      return String(UnicodeScalar(first)).uppercased()
    }()

    if let last = lastChosen, last.spellings == spellings,
       let idx = spellings.firstIndex(of: last.spelling) {
      if last.isBrowsing {
        return idx
      }
      if isLetter(last.spelling) {
        if leadingInitialLetter == last.spelling {
          return idx
        }
        if !hasAnyDigits, tailPart.count == 1, tailPart.uppercased() == last.spelling {
          return idx
        }
      }
      if isSyllable(last.spelling), !hasAnyDigits, tailPart == last.spelling {
        return idx
      }
    }

    if let letter = leadingInitialLetter,
       let idx = spellings.firstIndex(of: letter) {
      return idx
    }
    if !hasAnyDigits, !tailPart.isEmpty {
      if let idx = spellings.firstIndex(of: tailPart) {
        return idx
      }
      if tailPart.count == 1,
         let idx = spellings.firstIndex(of: tailPart.uppercased()) {
        return idx
      }
    }
    return nil
  }

  /// 按一下「选拼音」时应当切换到的下一个候选拼音下标；末尾自动回绕到第一项。
  static func nextIndex(in spellings: [String], currentSelected: Int?) -> Int? {
    let cyclable = cyclableIndices(in: spellings)
    guard !cyclable.isEmpty else { return nil }
    if let current = currentSelected, let pos = cyclable.firstIndex(of: current) {
      return cyclable[(pos + 1) % cyclable.count]
    }
    return cyclable[0]
  }
}

/// 九键顶栏横向「选拼音」条（同时用于 iOS 原生九键组字态候选词上方常驻行，以及展开候选面板时的顶部选拼音行）。
///
/// 未限定拼音时所有项均不画底框容器，仅当用户实际选中或浏览某一项时才在该项上显示高亮胶囊容器；点按任意一项或「选拼音」键均可切换并原地刷新候选。
@MainActor
final class NineKeyStripSpellingBar: UIView {
  let scrollView = CandidateScrollView()
  var onSelect: ((Int) -> Void)?

  private let itemIdentifierPrefix: String
  private let showsSeparators: Bool
  private let stack = UIStackView()
  private let previewLabel = UILabel()
  private var buttons: [KeyboardKeyButton] = []
  private var separators: [UIView] = []
  private var appliedItems: [NineKeySpellingCyclePolicy.DisplayedItem] = []
  private(set) var appliedSelectedIndex: Int?

  init(
    accessibilityIdentifier: String = "nineKeyStripSpellingBar",
    itemIdentifierPrefix: String = "candidatePanelSpelling_",
    showsSeparators: Bool = false
  ) {
    self.itemIdentifierPrefix = itemIdentifierPrefix
    self.showsSeparators = showsSeparators
    super.init(frame: .zero)
    self.accessibilityIdentifier = accessibilityIdentifier
    backgroundColor = .clear
    clipsToBounds = showsSeparators
    setContentHuggingPriority(.init(1), for: .horizontal)
    setContentCompressionResistancePriority(.init(1), for: .horizontal)

    scrollView.showsHorizontalScrollIndicator = false
    scrollView.disableEdgeEffects()
    scrollView.backgroundColor = .clear
    if showsSeparators {
      scrollView.contentInset = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 6)
    }
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)

    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = showsSeparators ? 0 : 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(stack)

    previewLabel.isHidden = true
    previewLabel.font = .systemFont(ofSize: 14.5, weight: .medium)
    previewLabel.lineBreakMode = .byTruncatingHead
    previewLabel.isUserInteractionEnabled = false
    previewLabel.accessibilityIdentifier = "\(accessibilityIdentifier)_previewReading"
    previewLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(previewLabel)

    let stackHeight = stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
    stackHeight.priority = .init(998)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
      previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      stackHeight,
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 滑行拖动实时预览态：在常驻顶栏行里直接展示当前解出的实时拼音串（不拦截触摸），抬手后无缝切回可选拼音按钮。
  func showPreviewReading(
    _ reading: String,
    skin: KeyboardTheme,
    palette: CandidatePalette?
  ) {
    let usesDesktopPalette = palette.map { !$0.usesKeyboardStyle } ?? false
    previewLabel.text = reading
    previewLabel.textColor = usesDesktopPalette
      ? (palette?.preeditText ?? palette?.secondary ?? skin.secondary)
      : skin.keyForeground.withAlphaComponent(0.78)
    if previewLabel.isHidden { previewLabel.isHidden = false }
    if !scrollView.isHidden { scrollView.isHidden = true }
  }

  /// 退出滑行实时预览态：隐藏并清空拼音预览标签，恢复常规候选拼音滚动条。
  func clearPreviewReading() {
    previewLabel.text = nil
    if !previewLabel.isHidden { previewLabel.isHidden = true }
    if scrollView.isHidden { scrollView.isHidden = false }
  }

  /// 更新横向拼音按钮列表并同步当前皮肤/候选配色：仅 `selectedIndex` 显示胶囊容器，其余项仅展示文字；切换时自动滚动保证选中项可见。
  func update(
    items: [NineKeySpellingCyclePolicy.DisplayedItem],
    selectedIndex: Int? = nil,
    skin: KeyboardTheme,
    palette: CandidatePalette?,
    canvasLoaded: Bool
  ) {
    if !previewLabel.isHidden { previewLabel.isHidden = true }
    if scrollView.isHidden { scrollView.isHidden = false }
    let listChanged = appliedItems != items
    let validSelected = selectedIndex.flatMap { items.indices.contains($0) ? $0 : nil }
    let selectionChanged = appliedSelectedIndex != validSelected
    appliedItems = items
    appliedSelectedIndex = validSelected

    while buttons.count < items.count {
      if showsSeparators, !buttons.isEmpty {
        let separator = makeSeparatorView()
        separators.append(separator)
        stack.addArrangedSubview(separator)
      }
      let button = makeSpellingButton()
      buttons.append(button)
      stack.addArrangedSubview(button)
    }

    let fontSize: CGFloat = showsSeparators ? 15.5 : 16
    let regularFont = UIFont.systemFont(ofSize: fontSize, weight: .regular)
    let selectedFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
    let insets = showsSeparators
      ? NSDirectionalEdgeInsets(top: 2, leading: 13, bottom: 2, trailing: 13)
      : NSDirectionalEdgeInsets(top: 4, leading: 11, bottom: 4, trailing: 11)
    let usesDesktopPalette = palette.map { !$0.usesKeyboardStyle } ?? false
    let separatorColor: UIColor = usesDesktopPalette
      ? (palette?.border ?? skin.hairline)
      : skin.keyForeground.withAlphaComponent(0.20)

    UIView.performWithoutAnimation {
      for (index, button) in buttons.enumerated() {
        guard items.indices.contains(index) else {
          if !button.isHidden { button.isHidden = true }
          continue
        }
        let item = items[index]
        let isSelected = index == validSelected
        if button.isHidden { button.isHidden = false }
        var config = button.configuration ?? UIButton.Configuration.plain()
        config.title = item.title
        config.titleLineBreakMode = .byClipping
        config.contentInsets = insets
        let font = isSelected ? selectedFont : regularFont
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
          var out = attributes
          out.font = font
          return out
        }
        config.background.customView = nil
        if isSelected {
          if usesDesktopPalette, let palette {
            config.background.backgroundColor = palette.selected
            config.background.cornerRadius = palette.layout?.itemRadius ?? 9
            config.background.strokeWidth = palette.layout?.borderWidth ?? 1
            config.background.strokeColor = palette.border
            config.baseForegroundColor = palette.selectedText ?? palette.accent
          } else {
            config.background.backgroundColor = skin.keyBackground
            config.background.cornerRadius = showsSeparators ? (skin.isNative ? 11 : 8) : (skin.isNative ? 14 : 9)
            config.background.strokeWidth = skin.isNative ? 0.5 : 0
            config.background.strokeColor = skin.isNative ? skin.calloutBorder : nil
            config.baseForegroundColor = skin.keyForeground
          }
        } else {
          config.background.backgroundColor = .clear
          config.background.cornerRadius = 0
          config.background.strokeWidth = 0
          config.background.strokeColor = nil
          config.baseForegroundColor = usesDesktopPalette ? (palette?.text ?? skin.keyForeground) : skin.keyForeground
        }
        button.configuration = config
        button.isSelected = isSelected
        button.layer.shadowOpacity = 0
        button.tag = item.engineIndex
        button.accessibilityLabel = KeyboardNineKeyPanelColumns.spellingAccessibilityLabel(item.raw)
        button.accessibilityIdentifier = "\(itemIdentifierPrefix)\(item.title)"
        button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
      }
      if showsSeparators {
        for (sepIndex, separator) in separators.enumerated() {
          let visible = sepIndex + 1 < items.count
          if separator.isHidden == visible { separator.isHidden = !visible }
          if visible {
            separator.backgroundColor = separatorColor
            let adjacentToSelected = validSelected.map { $0 == sepIndex || $0 == sepIndex + 1 } ?? false
            separator.alpha = adjacentToSelected ? 0 : 1
          }
        }
      }
      stack.layoutIfNeeded()
      scrollView.layoutIfNeeded()
    }

    if listChanged, scrollView.contentOffset != .zero {
      scrollView.setContentOffset(.zero, animated: false)
    }
    if (listChanged || selectionChanged),
       let validSelected,
       buttons.indices.contains(validSelected),
       !buttons[validSelected].isHidden,
       scrollView.bounds.width > 0,
       scrollView.contentSize.width > scrollView.bounds.width {
      let targetRect = buttons[validSelected].convert(buttons[validSelected].bounds, to: scrollView)
        .insetBy(dx: -8, dy: 0)
      scrollView.scrollRectToVisible(targetRect, animated: !listChanged)
    }
  }

  private func makeSeparatorView() -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    view.translatesAutoresizingMaskIntoConstraints = false
    let width = view.widthAnchor.constraint(equalToConstant: 1.0 / max(UIScreen.main.scale, 2.0))
    let height = view.heightAnchor.constraint(equalToConstant: 15)
    height.priority = .defaultHigh
    NSLayoutConstraint.activate([width, height])
    return view
  }

  private func makeSpellingButton() -> KeyboardKeyButton {
    let button = KeyboardKeyButton(
      configuration: .plain(),
      primaryAction: UIAction { [weak self] action in
        guard let self, let sender = action.sender as? UIButton else { return }
        self.onSelect?(sender.tag)
      })
    button.animatesPressFeedback = false
    button.pressFeedback = .opacity(0.6)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    let minWidth = button.widthAnchor.constraint(greaterThanOrEqualToConstant: showsSeparators ? 38 : 36)
    minWidth.priority = .init(999)
    let minHeight = button.heightAnchor.constraint(greaterThanOrEqualToConstant: showsSeparators ? 26 : 32)
    minHeight.priority = showsSeparators ? .defaultHigh : .init(999)
    NSLayoutConstraint.activate([minWidth, minHeight])
    return button
  }
}
