import XCTest
import CoreGraphics
import UIKit

/// GlideBeam 滑行引擎（GlideKeyboard MIT 移植）的桥与偏好。nihao 轨迹自检
/// 与 GlideKeyboard 的 EngineSelfTest 同源：期望值来自词典本身，不是拍脑袋。
final class GlideEngineTests: XCTestCase {
  override func setUp() {
    super.setUp()
    enableAllInputSchemes()
    GlideEnginePreference.choice = .msime
  }

  override func tearDown() {
    GlideEnginePreference.choice = .msime
    super.tearDown()
  }

  /// 测试宿主随扩展一起暂存了词典三件套（project.yml 的 glide-engine 文件夹引用）。
  func testGlidebeamAssetsAreAvailableInTestHost() {
    XCTAssertTrue(GlideEngineChoice.glidebeamAvailable)
  }

  func testPreferenceRoundTripAndDefault() {
    XCTAssertEqual(GlideEnginePreference.choice, .msime, "缺键时按水杉引擎")
    GlideEnginePreference.choice = .glidebeam
    XCTAssertEqual(GlideEnginePreference.choice, .glidebeam)
    XCTAssertEqual(GlideEnginePreference.defaults.string(forKey: GlideEnginePreference.key), "glidebeam")
    GlideEnginePreference.choice = .msime
    XCTAssertEqual(GlideEnginePreference.choice, .msime)
  }

  /// 26 键的固定测试布局：三排 QWERTY，键 37×45、列距 6（与 iOS 27 官方度量同量级）。
  private static func letterFrames() -> [(Character, CGRect)] {
    let rows: [String] = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    var frames: [(Character, CGRect)] = []
    for (row, letters) in rows.enumerated() {
      let inset = CGFloat(row) * (37 + 6) / 2
      for (column, letter) in letters.enumerated() {
        let x = 8 + inset + CGFloat(column) * (37 + 6)
        let y = CGFloat(row) * (45 + 11)
        frames.append((letter, CGRect(x: x, y: y, width: 37, height: 45)))
      }
    }
    return frames
  }

  /// 沿相邻字母中心连线插值出合成轨迹（GlideKeyboard EngineSelfTest 的
  /// trajectory(for:) 同一思路）：每段 8 个采样，时间随距离走。
  private static func trajectory(for word: String, centers: [Character: CGPoint]) -> [GlideTyping.Sample] {
    let letters = Array(word.lowercased())
    guard letters.count >= 2, let first = centers[letters[0]] else { return [] }
    var samples = [GlideTyping.Sample(x: first.x, y: first.y, milliseconds: 0)]
    var elapsed: Double = 0
    for index in 0..<(letters.count - 1) {
      guard let from = centers[letters[index]], let to = centers[letters[index + 1]] else { return [] }
      let distance = hypot(to.x - from.x, to.y - from.y)
      let steps = max(3, Int(distance / 4))
      for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        elapsed += max(4, distance / CGFloat(steps) * 0.6)
        samples.append(GlideTyping.Sample(x: from.x + (to.x - from.x) * t,
                                          y: from.y + (to.y - from.y) * t,
                                          milliseconds: elapsed))
      }
    }
    return samples
  }

  func testEngineDecodesNihaoTrajectoryIntoTheReading() throws {
    let frames = Self.letterFrames()
    let centers = Dictionary(uniqueKeysWithValues: frames.map { ($0.0, CGPoint(x: $0.1.midX, y: $0.1.midY)) })
    let engine = GlideBeamEngine.shared
    engine.prepareAndWait()
    XCTAssertTrue(engine.isReady, "测试宿主的 glide-engine 词典应能加载")
    let samples = Self.trajectory(for: "nihao", centers: centers)
    XCTAssertGreaterThanOrEqual(samples.count, 10)
    let reading = engine.decodeReading(samples: samples,
                                       letters: frames.map { UInt32($0.0.asciiValue!) },
                                       frames: frames.map { $0.1 })
    XCTAssertEqual(reading, "nihao", "轨迹应解出拼音读音")
  }

  /// 几何没变时第二次解码不重发键位（签名短路）；变化的几何换一组注册。
  func testDecodeIsRepeatableAcrossGeometryChanges() throws {
    let engine = GlideBeamEngine.shared
    engine.prepareAndWait()
    let frames = Self.letterFrames()
    let centers = Dictionary(uniqueKeysWithValues: frames.map { ($0.0, CGPoint(x: $0.1.midX, y: $0.1.midY)) })
    let letters = frames.map { UInt32($0.0.asciiValue!) }
    let rects = frames.map { $0.1 }
    for _ in 0..<2 {
      let samples = Self.trajectory(for: "nihao", centers: centers)
      XCTAssertEqual(engine.decodeReading(samples: samples, letters: letters, frames: rects), "nihao")
    }
    // 整体平移（模拟键盘位置变化）：解码仍应成立。
    let shifted = rects.map { $0.offsetBy(dx: 30, dy: 12) }
    let shiftedCenters = Dictionary(uniqueKeysWithValues: zip(frames.map { $0.0 }, shifted)
      .map { ($0.0, CGPoint(x: $0.1.midX, y: $0.1.midY)) })
    let samples = Self.trajectory(for: "nihao", centers: shiftedCenters)
    XCTAssertEqual(engine.decodeReading(samples: samples, letters: letters, frames: shifted), "nihao")
  }

  /// 少于 20 个键位（半面键盘）时拒绝解码，调用点回退水杉引擎。
  func testDecodeRefusesIncompleteLayouts() {
    let engine = GlideBeamEngine.shared
    engine.prepareAndWait()
    let frames = Array(Self.letterFrames().prefix(10))
    let samples = [GlideTyping.Sample(x: 10, y: 10, milliseconds: 0),
                   GlideTyping.Sample(x: 50, y: 10, milliseconds: 40)]
    XCTAssertNil(engine.decodeReading(samples: samples,
                                      letters: frames.map { UInt32($0.0.asciiValue!) },
                                      frames: frames.map { $0.1 }))
  }

  func testDecodeReadingsReturnsMultipleCandidatesAndAsyncDoesNotBlock() {
    let engine = GlideBeamEngine.shared
    engine.prepareAndWait()
    XCTAssertTrue(engine.isReady)

    let frames = Self.letterFrames()
    let centers = Dictionary(uniqueKeysWithValues: frames.map { ($0.0, CGPoint(x: $0.1.midX, y: $0.1.midY)) })
    let letters = frames.map { UInt32($0.0.asciiValue!) }
    let rects = frames.map { $0.1 }
    let samples = Self.trajectory(for: "xian", centers: centers)

    let readings = engine.decodeReadings(samples: samples, letters: letters, frames: rects, limit: 5)
    XCTAssertFalse(readings.isEmpty)
    XCTAssertEqual(readings.first, "xian")
    XCTAssertEqual(Set(readings).count, readings.count)

    let expectation = expectation(description: "async glide decode")
    engine.decodeReadingsAsync(samples: samples, letters: letters, frames: rects, limit: 5) { asyncReadings in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(asyncReadings, readings)
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 5)
  }
}
