import UIKit

/// 26 键字母键的长按变体，复刻原生键盘的长按弹出：拼音 26 键给元音的声调字母，英文 26 键给带变音符号的字母。
/// 变体表只有这两套：双拼、注音、韩文、粤拼这些方案的字母键各有自己的编码语义，字面变体会打错字，
/// 所以不弹；这些方案长按照旧直出角标（`LetterHintTable`）。选中的变体与角标同一条路字面上屏
/// （`insertSymbolLayerLiteral`）：先结束组字再写出，引擎组字只收 ASCII，声调字母进不了组合缓冲。
enum KeyboardLetterVariants {
  /// 变体表按输入语境二选一。
  enum Alphabet: Equatable {
    /// 拼音 26 键：元音的声调字母与 ü。
    case pinyin
    /// 英文 26 键：常用的带变音符号字母。
    case english
  }

  /// 拼音的声调字母。四声各一枚，u 键附 ü 系四声，v 键本身是 ü 的编码键所以把 ü 放在最前，
  /// n 附上声和去声；声母没有声调变体，不在表里的键长按照旧输入角标。
  private static let pinyinVariants: [Character: [String]] = [
    "a": ["ā", "á", "ǎ", "à"],
    "o": ["ō", "ó", "ǒ", "ò"],
    "e": ["ē", "é", "ě", "è"],
    "i": ["ī", "í", "ǐ", "ì"],
    "u": ["ū", "ú", "ǔ", "ù", "ǖ", "ǘ", "ǚ", "ǜ"],
    "v": ["ü", "ǖ", "ǘ", "ǚ", "ǜ"],
    "n": ["ň", "ǹ"],
  ]

  /// 英文常用变音字母，大致按使用频率排。
  private static let englishVariants: [Character: [String]] = [
    "a": ["á", "à", "â", "ä", "ã", "å", "æ", "ā"],
    "e": ["é", "è", "ê", "ë", "ē", "ę"],
    "i": ["í", "ì", "î", "ï", "ī"],
    "o": ["ó", "ò", "ô", "ö", "õ", "ø", "ō"],
    "u": ["ú", "ù", "û", "ü", "ū"],
    "n": ["ñ", "ń"],
    "c": ["ç", "ć", "č"],
    "s": ["ś", "š"],
    "y": ["ý", "ÿ"],
    "z": ["ž", "ź", "ż"],
    "d": ["đ"],
    "l": ["ł"],
    "t": ["ť"],
    "g": ["ğ"],
  ]

  /// 这个字母在所选语境下有哪些长按变体；不在表里时为 nil，长按照旧输入角标。
  static func variants(for letter: String, alphabet: Alphabet) -> [String]? {
    guard letter.count == 1, let character = letter.first, character.isASCII, character.isLetter else { return nil }
    let table = alphabet == .pinyin ? pinyinVariants : englishVariants
    return table[Character(character.lowercased())]
  }

  /// 长按变体只属于手机布局上的拼音 26 键和英文 26 键：iPad 的原生键盘不弹长按变体（与 `KeyPressPreviewView`
  /// 只在手机上画一致）；14/18 键字母网格、九键、本地模式、双拼和其他方案的字母键另有语义。纯函数，键面更新与测试共用。
  static func alphabet(chinese: Bool, scheme: ChineseInputScheme, letterGridShown: Bool,
                       localMode: Bool, phoneIdiom: Bool) -> Alphabet? {
    guard phoneIdiom, !localMode, !letterGridShown else { return nil }
    if !chinese { return .english }
    return scheme == .quanpin ? .pinyin : nil
  }
}

/// 长按变体条：按键上方、放大气泡之上的一行变体字符，与 `KeyPressPreviewView` 同一套圆角、阴影和配色。
/// 手指在条上滑动时高亮所在项并把气泡换成它，松手由 `KeyboardKeyButton` 把选中的变体交给控制器。
final class KeyboardHoldVariantBar: UIView {
  private let shape = CAShapeLayer()
  private let highlightLayer = CAShapeLayer()
  private var labels: [UILabel] = []
  private var cellFrames: [CGRect] = []
  private var barFill: UIColor = .secondarySystemBackground
  private var restingText: UIColor = .label
  private var invertedText: UIColor = .white
  private(set) var selected: Int?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    accessibilityElementsHidden = true
    // 与 KeyPressPreviewView 相同的阴影和描边。
    shape.shadowColor = UIColor.black.cgColor
    shape.shadowOpacity = 0.22
    shape.shadowRadius = 9
    shape.shadowOffset = CGSize(width: 0, height: 6)
    shape.strokeColor = UIColor.black.withAlphaComponent(0.08).cgColor
    shape.lineWidth = 0.5
    layer.addSublayer(shape)
    highlightLayer.cornerRadius = 7
    highlightLayer.isHidden = true
    layer.addSublayer(highlightLayer)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 条的几何：每个变体一格，格宽与气泡同宽系数，整条与按键居中并压进宿主边界，下边缘隔 `gap` 顶着气泡。
  /// `bubbleTop` 是气泡的上边缘。顶行按键上方放不下整条高度时条被压矮：高度止于边界顶。
  static func geometry(variantCount: Int, keyFrame: CGRect, bubbleTop: CGFloat, in bounds: CGRect) -> CGRect {
    guard variantCount > 0 else { return .zero }
    var cellWidth = keyFrame.width * KeyPressPreviewView.widthFactor
    var width = cellWidth * CGFloat(variantCount)
    let maxWidth = bounds.width - 8
    if width > maxWidth {
      width = maxWidth
      cellWidth = width / CGFloat(variantCount)
    }
    let height = KeyPressPreviewView.height
    let gap: CGFloat = 4
    var x = min(max(keyFrame.midX - width / 2, bounds.minX + 4), bounds.maxX - width - 4)
    if x < bounds.minX { x = bounds.minX }
    let y = max(bubbleTop - gap - height, bounds.minY + 2)
    let visible = min(height, bubbleTop - gap - y)
    guard visible > 12 else { return .zero }
    return CGRect(x: x, y: y, width: width, height: visible)
  }

  /// 摆出这一条变体：`keyFrame` 是按键在宿主坐标系里的静止位置。
  func show(_ variants: [String], keyFrame: CGRect, in bounds: CGRect, fill: UIColor, text: UIColor) {
    barFill = fill
    restingText = text
    invertedText = fill
    let bubble = KeyPressPreviewView.geometry(key: keyFrame, in: bounds)
    let frame = Self.geometry(variantCount: variants.count, keyFrame: keyFrame,
                              bubbleTop: bubble.head.minY, in: bounds)
    self.frame = frame
    selected = nil
    highlightLayer.isHidden = true
    labels.forEach { $0.removeFromSuperview() }
    labels = []
    cellFrames = []
    guard frame.width > 0 else { return }
    let cellWidth = frame.width / CGFloat(variants.count)
    for variant in variants {
      let label = UILabel()
      label.textAlignment = .center
      label.adjustsFontSizeToFitWidth = true
      label.minimumScaleFactor = 0.5
      label.font = .systemFont(ofSize: 22, weight: .regular)
      label.textColor = restingText
      label.text = variant
      addSubview(label)
      labels.append(label)
    }
    // 重画条形和格子，并按格子数排开标签。
    layoutCells(cellWidth: cellWidth)
  }

  private func layoutCells(cellWidth: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shape.frame = bounds
    let path = KeyPressPreviewView.path(bounds)
    shape.path = path
    shape.shadowPath = path
    shape.fillColor = barFill.cgColor
    // 选中的格子反色：底用字的颜色，字用条的底色。
    highlightLayer.backgroundColor = restingText.cgColor
    CATransaction.commit()
    cellFrames = labels.indices.map { index in
      CGRect(x: CGFloat(index) * cellWidth, y: 0, width: cellWidth, height: bounds.height)
    }
    for (index, label) in labels.enumerated() {
      label.frame = cellFrames[index].insetBy(dx: 2, dy: 3)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard !labels.isEmpty else { return }
    layoutCells(cellWidth: bounds.width / CGFloat(labels.count))
  }

  /// 手指在条自身坐标里的位置对应的变体下标；不在条上（含上下各 6pt 的容差带）时为 nil。窗口坐标由调用方转换。
  func selectedIndex(inLocalPoint point: CGPoint) -> Int? {
    for (index, cell) in cellFrames.enumerated() where cell.insetBy(dx: 0, dy: -6).contains(point) {
      return index
    }
    return nil
  }

  /// 高亮第 `index` 项并把它的字换成反色；nil 清掉高亮。
  func set(selected index: Int?) {
    guard index != selected else { return }
    selected = index
    for (position, label) in labels.enumerated() {
      label.textColor = position == index ? invertedText : restingText
    }
    guard let index, cellFrames.indices.contains(index) else {
      highlightLayer.isHidden = true
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    highlightLayer.frame = bounds
    let rect = cellFrames[index].insetBy(dx: 4, dy: 5)
    highlightLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 7).cgPath
    highlightLayer.isHidden = false
    CATransaction.commit()
  }
}
