import UIKit

/// The physical keyboard the extension is drawing: a phone keyboard or a full-width tablet one.
///
/// It is decided from the traits the host hands the extension rather than from the device model, because an iPad does not always get the tablet keyboard: the floating keyboard and narrow Slide Over / Stage Manager windows report a compact width, and the system keyboard draws its phone layout there too. Following the same rule keeps this keyboard the same size as the one it replaces.
enum KeyboardFormFactor: Equatable {
  case phone
  case tablet

  /// 26 键手机竖屏已取消额外上下补偿留白，直接按 45pt 键帽排满以对齐 iOS 27 原生键盘高度。
  static let phoneLetterVerticalPadding: CGFloat = 0

  /// 26 键手机竖屏有 `rows` 排键时上下额外补偿空间，目前固定为 `0`。
  static func phoneLetterVerticalPadding(rows: Int) -> CGFloat {
    0
  }

  /// 手机 26 键第一排（10 键）单颗字母键宽度与水平节距：直接复用共享 `KeyboardGeometry` 计算。
  static func phoneLetterKeyMetrics(keysWidth: CGFloat, keySpacing: CGFloat) -> (keyWidth: CGFloat, pitch: CGFloat) {
    KeyboardGeometry.phoneLetterKeyMetrics(keysWidth: keysWidth, keySpacing: keySpacing)
  }

  /// 手机 26 键第二排（A–L）左右内边距：直接复用共享 `KeyboardGeometry` 计算。
  static func phoneMiddleRowHorizontalInset(keysWidth: CGFloat, keySpacing: CGFloat) -> CGFloat {
    KeyboardGeometry.phoneMiddleRowHorizontalInset(keysWidth: keysWidth, keySpacing: keySpacing)
  }

  /// 手机 26 键第三排（⇧ Z–M ⌫）左右功能键宽度与间距：直接复用共享 `KeyboardGeometry` 计算。
  static func phoneThirdRowEdgeLayout(keysWidth: CGFloat, keySpacing: CGFloat) -> (width: CGFloat, gap: CGFloat) {
    KeyboardGeometry.phoneThirdRowEdgeLayout(keysWidth: keysWidth, keySpacing: keySpacing)
  }

  static func resolve(
    idiom: UIUserInterfaceIdiom, horizontalSizeClass: UIUserInterfaceSizeClass
  ) -> KeyboardFormFactor {
    idiom == .pad && horizontalSizeClass != .compact ? .tablet : .phone
  }

  static func resolve(_ traits: UITraitCollection) -> KeyboardFormFactor {
    resolve(idiom: traits.userInterfaceIdiom, horizontalSizeClass: traits.horizontalSizeClass)
  }

  /// 是否属于同形态下的大屏设备（参考 KeyboardKit `KeyboardLayoutConfiguration` 分档）：
  /// - 手机：短边 >= 428pt 或长边 >= 926pt（Plus / Pro Max 系列）
  /// - 平板：短边 >= 1024pt 或长边 >= 1366pt（12.9" / 13" iPad Pro）
  static func isLargeScreen(idiom: UIUserInterfaceIdiom, screenSize: CGSize?) -> Bool {
    guard let screenSize, screenSize.width > 0, screenSize.height > 0 else { return false }
    let shortSide = min(screenSize.width, screenSize.height)
    let longSide = max(screenSize.width, screenSize.height)
    switch idiom {
    case .pad:
      return shortSide >= 1024 || longSide >= 1366
    case .phone:
      return shortSide >= 428 || longSide >= 926
    default:
      return false
    }
  }

  /// 键盘在顶部那一行和按键四周的内边距（dc.html `kbPad`）：
  /// - 手机上方 2、下方 4；两侧对齐 KeyboardKit（Liquid Glass）：标准竖屏 6pt，大屏竖屏与手机横屏 3pt。
  /// - iPad 保持 6 / 8 / 4。
  ///
  /// 手机的上边距原是设计稿的 6：顶栏为了打字时按键不跳，空闲时也按读音行加候选行的高度留着，再加上边距和下面的间隔，iPhone 上按键以上占了约 72pt，比四排按键的三分之一还多。上边距和间隔（`topRowGap`）是这一截里纯空白的部分，所以从这两处压。
  var padding: NSDirectionalEdgeInsets {
    padding()
  }

  /// 按当前屏幕方向和是否为大屏手机计算键盘内边距：手机上下保持 2pt / 4pt，使叠加系统 Liquid Glass 顶部圆角留白后总高与原生键盘一致；大屏竖屏与横屏把左右边距从 6pt 收紧到 3pt。
  func padding(landscape: Bool = false, largeScreen: Bool = false) -> NSDirectionalEdgeInsets {
    switch self {
    case .phone:
      let horizontal: CGFloat = (landscape || largeScreen) ? 3 : 6
      return NSDirectionalEdgeInsets(top: 2, leading: horizontal, bottom: 4, trailing: horizontal)
    case .tablet:
      return NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 4, trailing: 8)
    }
  }

  /// 顶部那一行与第一排按键之间的间隔（dc.html `kbGap`）：手机 4，iPad 9。手机原是设计稿的 11，理由见 `padding`。
  ///
  /// 设计稿的各排按键之间也用同样的间隔，这里则与 Android 一样保留用户的排间距（`touch_row_spacing_tenths`，取值 4-10，默认 7）：共享的取值范围放不下 11，而且用户调过的间距应当保持不变。
  var topRowGap: CGFloat { self == .tablet ? 9 : 4 }

  /// 默认键盘高度下一排按键的高度（四档设备键高参考 KeyboardKit `liquidGlass: true` 标准配置，保留九键等竖屏 52pt）：
  /// - 竖屏：标准手机 26 键及切出的数字/符号层 43pt、大屏手机（Plus / Pro Max）46pt；九键/网格/笔画/手写仍为 52pt；普通 iPad 54pt、大屏 iPad（12.9"/13"）61pt。
  /// - 横屏：手机 32pt，手写保留 40pt 以留足书写区；普通 iPad 74pt、大屏 iPad 78pt。
  func keyHeight(landscape: Bool, handwriting: Bool, letterKeys: Bool = false, largeScreen: Bool = false) -> CGFloat {
    guard landscape else {
      switch self {
      case .phone:
        return letterKeys ? (largeScreen ? 46 : 43) : KeyboardHeightPercent.portraitKeyHeight(tablet: false)
      case .tablet:
        return KeyboardHeightPercent.portraitKeyHeight(tablet: true, largeScreen: largeScreen)
      }
    }
    switch self {
    case .phone: return handwriting ? 40 : 32
    case .tablet: return largeScreen ? 78 : 74
    }
  }

  /// 键盘按几排按键来排布：四排；iPad 显示数字行时为五排，因为那是整整多出的一排，而不是从字母行里挤出来的。手机只在画「按键布局」的顶部数字行（或它在数字和符号页上的补充行）时为五排（`phoneNumberRow`），大千的第五排在手机上仍挤在四排里。竖屏手写也多一排（`handwritingAddsRow`），书写区因此有四排键高。
  func keyRows(numberRow: Bool, handwriting: Bool = false, landscape: Bool = false, phoneNumberRow: Bool = false) -> Int {
    ((self == .tablet ? numberRow : phoneNumberRow) ? 5 : 4)
      + (Self.handwritingAddsRow(handwriting: handwriting, landscape: landscape) ? 1 : 0)
  }

  /// 手写模式是否比其他布局多一排键高：竖屏的手机和 iPad 都多，书写区占四排键高、铺满键盘宽度；横屏屏幕本来就矮，保留原来的三排书写区。Android 与 HarmonyOS 按同一条规则（见 .agents/notes/implemented/feature/2026-10-25-mobile-handwriting-full-width-pad.md）。
  static func handwritingAddsRow(handwriting: Bool, landscape: Bool) -> Bool { handwriting && !landscape }

  /// 用户调整之前的键盘高度，按设计稿的结构逐项相加：上边距、顶部那一行、它下面的间隔、各排按键连同排间距，以及下边距。顶部那一行收起（`topRow` 为 0，「显示方式」为隐藏时）时间隔也一起去掉，与 `applyKeyboardMetrics` 把那段间隔设为 0 一致，否则多出的高度会被分给按键，组字开始和结束时按键高度跟着跳。
  func keyboardHeight(topRow: CGFloat, rowSpacing: CGFloat, landscape: Bool, handwriting: Bool,
                      numberRow: Bool = false, letterKeys: Bool = false, phoneNumberRow: Bool = false,
                      largeScreen: Bool = false) -> CGFloat {
    let rows = keyRows(numberRow: numberRow, handwriting: handwriting, landscape: landscape, phoneNumberRow: phoneNumberRow)
    let keyBlock = KeyboardHeightPercent.keyBlockHeight(
      keyHeight: keyHeight(landscape: landscape, handwriting: handwriting, letterKeys: letterKeys, largeScreen: largeScreen),
      rows: rows, rowSpacing: rowSpacing)
    // 手机竖屏 26 键直接按分档键帽高度计算紧凑高度，不再加回 52pt 标准键帽多出的留白。
    let letterHeightCompensation: CGFloat = 0
    let insets = padding(landscape: landscape, largeScreen: largeScreen)
    return insets.top + topRow + (topRow > 0 ? topRowGap : 0)
      + keyBlock + letterHeightCompensation
      + insets.bottom
  }

  /// Whether the third letter row carries the comma and full-stop keys, as the iPad system keyboard does.
  var showsLetterRowPunctuation: Bool { self == .tablet }

  /// Whether the keyboard can carry the digit row and Tab key of a full-size keyboard (`KeyboardLayoutPreference.tabletFullKeys`). A phone-width keyboard has no room for either.
  var canShowFullKeys: Bool { self == .tablet }
}

/// iPad 键盘的 26 键布局（dc.html 里的 `pad` 各行），跟随 iPadOS 系统键盘而不是手机的布局：⌫ 在第一行末尾，第二行缩进 2.5% 开始、以 return 结尾，第三行在 z–m 和 ，。 两端各有一个 ⇧，底行为 123 | 中 | space | 123 | ⌄，没有单独的 return。权重是相对一个字母键宽度的份额，底行则与设计稿的 flex 一样是相对本行的份额。
///
/// 只用于全宽平板键盘的字母行。iPad 的数字行和 Tab 仍在上方（`KeyboardLayoutPreference.tabletFullKeys`），符号层、九键框架、手写板、假名键和大千注音各行沿用手机上的行。
enum TabletLetterLayout {
  /// 第一行末尾的 ⌫。
  static let deleteWeight: CGFloat = 1.3
  /// 第二行末尾的 return。
  static let returnWeight: CGFloat = 1.75
  /// 第三行的每个 ⇧。
  static let shiftWeight: CGFloat = 1.4
  /// 第二行开头的缩进，以按键宽度的份额计。
  static let middleRowLeadingInset: CGFloat = 0.025

  /// 底行的 123 键，空格键两侧各一个。
  static let layerWeight: CGFloat = 1.5
  /// 中 / 英 切换键。
  static let languageWeight: CGFloat = 1.2
  /// 地球键，宿主要求时才有；设计稿没有画它，所以放在 中 后面，占一个普通键的份额。
  static let globeWeight: CGFloat = 1
  /// 空格键。
  static let spaceWeight: CGFloat = 6.4
  /// ⌄，收起键盘。
  static let dismissWeight: CGFloat = 1.2
  /// 收起键的键面：设计稿用 15pt 文字画这个字符，而不是图标。
  static let dismissFace = "⌄"
}

/// 横屏分离式键盘（iPad 的 `KeyboardLayoutPreference.tabletSplit`、iPhone 的 `phoneLandscapeSplit`）的规则：什么时候分、哪些布局分、从哪里分、中缝多宽。
///
/// 平板形态（regular 宽度的 iPad）横屏且 iPad 的开关打开时分；iPhone 横屏、iPhone 的开关打开、而且屏幕够宽（`phoneIsActive`）时也分，几何与 iPad 相同，只是键面是手机的。iPad 的浮动键盘、Slide Over 和台前调度里的窄窗口已经是手机形态，但不是 iPhone，不分；竖屏也不分，它们都保持原样。
///
/// 分的是 26 键字母布局（全拼、各种双拼含微软双拼的 `;` 键、五笔、英文、日文罗马字、韩文和其他字母方案）、它们的 123 符号页，以及 iPad 的数字行和 Tab 那一排；九键、全拼 14 键、笔画、手写、注音大千和日文假名九键不分，符号、表情、剪贴板等面板也不分。每一排（包括底部功能键那一排）在中间插入一段不接触摸的中缝，键盘高度不变。
enum KeyboardSplitLayout {
  /// 中缝占键区宽度的比例：左右两半最里面的两个键之间空出这么宽。
  static let gapRatio: CGFloat = 0.25

  /// 分离式键盘此刻是否生效。`enabled` 只在平板横屏时才读，手机和竖屏不必去读 App Group。
  static func isActive(formFactor: KeyboardFormFactor, landscape: Bool, enabled: @autoclosure () -> Bool) -> Bool {
    formFactor == .tablet && landscape && enabled()
  }

  /// iPhone 横屏分开后字母键至少要有多宽（pt）才分（#10224）。键区宽是键盘视图的宽度，不是屏幕宽度：全面屏 iPhone 横屏时系统在键盘两侧各留一栏放地球键和听写键，XR（896pt 宽的屏幕）真机上键盘只有约 662pt，分开后字母键约 44pt。36pt 不窄于 iPhone 竖屏时的字母键（SE 约 31.5pt，XR 约 35.4pt），所以默认 6pt 键距下所有 iPhone 横屏都分；它只挡住窄得不正常的键盘视图。早先的 50pt 是按屏幕宽度算的，真机上没有一台 iPhone 够得着。
  static let phoneMinimumLetterKeyWidth: CGFloat = 36

  /// iPhone 横屏分开后第一排字母键的宽度：一排十个字母加一段中缝，共十个键距；中缝视图宽 `gapViewWidth`，于是十个键分到 `(1 - gapRatio) * rowWidth - 8 * keySpacing`。第一排是手机键盘最窄的一排（第二排九个字母两侧缩进，第三排七个字母两侧是 44pt 的 ⇧ 和 ⌫，按同样的中缝算都更宽）。
  static func phoneLetterKeyWidth(rowWidth: CGFloat, keySpacing: CGFloat) -> CGFloat {
    ((1 - gapRatio) * rowWidth - 8 * keySpacing) / 10
  }

  /// iPhone 横屏分离式键盘此刻是否生效：真的是 iPhone（iPad 的浮动键盘和窄窗口也是手机形态，但不分）、横屏、分开后的字母键不窄于 `phoneMinimumLetterKeyWidth`，开关打开。开关放在最后读，竖屏和窄屏不读 App Group。
  static func phoneIsActive(idiom: UIUserInterfaceIdiom, formFactor: KeyboardFormFactor, landscape: Bool,
                            rowWidth: CGFloat, keySpacing: CGFloat, enabled: @autoclosure () -> Bool) -> Bool {
    idiom == .phone && formFactor == .phone && landscape
      && phoneLetterKeyWidth(rowWidth: rowWidth, keySpacing: keySpacing) >= phoneMinimumLetterKeyWidth
      && enabled()
  }

  /// 当前显示的键区是不是会分开的字母布局。英文和本地输入模式总是画 26 键字母；九键、全拼 14 键和 18 键、笔画、假名九键、注音大千和手写画的是各自的键区，不分。
  static func splitsLayout(scheme: ChineseInputScheme, chinese: Bool, localMode: Bool) -> Bool {
    guard chinese, !localMode else { return true }
    switch scheme {
    case .nineKey, .nineKeyShuangpin, .fourteenKey, .eighteenKey, .stroke, .japaneseNineKey, .zhuyin, .handwriting: return false
    default: return true
    }
  }

  /// 一排有 `characterKeys` 个字符键（字母、数字、符号，以及平板第三排末尾的逗号句号）时左半分到几个：从中间分，奇数时左半多一个。Tab、Shift 和删除这些功能键不计数，留在它们原来那一侧的外沿。
  ///
  /// 这样得到的正好是触摸打字的左右手分工：qwert | yuiop、asdfg | hjkl（微软双拼多出的 `;` 归右半）、zxcvb | nm，。；数字行和符号页是 5 | 5。
  static func leftKeyCount(_ characterKeys: Int) -> Int { (max(characterKeys, 0) + 1) / 2 }

  /// 中缝视图的宽度：键区宽度的 `gapRatio`，减去中缝两侧各一个键距，使两半最里面的键之间正好空出 `gapRatio`。
  static func gapViewWidth(rowWidth: CGFloat, keySpacing: CGFloat) -> CGFloat {
    max(0, rowWidth * gapRatio - 2 * keySpacing)
  }
}
