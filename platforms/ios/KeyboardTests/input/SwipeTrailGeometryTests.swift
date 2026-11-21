import XCTest
import CoreGraphics

/// 参照精确的滑行轨迹几何（T1，自 GlideKeyboard MIT 移植）：期望值按转录
/// 算法手工推算（GlideKeyboard docs/GLIDE_TRAIL_REFERENCE_AND_PLAN.md §1.3），
/// 不是跑参照 App 得到的。
final class SwipeTrailGeometryTests: XCTestCase {
  private func assertPoint(_ actual: CGPoint, _ expected: CGPoint,
                           accuracy: CGFloat = 1e-9,
                           file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
  }

  func testConstantsMatchReference() {
    XCTAssertEqual(SwipeTrailGeometry.maxWidth, 22)
    XCTAssertEqual(SwipeTrailGeometry.growthLength, 40)
    XCTAssertEqual(SwipeTrailGeometry.windowLength, 150)
    XCTAssertEqual(SwipeTrailGeometry.minSpacing, 2)
    XCTAssertEqual(SwipeTrailGeometry.normalEpsilon, 0.001)
  }

  func testDedupDropsBelowTwoPointsAndKeepsExactlyTwo() {
    var geometry = SwipeTrailGeometry()
    geometry.append(CGPoint(x: 0, y: 0))
    geometry.append(CGPoint(x: 1.999, y: 0))
    XCTAssertEqual(geometry.count, 1)
    geometry.append(CGPoint(x: 2, y: 0))
    XCTAssertEqual(geometry.count, 2, "恰好等于间距的采样保留")
    geometry.append(CGPoint(x: 3.9, y: 0))
    XCTAssertEqual(geometry.count, 2, "距离按上一个保留点量")
    geometry.append(CGPoint(x: 4, y: 0))
    XCTAssertEqual(geometry.count, 3)
  }

  func testTrimKeepsMostRecentWindow() {
    var geometry = SwipeTrailGeometry()
    for x in stride(from: 0, through: 190, by: 10) {
      geometry.append(CGPoint(x: CGFloat(x), y: 0))
    }
    // 向后走越过 150 的段是 30→40，所以 x < 40 的点被丢掉。
    XCTAssertEqual(geometry.count, 16)
    assertPoint(geometry.points.first!, CGPoint(x: 40, y: 0))
    assertPoint(geometry.points.last!, CGPoint(x: 190, y: 0))
    XCTAssertEqual(geometry.totalLength, 150, accuracy: 1e-9)
  }

  func testTrimKeepsExactlyWindowWhole() {
    var geometry = SwipeTrailGeometry()
    for x in stride(from: 0, through: 150, by: 10) {
      geometry.append(CGPoint(x: CGFloat(x), y: 0))
    }
    XCTAssertEqual(geometry.count, 16, "恰好 150pt 不超过窗口")
    XCTAssertEqual(geometry.totalLength, 150, accuracy: 1e-9)
  }

  func testWidthGrowsWithLengthAndSaturates() {
    var geometry = SwipeTrailGeometry()
    geometry.append(CGPoint(x: 0, y: 0))
    geometry.append(CGPoint(x: 10, y: 0))
    XCTAssertEqual(geometry.bandWidth, 5.5, accuracy: 1e-9)
    geometry.append(CGPoint(x: 40, y: 0))
    XCTAssertEqual(geometry.totalLength, 40, accuracy: 1e-9)
    XCTAssertEqual(geometry.bandWidth, 22, accuracy: 1e-9)
    geometry.append(CGPoint(x: 100, y: 0))
    XCTAssertEqual(geometry.bandWidth, 22, accuracy: 1e-9, "超过 40pt 后饱和")
  }

  func testStraightFixtureTaperAndFullWidthTip() {
    var geometry = SwipeTrailGeometry()
    geometry.append(CGPoint(x: 0, y: 0))
    geometry.append(CGPoint(x: 50, y: 0))
    geometry.append(CGPoint(x: 100, y: 0))
    XCTAssertEqual(geometry.totalLength, 100, accuracy: 1e-9)
    XCTAssertEqual(geometry.bandWidth, 22, accuracy: 1e-9)
    XCTAssertEqual(geometry.arcPositions(), [0, 50, 100])
    let (left, right) = geometry.edges()
    // 沿 +x 直行的中心差分法线是 (0, 1)；半宽 0 / 5.5 / 11——笔尖达到满宽，
    // 不塌陷。
    assertPoint(left[0], CGPoint(x: 0, y: 0))
    assertPoint(left[1], CGPoint(x: 50, y: 5.5))
    assertPoint(left[2], CGPoint(x: 100, y: 11))
    assertPoint(right[0], CGPoint(x: 0, y: 0))
    assertPoint(right[1], CGPoint(x: 50, y: -5.5))
    assertPoint(right[2], CGPoint(x: 100, y: -11))
  }

  func testCornerFixtureUsesCentralDifference() {
    var geometry = SwipeTrailGeometry()
    geometry.append(CGPoint(x: 0, y: 0))
    geometry.append(CGPoint(x: 40, y: 0))
    geometry.append(CGPoint(x: 40, y: 30))
    XCTAssertEqual(geometry.totalLength, 70, accuracy: 1e-9)
    let (left, right) = geometry.edges()
    // 拐角处的中心差分是 p[2]−p[0] = (40, 30)，法线 (−0.6, 0.8)；
    // 半宽 = 22 × 40 / 70 × 0.5。
    let half = 22.0 * 40.0 / 70.0 * 0.5
    assertPoint(left[1], CGPoint(x: 40 - 0.6 * half, y: 0.8 * half))
    assertPoint(right[1], CGPoint(x: 40 + 0.6 * half, y: -0.8 * half))
    // 笔尖保持最后一段的方向 (0, 1)，满宽。
    assertPoint(left[2], CGPoint(x: 29, y: 30))
    assertPoint(right[2], CGPoint(x: 51, y: 30))
  }

  func testPathConstructionSequence() {
    var geometry = SwipeTrailGeometry()
    geometry.append(CGPoint(x: 0, y: 0))
    geometry.append(CGPoint(x: 50, y: 0))
    geometry.append(CGPoint(x: 100, y: 0))
    let path = geometry.path()
    var elements: [CGPathElementType] = []
    var firstMove: CGPoint?
    path.applyWithBlock { element in
      elements.append(element.pointee.type)
      if element.pointee.type == .moveToPoint, firstMove == nil {
        firstMove = element.pointee.points[0]
      }
    }
    XCTAssertEqual(elements.first, .moveToPoint)
    XCTAssertEqual(elements.last, .closeSubpath)
    XCTAssertEqual(firstMove, CGPoint(x: 0, y: 0), "从尾端左边缘出发")
    XCTAssertTrue(elements.contains(.addLineToPoint), "直线边缘，不做平滑")
    XCTAssertTrue(elements.contains(.addCurveToPoint), "笔帽圆弧变成三次曲线")
    // 笔帽沿笔画轴伸出笔尖一个半径，跨度是整条带宽。
    XCTAssertEqual(path.boundingBoxOfPath.minX, 0, accuracy: 1e-6)
    XCTAssertEqual(path.boundingBoxOfPath.maxX, 111, accuracy: 1e-6)
    XCTAssertEqual(path.boundingBoxOfPath.height, 22, accuracy: 1e-6)
  }

  func testBelowTwoPointsDrawsNothing() {
    var geometry = SwipeTrailGeometry()
    XCTAssertTrue(geometry.path().isEmpty)
    geometry.append(CGPoint(x: 5, y: 5))
    XCTAssertTrue(geometry.path().isEmpty, "不画单点圆盘")
    XCTAssertTrue(geometry.edges().left.isEmpty)
  }

  func testNonFiniteSamplesRejected() {
    var geometry = SwipeTrailGeometry()
    geometry.append(CGPoint(x: CGFloat.nan, y: 0))
    geometry.append(CGPoint(x: 0, y: CGFloat.infinity))
    XCTAssertTrue(geometry.isEmpty)
    geometry.append(CGPoint(x: 0, y: 0))
    geometry.append(CGPoint(x: CGFloat.nan, y: CGFloat.nan))
    XCTAssertEqual(geometry.count, 1)
  }

  func testResetClearsEverything() {
    var geometry = SwipeTrailGeometry()
    geometry.append(CGPoint(x: 0, y: 0))
    geometry.append(CGPoint(x: 30, y: 0))
    geometry.reset()
    XCTAssertTrue(geometry.isEmpty)
    XCTAssertEqual(geometry.totalLength, 0)
    XCTAssertEqual(geometry.bandWidth, 0)
    XCTAssertTrue(geometry.path().isEmpty)
  }

  func testWindowSlidesWithNewSamples() {
    var geometry = SwipeTrailGeometry()
    for x in stride(from: 0, through: 200, by: 10) {
      geometry.append(CGPoint(x: CGFloat(x), y: 0))
    }
    XCTAssertEqual(geometry.points.first!.x, 50, accuracy: 1e-9)
    geometry.append(CGPoint(x: 260, y: 0))
    XCTAssertEqual(geometry.points.first!.x, 110, accuracy: 1e-9)
    XCTAssertEqual(geometry.totalLength, 150, accuracy: 1e-9)
  }

  func testSmoothedRoundsInteriorCornersAndPreservesEndpoints() {
    let pair = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 40)]
    XCTAssertEqual(SwipeTrailGeometry.smoothed(pair), pair)

    let corner = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 40)]
    let smoothed = SwipeTrailGeometry.smoothed(corner)
    XCTAssertEqual(smoothed.first, corner.first)
    XCTAssertEqual(smoothed.last, corner.last)
    XCTAssertEqual(smoothed.count, 4)
    XCTAssertEqual(smoothed[1], CGPoint(x: 30, y: 0))
    XCTAssertEqual(smoothed[2], CGPoint(x: 40, y: 10))
  }
}
