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

  test('a different motor only changes the full-steps constant', () {
    // 1.8 degree motor would be 200 full steps per revolution
    const other = MotorCal(fullStepsPerRev: 200);
    expect(other.stepsPerRev(16), 3200);
  });
}
