import Foundation
import CoreGraphics

#if GLIDE_ENGINE_LINKED

/// GlideBeam 滑行引擎（自 GlideKeyboard，MIT，Copyright (c) 2026 GlideKeyboard
/// contributors 移植进 iBoard，GPLv3）：静态库 `libglide_ios_bridge.a` 由
/// stage-glide-engine.sh 从 GlideKeyboard 构建产物暂存（SHA-256 锁在脚本里），
/// C ABI 见其 `Rust/ios-bridge/include/glide_keyboard.h`。
///
/// 职责只有一段：把滑行轨迹解成拼音读音。读音交给 `KeyboardViewController`
/// 逐字母喂进水杉会话组字——候选、词库与学习全部保持会话原样，本结构不做
/// 转换、不上屏。词典三件套是匹配集（`pinyin.wmcd` / `ngrams.wmcn` /
/// `glide.wmdict`，同批源数据生成），在扩展包的 `glide-engine/` 里。
///
/// 句柄纪律（头文件的约定）：句柄是受检令牌；`decode`/`candidate` 之类的
/// 多调用事务由调用方串行——本类把加载、键位注册与解码全部排进一条串行
/// 队列。加载是幂等的；加载完成前 `decodeReading` 返回 nil，调用点回退到
/// 水杉引擎的滑行。
final class GlideBeamEngine {
  static let shared = GlideBeamEngine()

  private let queue = DispatchQueue(label: "keyboard.glideBeamEngine", qos: .userInitiated)
  private let readyLock = NSLock()
  private var loadedReady = false
  private var handle: OpaquePointer?
  private var lastRegisteredKeys: [GKKeyC] = []
  private var lastRegisteredWidth: Float = 0

  /// 词典是否已加载完。用独立锁读取，避免后台正在加载时阻塞主线程。
  var isReady: Bool {
    readyLock.lock()
    defer { readyLock.unlock() }
    return loadedReady
  }

  /// 键盘出现或滑行起手时调用：选择 GlideBeam 的用户第一次滑行前预热词典。
  /// 幂等；重复调用不重复加载。
  func prepare() {
    queue.async { self.loadIfNeeded() }
  }

  /// 测试与诊断用：同步加载完再返回。
  func prepareAndWait() {
    queue.sync { loadIfNeeded() }
  }

  /// 收到系统内存警告、关闭滑行输入或扩展即将挂起时，异步释放已加载的 GlideBeam 词典句柄；
  /// 释放后 `isReady` 立即置为 `false`，下次用户起滑或再次 `prepare()` 时自动按需重建，避免常驻词典把扩展推向 Jetsam 上限。
  func releaseForMemoryPressure(completion: (@Sendable () -> Void)? = nil) {
    readyLock.lock()
    loadedReady = false
    readyLock.unlock()
    queue.async { [weak self] in
      self?.freeHandleLocked()
      completion?()
    }
  }

  /// 同步释放句柄（供扩展挂起前限时清理与单测使用）。
  func releaseForMemoryPressureSync() {
    readyLock.lock()
    loadedReady = false
    readyLock.unlock()
    queue.sync {
      freeHandleLocked()
    }
  }

  private func freeHandleLocked() {
    if let existing = handle {
      gkEngineFree(existing)
      handle = nil
    }
    lastRegisteredKeys = []
    lastRegisteredWidth = 0
    lastDecodeDiagnostics = nil
    readyLock.lock()
    loadedReady = false
    readyLock.unlock()
  }

  /// 轨迹 → 拼音读音（首选，纯小写字母；解不出时为 nil）。
  ///
  /// - Parameters:
  ///   - samples: 手势记录的采样（点坐标、毫秒），坐标系与 `frames` 相同。
  ///   - letters: 键位码点（a…z 的 ASCII），与 `frames` 一一对应。
  ///   - frames: 26 个字母键在手势视图里的布局矩形；中心与键宽注册给引擎，
  ///     几何没变时不重发。
  /// 最近一次解码的分步结果（键位注册、候选数、首选候选字节量），测试与诊断读。
  private(set) var lastDecodeDiagnostics: (keysResult: Int32, decodeCount: Int32, candidateSize: Int32)?

  func decodeReading(samples: [GlideTyping.Sample], letters: [UInt32], frames: [CGRect]) -> String? {
    decodeReadings(samples: samples, letters: letters, frames: frames, limit: 1).first
  }

  /// 轨迹 → 至多 `limit` 条按分数排序的拼音读音候选（去重、纯小写字母）。
  func decodeReadings(samples: [GlideTyping.Sample], letters: [UInt32], frames: [CGRect], limit: Int = 5) -> [String] {
    queue.sync {
      decodeReadingsLocked(samples: samples, letters: letters, frames: frames, limit: limit)
    }
  }

  /// 异步解码：不阻塞主线程，完成后在主线程回调多条读音候选。
  func decodeReadingsAsync(
    samples: [GlideTyping.Sample],
    letters: [UInt32],
    frames: [CGRect],
    limit: Int = 5,
    completion: @escaping @MainActor ([String]) -> Void
  ) {
    queue.async { [weak self] in
      let readings = self?.decodeReadingsLocked(samples: samples, letters: letters, frames: frames, limit: limit) ?? []
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          completion(readings)
        }
      }
    }
  }

  private func decodeReadingsLocked(samples: [GlideTyping.Sample], letters: [UInt32], frames: [CGRect], limit: Int) -> [String] {
    guard let handle, letters.count == frames.count, frames.count >= 20, limit >= 1 else { return [] }
    var keys = [GKKeyC]()
    keys.reserveCapacity(letters.count)
    var width = Float(0)
    var isSorted = true
    var previousLetter: UInt32 = 0
    for index in 0..<letters.count {
      let letter = letters[index]
      let frame = frames[index]
      if index > 0 && letter < previousLetter { isSorted = false }
      previousLetter = letter
      keys.append(GKKeyC(codepoint: letter, x: Float(frame.midX), y: Float(frame.midY)))
      width += Float(frame.width)
    }
    if !isSorted {
      keys.sort { $0.codepoint < $1.codepoint }
    }
    width = max(width / Float(frames.count), 1)
    var keysResult: Int32 = 0
    if width != lastRegisteredWidth || keys != lastRegisteredKeys {
      keysResult = keys.withUnsafeBufferPointer {
        gkSetKeys(handle, $0.baseAddress, $0.count, width)
      }
      guard keysResult == 0 else {
        lastDecodeDiagnostics = (keysResult, -1, -1)
        return []
      }
      lastRegisteredKeys = keys
      lastRegisteredWidth = width
    }
    // 120Hz ProMotion 长轨迹先均匀抽稀到 256 点以内，避免抬手解码耗掉多余帧预算。
    let boundedSamples = GlideTyping.downsampled(samples, limit: 256)
    var points = [GKPointC]()
    points.reserveCapacity(boundedSamples.count)
    for sample in boundedSamples {
      points.append(GKPointC(x: Float(sample.x), y: Float(sample.y),
                             timeMS: Int64(sample.milliseconds)))
    }
    let found = points.withUnsafeBufferPointer {
      gkDecode(handle, $0.baseAddress, $0.count, limit)
    }
    var candidateSize: Int32 = -1
    if found > 0 {
      var score: Double = 0
      candidateSize = gkCandidate(handle, 0, nil, 0, &score)
    }
    lastDecodeDiagnostics = (keysResult, found, candidateSize)
    guard found > 0 else { return [] }
    var seen: Set<String> = []
    var results: [String] = []
    for index in 0..<Int(found) {
      guard let text = Self.candidate(handle, index),
            !text.isEmpty,
            text.utf8.allSatisfy({ (97...122).contains($0) }),
            seen.insert(text).inserted else { continue }
      results.append(text)
    }
    return results
  }

  /// 读一个候选。`gk_candidate` 的 size 语义按 GlideKeyboard 的 WMEngine：
  /// 先用空缓冲量出含 NUL 的所需字节数，再按它取回。
  private static func candidate(_ handle: OpaquePointer, _ index: Int) -> String? {
    var score: Double = 0
    let size = gkCandidate(handle, index, nil, 0, &score)
    guard size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: Int(size))
    let written = gkCandidate(handle, index, &buffer, Int(size), &score)
    guard written > 0 else { return nil }
    let valid = buffer.prefix(Int(written)).prefix { $0 != 0 }
    return String(decoding: valid, as: UTF8.self)
  }

  private func loadIfNeeded() {
    guard handle == nil else { return }
    guard let dictionary = Self.asset("pinyin", "wmcd"),
          let ngrams = Self.asset("ngrams", "wmcn"),
          let glide = Self.asset("glide", "wmdict") else { return }
    guard let newHandle = gkEngineNew() else { return }
    let loaded = dictionary.withUnsafeBytes { d in
      ngrams.withUnsafeBytes { n in
        glide.withUnsafeBytes { g in
          gkLoadPinyinCompiled(newHandle, d.baseAddress, d.count,
                               n.baseAddress, n.count, g.baseAddress, g.count)
        }
      }
    }
    // 成功时返回正数（GlideKeyboard 的 WMEngine 同样按 > 0 判定），负数为错误。
    guard loaded > 0 else {
      gkEngineFree(newHandle)
      return
    }
    handle = newHandle
    readyLock.lock()
    loadedReady = true
    readyLock.unlock()
  }

  private static func asset(_ name: String, _ ext: String) -> Data? {
    Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "glide-engine")
      .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
  }
}

// MARK: - C ABI（glide_keyboard.h 的子集）

/// 与 C `struct GKKey { uint32_t codepoint; float x, y; }` 逐字节一致。
struct GKKeyC: Equatable {
  var codepoint: UInt32
  var x: Float
  var y: Float
}

/// 与 C `struct GKPoint { float x, y; int64_t time_ms; }` 逐字节一致。
struct GKPointC {
  var x: Float
  var y: Float
  var timeMS: Int64
}

@_silgen_name("gk_engine_new")
private func gkEngineNew() -> OpaquePointer?

@_silgen_name("gk_engine_free")
private func gkEngineFree(_ engine: OpaquePointer?)

@_silgen_name("gk_load_pinyin_compiled")
private func gkLoadPinyinCompiled(_ engine: OpaquePointer,
                                  _ dictionary: UnsafeRawPointer?, _ dictionaryLength: Int,
                                  _ ngrams: UnsafeRawPointer?, _ ngramsLength: Int,
                                  _ glide: UnsafeRawPointer?, _ glideLength: Int) -> Int32

@_silgen_name("gk_set_keys")
private func gkSetKeys(_ engine: OpaquePointer, _ keys: UnsafePointer<GKKeyC>?, _ count: Int,
                       _ width: Float) -> Int32

@_silgen_name("gk_decode")
private func gkDecode(_ engine: OpaquePointer, _ points: UnsafePointer<GKPointC>?, _ count: Int,
                      _ limit: Int) -> Int32

@_silgen_name("gk_candidate")
private func gkCandidate(_ engine: OpaquePointer, _ index: Int,
                         _ out: UnsafeMutablePointer<UInt8>?, _ capacity: Int,
                         _ score: UnsafeMutablePointer<Double>?) -> Int32

@_silgen_name("gk_engine_version")
private func gkEngineVersion() -> UnsafePointer<CChar>?

#endif
