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

  test('a different motor only changes the full-steps constant', () {
    // 1.8 degree motor would be 200 full steps per revolution
    const other = MotorCal(fullStepsPerRev: 200);
    expect(other.stepsPerRev(16), 3200);
  });
}
