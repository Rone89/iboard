import Foundation

/// 长按退格键的分段加速与按词删除策略。
///
/// 先保持稳定的初始起跳与常规连删节奏，持续按住超过阈值后切换为更紧凑的连删间隔；在无组字的非中文文本中，进一步过渡为按词删除，避免长段英文删起来偏慢。
enum BackspaceRepeatPolicy {
  static let initialDelay: TimeInterval = 0.4
  static let fastInterval: TimeInterval = 0.075
  static let acceleratedInterval: TimeInterval = 0.045
  static let acceleratedAfterSteps = 16
  static let wordDeleteAfterSteps = 18

  /// 第 `step` 次重复删除（从 1 开始）之后等待下一次触发的时间间隔。
  static func interval(forStep step: Int) -> TimeInterval {
    step >= acceleratedAfterSteps ? acceleratedInterval : fastInterval
  }

  /// 当前这一次重复退格是否升级为按词删除：手写撤笔迹、组字中、就地组字方案或中文模式下保持单步/按音节删除；仅在纯英文/无组字正文连续长按达标后按词删。
  static func deletesWord(step: Int, hasComposition: Bool, composesInPlace: Bool, isChineseMode: Bool, hasInk: Bool) -> Bool {
    guard !hasInk, !hasComposition, !composesInPlace, !isChineseMode else { return false }
    return step >= wordDeleteAfterSteps
  }

  /// 从光标前文本末尾计算一次按词删除应退掉的字符数（至少为 1）。
  ///
  /// 规则与系统键盘接近：先吞掉末尾连续的空格/制表符，再吞掉紧邻的一个英文/数字词（含 `'` 与 `_`）；若紧邻的是换行或单个标点，则只删 1 个字符。
  static func wordDeleteCount(beforeCursor: String?) -> Int {
    guard let beforeCursor, !beforeCursor.isEmpty else { return 1 }
    let chars = Array(beforeCursor)
    var index = chars.count

    while index > 0 && (chars[index - 1] == " " || chars[index - 1] == "\t") {
      index -= 1
    }
    let trailingSpaces = chars.count - index

    var wordChars = 0
    while index > 0 && isWordCharacter(chars[index - 1]) {
      index -= 1
      wordChars += 1
    }

    if wordChars > 0 {
      return trailingSpaces + wordChars
    }
    return max(1, trailingSpaces)
  }

  private static func isWordCharacter(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { scalar in
      CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "_"
    }
  }
}
