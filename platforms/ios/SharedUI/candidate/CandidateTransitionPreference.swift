import Foundation

/// 候选栏词语切换动画样式。
///
/// 仅影响候选栏词块在候选内容变化时的视觉过渡，不改变按钮命中区域或排版布局；
/// 开启系统「减弱动态效果」时，带位移/缩放的样式自动柔化为 `fade`。
enum CandidateTransitionStyle: String, CaseIterable, Hashable, Sendable {
  case none
  case rise
  case drop
  case slide
  case scale
  case fade

  var title: String {
    switch self {
    case .none: return "关闭"
    case .rise: return "上升"
    case .drop: return "下落"
    case .slide: return "横移"
    case .scale: return "弹出"
    case .fade: return "淡入"
    }
  }

  /// 开启系统「减弱动态效果」时去掉空间位移与缩放，保留轻柔淡入；「关闭」保持关闭。
  func resolved(reduceMotion: Bool) -> CandidateTransitionStyle {
    guard self != .none else { return .none }
    return reduceMotion ? .fade : self
  }
}

/// 候选栏词语切换动画偏好（本机 App Group 存储，不覆盖桌面端共享配置）。
enum CandidateTransitionPreference {
  static let key = "candidate.transitionAnimation"
  static let defaultStyle: CandidateTransitionStyle = .rise

  static var defaults: UserDefaults {
    InputSchemePreference.appGroupDefaults
  }

  static var style: CandidateTransitionStyle {
    get { parse(defaults.string(forKey: key)) }
    set { defaults.set(newValue.rawValue, forKey: key) }
  }

  /// 解析存储的样式值；缺省或未知字符串回落到默认样式。
  static func parse(_ rawValue: String?) -> CandidateTransitionStyle {
    guard let rawValue, let parsed = CandidateTransitionStyle(rawValue: rawValue) else {
      return defaultStyle
    }
    return parsed
  }
}
