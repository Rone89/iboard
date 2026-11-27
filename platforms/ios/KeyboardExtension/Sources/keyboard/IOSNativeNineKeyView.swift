import UIKit

/// 1:1 复刻 iOS 27 原生「简体中文 · 拼音（十键）」的独立键盘视图（`TouchNineKeyStyle.iosNative`）。
///
/// 实测基准（iPhone 18 Pro Max 440×956 pt @3x 原生 Spotlight 截图逐像素拟合）：
/// - 左右外边距 7.5 pt（小屏 < 390 pt 收为 6.5 pt）、5 等宽列 × 4 等高行、列间距 6 pt、行间距 7 pt、单行键高 49 pt（四行键区 217 pt）、连续曲率圆角 10 pt；
/// - 网格 2–9 字母采用 15.5 pt Regular + UIKit 宽字距（3 字母键 kern 2.2、`PQRS` 2.0、`WXYZ` 1.5），1 键 `,。?!` 按字符逐位修正全角句号右侧留白使其等距呈现，左列 `123` / `#@¥` / `ABC` 采用 15.5 pt Regular，中文标签（`选拼音` / `分词` / `重输` kern 2.0、`空格` kern 2.2、回车）采用 16 pt Regular；
/// - 左列：`123`（1 行）、`#@¥`（1 行）、`ABC`（跨第 3–4 行）；
/// - 中间 3 列：3×3 九宫格（1 键空态 `，。？！`、组字中 `分词`；2–9 居中字母、无右上角数字角标，保留长按与上滑数字），底行 `选拼音`（1 列）+ `空格`（2 列）；
/// - 右列：`⌫`（1 行）、双层堆叠 `^^/_` 颜文字矢量图（空态表情/颜文字，组字中切为 `重输`）、`↵` 回车（跨第 3–4 行）；
/// - 浅色/深色模式下所有键面使用统一键底色（仅回车在组字确认或主动作态时着强调色），点按 `选拼音` 直接展开候选面板（顶栏展示横向选拼音，下方候选面板展示全部候选词）。
@MainActor
final class IOSNativeNineKeyView: UIView {
  /// 键帽统一连续曲率圆角（iOS 27 原生十键四键子像素拟合：9.75–10.25 pt → 10.0 pt）。
  static let nativeCornerRadius: CGFloat = 10.0
  /// 手机竖屏单行基准键高（实测原生 48.7–49.2 pt → 49.0 pt）。
  static let nativeRowHeight: CGFloat = 49.0
  /// 原生默认行距与列距（实测 7.0 pt / 6.0 pt）。
  static let nativeRowSpacing: CGFloat = 7.0
  static let nativeColumnSpacing: CGFloat = 6.0
  /// 原生手机竖屏左右外边距（大屏实测 7.5 pt，小屏 < 390 pt 收紧至 6.5 pt）。
  static func nativeHorizontalMargin(largeScreen: Bool) -> CGFloat {
    largeScreen ? 7.5 : 6.5
  }
  /// 原生双层堆叠颜文字键图标（上 `^^` 下 `_`，实测 16.7 × 13.9 pt，模板渲染自动跟随明暗与皮肤前景色）。
  static let kaomojiIcon: UIImage = {
    let size = CGSize(width: 18, height: 15)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { _ in
      UIColor.black.setStroke()
      let strokeWidth: CGFloat = 1.65

      let leftCaret = UIBezierPath()
      leftCaret.move(to: CGPoint(x: 1.6, y: 7.7))
      leftCaret.addLine(to: CGPoint(x: 4.7, y: 1.8))
      leftCaret.addLine(to: CGPoint(x: 7.8, y: 7.7))
      leftCaret.lineWidth = strokeWidth
      leftCaret.lineCapStyle = .round
      leftCaret.lineJoinStyle = .round
      leftCaret.stroke()

      let rightCaret = UIBezierPath()
      rightCaret.move(to: CGPoint(x: 10.2, y: 7.7))
      rightCaret.addLine(to: CGPoint(x: 13.3, y: 1.8))
      rightCaret.addLine(to: CGPoint(x: 16.4, y: 7.7))
      rightCaret.lineWidth = strokeWidth
      rightCaret.lineCapStyle = .round
      rightCaret.lineJoinStyle = .round
      rightCaret.stroke()

      let bar = UIBezierPath()
      bar.move(to: CGPoint(x: 4.5, y: 13.1))
      bar.addLine(to: CGPoint(x: 13.5, y: 13.1))
      bar.lineWidth = strokeWidth
      bar.lineCapStyle = .round
      bar.stroke()
    }
    return image.withRenderingMode(.alwaysTemplate)
  }()
  /// 2–9 字母标签表，与原生键面一致。
  static let lettersByDigit: [Int: String] = [
    2: "ABC", 3: "DEF", 4: "GHI", 5: "JKL", 6: "MNO", 7: "PQRS", 8: "TUV", 9: "WXYZ",
  ]

  struct Callbacks {
    var makeKey: (_ title: String, _ accessibilityLabel: String, _ action: @escaping () -> Void) -> UIButton
    var makeDeleteKey: () -> UIButton
    var makeSpaceKey: () -> UIButton
    var makeGlobeKey: () -> UIButton
    var configureDigitKey: (_ button: UIButton, _ digit: Int, _ letters: String?) -> Void
    var onDigitTap: (_ digit: Int) -> Void
    var onPunctuationOrSeparatorTap: () -> Void
    var onToggleNumbers: () -> Void
    var onShowSymbols: () -> Void
    var onToggleLanguage: () -> Void
    var onKaomojiOrClear: () -> Void
    var onReturn: () -> Void
    var onOpenSpellingPanel: () -> Void
  }

  /// 供 `KeyboardViewController.returnKeys` 统一同步动态标题与强调色。
  let returnButton: UIButton
  /// 供 `KeyboardViewController` 统一同步空格标题或手势。
  let spaceButton: UIButton
  /// 供 `KeyboardViewController` 在需要地球键的设备上显示/隐藏。
  let globeButton: UIButton
  /// 供长按与上滑逻辑访问 1–9 九格按键。
  private(set) var digitButtons: [Int: UIButton] = [:]

  private let outerStack = UIStackView()
  private let leftContainer = UIView()
  private let leftStack = UIStackView()
  private let centerStack = UIStackView()
  private let rightStack = UIStackView()
  private var centerRows: [UIStackView] = []
  private var centerWidthConstraint: NSLayoutConstraint?

  private let numbersButton: UIButton
  private let symbolsButton: UIButton
  private let abcButton: UIButton
  private let key1Button: UIButton
  private let spellingToggleButton: UIButton
  private let deleteButton: UIButton
  private let kaomojiOrClearButton: UIButton
  private var allNativeKeys: [UIButton] = []

  private let onOpenSpellingPanel: () -> Void
  private var isComposing = false
  private var currentSpellings: [String] = []
  private var currentColSpacing: CGFloat = 6
  private var currentRowSpacing: CGFloat = 7

  init(callbacks: Callbacks) {
    self.onOpenSpellingPanel = callbacks.onOpenSpellingPanel

    let makeNativeKey: (String, String, @escaping () -> Void) -> UIButton = { title, label, action in
      let button = callbacks.makeKey(title, label, action)
      button.configuration?.contentInsets = .zero
      button.titleLabel?.adjustsFontSizeToFitWidth = true
      button.titleLabel?.minimumScaleFactor = 0.65
      (button as? KeyboardKeyButton)?.isFunctionKey = false
      (button as? KeyboardKeyButton)?.animatesPressFeedback = false
      return button
    }

    numbersButton = makeNativeKey("123", "切换到数字键盘", callbacks.onToggleNumbers)
    numbersButton.accessibilityIdentifier = "iosNativeNineKeyNumbers"

    symbolsButton = makeNativeKey("#@¥", "符号面板", callbacks.onShowSymbols)
    symbolsButton.accessibilityIdentifier = "iosNativeNineKeySymbols"

    abcButton = makeNativeKey("ABC", "切换中英文", callbacks.onToggleLanguage)
    abcButton.accessibilityIdentifier = "iosNativeNineKeyABC"

    key1Button = makeNativeKey(",。?!", "常用标点", callbacks.onPunctuationOrSeparatorTap)
    key1Button.tag = 1
    key1Button.accessibilityIdentifier = "iosNativeNineKey1"

    spellingToggleButton = makeNativeKey("选拼音", "选择拼音", {})
    spellingToggleButton.accessibilityIdentifier = "iosNativeNineKeySpelling"

    spaceButton = callbacks.makeSpaceKey()
    spaceButton.configuration?.title = "空格"
    spaceButton.configuration?.contentInsets = .zero
    spaceButton.accessibilityIdentifier = "iosNativeNineKeySpace"
    (spaceButton as? KeyboardKeyButton)?.isFunctionKey = false
    (spaceButton as? KeyboardKeyButton)?.animatesPressFeedback = false

    globeButton = callbacks.makeGlobeKey()
    globeButton.accessibilityIdentifier = "iosNativeNineKeyGlobe"
    (globeButton as? KeyboardKeyButton)?.isFunctionKey = false
    globeButton.isHidden = true

    deleteButton = callbacks.makeDeleteKey()
    deleteButton.accessibilityIdentifier = "iosNativeNineKeyDelete"
    (deleteButton as? KeyboardKeyButton)?.isFunctionKey = false

    kaomojiOrClearButton = makeNativeKey("", "颜文字与表情", callbacks.onKaomojiOrClear)
    kaomojiOrClearButton.configuration?.title = nil
    kaomojiOrClearButton.configuration?.image = Self.kaomojiIcon
    kaomojiOrClearButton.accessibilityIdentifier = "iosNativeNineKeyMiddle"

    returnButton = makeNativeKey("换行", "换行", callbacks.onReturn)
    returnButton.accessibilityIdentifier = "iosNativeNineKeyReturn"
    (returnButton as? KeyboardKeyButton)?.pressSoundClass = .enter

    super.init(frame: .zero)
    accessibilityIdentifier = "iosNativeNineKeyView"

    spellingToggleButton.addAction(UIAction { [weak self] _ in
      self?.onOpenSpellingPanel()
    }, for: .primaryActionTriggered)

    setupLayout(callbacks: callbacks)
    applyTypography()
    applyTheme(KeyboardTheme.current)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func setupLayout(callbacks: Callbacks) {
    outerStack.axis = .horizontal
    outerStack.spacing = currentColSpacing
    outerStack.alignment = .fill
    outerStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(outerStack)
    NSLayoutConstraint.activate([
      outerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      outerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      outerStack.topAnchor.constraint(equalTo: topAnchor),
      outerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    // 左列：123 / #@¥ / 双高 ABC。
    leftStack.axis = .vertical
    leftStack.spacing = currentRowSpacing
    leftStack.translatesAutoresizingMaskIntoConstraints = false
    leftStack.addArrangedSubview(numbersButton)
    leftStack.addArrangedSubview(symbolsButton)
    leftStack.addArrangedSubview(abcButton)
    leftContainer.addSubview(leftStack)
    NSLayoutConstraint.activate([
      leftStack.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
      leftStack.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor),
      leftStack.topAnchor.constraint(equalTo: leftContainer.topAnchor),
      leftStack.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor),
    ])
    outerStack.addArrangedSubview(leftContainer)

    // 中间 3 列：4 等高行（前 3 行为 3×3 九宫格，第 4 行为 选拼音 + [🌐] + 空格）。
    centerStack.axis = .vertical
    centerStack.spacing = currentRowSpacing
    centerStack.distribution = .fillEqually
    digitButtons[1] = key1Button
    callbacks.configureDigitKey(key1Button, 1, nil)

    var allKeys: [UIButton] = [
      numbersButton, symbolsButton, abcButton,
      key1Button, spellingToggleButton, globeButton, spaceButton,
      deleteButton, kaomojiOrClearButton, returnButton,
    ]

    for rowIndex in 0..<3 {
      let row = UIStackView()
      row.axis = .horizontal
      row.spacing = currentColSpacing
      row.distribution = .fillEqually
      for colIndex in 0..<3 {
        let digit = rowIndex * 3 + colIndex + 1
        if digit == 1 {
          row.addArrangedSubview(key1Button)
          continue
        }
        let letters = Self.lettersByDigit[digit] ?? ""
        let button = callbacks.makeKey(letters, "\(digit) \(letters)") {
          callbacks.onDigitTap(digit)
        }
        button.tag = digit
        button.configuration?.contentInsets = .zero
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
        button.accessibilityIdentifier = "iosNativeNineKey\(digit)"
        (button as? KeyboardKeyButton)?.isFunctionKey = false
        (button as? KeyboardKeyButton)?.animatesPressFeedback = false
        callbacks.configureDigitKey(button, digit, letters)
        digitButtons[digit] = button
        allKeys.append(button)
        row.addArrangedSubview(button)
      }
      centerRows.append(row)
      centerStack.addArrangedSubview(row)
    }

    let bottomMiddleRow = UIStackView()
    bottomMiddleRow.axis = .horizontal
    bottomMiddleRow.spacing = currentColSpacing
    bottomMiddleRow.addArrangedSubview(spellingToggleButton)
    bottomMiddleRow.addArrangedSubview(globeButton)
    bottomMiddleRow.addArrangedSubview(spaceButton)
    centerRows.append(bottomMiddleRow)
    centerStack.addArrangedSubview(bottomMiddleRow)
    outerStack.addArrangedSubview(centerStack)

    // 右列：⌫ / ^_^（或重输） / 双高回车。
    rightStack.axis = .vertical
    rightStack.spacing = currentRowSpacing
    rightStack.addArrangedSubview(deleteButton)
    rightStack.addArrangedSubview(kaomojiOrClearButton)
    rightStack.addArrangedSubview(returnButton)
    outerStack.addArrangedSubview(rightStack)

    allNativeKeys = allKeys

    // 精确 5 等宽列约束：left == right，center == 3 * left + 2 * colSpacing。
    let centerWidth = centerStack.widthAnchor.constraint(
      equalTo: leftContainer.widthAnchor, multiplier: 3, constant: currentColSpacing * 2)
    centerWidthConstraint = centerWidth

    // 选拼音与第 1 格完全等宽（1/5 整宽）；空格占剩余 2 列宽度；有地球键时地球键取 0.65 列宽。
    let globeWidth = globeButton.widthAnchor.constraint(equalTo: key1Button.widthAnchor, multiplier: 0.65)
    globeWidth.priority = .init(999)

    // 左右列的第 1、2 行与中间第 1、2 行严格等高，第 3 个键自动填满第 3–4 行（2×行高 + 行距）。
    NSLayoutConstraint.activate([
      rightStack.widthAnchor.constraint(equalTo: leftContainer.widthAnchor),
      centerWidth,
      spellingToggleButton.widthAnchor.constraint(equalTo: key1Button.widthAnchor),
      globeWidth,
      numbersButton.heightAnchor.constraint(equalTo: centerRows[0].heightAnchor),
      symbolsButton.heightAnchor.constraint(equalTo: centerRows[1].heightAnchor),
      deleteButton.heightAnchor.constraint(equalTo: centerRows[0].heightAnchor),
      kaomojiOrClearButton.heightAnchor.constraint(equalTo: centerRows[1].heightAnchor),
    ])
  }

  /// 原生九键字距参数（基于 iOS 27 iPhone 18 Pro Max 官方截图逐像素拟合，使用 UIKit `NSAttributedString.Key.kern`）。
  static let threeLetterKern: CGFloat = 2.2
  static let pqrsKern: CGFloat = 2.0
  static let wxyzKern: CGFloat = 1.5
  static let chineseLabelKern: CGFloat = 2.0
  static let spaceLabelKern: CGFloat = 2.2
  /// 1 键 `,。?!` 逐字符字距：补偿全角 `。` 自带的约 10.7 pt 右侧空隙，使四枚标点视觉间隔齐平（约 3.8 / 3.8 / 4.3 pt）。
  static let punctuationPerCharKerns: [CGFloat] = [1.1, -6.9, 2.3, 0.0]

  /// 构造仅作用于前 `n - 1` 个字符的 UIKit 富文本标题：
  /// 避免末字符追加多余尾部字距导致标签在键帽内左偏，同时不写入前景色以自动跟随 `baseForegroundColor`。
  private static func attributedTitle(_ text: String, font: UIFont, kern: CGFloat = 0) -> AttributedString {
    let mutable = NSMutableAttributedString(string: text, attributes: [.font: font])
    let length = (text as NSString).length
    if abs(kern) > 0.001, length > 1 {
      mutable.addAttribute(.kern, value: kern, range: NSRange(location: 0, length: length - 1))
    }
    return AttributedString(mutable)
  }

  /// 按字符数组分别设置 UIKit `kern`，供 `,。?!` 等含全角标点的键面精确对齐视觉间距。
  private static func attributedTitle(_ text: String, font: UIFont, perCharKerns: [CGFloat]) -> AttributedString {
    let mutable = NSMutableAttributedString(string: text, attributes: [.font: font])
    var utf16Offset = 0
    for (index, character) in text.enumerated() {
      let charLen = String(character).utf16.count
      if index < perCharKerns.count, abs(perCharKerns[index]) > 0.001 {
        mutable.addAttribute(.kern, value: perCharKerns[index], range: NSRange(location: utf16Offset, length: charLen))
      }
      utf16Offset += charLen
    }
    return AttributedString(mutable)
  }

  private func keyFont(size: CGFloat) -> UIFont {
    KeyboardTheme.current.usesMonospacedFont
      ? .monospacedSystemFont(ofSize: size, weight: .regular)
      : .systemFont(ofSize: size, weight: .regular)
  }

  private func applyKey1Title(composing: Bool) {
    if composing {
      key1Button.configuration?.attributedTitle = Self.attributedTitle("分词", font: keyFont(size: 16), kern: Self.chineseLabelKern)
      key1Button.accessibilityLabel = "拼音分词"
    } else {
      key1Button.configuration?.attributedTitle = Self.attributedTitle(",。?!", font: keyFont(size: 15.5), perCharKerns: Self.punctuationPerCharKerns)
      key1Button.accessibilityLabel = "常用标点"
    }
  }

  private func applyTypography() {
    let asciiFont = keyFont(size: 15.5)
    let chineseFont = keyFont(size: 16)

    for digit in 2...9 {
      guard let button = digitButtons[digit], let letters = Self.lettersByDigit[digit] else { continue }
      let kern: CGFloat
      switch digit {
      case 7: kern = Self.pqrsKern
      case 9: kern = Self.wxyzKern
      default: kern = Self.threeLetterKern
      }
      button.configuration?.titleTextAttributesTransformer = nil
      button.configuration?.attributedTitle = Self.attributedTitle(letters, font: asciiFont, kern: kern)
    }

    for (button, title) in [(numbersButton, "123"), (symbolsButton, "#@¥"), (abcButton, "ABC")] {
      button.configuration?.titleTextAttributesTransformer = nil
      button.configuration?.attributedTitle = Self.attributedTitle(title, font: asciiFont)
    }
    key1Button.configuration?.titleTextAttributesTransformer = nil
    applyKey1Title(composing: isComposing)

    spellingToggleButton.configuration?.titleTextAttributesTransformer = nil
    spellingToggleButton.configuration?.attributedTitle = Self.attributedTitle("选拼音", font: chineseFont, kern: Self.chineseLabelKern)

    spaceButton.configuration?.titleTextAttributesTransformer = nil
    spaceButton.configuration?.attributedTitle = Self.attributedTitle("空格", font: chineseFont, kern: Self.spaceLabelKern)

    kaomojiOrClearButton.configuration?.titleTextAttributesTransformer = nil
    if isComposing {
      kaomojiOrClearButton.configuration?.attributedTitle = Self.attributedTitle("重输", font: chineseFont, kern: Self.chineseLabelKern)
    }

    // 回车键标题由外部 `updateReturnKey()` 按输入框类型动态刷新，通过 UIKit 作用域的 `out.uiKit.kern` 保持字体与字距。
    let returnLabelTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var out = attributes
      out.uiKit.font = chineseFont
      return out
    }
    returnButton.configuration?.titleTextAttributesTransformer = returnLabelTransformer
  }

  /// 同步列距与行距（默认 6 pt / 7 pt，与实测原生完全一致）。
  func applySpacing(row: CGFloat, key: CGFloat) {
    currentRowSpacing = row
    currentColSpacing = key
    outerStack.spacing = key
    leftStack.spacing = row
    centerStack.spacing = row
    rightStack.spacing = row
    centerRows.forEach { $0.spacing = key }
    centerWidthConstraint?.constant = key * 2
  }

  /// 同步地球键显示状态（Face ID 设备隐藏，与原生一致）。
  func setGlobeShown(_ shown: Bool) {
    if globeButton.isHidden == shown { globeButton.isHidden = !shown }
  }

  /// 随输入组字状态与九键拼音选项更新键面（空态 / 组字中）。
  func updateState(composing: Bool, spellings: [String]) {
    isComposing = composing
    currentSpellings = spellings

    let key1Title = composing ? "分词" : ",。?!"
    if key1Button.configuration?.title != key1Title {
      applyKey1Title(composing: composing)
    }

    if composing {
      if kaomojiOrClearButton.configuration?.title != "重输" || kaomojiOrClearButton.configuration?.image != nil {
        kaomojiOrClearButton.configuration?.image = nil
        kaomojiOrClearButton.configuration?.attributedTitle = Self.attributedTitle("重输", font: keyFont(size: 16), kern: Self.chineseLabelKern)
        kaomojiOrClearButton.accessibilityLabel = "清空重新输入"
      }
    } else {
      if kaomojiOrClearButton.configuration?.title != nil || kaomojiOrClearButton.configuration?.image == nil {
        kaomojiOrClearButton.configuration?.attributedTitle = nil
        kaomojiOrClearButton.configuration?.title = nil
        kaomojiOrClearButton.configuration?.image = Self.kaomojiIcon
        kaomojiOrClearButton.accessibilityLabel = "颜文字与表情"
      }
    }

    // 与系统原生十键一致：空态时「选拼音」保持全不透明实体键帽与亮字；组字时展开选拼音面板，点击 1 键常用标点时循环切换候选符号。
    spellingToggleButton.isEnabled = true
    spellingToggleButton.alpha = 1.0
  }

  /// 应用皮肤与实测原生视觉：10 pt 连续圆角、全键统一键底色（回车色由外层 `styleReturnKey` 统一接管）。
  func applyTheme(_ skin: KeyboardTheme) {
    applyTypography()
    let radius = skin.design == nil ? Self.nativeCornerRadius : skin.cornerRadius
    for button in allNativeKeys {
      button.layer.cornerCurve = .continuous
      guard var config = button.configuration else { continue }
      config.cornerStyle = .fixed
      config.background.cornerRadius = radius
      if button !== returnButton {
        config.background.backgroundColor = skin.keyBackground
        config.baseForegroundColor = skin.keyForeground
      }
      button.configuration = config
    }
  }
}
