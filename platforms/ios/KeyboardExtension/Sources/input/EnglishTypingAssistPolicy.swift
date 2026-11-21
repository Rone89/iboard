import Foundation

/// 英文输入辅助策略：双击空格自动句号、常见无歧义英文缩写撇号兜底，以及自动空格后紧跟标点的智能回贴。
enum EnglishTypingAssistPolicy {
  /// 双击空格转句号的最大时间窗口（秒），与 iOS 系统键盘节奏对齐。
  static let doubleSpaceThreshold: TimeInterval = 0.45

  /// 允许紧跟在自动空格后自动回贴（吞掉多余前导空格）的半角标点集合。
  private static let pullbackPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":"]

  /// 常见无歧义英文缩写兜底表（特意排除 `its`/`were`/`well`/`hell`/`shell`/`ill`/`wed` 等本身是常见实词的拼写）。
  private static let unambiguousContractions: [String: String] = [
    "arent": "aren't",
    "cant": "can't",
    "couldnt": "couldn't",
    "didnt": "didn't",
    "doesnt": "doesn't",
    "dont": "don't",
    "hadnt": "hadn't",
    "hasnt": "hasn't",
    "havent": "haven't",
    "heres": "here's",
    "hes": "he's",
    "im": "I'm",
    "isnt": "isn't",
    "ive": "I've",
    "lets": "let's",
    "shes": "she's",
    "shouldnt": "shouldn't",
    "thats": "that's",
    "theres": "there's",
    "theyre": "they're",
    "theyve": "they've",
    "wasnt": "wasn't",
    "werent": "weren't",
    "weve": "we've",
    "whats": "what's",
    "whos": "who's",
    "wont": "won't",
    "wouldnt": "wouldn't",
    "youre": "you're",
    "youve": "you've",
  ]

  /// 当共享英文纠错未返回改写时，对高确定性常见缩写提供带撇号候选并保留首字母大小写。
  static func contractionFallback(for typed: String) -> String? {
    guard typed.count >= 2, typed.count <= 10 else { return nil }
    let lowered = typed.lowercased()
    guard let mapped = unambiguousContractions[lowered] else { return nil }
    if mapped.first?.isUppercase == true {
      return mapped
    }
    if typed.first?.isUppercase == true, let first = mapped.first {
      return first.uppercased() + mapped.dropFirst()
    }
    return mapped
  }

  /// 光标前文本是否满足「单词字母/数字 + 单个空格」的双击空格变句号条件。
  static func canConvertDoubleSpaceToPeriod(beforeCursor: String?) -> Bool {
    guard let beforeCursor, beforeCursor.count >= 2, beforeCursor.hasSuffix(" ") else { return false }
    let previous = beforeCursor[beforeCursor.index(beforeCursor.endIndex, offsetBy: -2)]
    return previous.isASCII && (previous.isLetter || previous.isNumber)
  }

  /// 输入的标点是否应回贴并吃掉紧邻的自动尾随空格。
  static func pullsAcrossTrailingSpace(symbol: String, beforeCursor: String?) -> Bool {
    guard symbol.count == 1, let mark = symbol.first, pullbackPunctuation.contains(mark) else { return false }
    guard let beforeCursor, beforeCursor.count >= 2, beforeCursor.hasSuffix(" ") else { return false }
    let previous = beforeCursor[beforeCursor.index(beforeCursor.endIndex, offsetBy: -2)]
    return previous.isASCII && (previous.isLetter || previous.isNumber || previous == ")" || previous == "]" || previous == "\"" || previous == "'")
  }
}

/// 英文输入辅助的轻状态跟踪器（双击空格计时、双击句号一键退格撤回、自动空格后标点回贴）。
struct EnglishTypingAssistTracker: Equatable {
  private var lastSpaceTime: TimeInterval?
  private var lastSpaceDocument: UUID?
  private var doubleSpaceUndoDocument: UUID?
  private var autoTrailingSpaceDocument: UUID?

  /// 当前这一次英文空格是否命中双击空格变句号窗口。
  mutating func shouldTriggerDoubleSpacePeriod(
    now: TimeInterval,
    beforeCursor: String?,
    document: UUID?
  ) -> Bool {
    guard let lastTime = lastSpaceTime,
          lastSpaceDocument == document,
          now - lastTime >= 0,
          now - lastTime <= EnglishTypingAssistPolicy.doubleSpaceThreshold,
          EnglishTypingAssistPolicy.canConvertDoubleSpaceToPeriod(beforeCursor: beforeCursor) else {
      return false
    }
    lastSpaceTime = nil
    lastSpaceDocument = nil
    return true
  }

  /// 记录刚输入的单次英文空格（区分是否由选词/纠错自动附带尾空格）。
  mutating func recordSingleSpace(now: TimeInterval, document: UUID?, autoInserted: Bool) {
    lastSpaceTime = now
    lastSpaceDocument = document
    doubleSpaceUndoDocument = nil
    autoTrailingSpaceDocument = autoInserted ? document : nil
  }

  /// 记录刚完成一次双击空格转句号，供紧接着的 ⌫ 一键还原为单个空格。
  mutating func recordDoubleSpacePeriodApplied(document: UUID?) {
    lastSpaceTime = nil
    lastSpaceDocument = nil
    autoTrailingSpaceDocument = nil
    doubleSpaceUndoDocument = document
  }

  /// 紧接着的一次 ⌫ 是否应把双击空格生成的 `". "` 还原为 `" "`。
  mutating func consumeDoubleSpacePeriodUndo(beforeCursor: String?, document: UUID?) -> Bool {
    guard let undoDoc = doubleSpaceUndoDocument else { return false }
    doubleSpaceUndoDocument = nil
    guard undoDoc == document, beforeCursor?.hasSuffix(". ") == true else { return false }
    return true
  }

  /// 紧跟在自动尾空格后的标点是否应吃掉多余的尾空格再上屏。
  mutating func consumeAutoSpacePullback(
    for symbol: String,
    beforeCursor: String?,
    document: UUID?
  ) -> Bool {
    guard let spaceDoc = autoTrailingSpaceDocument else { return false }
    autoTrailingSpaceDocument = nil
    guard spaceDoc == document,
          EnglishTypingAssistPolicy.pullsAcrossTrailingSpace(symbol: symbol, beforeCursor: beforeCursor) else {
      return false
    }
    return true
  }

  mutating func clearAll() {
    lastSpaceTime = nil
    lastSpaceDocument = nil
    doubleSpaceUndoDocument = nil
    autoTrailingSpaceDocument = nil
  }
}
