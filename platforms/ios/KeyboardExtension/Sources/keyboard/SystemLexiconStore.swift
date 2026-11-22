import UIKit

/// 读取并缓存 iOS 系统「设置 › 通用 › 键盘 › 文本替换（自定义短语）」词条（`UILexicon`）。
@MainActor
final class SystemLexiconStore {
  struct Entry: Equatable {
    let userInput: String
    let documentText: String
  }

  private(set) var entries: [Entry] = [] {
    didSet { rebuildIndex() }
  }
  /// 按小写快捷词预建索引，将每次按键时的线性扫描降为 O(1) 哈希查询。
  private var indexByLowercasedInput: [String: [String]] = [:]

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

  private func rebuildIndex() {
    guard !entries.isEmpty else {
      indexByLowercasedInput = [:]
      return
    }
    var index: [String: [String]] = [:]
    index.reserveCapacity(entries.count)
    for entry in entries {
      let key = entry.userInput.lowercased()
      var list = index[key] ?? []
      if !list.contains(entry.documentText) {
        list.append(entry.documentText)
        index[key] = list
      }
    }
    indexByLowercasedInput = index
  }

  /// 按当前输入键码或拼音串匹配系统自定义短语（忽略大小写与拼音分词撇号 `'`）。
  func matches(forInput input: String, preedit: String = "") -> [String] {
    guard !indexByLowercasedInput.isEmpty else { return [] }
    let normalizedInput = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedPreedit = preedit
      .replacingOccurrences(of: "'", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !normalizedInput.isEmpty || !normalizedPreedit.isEmpty else { return [] }

    let inputHits = normalizedInput.isEmpty ? nil : indexByLowercasedInput[normalizedInput]
    let preeditHits = (normalizedPreedit.isEmpty || normalizedPreedit == normalizedInput)
      ? nil : indexByLowercasedInput[normalizedPreedit]
    switch (inputHits, preeditHits) {
    case (nil, nil):
      return []
    case (let hits?, nil), (nil, let hits?):
      return hits
    case (let first?, let second?):
      var results = first
      var seen = Set(first)
      for text in second where seen.insert(text).inserted {
        results.append(text)
      }
      return results
    }
  }
}
