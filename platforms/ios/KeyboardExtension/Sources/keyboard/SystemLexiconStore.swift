import UIKit

/// 读取并缓存 iOS 系统「设置 › 通用 › 键盘 › 文本替换（自定义短语）」词条（`UILexicon`）。
@MainActor
final class SystemLexiconStore {
  struct Entry: Equatable {
    let userInput: String
    let documentText: String
  }

  private(set) var entries: [Entry] = []

  /// 向系统请求最新的补充词典（含用户自定义短语）。
  func load(from controller: UIInputViewController) {
    controller.requestSupplementaryLexicon { [weak self] lexicon in
      let parsed = lexicon.entries.compactMap { item -> Entry? in
        let input = item.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = item.documentText
        guard !input.isEmpty, !text.isEmpty, input != text else { return nil }
        return Entry(userInput: input, documentText: text)
      }
      Task { @MainActor [weak self] in
        self?.entries = parsed
      }
    }
  }

  func setEntriesForTests(_ entries: [Entry]) {
    self.entries = entries
  }

  /// 按当前输入键码或拼音串匹配系统自定义短语（忽略大小写与拼音分词撇号 `'`）。
  func matches(forInput input: String, preedit: String = "") -> [String] {
    guard !entries.isEmpty else { return [] }
    let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedPreedit = preedit
      .replacingOccurrences(of: "'", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !normalizedInput.isEmpty || !normalizedPreedit.isEmpty else { return [] }

    var results: [String] = []
    var seen = Set<String>()
    for entry in entries {
      let key = entry.userInput.lowercased()
      guard key == normalizedInput || (!normalizedPreedit.isEmpty && key == normalizedPreedit) else {
        continue
      }
      if seen.insert(entry.documentText).inserted {
        results.append(entry.documentText)
      }
    }
    return results
  }
}
