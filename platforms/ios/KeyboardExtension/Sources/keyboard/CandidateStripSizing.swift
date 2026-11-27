import UIKit

/// 混合滑行中含英文的词块留出一个备选的位置；候选本身与选词身份保持完整。
@MainActor
enum CandidateStripSizing {
  static func apply(to button: KeyboardKeyButton, word: String, viewport: UIScrollView,
                    enabled: Bool, hasAlternatives: Bool, spacing: CGFloat = 6) {
    let limited: Bool
    if enabled && hasAlternatives {
      limited = word.utf8.contains { (65...90).contains($0) || (97...122).contains($0) }
    } else {
      limited = false
    }
    let targetCompression: UILayoutPriority = limited ? .defaultHigh : .required
    if button.contentCompressionResistancePriority(for: .horizontal) != targetCompression {
      button.setContentCompressionResistancePriority(targetCompression, for: .horizontal)
    }
    guard limited else {
      if let maximum = button.englishMaximumWidthConstraint, maximum.isActive {
        maximum.isActive = false
        if let fixed = button.constraints.first(where: { $0.identifier == "candidateChipWidth" }),
           fixed.priority != .init(999) {
          fixed.priority = .init(999)
        }
      }
      return
    }
    // 保留内容宽度作为低一档的偏好：短词不会逐字母换行，长词仍服从半行上限；不依赖首次显示前尚为零的视口宽度。
    if let fixed = button.constraints.first(where: { $0.identifier == "candidateChipWidth" }),
       fixed.priority != .init(998) {
      fixed.priority = .init(998)
    }
    let targetConstant = -spacing / 2
    if let maximum = button.englishMaximumWidthConstraint {
      if maximum.constant != targetConstant { maximum.constant = targetConstant }
      if !maximum.isActive { maximum.isActive = true }
    } else {
      let constraint = button.widthAnchor.constraint(lessThanOrEqualTo: viewport.widthAnchor, multiplier: 0.5, constant: targetConstant)
      constraint.identifier = "candidateEnglishMaximumWidth"
      constraint.priority = .init(999)
      constraint.isActive = true
      button.englishMaximumWidthConstraint = constraint
    }
  }
}
