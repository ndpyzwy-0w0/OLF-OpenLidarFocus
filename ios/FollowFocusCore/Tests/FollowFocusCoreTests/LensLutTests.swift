import XCTest

@testable import FollowFocusCore

/// 从 Dart 的 `test/lens_lut_test.dart` 逐条搬过来。
final class LensLutTests: XCTestCase {
  func testTwoPointInverseDistanceInterpolation() {
    let lut = LensLut([
      LutPoint(meters: 1.0, steps: 0),
      LutPoint(meters: 2.0, steps: 1000),
    ])
    XCTAssertTrue(lut.ready)
    XCTAssertEqual(lut.stepsFor(1.0), 0)
    XCTAssertEqual(lut.stepsFor(2.0), 1000)
    XCTAssertEqual(lut.stepsFor(0.5), 0)
    XCTAssertEqual(lut.stepsFor(8.0), 1000)
    // 1/1.5 sits 2/3 of the way from 1/1 toward 1/2
    XCTAssertEqual(lut.stepsFor(1.5), 667)
  }

  func testNeedsTwoPoints() {
    XCTAssertNil(LensLut([]).stepsFor(1))
    XCTAssertNil(LensLut([LutPoint(meters: 1, steps: 10)]).stepsFor(1))
  }

  func testMultipointKeepsOrderAndReplacesNearby() {
    var lut = LensLut([
      LutPoint(meters: 2.0, steps: 200),
      LutPoint(meters: 0.7, steps: 0),
    ])
    lut = lut.adding(LutPoint(meters: 1.0, steps: 80))
    XCTAssertEqual(lut.points.map(\.meters), [0.7, 1.0, 2.0])
    lut = lut.adding(LutPoint(meters: 1.01, steps: 90))
    XCTAssertEqual(lut.points.count, 3)
    XCTAssertEqual(lut.points[1].steps, 90)
  }

  func testRemovingAPointKeepsTheRest() {
    let lut = LensLut([
      LutPoint(meters: 1, steps: 0),
      LutPoint(meters: 2, steps: 100),
    ]).removingAt(0)
    XCTAssertEqual(lut.points.count, 1)
    XCTAssertEqual(lut.points[0].meters, 2)
    // 越界删除用原表返回，而不是崩。
    XCTAssertEqual(lut.removingAt(9).points.count, 1)
  }

  func testDistFilterJumpsFasterThanItIdles() {
    let f = DistFilter()
    XCTAssertEqual(f.update(1.0), 1.0)
    XCTAssertEqual(f.update(1.01), 1.002, accuracy: 0.01)
    f.reset()
    _ = f.update(1.0)
    XCTAssertEqual(f.update(2.0), 1.55, accuracy: 0.01)
  }

  func testCalibrationRescalesWhenMicrostepsChange() {
    // 1 rev of travel recorded as 6400 steps at 1/16
    let lut = LensLut([
      LutPoint(meters: 1.0, steps: 0),
      LutPoint(meters: 2.0, steps: 6400),
    ], microsteps: 16)
    XCTAssertEqual(lut.stepsFor(2.0), 6400)

    // Same physical travel at 1/256 must be 16x the steps, not the same number.
    let fine = lut.scaledTo(256)
    XCTAssertEqual(fine.microsteps, 256)
    XCTAssertEqual(fine.stepsFor(2.0), 102400)
    // The distance->focus mapping itself must be unchanged (allow rounding).
    XCTAssertEqual(
      Double(fine.stepsFor(1.5)!), Double(lut.stepsFor(1.5)!) * 16, accuracy: 20)
  }

  func testScalingToSameMicrostepsReturnsItself() {
    let lut = LensLut([LutPoint(meters: 1, steps: 5)], microsteps: 16)
    XCTAssertEqual(lut.scaledTo(16), lut)
  }

  func testAddingAPointUnifiesTheWholeTableOnTheCurrentMicrosteps() {
    var lut = LensLut([
      LutPoint(meters: 1.0, steps: 0),
      LutPoint(meters: 2.0, steps: 6400),
    ], microsteps: 16)
    lut = lut.adding(LutPoint(meters: 3.0, steps: 51200), microsteps: 256)
    XCTAssertEqual(lut.microsteps, 256)
    XCTAssertEqual(lut.points.count, 3)
    // the older 6400-step point was converted, not left stale
    XCTAssertEqual(lut.points.map(\.steps), [0, 102400, 51200])
  }

  func testMicrostepsSurviveAJsonRoundTrip() {
    let lut = LensLut([LutPoint(meters: 1, steps: 100)], microsteps: 32)
    let back = LensLut(jsonObject: lut.jsonObject)
    XCTAssertEqual(back.microsteps, 32)
    XCTAssertEqual(back.points.count, 1)
    XCTAssertEqual(back.points[0].steps, 100)
    XCTAssertEqual(back.points[0].meters, 1)
  }
}
