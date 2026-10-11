import XCTest
@testable import FollowFocusCore

final class LensLutTests: XCTestCase {
  private var points: [LutPoint] { [
    LutPoint(meters: 0.5, steps: 0), LutPoint(meters: 1, steps: 1000),
    LutPoint(meters: 2, steps: 2000), LutPoint(meters: 3, steps: 3000),
    LutPoint(meters: 5, steps: 4000)] }

  func testFivePointsAndDirectionAreRequired() {
    XCTAssertFalse(LensLut(Array(points.prefix(4))).ready)
    let lut = LensLut(points)
    XCTAssertTrue(lut.ready)
    XCTAssertTrue(lut.matchesDirection(1))
    XCTAssertFalse(lut.matchesDirection(-1))
    XCTAssertTrue(LensLut(points.map { LutPoint(meters: $0.meters, steps: 4096 - $0.steps) }).matchesDirection(-1))
    XCTAssertFalse(LensLut(points + [LutPoint(meters: 6, steps: 100)]).ready)
  }

  func testInverseDistanceInterpolationAndEndpointClamping() {
    let lut = LensLut(points)
    XCTAssertEqual(lut.stepsFor(1.5), 1667)
    XCTAssertEqual(lut.stepsFor(0.1), 0)
    XCTAssertEqual(lut.stepsFor(100), 4000)
    for point in points { XCTAssertEqual(lut.stepsFor(point.meters), point.steps) }
    XCTAssertNil(lut.stepsFor(.nan))
    XCTAssertNil(lut.stepsFor(.infinity))
    XCTAssertNil(lut.stepsFor(-1))
  }

  func testChartSamplesTheSameMappingAsFollowFocus() {
    let lut = LensLut(points)
    XCTAssertEqual(lut.curve.count, 81)
    for sample in lut.curve { XCTAssertEqual(sample.steps, lut.stepsFor(sample.meters)) }
    XCTAssertFalse(LensLut(Array(points.prefix(2))).curve.isEmpty)
  }

  func testReplacingNearbyDistanceAndRemovingDisableFollow() {
    let lut = LensLut(points).adding(LutPoint(meters: 1.01, steps: 1100))
    XCTAssertEqual(lut.points.count, 5)
    XCTAssertEqual(lut.points[1].steps, 1100)
    XCTAssertFalse(lut.removingAt(0).ready)
    XCTAssertEqual(lut.removingAt(100), lut)
  }

  func testInvalidStoredOrAddedPointsCannotCorruptInterpolation() {
    let lut = LensLut(points)
    for p in [LutPoint(meters: .nan, steps: 3), LutPoint(meters: 0, steps: 3),
      LutPoint(meters: 2, steps: 4097), LutPoint(meters: 2, steps: -1)] {
      XCTAssertEqual(lut.adding(p), lut)
      XCTAssertEqual(LensLut(points + [p]), lut)
    }
    XCTAssertFalse(LensLut(points + [points[0]]).ready)
    XCTAssertEqual(LensLut(jsonObject: lut.jsonObject), lut)
  }

  func testDistFilterJumpsFasterThanItIdles() {
    let f = DistFilter()
    XCTAssertEqual(f.update(1), 1)
    XCTAssertEqual(f.update(1.01), 1.002, accuracy: 0.01)
    f.reset()
    XCTAssertEqual(f.update(2), 2)
  }
}
