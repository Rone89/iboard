import CoreHaptics
import QuartzCore
import UIKit

/// 基于 `CoreHaptics`（Taptic Engine）的分键型细腻震动引擎：
/// - 「跟随系统」继续走原生 `UIImpactFeedbackGenerator`；
/// - 「轻 / 中 / 强」按按键类别（普通字母、空格、回车、退格、起滑）使用不同的 `intensity`（强度）与 `sharpness`（清脆度）波形，其中「强」档字母键采用双脉冲模拟机械轴体段落与触底感；
/// - 预编译并缓存 `CHHapticPatternPlayer`，按键热路径零分配，并带 `12ms` 防抖冷却门控；
/// - 设 `playsHapticsOnly = true` 与 `isAutoShutdownEnabled = true`，不打断背景音乐、空闲自动休眠；设备不支持或引擎异常时自动回退原生 `UIImpactFeedbackGenerator`。
@MainActor
final class KeyboardHapticsEngine {
  struct Pulse: Equatable {
    let relativeTime: TimeInterval
    let intensity: Float
    let sharpness: Float
  }

  enum EventKind: Hashable {
    case key(KeySoundClass)
    case glideStart
  }

  private struct CacheKey: Hashable {
    let strength: KeyboardHapticStrength
    let event: EventKind
  }

  /// 连续触发的最小冷却间隔，防止极快连触或重复回调把 Taptic Engine 糊成一团。
  static let minimumCooldown: TimeInterval = 0.012

  /// 按强度档位与按键类别返回调教好的马达脉冲表；`.system` 返回空数组表示交由系统 `UIImpactFeedbackGenerator`。
  static func pulses(for strength: KeyboardHapticStrength, event: EventKind) -> [Pulse] {
    switch (strength, event) {
    case (.system, _):
      return []
    case (.light, .key(.standard)):
      return [Pulse(relativeTime: 0, intensity: 0.42, sharpness: 0.85)]
    case (.light, .key(.space)), (.light, .key(.enter)):
      return [Pulse(relativeTime: 0, intensity: 0.52, sharpness: 0.55)]
    case (.light, .key(.backspace)):
      return [Pulse(relativeTime: 0, intensity: 0.38, sharpness: 0.90)]
    case (.light, .glideStart):
      return [Pulse(relativeTime: 0, intensity: 0.30, sharpness: 0.75)]

    case (.medium, .key(.standard)):
      return [Pulse(relativeTime: 0, intensity: 0.62, sharpness: 0.78)]
    case (.medium, .key(.space)), (.medium, .key(.enter)):
      return [Pulse(relativeTime: 0, intensity: 0.76, sharpness: 0.45)]
    case (.medium, .key(.backspace)):
      return [Pulse(relativeTime: 0, intensity: 0.56, sharpness: 0.85)]
    case (.medium, .glideStart):
      return [Pulse(relativeTime: 0, intensity: 0.40, sharpness: 0.75)]

    case (.strong, .key(.standard)):
      // 双脉冲：先一声高锐度触发点，12ms 后叠加略低沉的触底回弹，模拟机械段落轴。
      return [
        Pulse(relativeTime: 0, intensity: 0.82, sharpness: 0.85),
        Pulse(relativeTime: 0.012, intensity: 0.42, sharpness: 0.35),
      ]
    case (.strong, .key(.space)), (.strong, .key(.enter)):
      return [Pulse(relativeTime: 0, intensity: 0.95, sharpness: 0.35)]
    case (.strong, .key(.backspace)):
      return [Pulse(relativeTime: 0, intensity: 0.78, sharpness: 0.80)]
    case (.strong, .glideStart):
      return [Pulse(relativeTime: 0, intensity: 0.50, sharpness: 0.75)]
    }
  }

  /// 距上次触发超过 `minimumCooldown` 时才放行；单测可直接校验门控逻辑。
  static func allowsTrigger(now: TimeInterval, last: TimeInterval, cooldown: TimeInterval = minimumCooldown) -> Bool {
    now - last >= cooldown
  }

  private let supportsCoreHaptics: Bool
  private var engine: CHHapticEngine?
  private var engineRunning = false
  private var players: [CacheKey: CHHapticPatternPlayer] = [:]
  private var lastTriggerTime: TimeInterval = -.infinity

  init(supportsCoreHaptics: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics) {
    self.supportsCoreHaptics = supportsCoreHaptics
  }

  /// 触发一次分键型马达震动；返回 `true` 表示已由 `CoreHaptics` 成功播放，`false` 时调用方回退 `UIImpactFeedbackGenerator`。
  @discardableResult
  func play(strength: KeyboardHapticStrength, event: EventKind, now: TimeInterval = CACurrentMediaTime()) -> Bool {
    guard supportsCoreHaptics, strength != .system else { return false }
    guard Self.allowsTrigger(now: now, last: lastTriggerTime) else { return true }
    let pulses = Self.pulses(for: strength, event: event)
    guard !pulses.isEmpty else { return false }
    guard ensureStarted(), let player = cachedPlayer(for: CacheKey(strength: strength, event: event), pulses: pulses) else {
      return false
    }
    do {
      try player.start(atTime: CHHapticTimeImmediate)
      lastTriggerTime = now
      return true
    } catch {
      engineRunning = false
      players.removeAll(keepingCapacity: true)
      return false
    }
  }

  /// 键盘收起或收到内存警告时停掉引擎并清掉缓存播放器，下次按下按需重建。
  func stop() {
    players.removeAll(keepingCapacity: false)
    if engineRunning {
      engine?.stop(completionHandler: nil)
      engineRunning = false
    }
  }

  private func ensureStarted() -> Bool {
    if engine == nil {
      do {
        let created = try CHHapticEngine()
        created.playsHapticsOnly = true
        created.isAutoShutdownEnabled = true
        created.stoppedHandler = { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.engineRunning = false
            self?.players.removeAll(keepingCapacity: true)
          }
        }
        created.resetHandler = { [weak self] in
          Task { @MainActor [weak self] in
            self?.engineRunning = false
            self?.players.removeAll(keepingCapacity: true)
          }
        }
        engine = created
      } catch {
        return false
      }
    }
    guard let engine else { return false }
    if !engineRunning {
      do {
        try engine.start()
        engineRunning = true
      } catch {
        engineRunning = false
        return false
      }
    }
    return true
  }

  private func cachedPlayer(for key: CacheKey, pulses: [Pulse]) -> CHHapticPatternPlayer? {
    if let existing = players[key] { return existing }
    guard let engine else { return nil }
    do {
      let events = pulses.map { pulse in
        CHHapticEvent(
          eventType: .hapticTransient,
          parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness),
          ],
          relativeTime: pulse.relativeTime
        )
      }
      let pattern = try CHHapticPattern(events: events, parameters: [])
      let player = try engine.makePlayer(with: pattern)
      players[key] = player
      return player
    } catch {
      return nil
    }
  }
}
