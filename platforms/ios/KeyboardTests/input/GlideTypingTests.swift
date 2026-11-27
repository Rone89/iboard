import ObjectiveC
import UIKit
import XCTest

/// 滑行输入（#5347）：什么时候算滑行、抬手时交给 Engine 的请求，以及键盘上的开关、键区和会话怎么接起来。
@MainActor
final class GlideTypingTests: XCTestCase {
  private var storedGlide: Any?
  private var storedBilingual: Any?

  override func setUp() {
    super.setUp()
    enableAllInputSchemes()
    storedGlide = KeyboardLayoutPreference.defaults.object(forKey: KeyboardLayoutPreference.glideTypingKey)
    storedBilingual = KeyboardLayoutPreference.defaults.object(forKey: KeyboardLayoutPreference.bilingualGlideKey)
    KeyboardLayoutPreference.bilingualGlide = false
  }

  override func tearDown() {
    if let storedGlide { KeyboardLayoutPreference.defaults.set(storedGlide, forKey: KeyboardLayoutPreference.glideTypingKey) }
    else { KeyboardLayoutPreference.defaults.removeObject(forKey: KeyboardLayoutPreference.glideTypingKey) }
    if let storedBilingual { KeyboardLayoutPreference.defaults.set(storedBilingual, forKey: KeyboardLayoutPreference.bilingualGlideKey) }
    else { KeyboardLayoutPreference.defaults.removeObject(forKey: KeyboardLayoutPreference.bilingualGlideKey) }
    super.tearDown()
  }

  // MARK: - 合成的键盘

  /// 手机 26 键的排法：30×40 的键、6pt 键距，第二行缩进半个键距，第三行缩进一个半；按 a..z 排列。
  private nonisolated static let frames: [CGRect] = {
    let rows: [(String, CGFloat)] = [("qwertyuiop", 0), ("asdfghjkl", 0.5), ("zxcvbnm", 1.5)]
    var frames = [CGRect](repeating: .null, count: 26)
    for (row, (letters, indent)) in rows.enumerated() {
      for (column, letter) in letters.unicodeScalars.enumerated() {
        let index = Int(letter.value - UnicodeScalar("a").value)
        frames[index] = CGRect(x: (CGFloat(column) + indent) * 36, y: CGFloat(row) * 48, width: 30, height: 40)
      }
    }
    return frames
  }()

  private static func center(_ letter: Character, in frames: [CGRect] = frames) -> CGPoint {
    let frame = frames[GlideTyping.letters.firstIndex(of: letter)!]
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  /// 依次经过 `word` 各字母键中心的一笔：大约每 6pt 一个采样、每个采样 8ms。
  private static func stroke(_ word: String, in frames: [CGRect] = frames) -> [GlideTyping.Sample] {
    let centers = word.map { center($0, in: frames) }
    var samples: [GlideTyping.Sample] = []
    func add(_ point: CGPoint) {
      samples.append(GlideTyping.Sample(x: point.x, y: point.y, milliseconds: Double(samples.count) * 8))
    }
    for (from, to) in zip(centers, centers.dropFirst()) {
      let steps = max(1, Int((hypot(to.x - from.x, to.y - from.y) / 6).rounded(.up)))
      for step in 0..<steps {
        let t = CGFloat(step) / CGFloat(steps)
        add(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
      }
    }
    add(centers[centers.count - 1])
    return samples
  }

  private func decode(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  // MARK: - 判定

  func testAGlideStartsOverAnotherLetterFarEnoughSideways() {
    let frames = Self.frames
    let g = GlideTyping.letters.firstIndex(of: "g")!
    let h = GlideTyping.letters.firstIndex(of: "h")!
    let down = Self.center("g")
    // 还在按下的键上，走多远都不算。
    XCTAssertFalse(GlideTyping.startsGlide(downKey: g, down: down, current: CGPoint(x: down.x + 14, y: down.y), frames: frames))
    // 进了隔壁的 h 中心（位移 36pt = 1.2 倍键宽），正常起滑。
    XCTAssertTrue(GlideTyping.startsGlide(downKey: g, down: down, current: Self.center("h"), frames: frames))
    // 仅贴边蹭进 h 外缘 2pt（从 g 右缘偏右起手只移 14pt），属于点按滚滑，不能误起滑行。
    let edgeDown = CGPoint(x: frames[g].maxX - 3, y: down.y)
    let edgeGraze = CGPoint(x: frames[h].minX + 2, y: down.y)
    XCTAssertFalse(GlideTyping.startsGlide(downKey: g, down: edgeDown, current: edgeGraze, frames: frames))
    // 键距里的点不在任何键上。
    XCTAssertFalse(GlideTyping.startsGlide(downKey: g, down: down, current: CGPoint(x: frames[g].maxX + 3, y: down.y), frames: frames))
    // 竖直往上滑到 t 上：关闭纵向保护时支持二维直滑起滑；开启角标纵滑保护时，小幅斜滑（dx < dy * 0.85）仍留给角标，不被滑行抢走。
    let t = Self.frames[GlideTyping.letters.firstIndex(of: "t")!]
    XCTAssertTrue(t.contains(CGPoint(x: down.x - 6, y: t.midY)))
    XCTAssertTrue(GlideTyping.startsGlide(downKey: g, down: down, current: CGPoint(x: down.x - 6, y: t.midY), frames: frames))
    XCTAssertFalse(GlideTyping.startsGlide(downKey: g, down: down, current: CGPoint(x: down.x - 6, y: t.midY), frames: frames, allowsVerticalGlide: false))
    XCTAssertFalse(GlideTyping.startsGlide(downKey: g, down: down, current: CGPoint(x: down.x - 12, y: t.midY), frames: frames, allowsVerticalGlide: false))
    // 横向明确滑入邻键（如 g → h 中心）即使同键开启角标保护也能正常起滑。
    XCTAssertTrue(GlideTyping.startsGlide(downKey: g, down: down, current: Self.center("h"), frames: frames, allowsVerticalGlide: false))
    XCTAssertFalse(GlideTyping.startsGlide(downKey: 26, down: down, current: Self.center("h"), frames: frames), "按下的键不存在")
  }

  func testTwentySixKeyAntiMisfireGuardsRapidTypingGapStartsAndShortSlips() {
    let frames = Self.frames
    let g = GlideTyping.letters.firstIndex(of: "g")!
    let h = GlideTyping.letters.firstIndex(of: "h")!
    let downRight = CGPoint(x: frames[g].maxX - 4, y: frames[g].midY)
    // 从 g 右偏处滑入 h 内部（位移 24pt = 0.8 倍键宽）：常态已过 0.72 门槛可起滑，但在连打节律或键缝起手下仍拦截防误触。
    let targetInsideH = CGPoint(x: downRight.x + 24, y: frames[h].midY)
    XCTAssertTrue(frames[h].contains(targetInsideH))
    XCTAssertTrue(GlideTyping.startsGlide(downKey: g, down: downRight, current: targetInsideH, frames: frames))
    XCTAssertFalse(GlideTyping.startsGlide(downKey: g, down: downRight, current: targetInsideH, frames: frames, rapidTyping: true))
    XCTAssertFalse(GlideTyping.startsGlide(downKey: g, down: downRight, current: targetInsideH, frames: frames, startedInGap: true))
    // 连打中主动跨过整键距（如 g 中心 → h 中心 = 36pt = 1.2 倍键宽）依然可以顺滑切入滑行。
    XCTAssertTrue(GlideTyping.startsGlide(downKey: g, down: Self.center("g"), current: Self.center("h"), frames: frames, rapidTyping: true))

    // 26 键 4pt 键缝容差：覆盖相邻键 6pt 键缝，但不会吸附距离底排 8pt 的空格边缘触摸。
    XCTAssertEqual(GlideTyping.nearestKeyIndex(at: CGPoint(x: 31.5, y: 20), in: frames, maxGapPadding: GlideTyping.twentySixKeyGapPadding),
                   GlideTyping.letters.firstIndex(of: "q"))
    XCTAssertNil(GlideTyping.nearestKeyIndex(at: CGPoint(x: frames[g].midX, y: frames[GlideTyping.letters.firstIndex(of: "b")!].maxY + 7),
                                             in: frames, maxGapPadding: GlideTyping.twentySixKeyGapPadding))

    // 超短瞬时蹭键（40ms、净位移 22pt < 0.85 * 30 = 25.5pt）被判定为误滑；真实快速相邻滑行（g → h 中心 = 36pt）放行。
    let slip = [
      GlideTyping.Sample(x: downRight.x, y: downRight.y, milliseconds: 0),
      GlideTyping.Sample(x: downRight.x + 22, y: downRight.y, milliseconds: 40),
    ]
    XCTAssertTrue(GlideTyping.isAccidentalShortSlip(samples: slip, frames: frames, pathLength: 22))
    let realShortGlide = [
      GlideTyping.Sample(x: Self.center("g").x, y: Self.center("g").y, milliseconds: 0),
      GlideTyping.Sample(x: Self.center("h").x, y: Self.center("h").y, milliseconds: 45),
    ]
    XCTAssertFalse(GlideTyping.isAccidentalShortSlip(samples: realShortGlide, frames: frames, pathLength: 36))

    // 速度自适应起滑：常态主动快滑（velocity >= 360 pt/s）在跨入邻键且位移达 0.60 倍键宽（18pt）即刻起滑；慢速滚滑（velocity = 120）与连打节律下仍拦截防误触。
    let fastTarget = CGPoint(x: frames[h].minX + 4, y: frames[h].midY)
    let fastDown = CGPoint(x: fastTarget.x - 18, y: frames[g].midY)
    XCTAssertTrue(frames[g].contains(fastDown))
    XCTAssertTrue(frames[h].contains(fastTarget))
    XCTAssertFalse(GlideTyping.startsGlide(downKey: g, down: fastDown, current: fastTarget, frames: frames, velocity: 120))
    XCTAssertTrue(GlideTyping.startsGlide(downKey: g, down: fastDown, current: fastTarget, frames: frames, velocity: 480))
    XCTAssertFalse(GlideTyping.startsGlide(downKey: g, down: fastDown, current: fastTarget, frames: frames, rapidTyping: true, velocity: 480))
    XCTAssertFalse(GlideTyping.startsGlide(downKey: g, down: fastDown, current: fastTarget, frames: frames, startedInGap: true, velocity: 480))
  }

  func testKeyIndexSkipsHiddenKeysAndGaps() {
    var frames = Self.frames
    XCTAssertEqual(GlideTyping.keyIndex(at: Self.center("q"), in: frames), GlideTyping.letters.firstIndex(of: "q"))
    XCTAssertNil(GlideTyping.keyIndex(at: CGPoint(x: 33, y: 20), in: frames), "q 与 w 之间的键距")
    frames[GlideTyping.letters.firstIndex(of: "q")!] = .null
    XCTAssertNil(GlideTyping.keyIndex(at: Self.center("q", in: Self.frames), in: frames))
  }

  func testNearestKeyIndexSnapsGapTouchesWithinPadding() {
    let frames = Self.frames
    let q = GlideTyping.letters.firstIndex(of: "q")!
    let w = GlideTyping.letters.firstIndex(of: "w")!
    // 落在 q 与 w 之间 6pt 键缝内偏左/偏右，应分别吸附到最近的字母键。
    XCTAssertEqual(GlideTyping.nearestKeyIndex(at: CGPoint(x: 31.5, y: 20), in: frames), q)
    XCTAssertEqual(GlideTyping.nearestKeyIndex(at: CGPoint(x: 34.5, y: 20), in: frames), w)
    // 超出键缝容差（如落到最下方功能行），不吸附。
    XCTAssertNil(GlideTyping.nearestKeyIndex(at: CGPoint(x: 20, y: 170), in: frames))
  }

  func testTrimmedLiftoffHookRemovesShortReverseTailOnly() {
    let clean = Self.stroke("nihao")
    XCTAssertEqual(GlideTyping.trimmedLiftoffHook(clean, frames: Self.frames), clean)

    var hooked = clean
    let last = clean.last!
    let prev = clean[clean.count - 2]
    let dx = last.x - prev.x
    let dy = last.y - prev.y
    let len = max(hypot(dx, dy), 1)
    hooked.append(GlideTyping.Sample(
      x: last.x - (dx / len) * 9,
      y: last.y - (dy / len) * 9,
      milliseconds: last.milliseconds + 10
    ))
    let trimmed = GlideTyping.trimmedLiftoffHook(hooked, frames: Self.frames)
    XCTAssertEqual(trimmed.count, clean.count, "应裁掉末段 10ms 反向短回勾")
    XCTAssertEqual(trimmed.last, clean.last)
  }

  func testRequestWithExternalReadingsEncodesValidReadingsOnly() throws {
    let samples = Self.stroke("nihao")
    let data = try XCTUnwrap(GlideTyping.request(
      frames: Self.frames,
      samples: samples,
      bilingual: true,
      readings: ["nihao", "BAD!", "", "ni"],
      preview: true
    ))
    let json = try decode(data)
    XCTAssertEqual(json["bilingual"] as? Bool, true)
    XCTAssertEqual(json["preview"] as? Bool, true)
    XCTAssertEqual(json["readings"] as? [String], ["nihao", "ni"])
  }

  // MARK: - 请求

  func testBilingualRequestIsExplicitAndDoesNotChangeTheDefaultRequest() throws {
    let samples = Self.stroke("hello")
    let original = try decode(XCTUnwrap(GlideTyping.request(frames: Self.frames, samples: samples)))
    XCTAssertNil(original["bilingual"])
    let mixed = try decode(XCTUnwrap(GlideTyping.request(frames: Self.frames, samples: samples, bilingual: true)))
    XCTAssertEqual(mixed["bilingual"] as? Bool, true)
    XCTAssertEqual(mixed["points"] as? [[Double]], original["points"] as? [[Double]])
  }

  func testDownsamplingKeepsBothEndsWithinTheLimit() {
    let short = Array(0..<10)
    XCTAssertEqual(GlideTyping.downsampled(short, limit: 10), short)
    let long = Array(0..<5_000)
    let kept = GlideTyping.downsampled(long)
    XCTAssertEqual(kept.count, GlideTyping.pointLimit)
    XCTAssertEqual(kept.first, 0)
    XCTAssertEqual(kept.last, 4_999)
    XCTAssertEqual(kept, kept.sorted())
    XCTAssertEqual(Set(kept).count, kept.count, "均匀抽取不会重复取同一个采样")
    XCTAssertEqual(GlideTyping.downsampled(Array(0..<1_025)).count, 1_024)
  }

  func testLiveStrokeBufferIsBoundedBeforeTheRequestIsBuilt() {
    var samples: [GlideTyping.Sample] = []
    for index in 0..<(GlideTyping.sampleBufferLimit * 3) {
      GlideTyping.appendBounded(
        GlideTyping.Sample(x: CGFloat(index), y: 0, milliseconds: Double(index)),
        to: &samples)
    }
    XCTAssertLessThanOrEqual(samples.count, GlideTyping.sampleBufferLimit)
    XCTAssertEqual(samples.first?.x, 0)
    XCTAssertEqual(samples.last?.x, CGFloat(GlideTyping.sampleBufferLimit * 3 - 1))
  }

  func testRequestCarriesTheKeyCentresTheKeySizeAndTheStroke() throws {
    var frames = Self.frames
    // 第二行的键稍宽一些，一个字母键的大小取最小的那个。
    for letter in "asdfghjkl" {
      let index = GlideTyping.letters.firstIndex(of: letter)!
      frames[index].size.width = 33
    }
    let samples = [
      GlideTyping.Sample(x: 10.04, y: 20.06, milliseconds: 0),
      GlideTyping.Sample(x: 50.5, y: 21, milliseconds: 16.4),
      GlideTyping.Sample(x: 88.26, y: 19.74, milliseconds: 40.6),
    ]
    let data = try XCTUnwrap(GlideTyping.request(frames: frames, samples: samples))
    let request = try decode(data)
    XCTAssertEqual(Set(request.keys), ["keys", "key_width", "key_height", "points"], "Engine 拒绝未知字段")
    let keys = try XCTUnwrap(request["keys"] as? [[Double]])
    XCTAssertEqual(keys.count, 26)
    XCTAssertEqual(keys[0], [Double(frames[0].midX), Double(frames[0].midY)], "a 在最前")
    XCTAssertEqual(keys[25], [Double(Self.center("z").x), Double(Self.center("z").y)], "z 在最后")
    XCTAssertEqual(request["key_width"] as? Double, 30)
    XCTAssertEqual(request["key_height"] as? Double, 40)
    let points = try XCTUnwrap(request["points"] as? [[Double]])
    XCTAssertEqual(points, [[10.0, 20.1, 0], [50.5, 21.0, 16], [88.3, 19.7, 41]])
  }

  func testRequestNeedsTheWholeKeyboardAndAStroke() {
    let samples = Self.stroke("nihao")
    XCTAssertNotNil(GlideTyping.request(frames: Self.frames, samples: samples))
    XCTAssertNil(GlideTyping.request(frames: Array(Self.frames.dropLast()), samples: samples))
    var hidden = Self.frames
    hidden[3] = .null
    XCTAssertNil(GlideTyping.request(frames: hidden, samples: samples))
    XCTAssertNil(GlideTyping.request(frames: Self.frames, samples: Array(samples.prefix(1))))
    var broken = samples
    broken[1].x = .nan
    XCTAssertNil(GlideTyping.request(frames: Self.frames, samples: broken))
  }

  func testALongStrokeStaysWithinTheEngineLimits() throws {
    let samples = (0..<6_000).map { index in
      GlideTyping.Sample(x: 9_999.99 - CGFloat(index), y: -9_999.99, milliseconds: Double(index) * 4.17)
    }
    let data = try XCTUnwrap(GlideTyping.request(frames: Self.frames, samples: samples))
    XCTAssertLessThanOrEqual(data.count, GlideTyping.requestByteLimit)
    let points = try XCTUnwrap(try decode(data)["points"] as? [[Double]])
    XCTAssertEqual(points.count, GlideTyping.pointLimit)
    XCTAssertEqual(points.first, [10_000.0, -10_000.0, 0])
    XCTAssertEqual(points.last?[2], (5_999 * 4.17).rounded())
  }

  /// 轨迹视图的色带由 `SwipeTrailGeometry` 承担（几何断言在
  /// SwipeTrailGeometryTests）；这里只看视图的生命周期：有采样即算有轨迹，
  /// clear 后归零。
  func testTrailViewTracksGeometryPresence() {
    let trail = GlideTrailView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    XCTAssertFalse(trail.hasTrail)
    trail.draw([GlideTyping.Sample(x: 10, y: 10, milliseconds: 0),
                GlideTyping.Sample(x: 60, y: 30, milliseconds: 30),
                GlideTyping.Sample(x: 110, y: 10, milliseconds: 60),
                GlideTyping.Sample(x: 160, y: 40, milliseconds: 90)], color: .red)
    XCTAssertTrue(trail.hasTrail)
    trail.clear()
    XCTAssertFalse(trail.hasTrail)
  }

  /// 回归（轨迹「偶尔丢失」）：抬手淡出动画 `isRemovedOnCompletion = false` +
  /// `fillMode = .forwards`，不清掉就会把下一笔的展示层永久压在透明度 0 上。
  /// 新一笔的 draw 必须先摘动画、恢复不透明度（参照 clearStroke 的次序）。
  func testNewStrokeRevivesTheTrailAfterAFade() {
    let trail = GlideTrailView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    let shape = trail.layer.sublayers?.first
    let samples = [GlideTyping.Sample(x: 0, y: 0, milliseconds: 0),
                   GlideTyping.Sample(x: 100, y: 0, milliseconds: 100)]
    trail.draw(samples, color: .red)
    trail.fadeOut()
    XCTAssertEqual(shape?.opacity ?? -1, 0, accuracy: 0.001, "淡出把模型透明度压到 0")
    XCTAssertNotNil(shape?.animation(forKey: "fade"), "淡出动画留在层上")
    trail.draw(samples, color: .red)
    XCTAssertNil(shape?.animation(forKey: "fade"), "新的一笔摘走淡出动画")
    XCTAssertEqual(shape?.opacity ?? -1, 1, accuracy: 0.001, "新的一笔恢复不透明度")
  }

  // MARK: - 会话

  func testTheSessionTypesAQuanpinGlideAndRefusesOtherSchemes() throws {
    let state = FileManager.default.temporaryDirectory
      .appendingPathComponent("msime-glide-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let bridge = MetasequoiaInputSessionBridge(stateRoot: state)
    _ = bridge.switch(toShuangpin: false)
    let request = try XCTUnwrap(GlideTyping.request(frames: Self.frames, samples: Self.stroke("nihao")))
    let typed = bridge.glide(request)
    XCTAssertTrue(typed.isHandled, String(describing: typed.diagnosticText))
    XCTAssertEqual(typed.editingText, "nihao")
    XCTAssertFalse(typed.candidates.isEmpty)
    _ = bridge.cancel()

    XCTAssertFalse(bridge.glide(Data("{}".utf8)).isHandled, "Engine 拒绝不完整的请求")
    XCTAssertFalse(bridge.glide(Data()).isHandled)

    _ = bridge.switchToWubi()
    let refused = bridge.glide(request)
    XCTAssertFalse(refused.isHandled, "只有全拼解码滑行")
    XCTAssertTrue(refused.editingText.isEmpty)
  }

  // MARK: - 键盘

  private func nodes(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(nodes) }

  private func keyboard(_ scheme: ChineseInputScheme, glide: Bool) -> KeyboardViewController {
    InputSchemePreference.scheme = scheme
    KeyboardLayoutPreference.glideTyping = glide
    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: KeyboardViewController.defaultKeyboardHeight)
    controller.viewWillAppear(false)
    controller.view.layoutIfNeeded()
    return controller
  }

  private func keyArea(_ controller: KeyboardViewController) throws -> KeyAreaStackView {
    try XCTUnwrap(nodes(controller.view).first { $0 is KeyAreaStackView } as? KeyAreaStackView)
  }

  private func gesture(_ controller: KeyboardViewController) throws -> GlideTypingGestureRecognizer {
    try XCTUnwrap(try keyArea(controller).gestureRecognizers?.first { $0 is GlideTypingGestureRecognizer }
      as? GlideTypingGestureRecognizer)
  }

  func testTheSettingIsOffByDefault() {
    KeyboardLayoutPreference.defaults.removeObject(forKey: KeyboardLayoutPreference.glideTypingKey)
    XCTAssertEqual(KeyboardLayoutPreference.glideTypingKey, "keyboard.gesture.glide")
    XCTAssertFalse(KeyboardLayoutPreference.glideTyping)
    KeyboardLayoutPreference.glideTyping = true
    XCTAssertEqual(KeyboardLayoutPreference.defaults.object(forKey: KeyboardLayoutPreference.glideTypingKey) as? Bool, true)
  }

  func testGlideIsArmedOnlyOnTheQuanpinLettersWithTheSettingOn() throws {
    let previous = InputSchemePreference.scheme
    defer { InputSchemePreference.scheme = previous }
    XCTAssertTrue(try gesture(keyboard(.quanpin, glide: true)).isArmed())
    XCTAssertFalse(try gesture(keyboard(.quanpin, glide: false)).isArmed(), "默认关")
    XCTAssertTrue(try gesture(keyboard(.nineKey, glide: true)).isArmed(), "拼音九键开滑行后同样武装")
    XCTAssertFalse(try gesture(keyboard(.nineKey, glide: false)).isArmed())
    XCTAssertFalse(try gesture(keyboard(.shuangpin, glide: true)).isArmed())
    XCTAssertFalse(try gesture(keyboard(.korean, glide: true)).isArmed(), "韩文键帽")

    // 切到 123 符号层后不滑行。
    let symbols = keyboard(.quanpin, glide: true)
    try XCTUnwrap(nodes(symbols.view).first { $0.accessibilityIdentifier == "layoutToggleButton" } as? UIButton)
      .sendActions(for: .primaryActionTriggered)
    XCTAssertFalse(try gesture(symbols).isArmed())
    // 英文模式不滑行；切回中文又能滑行（同时把「沿用上次」可能记下的模式放回中文）。
    let english = keyboard(.quanpin, glide: true)
    let language = try XCTUnwrap(nodes(english.view).first { $0.accessibilityIdentifier == "bottomLanguageKey" } as? UIButton)
    language.sendActions(for: .primaryActionTriggered)
    XCTAssertFalse(try gesture(english).isArmed())
    language.sendActions(for: .primaryActionTriggered)
    XCTAssertTrue(try gesture(english).isArmed())
  }

  func testTheKeyboardMapsItsLetterKeysAndTypesTheStrokeOnLift() throws {
    let previous = InputSchemePreference.scheme
    defer { InputSchemePreference.scheme = previous }
    let controller = keyboard(.quanpin, glide: true)
    let area = try keyArea(controller)
    let glide = try gesture(controller)
    let frames = glide.keyFrames()
    XCTAssertEqual(frames.count, 26)
    XCTAssertFalse(frames.contains { $0.isEmpty })
    // 每个字母键都认得出来，`;` 和其他键不算字母键。
    for (index, letter) in GlideTyping.letters.enumerated() {
      let key = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityLabel == "字母 \(letter.uppercased())" })
      XCTAssertEqual(glide.letterIndex(key), index, "\(letter)")
      XCTAssertEqual(KeyAreaStackView.layoutFrame(of: key, in: area), frames[index])
    }
    let space = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityIdentifier == "spaceKey" })
    XCTAssertNil(glide.letterIndex(space))
    XCTAssertTrue(nodes(controller.view).contains { $0 is GlideTrailView })

    // 抬手：这一笔经会话变成全拼组字。
    glide.onEnded(Self.stroke("nihao", in: frames), frames)
    let preedit = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityIdentifier == "preeditButton" } as? UIButton)
    XCTAssertEqual(preedit.accessibilityValue?.filter(\.isLetter), "nihao")
  }

  func testTheBilingualSettingRoutesAnEnglishStrokeThroughTheChineseKeyboard() throws {
    let previous = InputSchemePreference.scheme
    defer { InputSchemePreference.scheme = previous }
    KeyboardLayoutPreference.bilingualGlide = true
    let controller = keyboard(.quanpin, glide: true)
    let glide = try gesture(controller)
    let frames = glide.keyFrames()
    XCTAssertTrue(glide.isArmed())
    glide.onEnded(Self.stroke("hello", in: frames), frames)
    let preedit = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityIdentifier == "preeditButton" } as? UIButton)
    XCTAssertEqual(preedit.accessibilityValue?.filter(\.isLetter).lowercased(), "hello")
  }

  func testConsecutiveBilingualChineseStrokesKeepTheWholeComposition() throws {
    let previous = InputSchemePreference.scheme
    defer { InputSchemePreference.scheme = previous }
    KeyboardLayoutPreference.bilingualGlide = true
    let controller = keyboard(.quanpin, glide: true)
    let glide = try gesture(controller)
    let frames = glide.keyFrames()
    glide.onEnded(Self.stroke("nihao", in: frames), frames)
    glide.onEnded(Self.stroke("shijie", in: frames), frames)
    let preedit = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityIdentifier == "preeditButton" } as? UIButton)
    XCTAssertEqual(preedit.accessibilityValue?.filter(\.isLetter).lowercased(), "nihaoshijie")
  }

  /// 记录正式渲染器对文档的写入；组字标记不算已提交文本，取消标记时留下的文字（「改标记再取消标记」的上屏）才算。
  private final class Document: NSObject, UITextDocumentProxy {
    let editor = UITextView()
    var inserted: [String] = []
    private var marked = ""
    var documentIdentifier = UUID()
    var documentInputMode: UITextInputMode? { editor.textInputMode }
    var hasText: Bool { editor.hasText }
    var documentContextBeforeInput: String? { editor.text }
    var documentContextAfterInput: String? { "" }
    var selectedText: String? { nil }
    func insertText(_ text: String) { marked = ""; inserted.append(text); editor.insertText(text) }
    func deleteBackward() { editor.deleteBackward() }
    func setMarkedText(_ text: String, selectedRange: NSRange) {
      marked = text
      editor.setMarkedText(text, selectedRange: selectedRange)
    }
    func unmarkText() {
      if !marked.isEmpty { inserted.append(marked) }
      marked = ""
      editor.unmarkText()
    }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
  }

  func testOnlyExplicitSelectionWritesBilingualGlidesIntoTheDocument() throws {
    let document = Document()
    let selector = #selector(getter: UIInputViewController.textDocumentProxy)
    let inherited = try XCTUnwrap(class_getInstanceMethod(UIInputViewController.self, selector))
    let original = method_getImplementation(inherited)
    let block: @convention(block) (AnyObject) -> AnyObject = { _ in document }
    let replacement = imp_implementationWithBlock(block)
    if !class_addMethod(KeyboardViewController.self, selector, replacement, method_getTypeEncoding(inherited)) {
      method_setImplementation(try XCTUnwrap(class_getInstanceMethod(KeyboardViewController.self, selector)), replacement)
    }
    defer {
      if let own = class_getInstanceMethod(KeyboardViewController.self, selector) { method_setImplementation(own, original) }
      imp_removeBlock(replacement)
    }
    let previous = InputSchemePreference.scheme
    defer { InputSchemePreference.scheme = previous }
    KeyboardLayoutPreference.bilingualGlide = true
    let controller = keyboard(.quanpin, glide: true)
    defer { controller.viewDidDisappear(false) }
    let glide = try gesture(controller)
    let frames = glide.keyFrames()
    for selection in ["candidate-1", "spaceKey", "returnKey"] {
      for words in [["nihao", "shijie"], ["nihao", "hello"], ["hello", "nihao"], ["hello", "world"]] {
        document.inserted = []
        for spelling in words {
          glide.onEnded(Self.stroke(spelling, in: frames), frames)
          XCTAssertTrue(document.inserted.isEmpty, "下一笔不能写入上一笔的首选")
        }
        let preedit = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityIdentifier == "preeditButton" } as? UIButton)
        try XCTUnwrap(nodes(controller.view).first { $0.accessibilityIdentifier == selection } as? UIButton)
          .sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(document.inserted.count, 1)
        let committed = try XCTUnwrap(document.inserted.first)
        XCTAssertFalse(committed.isEmpty)
        XCTAssertFalse(committed.contains("\n"), "确认候选不能顺带换行")
        XCTAssertTrue(preedit.accessibilityValue?.isEmpty ?? true, "明确确认后清除组字")
      }
    }
  }

  func testBilingualEnglishCandidatesHideRedundantEnglishCaptions() throws {
    setCandidateGloss(true)
    let previous = InputSchemePreference.scheme
    let primary = CandidateTranslationPreference.primaryIndex
    defer { InputSchemePreference.scheme = previous; CandidateTranslationPreference.primaryIndex = primary }
    CandidateTranslationPreference.primaryIndex = 0
    KeyboardLayoutPreference.bilingualGlide = true
    let controller = keyboard(.quanpin, glide: true)
    defer { controller.viewDidDisappear(false) }
    controller.render(MetasequoiaInputSnapshot(
      isHandled: true, preedit: "hello", candidates: ["hello", "你好"],
      candidateGlosses: ["greeting; hello", "hello"], candidateAnnotations: ["hello", ""],
      candidateSources: [0, 0], candidatePageCount: 1, editingText: "hello", caretPosition: 5))
    controller.view.layoutIfNeeded()
    let english = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityIdentifier == "candidate-1" } as? UIButton)
    let chinese = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityIdentifier == "candidate-2" } as? UIButton)
    XCTAssertFalse(english.accessibilityLabel?.contains("还需输入 hello") == true)
    XCTAssertFalse(english.accessibilityLabel?.contains("释义 greeting") == true)
    XCTAssertTrue(chinese.accessibilityLabel?.contains("释义 hello") == true)
  }

  func testBilingualEnglishCandidatesKeepUsefulChineseMeaningsWithoutSpellingHints() throws {
    setCandidateGloss(true)
    let previous = InputSchemePreference.scheme
    let primary = CandidateTranslationPreference.primaryIndex
    defer { InputSchemePreference.scheme = previous; CandidateTranslationPreference.primaryIndex = primary }
    CandidateTranslationPreference.primaryIndex = 0
    KeyboardLayoutPreference.bilingualGlide = true
    let controller = keyboard(.quanpin, glide: true)
    defer { controller.viewDidDisappear(false) }
    controller.render(MetasequoiaInputSnapshot(
      isHandled: true, preedit: "helo", candidates: ["hello"],
      candidateGlosses: ["嘿；喂"], candidateAnnotations: ["helo"], candidateSources: [0],
      candidatePageCount: 1, editingText: "helo", caretPosition: 4))
    let english = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityIdentifier == "candidate-1" } as? UIButton)
    XCTAssertTrue(english.accessibilityLabel?.contains("释义 嘿；喂") == true)
    XCTAssertFalse(english.accessibilityLabel?.contains("还需输入 helo") == true)
  }

  func testBilingualCaptionFilteringPreservesOtherTargetsAndOrdinaryTyping() {
    XCTAssertNil(BilingualCandidateCaptionPolicy.gloss("greeting", candidate: "hello", target: "EN", enabled: true))
    XCTAssertEqual(BilingualCandidateCaptionPolicy.gloss("bonjour", candidate: "hello", target: "FR", enabled: true), "bonjour")
    XCTAssertEqual(BilingualCandidateCaptionPolicy.gloss("greeting", candidate: "hello", target: "EN", enabled: false), "greeting")
    XCTAssertEqual(BilingualCandidateCaptionPolicy.annotation("hello'world", candidate: "hello world", enabled: true), "")
    XCTAssertEqual(BilingualCandidateCaptionPolicy.annotation("helo", candidate: "hello", enabled: true), "")
    XCTAssertEqual(BilingualCandidateCaptionPolicy.annotation("helo", candidate: "hello", enabled: false), "helo")
  }

  func testEveryBilingualEnglishAlternativeHidesTheDecodedSpelling() throws {
    setCandidateGloss(true)
    let previous = InputSchemePreference.scheme
    defer { InputSchemePreference.scheme = previous }
    KeyboardLayoutPreference.bilingualGlide = true
    let controller = keyboard(.quanpin, glide: true)
    defer { controller.viewDidDisappear(false) }
    for (spelling, words) in [
      ("test", ["test", "rest", "teat"]),
      ("transmission", ["translations", "transmissions", "transmission"])
    ] {
      controller.render(MetasequoiaInputSnapshot(
        isHandled: true, preedit: spelling, candidates: words + ["你好"],
        candidateGlosses: ["检验", "样例释义", "另一释义", "hello"],
        candidateAnnotations: Array(repeating: spelling, count: words.count) + ["nihao"],
        candidateSources: [0, 0, 0, 0], candidatePageCount: 1,
        editingText: spelling, caretPosition: spelling.count))
      controller.view.layoutIfNeeded()
      for index in words.indices {
        let chip = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityIdentifier == "candidate-\(index + 1)" } as? UIButton)
        XCTAssertFalse(chip.accessibilityLabel?.contains("还需输入") == true, "第 \(index + 1) 个英文候选仍带了解码拼写")
        XCTAssertTrue(chip.accessibilityLabel?.contains("释义") == true)
        if spelling == "test", let title = chip.configuration?.attributedTitle {
          let attributed = NSAttributedString(title)
          let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
          let insets = chip.configuration?.contentInsets ?? .zero
          let minimum = (words[index] as NSString).size(withAttributes: [.font: font]).width + insets.leading + insets.trailing
          XCTAssertGreaterThanOrEqual(chip.bounds.width, minimum - 0.5, "短英文标题不能压成逐字母换行")
        }
      }
      let chinese = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityIdentifier == "candidate-4" } as? UIButton)
      XCTAssertTrue(chinese.accessibilityLabel?.contains("还需输入 nihao") == true)
      XCTAssertTrue(chinese.accessibilityLabel?.contains("释义 hello") == true)
    }
  }

  func testNewFingersHitTheKeyAreaItselfWhileAGlideRuns() throws {
    let previous = InputSchemePreference.scheme
    defer { InputSchemePreference.scheme = previous }
    let controller = keyboard(.quanpin, glide: true)
    let area = try keyArea(controller)
    let glide = try gesture(controller)
    let q = try XCTUnwrap(nodes(controller.view).first { $0.accessibilityLabel == "字母 Q" })
    let point = q.convert(CGPoint(x: q.bounds.midX, y: q.bounds.midY), to: controller.view)
    XCTAssertTrue(controller.view.hitTest(point, with: nil) === q)
    glide.onBegan()
    XCTAssertTrue(area.suppressesKeyHits)
    XCTAssertTrue(controller.view.hitTest(point, with: nil) === area, "滑行中落下的手指不按任何键")
    glide.onCancelled()
    XCTAssertFalse(area.suppressesKeyHits)
    XCTAssertTrue(controller.view.hitTest(point, with: nil) === q)
  }

  func testNineKeyGlideFramesAndArming() throws {
    let previousScheme = InputSchemePreference.scheme
    let previousStyle = TouchKeyLayoutStyle.mirrored
    defer {
      InputSchemePreference.scheme = previousScheme
      TouchKeyLayoutStyle.mirrored = previousStyle
    }

    // 校验 2–9 矩形到 26 槽坐标的映射及跨键起滑判定。
    var digitRects: [Int: CGRect] = [:]
    for digit in 2...9 {
      let row = (digit - 1) / 3
      let col = (digit - 1) % 3
      digitRects[digit] = CGRect(x: CGFloat(col) * 86, y: CGFloat(row) * 56, width: 80, height: 49)
    }
    let frames = GlideTyping.nineKeyFrames(from: digitRects)
    XCTAssertEqual(frames.count, 26)
    XCTAssertEqual(frames[0], digitRects[2])
    XCTAssertEqual(frames[12], digitRects[6])
    XCTAssertEqual(frames[25], digitRects[9])
    let downKey = try XCTUnwrap(GlideTyping.nineKeyRepresentativeIndex(forDigit: 7))
    let from7 = CGPoint(x: digitRects[7]!.midX, y: digitRects[7]!.midY)
    let to4 = CGPoint(x: digitRects[4]!.midX, y: digitRects[4]!.midY)
    XCTAssertTrue(GlideTyping.startsGlide(downKey: downKey, down: from7, current: to4, frames: frames))

    // 九键短距竖滑（从 7 上半部向上滑入 4 下半部，总位移 ~22pt < 键宽*0.4=32pt 但 >= 键高*0.4=19.6pt）也应顺滑起滑。
    let shortFrom7 = CGPoint(x: digitRects[7]!.midX, y: digitRects[7]!.minY + 6)
    let shortTo4 = CGPoint(x: digitRects[4]!.midX, y: digitRects[4]!.maxY - 9)
    XCTAssertTrue(GlideTyping.startsGlide(downKey: downKey, down: shortFrom7, current: shortTo4, frames: frames))

    // 九键键序兜底预览应显示数字路径（`742`）而非首字母乱码（`pga`）。
    XCTAssertTrue(GlideTyping.isNineKeyFrames(frames))
    let nineKeySamples = [
      GlideTyping.Sample(x: digitRects[7]!.midX, y: digitRects[7]!.midY, milliseconds: 0),
      GlideTyping.Sample(x: digitRects[4]!.midX, y: digitRects[4]!.midY, milliseconds: 40),
      GlideTyping.Sample(x: digitRects[2]!.midX, y: digitRects[2]!.midY, milliseconds: 80),
    ]
    XCTAssertEqual(GlideLivePreviewPolicy.keyPathPreview(samples: nineKeySamples, frames: frames), "742")

    // 真键盘在标准九键下武装滑行，26 槽坐标有效，且九键上滑输数字自动让位。
    TouchKeyLayoutStyle.mirrored = TouchKeyLayoutStyle(nineKey: .standard)
    let controller = keyboard(.nineKey, glide: true)
    let glide = try gesture(controller)
    XCTAssertTrue(glide.isArmed())
    XCTAssertEqual(glide.keyFrames().count, 26)
    XCTAssertEqual(controller.activeNineKeySwipeDigits, .off)
  }

  func testNineKeyGlideAntiMisfireAndShortVerticalHookTrimming() throws {
    var digitRects: [Int: CGRect] = [:]
    for digit in 2...9 {
      let row = (digit - 1) / 3
      let col = (digit - 1) % 3
      digitRects[digit] = CGRect(x: CGFloat(col) * 86, y: CGFloat(row) * 56, width: 80, height: 49)
    }
    let frames = GlideTyping.nineKeyFrames(from: digitRects)
    let down7 = try XCTUnwrap(GlideTyping.nineKeyRepresentativeIndex(forDigit: 7))
    let r7 = try XCTUnwrap(digitRects[7])
    let r4 = try XCTUnwrap(digitRects[4])

    // 1. 浅边缘 2pt 蹭入邻键应被内缩拦下，避免快打误起滑行。
    let downNearTop7 = CGPoint(x: r7.midX, y: r7.minY + 14)
    let grazeBottom4 = CGPoint(x: r4.midX, y: r4.maxY - 2)
    XCTAssertFalse(GlideTyping.startsGlide(downKey: down7, down: downNearTop7, current: grazeBottom4, frames: frames))

    // 2. 连打节律（rapidTyping）与键缝起手（startedInGap）提高门槛，22pt 微滑不误触；蓄意跨入中心（56pt）照常起滑。
    let shortFrom7 = CGPoint(x: r7.midX, y: r7.minY + 6)
    let shortTo4 = CGPoint(x: r4.midX, y: r4.maxY - 9) // ~22pt
    XCTAssertFalse(GlideTyping.startsGlide(downKey: down7, down: shortFrom7, current: shortTo4, frames: frames, rapidTyping: true))
    XCTAssertFalse(GlideTyping.startsGlide(downKey: down7, down: shortFrom7, current: shortTo4, frames: frames, startedInGap: true))
    let center7 = CGPoint(x: r7.midX, y: r7.midY)
    let center4 = CGPoint(x: r4.midX, y: r4.midY)
    XCTAssertTrue(GlideTyping.startsGlide(downKey: down7, down: center7, current: center4, frames: frames, rapidTyping: true))

    // 3. 主动快滑（velocity >= 320pt/s）放宽到 0.36×49 ≈ 17.6pt，保证干脆起滑。
    let fastFrom7 = CGPoint(x: r7.midX, y: r7.minY + 4)
    let fastTo4 = CGPoint(x: r4.midX, y: r4.maxY - 8) // 19pt
    XCTAssertFalse(GlideTyping.startsGlide(downKey: down7, down: fastFrom7, current: fastTo4, frames: frames, velocity: 120))
    XCTAssertTrue(GlideTyping.startsGlide(downKey: down7, down: fastFrom7, current: fastTo4, frames: frames, velocity: 400))

    // 4. 九键超短误滑兜底：35ms、22pt 边缘蹭键应取消；40ms、56pt 真实快速 7→4 竖滑绝不取消。
    let accidentalSlip = [
      GlideTyping.Sample(x: shortFrom7.x, y: shortFrom7.y, milliseconds: 0),
      GlideTyping.Sample(x: shortTo4.x, y: shortTo4.y, milliseconds: 35),
    ]
    XCTAssertTrue(GlideTyping.isAccidentalShortSlip(samples: accidentalSlip, frames: frames, pathLength: 22))
    let fastRealVertical = [
      GlideTyping.Sample(x: center7.x, y: center7.y, milliseconds: 0),
      GlideTyping.Sample(x: center4.x, y: center4.y, milliseconds: 40),
    ]
    XCTAssertFalse(GlideTyping.isAccidentalShortSlip(samples: fastRealVertical, frames: frames, pathLength: 56))

    // 5. 九键抬手回勾裁剪改用短边 49pt（maxTailHookLength ≈ 23.5pt）：
    //    真实 14pt 离屏回勾应裁掉；而 30pt 主动折返（若误用 80pt 键宽会被 38.4pt 误裁）必须完整保留。
    let baseStroke: [GlideTyping.Sample] = [
      .init(x: center7.x, y: center7.y, milliseconds: 0),
      .init(x: center7.x, y: center7.y - 14, milliseconds: 22),
      .init(x: center7.x, y: center7.y - 28, milliseconds: 44),
      .init(x: center7.x, y: center7.y - 42, milliseconds: 66),
      .init(x: center4.x, y: center4.y, milliseconds: 88),
    ]
    let withHook = baseStroke + [.init(x: center4.x, y: center4.y + 14, milliseconds: 100)]
    XCTAssertEqual(GlideTyping.trimmedLiftoffHook(withHook, frames: frames).count, baseStroke.count)
    let withDeliberateReturn = baseStroke + [.init(x: center4.x, y: center4.y + 30, milliseconds: 100)]
    XCTAssertEqual(GlideTyping.trimmedLiftoffHook(withDeliberateReturn, frames: frames).count, withDeliberateReturn.count)
  }

  func testGlideInflectionTrackerAnchorsCornersAndDwellsButIgnoresStraightPassThrough() throws {
    var tracker = GlideInflectionTracker()
    func keyFrame(_ letter: Character) throws -> CGRect {
      let idx = try XCTUnwrap(GlideTyping.letters.firstIndex(of: letter))
      return Self.frames[idx]
    }
    let a = try keyFrame("a")
    let s = try keyFrame("s")
    let d = try keyFrame("d")
    let f = try keyFrame("f")
    let r = try keyFrame("r")

    tracker.reset(initialKey: GlideTyping.letters.firstIndex(of: "a"))
    // 1. 沿第 2 排从 A 直线匀速划过 S、D 到 F：中间过路键不应触发拐点锚定。
    let straightSamples = [
      GlideTyping.Sample(x: a.midX, y: a.midY, milliseconds: 0),
      GlideTyping.Sample(x: s.midX, y: s.midY, milliseconds: 30),
      GlideTyping.Sample(x: d.midX, y: d.midY, milliseconds: 60),
      GlideTyping.Sample(x: f.midX, y: f.midY, milliseconds: 90),
    ]
    XCTAssertNil(tracker.detectAnchor(samples: straightSamples, frames: Self.frames))

    // 2. 在 F 键拐弯向上滑往第 1 排的 R（折角 ~90° >= 68°）：应锚定拐点顶点 F。
    let cornerSamples = straightSamples + [
      GlideTyping.Sample(x: r.midX, y: r.midY, milliseconds: 130),
    ]
    let fIndex = try XCTUnwrap(GlideTyping.letters.firstIndex(of: "f"))
    XCTAssertEqual(tracker.detectAnchor(samples: cornerSamples, frames: Self.frames), fIndex)

    // 3. 在 R 键上驻留满 85ms（且距上次锚定已过 65ms 冷却）：应锚定驻留键 R。
    let rIndex = try XCTUnwrap(GlideTyping.letters.firstIndex(of: "r"))
    let dwellSamples = cornerSamples + [
      GlideTyping.Sample(x: r.midX + 1, y: r.midY, milliseconds: 165),
      GlideTyping.Sample(x: r.midX + 2, y: r.midY + 1, milliseconds: 220),
    ]
    XCTAssertEqual(tracker.detectAnchor(samples: dwellSamples, frames: Self.frames), rIndex)
  }

  func testGlideInflectionTrackerScalesChordAndDwellForNineKeyFrames() throws {
    var digitRects: [Int: CGRect] = [:]
    for digit in 2...9 {
      let row = (digit - 1) / 3
      let col = (digit - 1) % 3
      digitRects[digit] = CGRect(x: CGFloat(col) * 86, y: CGFloat(row) * 56, width: 80, height: 49)
    }
    let frames = GlideTyping.nineKeyFrames(from: digitRects)
    let r7 = try XCTUnwrap(digitRects[7])
    let r8 = try XCTUnwrap(digitRects[8])
    let r5 = try XCTUnwrap(digitRects[5])
    let key7 = try XCTUnwrap(GlideTyping.nineKeyRepresentativeIndex(forDigit: 7))
    let key8 = try XCTUnwrap(GlideTyping.nineKeyRepresentativeIndex(forDigit: 8))
    let key5 = try XCTUnwrap(GlideTyping.nineKeyRepresentativeIndex(forDigit: 5))

    var tracker = GlideInflectionTracker()
    tracker.reset(initialKey: key7)

    // 1. 宽九键（80×49pt）内 14pt 的小幅折抖（< effectiveChordLength ≈ 20.6pt）不应误触发拐点反馈。
    let microJitter = [
      GlideTyping.Sample(x: r7.midX, y: r7.midY, milliseconds: 0),
      GlideTyping.Sample(x: r8.midX - 14, y: r8.midY, milliseconds: 30),
      GlideTyping.Sample(x: r8.midX, y: r8.midY, milliseconds: 50),
      GlideTyping.Sample(x: r8.midX, y: r8.midY - 14, milliseconds: 70),
    ]
    XCTAssertNil(tracker.detectAnchor(samples: microJitter, frames: frames))

    // 2. 明确跨键 90° 拐弯（7 → 8 → 5）应准确锚定拐点键 8。
    let realCorner = [
      GlideTyping.Sample(x: r7.midX, y: r7.midY, milliseconds: 0),
      GlideTyping.Sample(x: r8.midX, y: r8.midY, milliseconds: 40),
      GlideTyping.Sample(x: r8.midX, y: r8.midY - 10, milliseconds: 60),
      GlideTyping.Sample(x: r5.midX, y: r5.midY, milliseconds: 90),
    ]
    XCTAssertEqual(tracker.detectAnchor(samples: realCorner, frames: frames), key8)

    // 3. 在 5 键内以 ~13.4pt 轻微晃动驻留 95ms（26 键 11pt 会漏判，九键缩放半径 ~14.7pt 应正常锚定 5 键）。
    let nineKeyDwell = realCorner + [
      GlideTyping.Sample(x: r5.midX + 6, y: r5.midY + 4, milliseconds: 140),
      GlideTyping.Sample(x: r5.midX + 12, y: r5.midY + 6, milliseconds: 185),
    ]
    XCTAssertEqual(tracker.detectAnchor(samples: nineKeyDwell, frames: frames), key5)
  }
}
