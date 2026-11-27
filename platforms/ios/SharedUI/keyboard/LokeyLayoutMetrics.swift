import CoreGraphics
import Foundation
import UIKit

/// Lokey 0.9.5 键帽配色、按压反馈与气泡样式常量（对应 `LokeyKeyboard.appex` `0x1001b9700` / `0x1001baf88` / `0x1001c3738`）。
///
/// 浅色下字母键与功能键常态统一为纯白 `#FFFFFF`（按下 `#DADDE4`）；
/// 深色下常态统一为 `white 15.5%` 半透明玻璃叠层（按下 `white 28%`）；
/// 键帽全程扁平无阴影（`shadowOpacity = 0`）、无描边、按下不缩放键帽。
enum LokeyVisualStyle {
  /// 浅色常态键帽底色（字母键、功能键、默认换行统一纯白 `#FFFFFF`）。
  static let lightKeyFill = UIColor.white
  /// 浅色按下态底色（`rgb(0.855, 0.868, 0.896)` = `#DADDE4`）。
  static let lightPressedFill = UIColor(red: 0.855, green: 0.868, blue: 0.896, alpha: 1.0)
  /// 深色常态键帽底色（15.5% 纯白半透明叠层，透出 iOS 26/27 Liquid Glass 底板）。
  static let darkKeyFill = UIColor(white: 1.0, alpha: 0.155)
  /// 深色按下态底色（28% 纯白提亮）。
  static let darkPressedFill = UIColor(white: 1.0, alpha: 0.28)

  /// Shift 激活态（单次大写 / 大写锁定）：实体纯白键帽配纯黑图标，与 Lokey/原生高对比一致。
  static let activeShiftFill = UIColor.white
  static let activeShiftForeground = UIColor.black

  /// 禁用态键帽底色与文字（如微信/Spotlight 空输入框且 `enablesReturnKeyAutomatically == true` 时的发送/搜索键）：
  /// 严格对齐 `LokeyKeyboard.appex` `0x1001c5e14`–`0x1001c5fb0`：
  /// 深色为 `white 10%` 底色配 `white 32%` 前景，浅色为 `#BFC0C4` 底色配 `#A4A5AA` 前景。
  static let disabledKeyFill = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 1.0, alpha: 0.10)
      : UIColor(red: 191.0 / 255.0, green: 192.0 / 255.0, blue: 196.0 / 255.0, alpha: 1.0)
  }
  static let disabledForeground = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 1.0, alpha: 0.32)
      : UIColor(red: 164.0 / 255.0, green: 165.0 / 255.0, blue: 170.0 / 255.0, alpha: 1.0)
  }

  /// 主动作蓝色回车键底色与前景（对应 `LokeyKeyboard.appex` `0x1001c62d0` / `0x1001c6304`）：
  /// 深色 `#0A84FF`（`rgb(0.039, 0.518, 1.0)`），浅色 `#007AFF`（`rgb(0.0, 0.478, 1.0)`）。
  static let actionBackground = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1.0)
      : UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)
  }
  static let actionForeground = UIColor.white

  /// Lokey 0.9.5 键帽静态字号表（对应 `LokeyKeyboard.appex` `0x1001bee88`–`0x1001bf2c8`）。
  static let lowercaseLetterFontSize: CGFloat = 25.0
  static let uppercaseLetterFontSize: CGFloat = 22.5
  /// `123` / `#+=` 三排全部单字符（数字 `1–0`、第二排符号、第三排 6 标点）统一 `22.0pt .regular`（`0x1001bef10`）。
  static let symbolCharacterFontSize: CGFloat = 22.0
  static let multiCharacterSymbolFontSize: CGFloat = 17.5
  /// `#+=` 切换键 `13.8pt .regular`（`0x1001beff0`）。
  static let symbolMoreToggleFontSize: CGFloat = 13.8
  /// `拼音` 切换键 `15.8pt .regular`（`0x1001bf034`）。
  static let pinyinToggleFontSize: CGFloat = 15.8
  /// `123` / `ABC` 切换键 `16.0pt .regular`（`0x1001bf164`）。
  static let layerToggleFontSize: CGFloat = 16.0
  /// 回车文字键（搜索/发送/换行）`16.5pt`（常态 `.regular`，蓝色主动作态 `.medium`，`0x1001bf1d4`）。
  static let returnTitleFontSize: CGFloat = 16.5

  /// 叠在常态键帽之上的按压遮罩色与透明度，使浅色 `#FFFFFF` 精准合成 `#DADDE4`、深色 `15.5% 白` 精准合成 `28% 白`，不遮挡文字且零布局开销。
  static let lightPressOverlayColor = UIColor(red: 0.0, green: 0.0897, blue: 0.2828, alpha: 1.0)
  static let lightPressOverlayAlpha: CGFloat = 0.145
  static let darkPressOverlayColor = UIColor.white
  static let darkPressOverlayAlpha: CGFloat = 0.148

  /// 动态适配深浅色的 Lokey 键帽常态底色。
  static let keyFill = UIColor { traits in
    traits.userInterfaceStyle == .dark ? darkKeyFill : lightKeyFill
  }
  /// 动态适配深浅色的 Lokey 键帽按下态底色。
  static let pressedFill = UIColor { traits in
    traits.userInterfaceStyle == .dark ? darkPressedFill : lightPressedFill
  }
  /// 动态适配深浅色的 Lokey 键帽文字与图标色（浅黑深白）。
  static let foreground = UIColor { traits in
    traits.userInterfaceStyle == .dark ? .white : .black
  }

  /// Lokey 按键放大气泡参数（`KeyCalloutBubbleView` `0x1001baf88` / `0x1001bb77c`）。
  static let calloutWidthFactor: CGFloat = 1.54
  static let calloutMinimumWidth: CGFloat = 48.0
  static let calloutHeight: CGFloat = 52.0
  static let darkCalloutFill = UIColor(red: 0.36, green: 0.36, blue: 0.38, alpha: 1.0)
  static let calloutFill = UIColor { traits in
    traits.userInterfaceStyle == .dark ? darkCalloutFill : .white
  }
  static let calloutBorder = UIColor { traits in
    traits.userInterfaceStyle == .dark ? UIColor(white: 1.0, alpha: 0.12) : UIColor(white: 0.0, alpha: 0.08)
  }
}

/// Lokey 0.9.5 屏幕分档，对应 `LokeyKeyboard.appex` `0x1001b8d24` 的 7 档分类规则。
enum LokeyScreenProfile: Int, CaseIterable, Equatable, Hashable {
  /// 窄屏竖屏（iPhone mini / SE 等，宽度 < 390pt）。
  case miniPortrait = 0
  /// 标准竖屏（iPhone 标准款，390pt <= 宽度 < 428pt）。
  case compactPortrait = 1
  /// 大屏竖屏（Plus / Pro Max 等，428pt <= 宽度 < 446pt，或宽度尚未确定时的缺省）。
  case maxPortrait = 2
  /// 手机横屏（宽度 > 520pt 且屏幕短边 < 460pt）。
  case landscape = 3
  /// 折叠屏外屏（446pt <= 宽度 <= 520pt）。
  case duoCover = 4
  /// 折叠屏展开竖向（宽度 > 520pt、短边 >= 460pt 且非横屏宽幅）。
  case duoUnfoldedPortrait = 5
  /// 折叠屏展开横向（宽度 > 725pt 或宽屏横向形态）。
  case duoUnfoldedLandscape = 6

  /// 按键盘容器宽度与屏幕尺寸判定 Lokey 屏幕分档。
  static func resolve(containerWidth: CGFloat, screenSize: CGSize?, landscape: Bool) -> LokeyScreenProfile {
    let screenW = screenSize?.width ?? 0
    let screenH = screenSize?.height ?? 0
    let shortSide = min(screenW, screenH)
    let longSide = max(screenW, screenH)

    if containerWidth > 520 {
      if shortSide > 0 && shortSide < 460 {
        return .landscape
      }
      if shortSide >= 460 {
        if longSide < 600 {
          return containerWidth > 725 ? .duoUnfoldedLandscape : .duoUnfoldedPortrait
        }
        if containerWidth > 725 || landscape {
          return .duoUnfoldedLandscape
        }
        return .duoUnfoldedPortrait
      }
      return landscape ? .landscape : .maxPortrait
    }

    if landscape && containerWidth > 446 {
      return .landscape
    }
    if containerWidth >= 446 {
      return .duoCover
    }
    if containerWidth <= 0 || containerWidth >= 428 {
      return .maxPortrait
    }
    if containerWidth >= 390 {
      return .compactPortrait
    }
    return .miniPortrait
  }

  /// 是否属于折叠屏展开形态（底行与圆角采用展开档位参数）。
  var isDuoUnfolded: Bool {
    self == .duoUnfoldedPortrait || self == .duoUnfoldedLandscape
  }
}

/// Lokey 0.9.5 键区几何与高度度量表，严格对齐 `KeyGridView`（`0x1001c1598`）与 `KeyboardTheme`（`0x1001b8a6c` / `0x1001b90ac`）。
struct LokeyGridMetrics: Equatable {
  let profile: LokeyScreenProfile
  /// 键盘左右外边距（pt）。
  let horizontalMargin: CGFloat
  /// 同排按键之间的水平键距（pt）。
  let horizontalGap: CGFloat
  /// 相邻排按键之间的垂直排距（pt）。
  let verticalGap: CGFloat
  /// 顶栏底边到第一排字母顶边的间隔（pt）。
  let topGap: CGFloat
  /// 底排按键底边到键盘底部的留白（pt）。
  let bottomInset: CGFloat
  /// 键帽连续曲率圆角半径（pt）。
  let cornerRadius: CGFloat
  /// Lokey 参考顶栏高度（未扣减 `hostTopPadding` 前）。
  let baseTopBarHeight: CGFloat
  /// Lokey 4 排常规键盘参考总高（未扣减 `hostTopPadding` 前）。
  let baseTotalHeight: CGFloat
  /// 单排按键高度（pt），由 4 排总高扣减顶栏、留白和 3 道排距精确反推。
  let keyHeight: CGFloat

  /// 构造指定分档与容器宽度的几何参数；折叠屏展开横屏超 860pt 时将键区限宽 781pt 并水平居中。
  static func forProfile(_ profile: LokeyScreenProfile, containerWidth: CGFloat = 0) -> LokeyGridMetrics {
    let hMargin: CGFloat
    let hGap: CGFloat
    let vGap: CGFloat
    let topGap: CGFloat
    let bottomInset: CGFloat
    let radius: CGFloat
    let topBar: CGFloat
    let totalHeight: CGFloat

    switch profile {
    case .miniPortrait:
      hMargin = 6.5
      hGap = 6.25
      vGap = 10.5
      topGap = 4.5
      bottomInset = 1.5
      radius = 9.0
      topBar = 41.0
      totalHeight = 239.0
    case .compactPortrait:
      hMargin = 6.5
      hGap = 6.25
      vGap = 10.5
      topGap = 4.5
      bottomInset = 1.5
      radius = 9.0
      topBar = 44.0
      totalHeight = 250.0
    case .maxPortrait:
      hMargin = 6.5
      hGap = 6.25
      vGap = 11.0
      topGap = 4.5
      bottomInset = 7.0
      radius = 9.0
      topBar = 44.0
      totalHeight = 268.5
    case .landscape:
      hMargin = 6.0
      hGap = 7.0
      vGap = 7.0
      topGap = 3.0
      bottomInset = 4.0
      radius = 9.0
      topBar = 36.0
      totalHeight = 197.5
    case .duoCover:
      hMargin = 0.0
      hGap = 6.0
      vGap = 11.0
      topGap = 4.5
      bottomInset = 7.0
      radius = 9.0
      topBar = 44.0
      totalHeight = 268.5
    case .duoUnfoldedPortrait:
      hMargin = 11.0
      hGap = 9.0
      vGap = 14.5
      topGap = 6.0
      bottomInset = 3.5
      radius = 10.5
      topBar = 50.0
      totalHeight = 300.0
    case .duoUnfoldedLandscape:
      hMargin = containerWidth > 860 ? (containerWidth - 781.0) * 0.5 : 10.0
      hGap = 10.0
      vGap = 13.5
      topGap = 5.5
      bottomInset = 3.0
      radius = 11.5
      topBar = 48.0
      totalHeight = 265.0
    }

    let keyHeight = max((totalHeight - topBar - topGap - bottomInset - 3 * vGap) / 4, 30.0)
    return LokeyGridMetrics(
      profile: profile,
      horizontalMargin: hMargin,
      horizontalGap: hGap,
      verticalGap: vGap,
      topGap: topGap,
      bottomInset: bottomInset,
      cornerRadius: radius,
      baseTopBarHeight: topBar,
      baseTotalHeight: totalHeight,
      keyHeight: keyHeight
    )
  }
}

/// Lokey 0.9.5 26 键几何计算、iOS 26 `hostTopPadding` 补偿及 123/#+= 符号层键表。
enum LokeyLayoutMetrics {
  /// iOS 26/27 宿主通过 `safeAreaInsets.top` 明确上报顶部留白时的最大扣减上限（pt），对应 `0x1001b8a74` 的 `17.0`。
  static let maxHostTopPadding: CGFloat = 17.0
  /// iOS 26/27 Liquid Glass 竖屏键盘扩展在 `safeAreaInsets.top == 0` 时的默认补扣量（pt）：
  /// 真机实测 Spotlight 等新拉起场景下玻璃顶边与 `UIInputViewController.view` 顶边完全重合（0pt），
  /// 强行预扣 `17pt` 会把顶栏压死到玻璃圆角边；对齐 Lokey 0.9.5 正式版（`0x10019f9f0`），默认返回 `0`。
  static let defaultLiquidGlassHostTopPadding: CGFloat = 0.0
  /// 扣减宿主顶部留白后顶栏保底高度（pt），对应 `0x1001b8a98` 的 `31.0`。
  static let minimumTopBarFloor: CGFloat = 31.0
  /// 顶栏图标垂直微调偏移（pt）：默认 `0` 保持垂直居中，避免贴近液态玻璃顶沿圆角。
  static let compactTopBarOpticalOffset: CGFloat = 0.0
  /// 第三排 `⇧`/`⌫` 与 `#+=`/`⌫` 的单键宽比例系数（`0x100205b78`）。
  static let sideKeyWidthRatio: CGFloat = 1.348
  /// 第三排侧键最小宽度（pt）。
  static let sideKeyMinimumWidth: CGFloat = 42.0
  /// 123 / `#+=` 第三排在 `#+=` 与 `⌫` 内侧各自追加的缓冲宽度（pt，总计 `10pt`）。
  static let symbolRowInnerBuffer: CGFloat = 5.0
  /// 空格键最小保底宽度（pt，对应 `0x1001c1ec4` 的 `80.0`）。
  static let minimumSpaceWidth: CGFloat = 80.0

  /// 限制 iOS 26 宿主顶部留白到 `[0, 17]`。
  static func clampedHostTopPadding(_ raw: CGFloat) -> CGFloat {
    guard raw.isFinite else { return 0 }
    return min(max(raw, 0), maxHostTopPadding)
  }

  /// 计算当前宿主在键盘扩展顶部注入的系统留白（pt）：
  /// - 横屏与 iPad 不扣减；
  /// - 仅在测试注入或宿主通过 `safeAreaInsets.top` 明确上报时夹紧采信；
  /// - `safeAreaInsets.top == 0` 时按 `defaultLiquidGlassHostTopPadding`（`0`）处理，避免在无系统顶距的宿主里把顶栏压死。
  static func resolvedHostTopPadding(
    safeAreaTop: CGFloat,
    isPhonePortrait: Bool,
    isLiquidGlassKeyboard: Bool,
    isKeyboardExtensionProcess: Bool,
    overrideForTesting: CGFloat? = nil
  ) -> CGFloat {
    guard isPhonePortrait else { return 0 }
    if let overrideForTesting { return clampedHostTopPadding(overrideForTesting) }
    if safeAreaTop > 0.5 { return clampedHostTopPadding(safeAreaTop) }
    guard isLiquidGlassKeyboard, isKeyboardExtensionProcess else { return 0 }
    return defaultLiquidGlassHostTopPadding
  }

  /// 对通用竖屏键盘（9 键、14/18 键、标准 26 键、手写）按宿主顶部留白压缩单行顶栏高度，保底 `31pt`，
  /// 同时完整保留释义行/独立读音行/放大缩放带来的额外高度，且不把用户主动调小的候选栏撑高。
  static func compactGeneralTopRowHeight(
    baseTopRow: CGFloat,
    standardTopRow: CGFloat,
    hostTopPadding: CGFloat
  ) -> CGFloat {
    guard baseTopRow > 0 else { return 0 }
    let pad = clampedHostTopPadding(hostTopPadding)
    guard pad > 0 else { return baseTopRow }
    let extra = max(0, baseTopRow - standardTopRow)
    let nominal = max(minimumTopBarFloor, standardTopRow - pad)
    return min(baseTopRow, nominal + extra)
  }

  /// 计算当前设备与 `hostTopPadding` 下 Lokey 风格的顶栏高度：
  /// 在保留 iBoard 动态顶栏（释义行/缩放）增量的前提下，对普通单行顶栏按 `hostTopPadding` 同步扣减并保底 `31pt`。
  static func effectiveTopRowHeight(
    baseTopRow: CGFloat,
    standardTopRow: CGFloat,
    metrics: LokeyGridMetrics,
    hostTopPadding: CGFloat
  ) -> CGFloat {
    guard baseTopRow > 0 else { return 0 }
    let extra = max(0, baseTopRow - standardTopRow)
    let pad = metrics.profile == .landscape ? 0 : clampedHostTopPadding(hostTopPadding)
    let nominal = max(minimumTopBarFloor, metrics.baseTopBarHeight - pad)
    return nominal + extra
  }

  /// 计算 Lokey 26 键键盘总高度：4 排时按顶栏实际缩减量（不超出 `baseTopBarHeight - minimumTopBarFloor`，避免压扁 4 排键帽）扣减，
  /// 开启顶部第 5 排数字行或释义行增高时按增量叠加。
  static func keyboardHeight(
    topRow: CGFloat,
    standardTopRow: CGFloat,
    rows: Int,
    metrics: LokeyGridMetrics,
    hostTopPadding: CGFloat
  ) -> CGFloat {
    let extraTop = topRow > 0 ? max(0, topRow - standardTopRow) : -(metrics.baseTopBarHeight + metrics.topGap)
    let pad = metrics.profile == .landscape ? 0 : clampedHostTopPadding(hostTopPadding)
    let effectiveTopReduction = topRow > 0
      ? max(0, metrics.baseTopBarHeight - max(minimumTopBarFloor, metrics.baseTopBarHeight - pad))
      : 0
    let extraRows = max(0, rows - 4)
    let extraRowsHeight = CGFloat(extraRows) * (metrics.keyHeight + metrics.verticalGap)
    return max(120, metrics.baseTotalHeight - effectiveTopReduction + extraTop + extraRowsHeight)
  }

  /// 第一排（10 键）单颗字母宽与节距，保底 18pt。
  static func letterKeyMetrics(keysWidth: CGFloat, keySpacing: CGFloat) -> (keyWidth: CGFloat, pitch: CGFloat) {
    let keyWidth = max((keysWidth - 9 * keySpacing) / 10, 18)
    return (keyWidth, keyWidth + keySpacing)
  }

  /// 第二排（A–L，9 键居中）左右内边距：`0.5 * pitch`。
  static func middleRowHorizontalInset(keysWidth: CGFloat, keySpacing: CGFloat) -> CGFloat {
    let (_, pitch) = letterKeyMetrics(keysWidth: keysWidth, keySpacing: keySpacing)
    return max(0, pitch * 0.5)
  }

  /// 第三排字母行（`⇧ Z–M ⌫`）侧键宽度与缓冲间隙：
  /// `sideWidth = max(keyWidth * 1.348, 42)`，`Z–M` 居中保持与首排等宽，Pro Max 430pt 下两侧留约 `14.9pt` 缓冲。
  static func thirdRowEdgeLayout(keysWidth: CGFloat, keySpacing: CGFloat) -> (width: CGFloat, gap: CGFloat) {
    let (keyWidth, pitch) = letterKeyMetrics(keysWidth: keysWidth, keySpacing: keySpacing)
    let slot = max(0, 1.5 * pitch)
    let rawSide = max(keyWidth * sideKeyWidthRatio, sideKeyMinimumWidth)
    let sideWidth = max(0, min(rawSide, slot - keySpacing))
    let gap = max(keySpacing, slot - sideWidth)
    return (sideWidth, gap)
  }

  /// 123 / `#+=` 第三排（`#+=` / 6 标点 / `⌫`）侧键宽度与内侧间距（在标准键距外各追加 5pt 缓冲）。
  static func symbolThirdRowLayout(keysWidth: CGFloat, keySpacing: CGFloat) -> (sideWidth: CGFloat, innerGap: CGFloat) {
    let (keyWidth, _) = letterKeyMetrics(keysWidth: keysWidth, keySpacing: keySpacing)
    let sideWidth = max(keyWidth * sideKeyWidthRatio, sideKeyMinimumWidth)
    return (sideWidth, keySpacing + symbolRowInnerBuffer)
  }

  /// iOS 原生（Lokey 几何）底行像素级精确宽度（`0x1001c1da0`）：
  /// - 常规手机（无地球键）：`returnW = 2.5 * keyW + 1.5 * hGap`，`123` 与 `中/英` 各宽 `(returnW - hGap) / 2`，左右严格对称；
  /// - 常规手机（有地球键）：`123` / `🌐` / `中/英` 各宽 `keyW`，`returnW` 不变；
  /// - 折叠屏展开态：`returnW = 1.8 * keyW + 0.5 * hGap`，无地球键时左侧两键各宽 `keyW`，有地球键时各宽 `0.91 * keyW`。
  struct BottomRowWidths: Equatable {
    let layerWidth: CGFloat
    let globeWidth: CGFloat
    let languageWidth: CGFloat
    let returnWidth: CGFloat

    /// 兼容旧称（同 `languageWidth`）。
    var emojiWidth: CGFloat { languageWidth }
  }

  static func bottomRowWidths(
    keysWidth: CGFloat,
    keySpacing: CGFloat,
    globe: Bool,
    profile: LokeyScreenProfile
  ) -> BottomRowWidths {
    let (keyWidth, _) = letterKeyMetrics(keysWidth: keysWidth, keySpacing: keySpacing)
    if profile.isDuoUnfolded {
      let returnWidth = keyWidth * 1.8 + keySpacing * 0.5
      let leftWidth = globe ? keyWidth * 0.91 : keyWidth
      return BottomRowWidths(
        layerWidth: leftWidth,
        globeWidth: globe ? leftWidth : 0,
        languageWidth: leftWidth,
        returnWidth: returnWidth
      )
    }
    let returnWidth = keyWidth * 2.5 + keySpacing * 1.5
    if globe {
      return BottomRowWidths(
        layerWidth: keyWidth,
        globeWidth: keyWidth,
        languageWidth: keyWidth,
        returnWidth: returnWidth
      )
    }
    let leftWidth = max((returnWidth - keySpacing) * 0.5, 24)
    return BottomRowWidths(
      layerWidth: leftWidth,
      globeWidth: 0,
      languageWidth: leftWidth,
      returnWidth: returnWidth
    )
  }

  // MARK: - Lokey 123 / #+= 符号层键表（从 LokeyKeyboard 二进制直接解码）

  private static let numberDigits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
  private static let chineseNumberSymbols = ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"]
  private static let chineseCornerNumberSymbols = ["-", "/", "：", "；", "（", "）", "¥", "@", "「", "」"]
  private static let englishNumberSymbols = ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
  /// 中文 `123` 第 3 排 6 标点（含半角 `.`）。
  private static let chineseNumberPunctuation = ["。", "，", "、", "？", "！", "."]
  private static let englishNumberPunctuation = [".", ",", "?", "!", "'", "-"]
  /// 中文 `#+=` 首排使用全角括号 `【 】 ｛ ｝`。
  private static let chineseMoreSymbolsFirst = ["【", "】", "｛", "｝", "#", "%", "^", "*", "+", "="]
  private static let englishMoreSymbolsFirst = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
  private static let chineseMoreSymbolsSecond = ["_", "—", "\\", "|", "～", "《", "》", "€", "&", "·"]
  private static let englishMoreSymbolsSecond = ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
  private static let chineseMorePunctuation = ["…", "，", "、", "？", "！", "’"]
  private static let englishMorePunctuation = [".", ",", "?", "!", "'", "`"]

  /// 返回 Lokey 123 / `#+=` 符号层三排字符（第 3 排固定 6 标点）。
  static func symbolCharacterRows(more: Bool, chinese: Bool, cornerQuotes: Bool = false) -> [[String]] {
    if more {
      return [
        chinese ? chineseMoreSymbolsFirst : englishMoreSymbolsFirst,
        chinese ? chineseMoreSymbolsSecond : englishMoreSymbolsSecond,
        chinese ? chineseMorePunctuation : englishMorePunctuation,
      ]
    }
    let second = chinese ? (cornerQuotes ? chineseCornerNumberSymbols : chineseNumberSymbols) : englishNumberSymbols
    let third = chinese ? chineseNumberPunctuation : englishNumberPunctuation
    return [numberDigits, second, third]
  }
}
