import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/ff_core.dart';
import 'package:iphone_follow_focus/ff_core_demo.dart';

/// `FfCoreDemo` 是 web 预览用的假核心，但它有真分支：相位推进、软限位、细分换算。
/// 这里钉住这几条，免得改坏之后 web 预览悄悄变成“点了没反应”。
void main() {
  test('auto calibration channel fields parse without control logic in Dart', () {
    final state = FfState.fromMap({
      'cal_supported': true,
      'cal_stage': 'seek_positive',
      'cal_error': 5,
      'cal_safe_span': 8000,
      'cal_travel': 8512,
      'cal_direction_pending': true,
      'lenses': [
        {'id': 'L', 'name': '50mm', 'auto_travel': 8512,
          'auto_safe_span': 8000, 'auto_rms_ma': 800,
          'auto_threshold': 60, 'auto_max_steps': 12800,
          'auto_firmware': '1.1.0'}
      ],
    });
    expect(state.calSupported, isTrue);
    expect(state.calStage, 'seek_positive');
    expect(state.calDirectionPending, isTrue);
    expect(state.lenses.single.autoThreshold, 60);
    expect(state.lenses.single.autoFirmware, '1.1.0');
  });
  test('web demo exposes auto stroke and direction confirmation', () async {
    final core = FfCoreDemo();
    await core.createLens(name: '35mm', params: '');
    await core.startAutoCalibration(threshold: 60, maxRevs: 2);
    var s = await core.snapshot();
    expect(s.calDirectionPending, isTrue);
    expect(s.calSafeSpan, greaterThan(0));
    await core.setDir(-1);
    s = await core.snapshot();
    expect(s.calDirectionPending, isFalse);
    expect(s.nearSteps, s.calSafeSpan);
  });
  test('预置一个已标定镜头，起始就在跟焦相位', () async {
    final s = await FfCoreDemo().snapshot();

    expect(s.lenses, hasLength(1));
    expect(s.lenses.single.calibrated, isTrue);
    expect(s.lutPoints, hasLength(2));
    expect(s.phase, SetupPhase.follow);
  });

  test('切镜头退回对齐相位，点“开始跟焦”才进跟焦', () async {
    final core = FfCoreDemo();
    await core.selectLens('demo');
    expect((await core.snapshot()).phase, SetupPhase.align);

    await core.startFollow();
    expect((await core.snapshot()).phase, SetupPhase.follow);
  });

  test('标定行程阶段没有软限位，jog 不会被夹死', () async {
    final core = FfCoreDemo();
    await core.createLens(name: '35mm', params: 'F2');
    var s = await core.snapshot();
    expect(s.phase, SetupPhase.stroke);
    expect((s.limitLo, s.limitHi), (0, 0));

    final before = s.pos;
    await core.invoke('jog', {'delta': 5000});
    s = await core.snapshot();
    expect(s.pos, before + 5000, reason: '标定行程时要能自由转到两端');
  });

  test('对齐后 jog 被软限位夹住', () async {
    final core = FfCoreDemo();
    await core.selectLens('demo');
    await core.confirmNear();
    await core.startFollow();
    final s = await core.snapshot();
    expect((s.limitLo, s.limitHi), (1000, 7400));

    await core.invoke('jog', {'delta': 99999});
    expect((await core.snapshot()).pos, s.limitHi);
    await core.invoke('jog', {'delta': -99999});
    expect((await core.snapshot()).pos, s.limitLo);
  });

  test('换细分保持物理位置（圈数不变）', () async {
    final core = FfCoreDemo();
    final before = await core.snapshot();

    await core.setMicrosteps(256);
    final after = await core.snapshot();

    expect(after.stepsPerRev, 400 * 256);
    expect(after.posRevs, closeTo(before.posRevs, 1e-9));
  });

  test('把镜头删光不崩，回到空列表', () async {
    final core = FfCoreDemo();
    await core.deleteLens('demo');
    final s = await core.snapshot();

    expect(s.lenses, isEmpty);
    expect(s.lensId, isNull);
  });
}
