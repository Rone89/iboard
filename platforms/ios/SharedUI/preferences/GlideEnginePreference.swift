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
  ///
  /// 词典只随键盘扩展打包（`glide-engine/` 文件夹引用）：扩展与测试宿主在
  /// 自己的包里就有；设置 App 没有这一份，查的是**内嵌键盘扩展**的包
  /// （与按键音效包、输入语言列表同一套读法）。两处都没有才算不可用。
  static var glidebeamAvailable: Bool {
    if let plugins = Bundle.main.builtInPlugInsURL,
       let contents = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
      let bundles = [Bundle.main] + contents.filter { $0.pathExtension == "appex" }.compactMap(Bundle.init(url:))
      return bundles.contains(where: Self.hasDictionaries)
    }
    return Self.hasDictionaries(Bundle.main)
  }

  /// 词典三件套是匹配集，三个文件齐才算可用；缺任何一个都按不可用。
  private static func hasDictionaries(_ bundle: Bundle) -> Bool {
    bundle.url(forResource: "pinyin", withExtension: "wmcd", subdirectory: "glide-engine") != nil
      && bundle.url(forResource: "ngrams", withExtension: "wmcn", subdirectory: "glide-engine") != nil
      && bundle.url(forResource: "glide", withExtension: "wmdict", subdirectory: "glide-engine") != nil
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
