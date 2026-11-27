import Foundation

/// 触屏拼音组字的回删粒度：打开后，全拼 26 键与双拼 26 键的组字里单次 ⌫ 一次删掉最后一个完整拼音音节而不是单个字母（组字 `meiyou` 退一格变 `mei`）；关闭时按字母删。滑行与逐键打的字母同粒度，长按连删本来就按音节缩，打开后两者一致。九键、14/18 键和五笔等没有字母音节的方案不受影响。
///
/// 文档是唯一的权威来源（共享键 `touch_backspace_by_syllable`，client-core `Preferences` 的字段）。App Group 里的这份只是镜像，给键盘每次按键读数用，由读到文档的一方（设置页、键盘重载文档时）写入；缺字段或值不是布尔时按关，与 client-core 的缺省一致。
enum TouchBackspaceSyllablePreference {
  static let documentKey = "touch_backspace_by_syllable"
  static let appGroupKey = "backspaceBySyllable"
  /// 仅滑行输入的内容才按音节回删（本机 App Group 开关，默认关以保持既有一致粒度）。
  static let glideOnlyAppGroupKey = "backspaceBySyllableGlideOnly"

  static var isEnabled: Bool {
    get { InputSchemePreference.appGroupDefaults.bool(forKey: appGroupKey) }
    set { InputSchemePreference.appGroupDefaults.set(newValue, forKey: appGroupKey) }
  }

  /// 打开后仅当光标前待删内容来自滑行输入时才按音节回删，逐键点按的字母仍逐字母删除。
  static var glideOnly: Bool {
    get { InputSchemePreference.appGroupDefaults.bool(forKey: glideOnlyAppGroupKey) }
    set { InputSchemePreference.appGroupDefaults.set(newValue, forKey: glideOnlyAppGroupKey) }
  }

  /// 文档里记的开关；没有记过或值不是布尔时按关，与 client-core 的缺省一致。
  static func isEnabled(in document: [String: Any]?) -> Bool {
    document?[documentKey] as? Bool ?? false
  }

  /// 文档是权威来源；键盘和设置页读到文档后才更新 App Group 镜像。
  static func mirror(_ document: [String: Any]?) {
    guard document != nil else { return }
    isEnabled = isEnabled(in: document)
  }

  /// 与方案选择使用同一个 PreferencesStore 写入路径，避免只写 App Group 后被下一次会话重置。先写共享文档，写成功了再更新镜像；文档没写进去时返回 false，镜像保持原值。
  @discardableResult
  static func save(_ value: Bool, stateRoot: URL? = nil) -> Bool {
    guard MetasequoiaInputSessionBridge.updateSharedPreferences(stateRoot: stateRoot, {
      $0[documentKey] = value
    }) else { return false }
    isEnabled = value
    return true
  }
}
