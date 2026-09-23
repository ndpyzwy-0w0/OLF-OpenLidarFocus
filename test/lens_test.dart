import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/lens.dart';
import 'package:iphone_follow_focus/lens_lut.dart';

void main() {
  test('stroke is length-only and rescales with microsteps', () {
    final l = Lens(id: '1', name: 'x', strokeSteps: 6400, strokeMicrosteps: 16);
    expect(l.calibrated, isTrue);
    expect(l.strokeAt(16), 6400);
    // 1/256 is 16x finer, so the same physical travel needs 16x the pulses.
    expect(l.strokeAt(256), 102400);
    expect(Lens(id: '2', name: 'y').calibrated, isFalse);
    // 减号只是方向，行程长度取绝对值。
    expect(Lens(id: '3', name: 'z', strokeSteps: -6400, strokeMicrosteps: 16)
        .strokeAt(16), 6400);
  });

  test('aligned range only covers the far side of the nearest point', () {
    expect(alignedRange(1000, 1, 500), (lo: 1000, hi: 1500));
    expect(alignedRange(1000, -1, 500), (lo: 500, hi: 1000));
    // 行程为 0 时退化成一个点，而不是一个反向区间。
    expect(alignedRange(-3, 1, 0), (lo: -3, hi: -3));
  });

  test('inferDir reads the distance table direction', () {
    final rising = LensLut(const [
      LutPoint(meters: 1, steps: 0),
      LutPoint(meters: 3, steps: 900),
    ], microsteps: 16);
    expect(inferDir(rising), 1);
    final falling = LensLut(const [
      LutPoint(meters: 1, steps: 900),
      LutPoint(meters: 3, steps: 0),
    ], microsteps: 16);
    expect(inferDir(falling), -1);
    expect(inferDir(LensLut(const [])), isNull);
  });

  test('rebase puts the nearest table point onto today\'s nearest point', () {
    final lut = LensLut(const [
      LutPoint(meters: 1, steps: 300),
      LutPoint(meters: 3, steps: 5300),
    ], microsteps: 16);
    final delta = lutRebaseDelta(-200, lut);
    expect(delta, -500);
    final rebased = lut.shifted(delta);
    expect(rebased.points.first.steps, -200);
    // 平移不改变距离→步数的相对关系。
    expect(rebased.stepsFor(2), lut.stepsFor(2)! - 500);
  });

  test('lens survives a json round trip', () {
    final l = Lens(
      id: 'a',
      name: '50mm',
      params: 'F1.4',
      dir: -1,
      strokeSteps: 8000,
      strokeMicrosteps: 32,
      lut: LensLut(const [
        LutPoint(meters: 1, steps: 0),
        LutPoint(meters: 2, steps: 6400),
      ], microsteps: 32),
    );
    final back = Lens.fromJson(l.toJson());
    expect(back.id, 'a');
    expect(back.name, '50mm');
    expect(back.params, 'F1.4');
    expect(back.dir, -1);
    expect(back.strokeSteps, 8000);
    expect(back.strokeMicrosteps, 32);
    expect(back.lut.microsteps, 32);
    expect(back.lut.points.length, 2);
  });

  test('withoutStroke clears only the stroke', () {
    final l = Lens(
      id: 'a',
      name: '50mm',
      dir: -1,
      strokeSteps: 8000,
      lut: LensLut(const [LutPoint(meters: 1, steps: 5)], microsteps: 16),
    );
    final cleared = l.withoutStroke();
    expect(cleared.calibrated, isFalse);
    // 防误触清空的是行程，方向和历史标定要留着，方便重标后接着用。
    expect(cleared.dir, -1);
    expect(cleared.lut.points.length, 1);
  });
}
