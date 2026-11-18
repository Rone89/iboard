import Foundation

/// 「滑行引擎」：全拼 26 键滑行时把轨迹交给哪个解码器。`msime`（默认）走共享
/// C ABI 的 `msime_client_glide`，由水杉引擎解码；`glidebeam` 走自 GlideKeyboard
/// （MIT）移植的 GlideBeam——它把轨迹解成拼音读音，再逐字母喂进同一个会话
/// 组字，候选栏、词库与学习保持会话原样。只存本机 App Group，不进共享文档，
/// 也不随设置同步（与滑行开关 `keyboard.gesture.glide` 同一口径）。
enum GlideEngineChoice: String, CaseIterable {
  case msime
  case glidebeam

  var title: String {
    switch self {
    case .msime: return "水杉引擎"
    case .glidebeam: return "GlideBeam"
    }
  }

  /// 键盘没暂存词典时 GlideBeam 不可用：设置页隐藏该选项，已存的值照常读回、
  /// 键盘运行时静默回退（`KeyboardViewController.typeGlideWithGlideBeam`）。
  static var glidebeamAvailable: Bool {
    Bundle.main.url(forResource: "pinyin", withExtension: "wmcd", subdirectory: "glide-engine") != nil
      && Bundle.main.url(forResource: "ngrams", withExtension: "wmcn", subdirectory: "glide-engine") != nil
      && Bundle.main.url(forResource: "glide", withExtension: "wmdict", subdirectory: "glide-engine") != nil
  }
}

enum GlideEnginePreference {
  static let key = "keyboard.glideEngine"
  static var defaults: UserDefaults { InputSchemePreference.appGroupDefaults }

  static var choice: GlideEngineChoice {
    get { defaults.string(forKey: key).flatMap(GlideEngineChoice.init(rawValue:)) ?? .msime }
    set { defaults.set(newValue.rawValue, forKey: key) }
  }
}
