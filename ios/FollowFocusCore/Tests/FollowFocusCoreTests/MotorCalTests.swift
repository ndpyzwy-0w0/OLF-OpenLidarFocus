import XCTest

@testable import FollowFocusCore

/// 从 Dart 的 `test/motor_cal_test.dart` 逐条搬过来。
final class MotorCalTests: XCTestCase {
  private let cal = MotorCal()

  func testMotorIs400FullStepsPerRev() {
    XCTAssertEqual(kFullStepsPerRev, 400)
    XCTAssertEqual(cal.stepsPerRev(1), 400)
  }

  func testMicrostepsScalePulsesPerRevolution() {
    XCTAssertEqual(cal.stepsPerRev(16), 6400)
    XCTAssertEqual(cal.stepsPerRev(8), 3200)
    XCTAssertEqual(cal.stepsPerRev(256), 102400)
  }

  func testRevolutionsConvertToStepsWithSignAndRounding() {
    XCTAssertEqual(cal.revsToSteps(1, 16), 6400)
    XCTAssertEqual(cal.revsToSteps(2, 16), 12800)
    XCTAssertEqual(cal.revsToSteps(-0.5, 16), -3200)
    // 0.1 rev is not a whole number of steps at 1/16
    XCTAssertEqual(cal.revsToSteps(0.1, 16), 640)
    XCTAssertEqual(cal.revsToSteps(0.01, 16), 64)
  }

  func testBadInputDegradesToNoMovementInsteadOfThrowing() {
    XCTAssertEqual(cal.revsToSteps(.nan, 16), 0)
    XCTAssertEqual(cal.revsToSteps(.infinity, 16), 0)
    // microsteps of 0 must not divide by zero
    XCTAssertEqual(cal.stepsPerRev(0), 400)
  }

  func testStepsConvertBackToRevolutionsForDisplay() {
    XCTAssertEqual(cal.stepsToRevs(6400, 16), 1.0, accuracy: 1e-9)
    XCTAssertEqual(cal.stepsToRevs(-3200, 16), -0.5, accuracy: 1e-9)
  }

  func testDefaultSoftLimitScalesWithMicrosteps() {
    // 1/16: 20 rev = 128000 steps
    XCTAssertEqual(cal.defaultLimitSpan(16), 128000)
    // 1/256 is 16x finer, so the same 20 revolutions needs 16x the steps.
    // A fixed step limit would shrink the usable travel to 0.2 rev.
    XCTAssertEqual(cal.defaultLimitSpan(256), 2048000)
    XCTAssertEqual(cal.defaultLimitSpan(256) / cal.defaultLimitSpan(16), 16)
  }

  func testMaxPhysicalSpeedDropsAsMicrostepsRise() {
    // Ceiling is 40k steps/s. At 1/16 (6400 steps/rev) that is 6.25 rev/s;
    // at 1/256 (102400 steps/rev) the ceiling is only 0.39 rev/s. This is why
    // a speed setting in steps/s looked 16x slower after switching to 1/256.
    XCTAssertEqual(cal.maxRevsPerSec(16), 6.25, accuracy: 1e-9)
    XCTAssertEqual(cal.maxRevsPerSec(256), 0.390625, accuracy: 1e-9)
    XCTAssertEqual(cal.maxRevsPerSec(16) / cal.maxRevsPerSec(256), 16, accuracy: 1e-9)
  }

  func testPeakSpeedDependsOnDistance() {
    // v_peak = sqrt(accel * distance) while that stays under cruise speed.
    // Hardware check at accel=500 steps/s^2 and 80 steps predicted 200
    // steps/s and measured ~220 steps/s.
    XCTAssertEqual(cal.peakStepsPerSec(80, 500), 200, accuracy: 1e-6)
    XCTAssertEqual(cal.peakStepsPerSec(800, 500), 632.455, accuracy: 0.01)
    // Doubling the distance raises the peak by sqrt(2), not by 2.
    XCTAssertEqual(
      cal.peakStepsPerSec(160, 500) / cal.peakStepsPerSec(80, 500),
      1.4142135,
      accuracy: 1e-6
    )
  }

  func testPeakRevsPerSecIsCappedByCruiseSpeed() {
    // App defaults at 1/16: cruise 1.2 rev/s, accel 30 rev/s^2.
    let cruise = 7680, accel = 192000, ms = 16
    // 800 steps can reach cruise: sqrt(192000*800) = 12393 > 7680, so capped.
    XCTAssertEqual(cal.peakRevsPerSec(800, accel, cruise, ms), 1.2, accuracy: 1e-9)
    // 80 steps cannot: sqrt(192000*80) = 3919 -> 0.61 rev/s, half the cruise.
    XCTAssertEqual(cal.peakRevsPerSec(80, accel, cruise, ms), 0.6124, accuracy: 1e-3)
    XCTAssertLessThan(
      cal.peakRevsPerSec(80, accel, cruise, ms),
      cal.peakRevsPerSec(800, accel, cruise, ms)
    )
  }

  func testADifferentMotorOnlyChangesTheFullStepsConstant() {
    // 1.8 degree motor would be 200 full steps per revolution
    let other = MotorCal(fullStepsPerRev: 200)
    XCTAssertEqual(other.stepsPerRev(16), 3200)
  }
}
