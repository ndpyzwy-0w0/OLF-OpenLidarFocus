import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/lens_lut.dart';

void main() {
  test('two-point 1/distance interpolation', () {
    final lut = LensLut(const [
      LutPoint(meters: 1.0, steps: 0),
      LutPoint(meters: 2.0, steps: 1000),
    ]);
    expect(lut.ready, isTrue);
    expect(lut.stepsFor(1.0), 0);
    expect(lut.stepsFor(2.0), 1000);
    expect(lut.stepsFor(0.5), 0);
    expect(lut.stepsFor(8.0), 1000);
    // 1/1.5 sits 2/3 of the way from 1/1 toward 1/2
    expect(lut.stepsFor(1.5), 667);
  });

  test('needs two points', () {
    expect(LensLut(const []).stepsFor(1), isNull);
    expect(
      LensLut(const [LutPoint(meters: 1, steps: 10)]).stepsFor(1),
      isNull,
    );
  });

  test('multipoint keeps order and replaces nearby', () {
    var lut = LensLut(const [
      LutPoint(meters: 2.0, steps: 200),
      LutPoint(meters: 0.7, steps: 0),
    ]);
    lut = lut.adding(const LutPoint(meters: 1.0, steps: 80));
    expect(lut.points.map((p) => p.meters).toList(), [0.7, 1.0, 2.0]);
    lut = lut.adding(const LutPoint(meters: 1.01, steps: 90));
    expect(lut.points.length, 3);
    expect(lut.points[1].steps, 90);
  });

  test('dist filter jumps faster than it idles', () {
    final f = DistFilter();
    expect(f.update(1.0), 1.0);
    final still = f.update(1.01);
    expect(still, closeTo(1.002, 0.01));
    f.reset();
    f.update(1.0);
    final jump = f.update(2.0);
    expect(jump, closeTo(1.55, 0.01));
  });

  test('calibration rescales when microsteps change', () {
    // 1 rev of travel recorded as 6400 steps at 1/16
    final lut = LensLut(const [
      LutPoint(meters: 1.0, steps: 0),
      LutPoint(meters: 2.0, steps: 6400),
    ], microsteps: 16);
    expect(lut.stepsFor(2.0), 6400);

    // Same physical travel at 1/256 must be 16x the steps, not the same number.
    final fine = lut.scaledTo(256);
    expect(fine.microsteps, 256);
    expect(fine.stepsFor(2.0), 102400);
    // The distance->focus mapping itself must be unchanged (allow rounding).
    expect(fine.stepsFor(1.5), closeTo(lut.stepsFor(1.5)! * 16, 20));
  });

  test('adding a point unifies the whole table on the current microsteps', () {
    var lut = LensLut(const [
      LutPoint(meters: 1.0, steps: 0),
      LutPoint(meters: 2.0, steps: 6400),
    ], microsteps: 16);
    lut = lut.adding(const LutPoint(meters: 3.0, steps: 51200), microsteps: 256);
    expect(lut.microsteps, 256);
    expect(lut.points.length, 3);
    // the older 6400-step point was converted, not left stale
    expect(lut.points.map((p) => p.steps).toList(), [0, 102400, 51200]);
  });

  test('microsteps survive a save/load round trip', () {
    final lut = LensLut(const [LutPoint(meters: 1, steps: 100)],
        microsteps: 32);
    final back = LensLut.fromJson(lut.toJson());
    expect(back.microsteps, 32);
    expect(back.points.single.steps, 100);
  });
}
