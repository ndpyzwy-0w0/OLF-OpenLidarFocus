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
}
