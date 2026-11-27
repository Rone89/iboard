import CoreGraphics
import Foundation

/// 滑行输入（#5347）里与 UIKit 无关的那部分：一次触摸什么时候算滑行，以及抬手时交给 `msime_client_glide` 的请求怎么拼。
///
/// 所有坐标都在同一个键区坐标系里（键盘用 `KeyAreaStackView` 的坐标），`frames` 是 a..z 二十六个字母键按字母顺序排列的布局矩形。判断是不是滑行完全由宿主决定，Engine 只负责把这一笔解码成全拼字母；Android 和 HarmonyOS 用的是同一套规则。
enum GlideTyping {
  /// 一个触摸采样：键区坐标里的位置，以及从按下那一刻起经过的毫秒数。Engine 用时间认出手指在某个键上的停留。
  struct Sample: Equatable {
    var x: CGFloat
    var y: CGFloat
    var milliseconds: Double
  }

  static let letters = Array("abcdefghijklmnopqrstuvwxyz")
  /// 预计算的 `a..z` ASCII 码点数组，避免每次 85ms 实时预览与抬手解码重复分配。
  static let letterCodes: [UInt32] = letters.compactMap(\.asciiValue).map(UInt32.init)
  /// 九键 2–9 数字键对应的 `a..z` 下标分组：复用 26 槽 `GlideKeyboard` 协议，无需修改 FFI。
  static let nineKeyLetterGroups: [(digit: Int, indices: [Int])] = [
    (2, [0, 1, 2]),
    (3, [3, 4, 5]),
    (4, [6, 7, 8]),
    (5, [9, 10, 11]),
    (6, [12, 13, 14]),
    (7, [15, 16, 17, 18]),
    (8, [19, 20, 21]),
    (9, [22, 23, 24, 25]),
  ]

  /// 九键数字键 `2...9` 在 26 槽字母数组里的代表下标（每个分组的首字母下标，与 `keyIndex(at:in:)` 命中一致）。
  static func nineKeyRepresentativeIndex(forDigit digit: Int) -> Int? {
    nineKeyLetterGroups.first { $0.digit == digit }?.indices.first
  }

  /// 由 26 槽下标反查对应的九键数字（2–9）。
  static func nineKeyDigit(forIndex index: Int) -> Int? {
    nineKeyLetterGroups.first { $0.indices.contains(index) }?.digit
  }

  /// 判断 26 槽布局矩形是否来自九键 2–9 展开（同一 T9 分组内的字母共享相同矩形）。
  static func isNineKeyFrames(_ frames: [CGRect]) -> Bool {
    guard frames.count == letters.count else { return false }
    for group in nineKeyLetterGroups {
      guard let first = group.indices.first, !frames[first].isEmpty else { return false }
      let ref = frames[first]
      for idx in group.indices.dropFirst() {
        let rect = frames[idx]
        if abs(rect.midX - ref.midX) > 0.5 || abs(rect.midY - ref.midY) > 0.5 {
          return false
        }
      }
    }
    return true
  }

  /// 把九键 2–9 八个数字键的布局矩形按 T9 字母归属展开成 26 槽矩形数组；缺任一键或为空时返回空数组。
  static func nineKeyFrames(from digitFrames: [Int: CGRect]) -> [CGRect] {
    var result = Array(repeating: CGRect.zero, count: letters.count)
    for group in nineKeyLetterGroups {
      guard let rect = digitFrames[group.digit], !rect.isEmpty else { return [] }
      for index in group.indices {
        result[index] = rect
      }
    }
    return result
  }
  /// `msime_client_glide` 一次最多接受的采样点数。
  static let pointLimit = 1_024
  /// 手指尚未跨到另一枚键时也限制内存；抬手时还会再抽稀到 `pointLimit`。
  static let sampleBufferLimit = 4_096
  /// `msime_client_glide` 接受的请求最大字节数。
  static let requestByteLimit = 65_536
  /// 九键滑行常态起滑比例（按 `min(键宽, 键高)` 算，约 20.6pt），保障宽扁键位短距竖滑流畅。
  static let horizontalThreshold: CGFloat = 0.42
  /// 九键主动快滑（速度 >= `nineKeyFastVelocity` 且非连打/非键缝）时的即时起滑比例（约 17.6pt）。
  static let nineKeyFastStartThreshold: CGFloat = 0.36
  /// 判定九键主动快滑的最小初速度阈值（pt/s）。
  static let nineKeyFastVelocity: CGFloat = 320
  /// 九键起手落在键缝吸附时的起滑比例（约 27pt），防止键缝点按回正误起滑行。
  static let nineKeyGapStartThreshold: CGFloat = 0.55
  /// 九键连续点按节律（240ms 内刚敲过数字键）下的起滑比例（约 30.4pt），防止快打蹭边抢走普通点按。
  static let nineKeyRapidTypingThreshold: CGFloat = 0.62
  /// 26 键正常起滑距离（键宽倍数，iPhone 上约 25–27pt，显著高于普通点按拇指滚滑幅度，仍远小于相邻键中心距 ~1.18 倍键宽）。
  static let twentySixKeyStartThreshold: CGFloat = 0.72
  /// 26 键主动快滑（速度 >= `twentySixKeyFastVelocity` 且非连打/非键缝/无同向角标冲突）时的即时起滑距离（键宽倍数），让蓄意滑行与原生 iOS QuickPath 一样零迟滞出轨迹。
  static let twentySixKeyFastStartThreshold: CGFloat = 0.56
  /// 判定 26 键主动快滑的最小初速度阈值（pt/s）。
  static let twentySixKeyFastVelocity: CGFloat = 360
  /// 26 键起手落在键缝吸附时的起滑距离（键宽倍数），防止键缝点按回正到目标键时误起滑行。
  static let twentySixKeyGapStartThreshold: CGFloat = 0.85
  /// 26 键连续点按节律（240ms 内刚敲过字母）下的起滑距离（键宽倍数），避免快打轻微蹭边抢走普通点按。
  static let twentySixKeyRapidTypingThreshold: CGFloat = 0.95
  /// 26 键开启同向角标纵滑时，逃逸为横向滑行所需的最小横向键宽倍数。
  static let twentySixKeyCornerGuardHorizontalThreshold: CGFloat = 0.78
  /// 26 键起手键缝吸附容差（pt）：仅覆盖相邻字母键 6pt 键缝的一半，不越界吸附空格/功能行边缘。
  static let twentySixKeyGapPadding: CGFloat = 4
  /// 26 键连续点按节律保护窗口（秒）。
  static let rapidTypingWindow: TimeInterval = 0.24

  /// `point` 落在哪个字母键的布局矩形里；落在键距里或键区外时为 nil。空矩形（隐藏的键）不参与。
  static func keyIndex(at point: CGPoint, in frames: [CGRect]) -> Int? {
    frames.firstIndex { !$0.isEmpty && $0.contains(point) }
  }

  /// 拇指起手偶尔落在两枚字母键之间的键缝时，在 `maxGapPadding` 容差内吸附到中心最近的字母键，减少起滑断触。
  /// 若点已经严格落在某枚键内，直接返回该键；若超出键缝容差（如点到空格/底部功能区），返回 nil。
  static func nearestKeyIndex(at point: CGPoint, in frames: [CGRect], maxGapPadding: CGFloat = 10) -> Int? {
    if let exact = keyIndex(at: point, in: frames) { return exact }
    var bestIndex: Int?
    var bestDistanceSquared = CGFloat.greatestFiniteMagnitude
    for (index, frame) in frames.enumerated() where !frame.isEmpty {
      guard frame.insetBy(dx: -maxGapPadding, dy: -maxGapPadding).contains(point) else { continue }
      let dx = point.x - frame.midX
      let dy = point.y - frame.midY
      let distSq = dx * dx + dy * dy
      if distSq < bestDistanceSquared {
        bestDistanceSquared = distSq
        bestIndex = index
      }
    }
    return bestIndex
  }

  /// 过滤起手最初 18ms 内拇指指腹压下滚动产生的短距反向初抖，以及抬手最后 24ms（120Hz 3 帧）内拇指离屏产生的反向回勾。
  /// 仅作用于包含有效时间戳且总时长 >= 80ms 的真实手势采样，对正常平滑笔画保持原样，同时惠及 GlideBeam 与内置引擎。
  static func trimmedLiftoffHook(_ samples: [Sample], frames: [CGRect]) -> [Sample] {
    let nineKey = isNineKeyFrames(frames)
    guard samples.count >= 6,
          let first = samples.first, let last = samples.last,
          last.milliseconds - first.milliseconds >= 80,
          let refSpan = frames.filter({ !$0.isEmpty }).map({ nineKey ? min($0.width, $0.height) : $0.width }).min(),
          refSpan > 0 else {
      return samples
    }
    let maxStartHookLength = refSpan * 0.35
    let maxTailHookLength = refSpan * 0.48
    let minAnchorSpan = refSpan * 0.25

    var start = 0
    for _ in 0..<2 {
      guard samples.count - start >= 6 else { break }
      let head = samples[start]
      let next = samples[start + 1]
      guard next.milliseconds - first.milliseconds <= 18,
            next.milliseconds - head.milliseconds <= 18 else { break }
      let hx = next.x - head.x
      let hy = next.y - head.y
      let headLen = hypot(hx, hy)
      guard headLen > 0.5, headLen <= maxStartHookLength else { break }
      var anchor = start + 1
      while anchor + 1 < samples.count
        && hypot(samples[anchor].x - next.x, samples[anchor].y - next.y) < minAnchorSpan {
        anchor += 1
      }
      let dx = samples[anchor].x - next.x
      let dy = samples[anchor].y - next.y
      let depLen = hypot(dx, dy)
      guard depLen > 0.5 else { break }
      let cosAngle = (hx * dx + hy * dy) / (headLen * depLen)
      if cosAngle < -0.45 {
        start += 1
      } else {
        break
      }
    }

    var end = samples.count
    for _ in 0..<3 {
      guard end - start >= 5 else { break }
      let tail = samples[end - 1]
      let prev = samples[end - 2]
      guard last.milliseconds - prev.milliseconds <= 24,
            tail.milliseconds - prev.milliseconds <= 20 else { break }
      let tx = tail.x - prev.x
      let ty = tail.y - prev.y
      let tailLen = hypot(tx, ty)
      guard tailLen > 0.5, tailLen <= maxTailHookLength else { break }
      var anchor = end - 2
      while anchor > start && hypot(prev.x - samples[anchor].x, prev.y - samples[anchor].y) < minAnchorSpan {
        anchor -= 1
      }
      let px = prev.x - samples[anchor].x
      let py = prev.y - samples[anchor].y
      let prevLen = hypot(px, py)
      guard prevLen > 0.5 else { break }
      let cosAngle = (tx * px + ty * py) / (tailLen * prevLen)
      if cosAngle < -0.38 {
        end -= 1
      } else {
        break
      }
    }
    return (start == 0 && end == samples.count) ? samples : Array(samples[start..<end])
  }

  /// 在 `downKey` 上按下、从 `down` 移到 `current` 的一根手指是否开始滑行：手指此刻在另一个字母键上，且满足位移与防误触门槛。
  /// - 九键按 `min(键宽, 键高)` 区分常态（`0.42`）、主动快滑（`0.36`）、键缝起手（`0.55`）与连打节律（`0.62`），并对短距跨键施加轻度目标键内缩过滤 1–4pt 边缘蹭键，兼顾短距竖滑跟手与快打防误触；
  /// - 26 键提高起滑距离（常态 `0.72`、键缝起手 `0.85`、连打节律 `0.95` 倍键宽），短距跨键时要求进入目标键内部（避开贴边 1–3pt 蹭键误触），同向角标保护时要求横向明显占优，防止斜滑角标被误抢。
  static func startsGlide(downKey: Int, down: CGPoint, current: CGPoint, frames: [CGRect],
                          allowsVerticalGlide: Bool = true,
                          rapidTyping: Bool = false,
                          startedInGap: Bool = false,
                          velocity: CGFloat = 0) -> Bool {
    guard frames.indices.contains(downKey), !frames[downKey].isEmpty,
          let key = keyIndex(at: current, in: frames), key != downKey else { return false }
    let dx = abs(current.x - down.x)
    let dy = abs(current.y - down.y)
    let rect = frames[downKey]
    let targetRect = frames[key]
    let distance = hypot(dx, dy)
    if isNineKeyFrames(frames) {
      let minSide = min(rect.width, rect.height)
      let fastDeliberateSwipe = !rapidTyping && !startedInGap && allowsVerticalGlide
        && velocity.isFinite && velocity >= nineKeyFastVelocity
      let thresholdRatio: CGFloat
      if rapidTyping {
        thresholdRatio = nineKeyRapidTypingThreshold
      } else if startedInGap {
        thresholdRatio = nineKeyGapStartThreshold
      } else if fastDeliberateSwipe {
        thresholdRatio = nineKeyFastStartThreshold
      } else {
        thresholdRatio = horizontalThreshold
      }
      let insetRatioX: CGFloat = fastDeliberateSwipe ? 0.05 : 0.08
      let insetRatioY: CGFloat = fastDeliberateSwipe ? 0.06 : 0.10
      let coreInsetX = min(targetRect.width * insetRatioX, 5)
      let coreInsetY = min(targetRect.height * insetRatioY, 5)
      let enteredTargetCore = distance >= minSide * 0.85
        || targetRect.insetBy(dx: coreInsetX, dy: coreInsetY).contains(current)
      guard enteredTargetCore else { return false }
      if allowsVerticalGlide {
        return distance >= minSide * thresholdRatio
      }
      return dx >= rect.width * thresholdRatio || dy >= rect.height * 1.45
    }
    let fastDeliberateSwipe = !rapidTyping && !startedInGap && allowsVerticalGlide
      && velocity.isFinite && velocity >= twentySixKeyFastVelocity
    let thresholdRatio: CGFloat
    if rapidTyping {
      thresholdRatio = twentySixKeyRapidTypingThreshold
    } else if startedInGap {
      thresholdRatio = twentySixKeyGapStartThreshold
    } else if fastDeliberateSwipe {
      thresholdRatio = twentySixKeyFastStartThreshold
    } else {
      thresholdRatio = twentySixKeyStartThreshold
    }
    let minDistance = rect.width * thresholdRatio
    // 短距跨入邻键时，慢速滚滑要求进入目标键内部（16% 内缩）过滤贴边蹭键；主动快滑放宽至 8% 内缩保证出轨跟手。
    let insetRatioX: CGFloat = fastDeliberateSwipe ? 0.08 : 0.16
    let insetRatioY: CGFloat = fastDeliberateSwipe ? 0.08 : 0.14
    let coreInsetX = min(targetRect.width * insetRatioX, 6)
    let coreInsetY = min(targetRect.height * insetRatioY, 6)
    let enteredTargetCore = distance >= rect.width * 1.05
      || targetRect.insetBy(dx: coreInsetX, dy: coreInsetY).contains(current)
    guard enteredTargetCore else { return false }
    if allowsVerticalGlide {
      return distance >= minDistance
    }
    let guardedHorizontal = max(minDistance, rect.width * twentySixKeyCornerGuardHorizontalThreshold)
    return (dx >= guardedHorizontal && dx >= dy * 0.85) || dy >= rect.height * 1.45
  }

  /// 抬手前的超短误滑兜底：过滤极短瞬时蹭键，不提交给滑行解码器。
  /// - 26 键：总时长 < 65ms、起止净位移 < 0.85 倍键宽且累计路径 < 1.15 倍键宽；
  /// - 九键（保守阈值，绝不拦正常 `7→4` 56pt 快速竖滑）：总时长 < 55ms、净位移 < 0.55 倍键短边（~27pt）且累计路径 < 0.72 倍键短边（~35pt）。
  static func isAccidentalShortSlip(samples: [Sample], frames: [CGRect], pathLength: CGFloat) -> Bool {
    guard let first = samples.first, let last = samples.last else {
      return false
    }
    let elapsed = last.milliseconds - first.milliseconds
    let netDistance = hypot(last.x - first.x, last.y - first.y)
    if isNineKeyFrames(frames) {
      guard let minSide = frames.filter({ !$0.isEmpty }).map({ min($0.width, $0.height) }).min(),
            minSide > 0, elapsed < 55 else {
        return false
      }
      return netDistance < minSide * 0.55 && pathLength < minSide * 0.72
    }
    guard let minWidth = frames.filter({ !$0.isEmpty }).map(\.width).min(), minWidth > 0,
          elapsed < 65 else {
      return false
    }
    return netDistance < minWidth * 0.85 && pathLength < minWidth * 1.15
  }

  /// 均匀抽取至多 `limit` 个采样，第一个和最后一个总是保留；不超过上限时原样返回。
  static func downsampled<Element>(_ samples: [Element], limit: Int = pointLimit) -> [Element] {
    guard limit >= 2, samples.count > limit else { return samples }
    let last = samples.count - 1
    return (0..<limit).map { samples[$0 * last / (limit - 1)] }
  }

  /// 追加一个触摸采样，同时限制尚未结束的手势占用的数组大小。
  static func appendBounded(_ sample: Sample, to samples: inout [Sample]) {
    if samples.count >= sampleBufferLimit {
      samples = downsampled(samples, limit: sampleBufferLimit / 2)
    }
    samples.append(sample)
  }

  /// `msime_client_glide` 的请求 JSON：`keys` 是 a..z 各键的中心，`key_width`/`key_height` 是一个字母键的大小（取二十六个键里最小的宽和高），`points` 是至多 `pointLimit` 个 `[x, y, ms]`；可选附带 `readings`（外部滑行引擎预解出的纯小写拼音候选列表）。坐标保留一位小数、时间取整毫秒，请求因此远小于 `requestByteLimit`。键不全、采样不足两个或有非有限值时为 nil。
  static func request(frames: [CGRect], samples: [Sample], bilingual: Bool = false, readings: [String] = [], preview: Bool = false) -> Data? {
    guard frames.count == letters.count, samples.count >= 2,
          frames.allSatisfy({ !$0.isEmpty && $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite }),
          samples.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.milliseconds.isFinite }),
          let width = frames.map(\.width).min(), let height = frames.map(\.height).min(),
          width > 0, height > 0 else { return nil }
    let keys = frames.map { "[\(number($0.midX)),\(number($0.midY))]" }.joined(separator: ",")
    let points = downsampled(samples).map { sample in
      "[\(number(sample.x)),\(number(sample.y)),\(milliseconds(sample.milliseconds))]"
    }.joined(separator: ",")
    var payload = "{\"keys\":[\(keys)],\"key_width\":\(number(width)),\"key_height\":\(number(height)),\"points\":[\(points)]"
    if bilingual {
      payload += ",\"bilingual\":true"
    }
    if preview {
      payload += ",\"preview\":true"
    }
    let validReadings = Array(readings.filter {
      !$0.isEmpty && $0.count <= 30 && $0.utf8.allSatisfy { (97...122).contains($0) }
    }.prefix(16))
    if !validReadings.isEmpty {
      let encoded = validReadings.map { "\"\($0)\"" }.joined(separator: ",")
      payload += ",\"readings\":[\(encoded)]"
    }
    payload += "}"
    let data = Data(payload.utf8)
    return data.count <= requestByteLimit ? data : nil
  }

  private static func number(_ value: CGFloat) -> String {
    String(format: "%.1f", Double(value))
  }

  private static func milliseconds(_ value: Double) -> UInt32 {
    UInt32(min(max(value, 0), Double(UInt32.max)).rounded())
  }
}
