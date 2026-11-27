import UIKit

/// 长按气泡（`KeyActionCalloutView`）与上下文按键策略。
///
/// 集中管理常用标点、符号/数字衍生项与网址/邮箱域名后缀的候选列表，避免把映射表散落在 `KeyboardViewController` 里。
enum KeyHoldCalloutPolicy {
  /// 常用标点键（`，`）长按候选：去重并保留设定顺序，至少需要 2 项才有弹出意义；只有 1 项时直接按原列表返回，仍可由单手势确认。
  static func quickPunctuationOptions(symbols: [String]) -> [String] {
    var seen: Set<String> = []
    return symbols.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// 句号键长按候选：手写模式保留原生 `!`/`！` 角标长按；在 `.URL` 与 `.emailAddress` 输入框下弹出常用域名后缀，其余普通输入框不额外拦截句号。
  static func periodOptions(keyboardType: UIKeyboardType, handwriting: Bool) -> [String] {
    guard !handwriting else { return [] }
    switch keyboardType {
    case .URL:
      return [".com", ".cn", ".net", ".org", ".edu"]
    case .emailAddress:
      return [".com", ".cn", ".net", ".org", "@"]
    default:
      return []
    }
  }

  /// 网址/邮箱输入框下常用标点键（在未自定义常用标点列表时）的上下文长按候选。
  static func urlOrEmailQuickPunctuationOptions(keyboardType: UIKeyboardType) -> [String] {
    switch keyboardType {
    case .URL:
      return ["/", ".", ".com", ".cn", "https://", ":"]
    case .emailAddress:
      return ["@", ".", ".com", ".cn", "_"]
    default:
      return []
    }
  }

  /// 123 / #+= 符号层及数字键长按时的衍生符号列表；没有衍生项的键返回空数组。
  static func symbolLayerOptions(for face: String, chinese: Bool) -> [String] {
    switch face {
    case "0": return ["0", "°"]
    case "-": return ["-", "—", "–", "•"]
    case "/": return ["/", "\\"]
    case "$": return ["$", "￥", "€", "£", "¥"]
    case "￥", "¥": return ["￥", "$", "€", "£"]
    case "\"", "“", "”": return chinese ? ["“", "”", "\"", "「", "」", "《", "》"] : ["\"", "“", "”", "«", "»"]
    case "'", "‘", "’": return chinese ? ["‘", "’", "'", "「", "」"] : ["'", "‘", "’"]
    case "~", "～": return ["~", "～", "≈"]
    case "%": return ["%", "‰"]
    case "=": return ["=", "≠", "≈"]
    case "*": return ["*", "×", "•"]
    case "+": return ["+", "±"]
    case "&": return ["&", "§"]
    case ".": return [".", "…"]
    case "。": return ["。", "…", "·"]
    case "、": return ["、", "·"]
    case "?", "？": return chinese ? ["？", "?", "¿"] : ["?", "¿", "？"]
    case "!", "！": return chinese ? ["！", "!", "¡"] : ["!", "¡", "！"]
    default: return []
    }
  }

  /// 多字符片段（如 `.com`、`https://`）绕过单字符标点路由，直接作为文本上屏。
  static func commitsDirectText(_ option: String) -> Bool {
    option.count > 1
  }
}

/// 回车键语义着蓝规则：原生/Lokey 皮肤在未组字且宿主为普通 `.default` 换行、或 `enablesReturnKeyAutomatically` 且输入框为空时回归非强调底色；只有可触发的主动作或组字「确认」态才着动作蓝；非原生主题保留设计稿全态强调色。
enum ReturnKeyStylePolicy {
  static func usesActionAccent(
    isNativeSkin: Bool,
    confirmsComposition: Bool,
    returnKeyType: UIReturnKeyType,
    enablesReturnKeyAutomatically: Bool = false,
    hasText: Bool = true
  ) -> Bool {
    guard isNativeSkin else { return true }
    if confirmsComposition { return true }
    guard returnKeyType != .default else { return false }
    if enablesReturnKeyAutomatically && !hasText { return false }
    return true
  }
}

/// 网址（`.URL`）与邮箱（`.emailAddress`）输入框下的底行上下文微调策略。
enum KeyboardContextBottomPolicy {
  /// 未自定义常用标点时，替换底行 `,` 的直达键面：网址为 `/`，邮箱为 `@`，其余保持 nil。
  static func quickPunctuationFace(keyboardType: UIKeyboardType, customQuickPunctuation: Bool) -> String? {
    guard !customQuickPunctuation else { return nil }
    switch keyboardType {
    case .URL: return "/"
    case .emailAddress: return "@"
    default: return nil
    }
  }

  /// 在网址或邮箱输入框下，手机 26 键字母层底行也显示独立 `.` 键，方便直接点按与长按域名后缀。
  static func showsIndependentPeriodKey(keyboardType: UIKeyboardType) -> Bool {
    keyboardType == .URL || keyboardType == .emailAddress
  }
}
