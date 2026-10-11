import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/ff_core.dart';
import 'package:iphone_follow_focus/ff_core_demo.dart';

void main() {
  test(
    'new lens previews limits then direction then five-point calibration',
    () async {
      final core = FfCoreDemo();
      await core.createLens(name: '35mm', params: '');
      expect((await core.snapshot()).phase, SetupPhase.stroke);
      await core.startAutoCalibration();
      expect((await core.snapshot()).calDirectionPending, isTrue);
      await core.setDir(-1);
      expect((await core.snapshot()).phase, SetupPhase.calibrate);
      await core.startFollow();
      expect((await core.snapshot()).phase, SetupPhase.calibrate);
    },
  );

  test('saved five-point map survives repeated limit search', () async {
    final core = FfCoreDemo();
    final original = await core.snapshot();
    expect(original.lutReady, isTrue);
    expect(original.lutPoints, hasLength(5));
    expect(original.lutCurve, isNotEmpty);
    await core.selectLens('demo');
    expect((await core.snapshot()).phase, SetupPhase.stroke);
    await core.startAutoCalibration();
    expect((await core.snapshot()).lutPoints.length, 5);
    await core.startFollow();
    expect((await core.snapshot()).phase, SetupPhase.follow);
  });

  test(
    'reset clears map and direction but keeps motor session limits',
    () async {
      final core = FfCoreDemo();
      await core.resetLensCalibration();
      final s = await core.snapshot();
      expect(s.lutPoints, isEmpty);
      expect(s.calDirectionPending, isTrue);
      expect(s.calSafeSpan, 4096);
    },
  );

  test('jog stays within FM03 normalized coordinates', () async {
    final core = FfCoreDemo();
    await core.jog(99999);
    expect((await core.snapshot()).pos, 4096);
    await core.jog(-99999);
    expect((await core.snapshot()).pos, 0);
  });

  test('channel carries curve and core readiness without Dart fit logic', () {
    final s = FfState.fromMap({
      'phase': 'calibrate',
      'lut_ready': true,
      'lut_curve': [
        {'meters': 2.0, 'steps': 1800},
      ],
      'lenses': [
        {
          'id': 'L',
          'direction_confirmed': true,
          'lut_ready': true,
          'lut_count': 5,
        },
      ],
    });
    expect(s.phase, SetupPhase.calibrate);
    expect(s.lutReady, isTrue);
    expect(s.lutCurve.single.steps, 1800);
    expect(s.lenses.single.directionConfirmed, isTrue);
  });

  test('FM03 settings preserve coordinate scale', () async {
    final core = FfCoreDemo();
    await core.setFm03(kFm03Tolerance, 8);
    final s = await core.snapshot();
    expect(s.stepsPerRev, 4096);
    expect(s.fm03Log.last, contains('key=2 value=8'));
  });

  test('deleting all lenses leaves an empty list', () async {
    final core = FfCoreDemo();
    await core.deleteLens('demo');
    final s = await core.snapshot();
    expect(s.lenses, isEmpty);
    expect(s.lensId, isNull);
  });
}
