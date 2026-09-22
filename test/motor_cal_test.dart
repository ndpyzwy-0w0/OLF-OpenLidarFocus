import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/motor_cal.dart';

void main() {
  const cal = MotorCal();

  test('0.9 degree motor is 400 full steps per revolution', () {
    expect(kFullStepsPerRev, 400);
    expect(cal.stepsPerRev(1), 400);
  });

  test('microsteps scale pulses per revolution', () {
    expect(cal.stepsPerRev(16), 6400);
    expect(cal.stepsPerRev(8), 3200);
    expect(cal.stepsPerRev(256), 102400);
  });

  test('revolutions convert to steps with sign and rounding', () {
    expect(cal.revsToSteps(1, 16), 6400);
    expect(cal.revsToSteps(2, 16), 12800);
    expect(cal.revsToSteps(-0.5, 16), -3200);
    // 0.1 rev is not a whole number of steps at 1/16
    expect(cal.revsToSteps(0.1, 16), 640);
    expect(cal.revsToSteps(0.01, 16), 64);
  });

  test('bad input degrades to no movement instead of throwing', () {
    expect(cal.revsToSteps(double.nan, 16), 0);
    expect(cal.revsToSteps(double.infinity, 16), 0);
    // microsteps of 0 must not divide by zero
    expect(cal.stepsPerRev(0), 400);
  });

  test('steps convert back to revolutions for display', () {
    expect(cal.stepsToRevs(6400, 16), closeTo(1.0, 1e-9));
    expect(cal.stepsToRevs(-3200, 16), closeTo(-0.5, 1e-9));
  });

  test('default soft limit scales with microsteps so travel is not clamped away', () {
    // 1/16: 20 rev = 128000 steps
    expect(cal.defaultLimitSpan(16), 128000);
    // 1/256 is 16x finer, so the same 20 revolutions needs 16x the steps.
    // A fixed step limit would shrink the usable travel to 0.2 rev.
    expect(cal.defaultLimitSpan(256), 2048000);
    expect(cal.defaultLimitSpan(256) ~/ cal.defaultLimitSpan(16), 16);
  });

  test('max physical speed drops as microsteps rise', () {
    // Ceiling is 40k steps/s. At 1/16 (6400 steps/rev) that is 6.25 rev/s;
    // at 1/256 (102400 steps/rev) the ceiling is only 0.39 rev/s. This is why
    // a speed setting in steps/s looked 16x slower after switching to 1/256.
    expect(cal.maxRevsPerSec(16), closeTo(6.25, 1e-9));
    expect(cal.maxRevsPerSec(256), closeTo(0.390625, 1e-9));
    expect(cal.maxRevsPerSec(16) / cal.maxRevsPerSec(256), closeTo(16, 1e-9));
  });

  test('peak speed depends on distance, which is why short jogs feel slow', () {
    // v_peak = sqrt(accel * distance) while that stays under cruise speed.
    // Hardware check at accel=500 steps/s^2 and 80 steps predicted 200
    // steps/s and measured ~220 steps/s.
    expect(cal.peakStepsPerSec(80, 500), closeTo(200, 1e-6));
    expect(cal.peakStepsPerSec(800, 500), closeTo(632.455, 0.01));
    // Doubling the distance raises the peak by sqrt(2), not by 2.
    expect(cal.peakStepsPerSec(160, 500) / cal.peakStepsPerSec(80, 500),
        closeTo(1.4142135, 1e-6));
  });

  test('peak rev/s is capped by cruise speed', () {
    // App defaults at 1/16: cruise 1.2 rev/s, accel 30 rev/s^2.
    const cruise = 7680, accel = 192000, ms = 16;
    // 800 steps can reach cruise: sqrt(192000*800) = 12393 > 7680, so capped.
    expect(cal.peakRevsPerSec(800, accel, cruise, ms), closeTo(1.2, 1e-9));
    // 80 steps cannot: sqrt(192000*80) = 3919 -> 0.61 rev/s, half the cruise.
    expect(cal.peakRevsPerSec(80, accel, cruise, ms), closeTo(0.6124, 1e-3));
    expect(cal.peakRevsPerSec(80, accel, cruise, ms),
        lessThan(cal.peakRevsPerSec(800, accel, cruise, ms)));
  });

  test('a different motor only changes the full-steps constant', () {
    // 1.8 degree motor would be 200 full steps per revolution
    const other = MotorCal(fullStepsPerRev: 200);
    expect(other.stepsPerRev(16), 3200);
  });
}
