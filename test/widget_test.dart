import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/ff_core.dart';
import 'package:iphone_follow_focus/lens_page.dart';
import 'package:iphone_follow_focus/main.dart';

/// 伪造的核心：只记录命令、按需推快照。
///
/// 只覆盖 [FfCore.invoke] 这一个出口，所以**不碰平台通道**，也不需要在测试里
/// mock `ff.core`。这样测试断言的是“UI 发出了什么命令”，而不是 UI 里复制了一份逻辑 ——
/// UI 里本来就不该有逻辑。
class FakeCore extends FfCore {
  final calls = <String>[];
  final args = <String, Map<String, Object?>?>{};
  final _controller = StreamController<FfState>.broadcast();

  FfState state;
  List<FfDevice> devicesToReturn = const [];

  FakeCore([this.state = const FfState()]);

  @override
  Stream<FfState> states() async* {
    yield state;
    yield* _controller.stream;
  }

  @override
  Future<FfState> snapshot() async => state;

  @override
  Future<List<FfDevice>> discover() async => devicesToReturn;

  @override
  Future<void> invoke(String method, [Map<String, Object?>? a]) async {
    calls.add(method);
    args[method] = a;
  }

  /// 推一条新快照，模拟核心的状态更新。
  void push(FfState s) {
    state = s;
    _controller.add(s);
  }

  /// 某个命令是否被调用过。
  bool called(String method) => calls.contains(method);

  int countOf(String method) => calls.where((c) => c == method).length;
}

FfLens lens({
  String id = 'L1',
  String name = '50mm F1.4',
  String params = 'F1.4',
  bool calibrated = true,
  int dir = 1,
  int lutCount = 0,
  double strokeRevs = 1,
}) => FfLens(
  id: id,
  name: name,
  params: params,
  dir: dir,
  directionConfirmed: calibrated,
  lutReady: lutCount >= 5,
  lutCount: lutCount,
);

/// 跟焦页需要的完整状态。
FfState stateFor({
  FfLens? current,
  SetupPhase phase = SetupPhase.follow,
  FfFm03? fm03,
  String? distanceM,
  int pos = 1000,
  int? nearSteps = 1000,
  bool connected = true,
  bool enabled = true,
  bool auto = false,
  bool lutReady = true,
  List<FfLutPoint>? lutPoints,
  List<String> fm03Log = const [],
  int limitLo = 1000,
  int limitHi = 7400,
  bool calSupported = false,
  bool calDirectionPending = false,
  String calStage = 'idle',
  String appVersion = '',
  bool linkAlive = true,
  int? statusAgeMs,
}) {
  final l = current ?? lens();
  return FfState(
    appVersion: appVersion,
    connected: connected,
    linkAlive: connected && linkAlive,
    statusAgeMs: statusAgeMs,
    calSupported: calSupported,
    calDirectionPending: calDirectionPending,
    calStage: calStage,
    calSafeSpan: 8000,
    calTravel: 8512,
    enabled: enabled,
    pos: pos,
    target: pos,
    phase: phase,
    lensId: l.id,
    lensName: l.name,
    lenses: [l],
    nearSteps: nearSteps,
    dir: l.dir,
    strokeSteps: 4096,
    strokeRevs: 1,
    positionTrusted: true,
    lutReady: lutReady,
    lutPoints:
        lutPoints ??
        (lutReady
            ? const [
                FfLutPoint(meters: 0.5, steps: 100),
                FfLutPoint(meters: 1, steps: 800),
                FfLutPoint(meters: 2, steps: 2000),
                FfLutPoint(meters: 3, steps: 2800),
                FfLutPoint(meters: 5, steps: 3800),
              ]
            : const []),
    limitLo: limitLo,
    limitHi: limitHi,
    distanceM: distanceM == null ? null : double.parse(distanceM),
    auto: auto,
    microsteps: 1,
    stepsPerRev: 4096,
    maxRevsPerSec: 6.25,
    posRevs: pos / 6400,
    fm03: fm03,
    fm03Log: fm03Log,
  );
}

Future<void> pumpLensPage(WidgetTester tester, FakeCore core) async {
  await tester.pumpWidget(MaterialApp(home: LensPage(core: core)));
  await tester.pumpAndSettle();
}

/// 同一个测试里重复 pumpWidget 时，Flutter 会复用同类型同 key 的 State，
/// 于是 initState/订阅不会重跑、页面还停在上一个核心的状态上。
/// 每次给不同的 key，强制重建，测试才是真的在测“这一次的状态”。
Future<void> pumpFollowPage(WidgetTester tester, FakeCore core) async {
  await tester.pumpWidget(
    MaterialApp(
      home: FollowPage(
        key: UniqueKey(),
        core: core,
        lensId: core.state.lensId ?? 'L1',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 跟焦页最外面那个滚动视图。注意不能只用 find.byType(Scrollable)：
/// 展开 TMC 面板后里面的日志 ListView 也是一个 Scrollable，会匹配到两个。
Finder get pageScroll => find.byType(Scrollable).first;

Future<void> scrollTo(WidgetTester tester, Finder f) =>
    tester.scrollUntilVisible(f, 200, scrollable: pageScroll);

/// 控件在折叠面板里时，多半在可视区之外；直接 tap 会打空而不报错，
/// 所以统一先滚到可见再点。
Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await scrollTo(tester, f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('keyboard can be dismissed in a dialog without losing input', (
    tester,
  ) async {
    final core = FakeCore();
    await tester.pumpWidget(FollowApp(core: core));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建镜头'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '35mm');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tap(find.text('收起键盘'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.text('新建镜头'), findsWidgets);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '35mm',
    );
    expect(core.called('createLens'), isFalse);
    // 输入框也支持键盘完成键收起，保持已经输入的内容。
    tester.view.resetViewInsets();
    await tester.enterText(find.byType(TextField).last, 'F2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'F2',
    );
  });

  testWidgets('app bar shows the version the core reported', (tester) async {
    final core = FakeCore(
      stateFor(
        phase: SetupPhase.stroke,
        nearSteps: null,
        appVersion: '9.9.9+7',
      ),
    );
    await pumpFollowPage(tester, core);
    expect(find.text('v9.9.9+7'), findsOneWidget, reason: '版本要显示在主界面标题下');
  });

  testWidgets('app bar tells a dead link apart from a live one', (
    tester,
  ) async {
    // socket 开着但收不到状态回包：必须说"失去回包"，不能继续显示 EN/SLP/UART。
    final dead = FakeCore(
      stateFor(
        phase: SetupPhase.stroke,
        nearSteps: null,
        linkAlive: false,
        statusAgeMs: 42000,
      ),
    );
    await pumpFollowPage(tester, dead);
    expect(find.textContaining('失去回包'), findsOneWidget);

    // 同一个 socket，回包正常时照旧报 EN/IDLE（UART 位取决于 TMC 自检结果）。
    final alive = FakeCore(
      stateFor(phase: SetupPhase.stroke, nearSteps: null, statusAgeMs: 120),
    );
    await pumpFollowPage(tester, alive);
    expect(find.textContaining('失去回包'), findsNothing);
    expect(find.textContaining('IDLE'), findsOneWidget);
  });

  testWidgets(
    'auto stroke requires explicit confirmation and direction choice',
    (tester) async {
      final core = FakeCore(
        stateFor(
          phase: SetupPhase.stroke,
          nearSteps: null,
          current: lens(calibrated: false),
          calSupported: true,
        ),
      );
      await pumpFollowPage(tester, core);
      await tapVisible(tester, find.text('FM03 自动寻限位'));
      expect(find.textContaining('机械挡块'), findsOneWidget);
      await tester.tap(find.text('开始校准'));
      await tester.pumpAndSettle();
      expect(core.called('startAutoCalibration'), isTrue);
      expect(core.args['startAutoCalibration'], isNull);
      core.push(
        stateFor(
          phase: SetupPhase.align,
          calSupported: true,
          calDirectionPending: true,
          calStage: 'completed',
          nearSteps: null,
        ),
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('+ 方向变近'));
      expect(core.args['setDir'], {'dir': -1});
    },
  );
  testWidgets('app starts on the lens picker', (tester) async {
    final core = FakeCore();
    await tester.pumpWidget(FollowApp(core: core));
    await tester.pumpAndSettle();
    expect(find.text('选择镜头'), findsOneWidget);
    expect(find.text('还没有镜头，点下面新建一个。'), findsOneWidget);
  });

  testWidgets('picker lists stored lenses with their calibration state', (
    tester,
  ) async {
    final core = FakeCore(
      FfState(
        lenses: [
          lens(id: 'a', name: '50mm F1.4', params: 'F1.4', lutCount: 3),
          lens(id: 'b', name: '85mm', calibrated: false, dir: -1),
        ],
      ),
    );
    await pumpLensPage(tester, core);

    expect(find.text('50mm F1.4'), findsOneWidget);
    expect(find.text('85mm'), findsOneWidget);
    expect(find.textContaining('距离标定 3 点'), findsOneWidget);
    expect(find.textContaining('待选择物距方向'), findsOneWidget);
    expect(find.textContaining('物距变近：− 方向'), findsOneWidget);
    expect(find.textContaining('行程 1.00'), findsNothing);
  });

  testWidgets(
    'picking a lens selects it in the core then opens the follow page',
    (tester) async {
      final core = FakeCore(
        FfState(
          lenses: [lens()],
          // 选中后核心会把这个镜头设成当前并进入 follow
          lensId: 'L1',
          phase: SetupPhase.follow,
        ),
      );
      await pumpLensPage(tester, core);

      await tester.tap(find.text('50mm F1.4'));
      await tester.pumpAndSettle();

      expect(core.called('selectLens'), isTrue, reason: '选镜头要下发到核心');
      expect(core.args['selectLens']?['id'], 'L1');
      expect(find.text('跟焦器'), findsOneWidget);
    },
  );

  testWidgets(
    'new lens is created in the core, then opens into stroke calibration',
    (tester) async {
      final core = FakeCore(const FfState());
      await pumpLensPage(tester, core);

      await tester.tap(find.text('新建镜头'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '35mm');
      await tester.enterText(find.byType(TextField).last, 'F2');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect(core.called('createLens'), isTrue);
      expect(core.args['createLens']?['name'], '35mm');
      expect(core.args['createLens']?['params'], 'F2');
    },
  );

  testWidgets('empty name does not create a lens', (tester) async {
    final core = FakeCore(const FfState());
    await pumpLensPage(tester, core);

    await tester.tap(find.text('新建镜头'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(core.called('createLens'), isFalse, reason: '名称是必填');
    expect(find.text('名称（如 50mm F1.4）'), findsOneWidget, reason: '空名时对话框不关闭');
  });

  testWidgets('deleting a lens asks first, then tells the core', (
    tester,
  ) async {
    final core = FakeCore(FfState(lenses: [lens()]));
    await pumpLensPage(tester, core);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(core.args['deleteLens']?['id'], 'L1');
  });

  testWidgets(
    'limit search stays visible before connection and in follow phase',
    (tester) async {
      final disconnected = FakeCore(
        stateFor(phase: SetupPhase.stroke, connected: false),
      );
      await pumpFollowPage(tester, disconnected);
      expect(find.text('FM03 自动寻限位'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'FM03 自动寻限位'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('记录这一端 A'), findsNothing);
      expect(find.text('确认为焦距最近点'), findsNothing);
      final following = FakeCore(stateFor(calSupported: true));
      await pumpFollowPage(tester, following);
      await tapVisible(tester, find.text('FM03 自动寻限位'));
      expect(find.text('FM03 内部行程校准'), findsOneWidget);
      await tester.tap(find.text('开始校准'));
      await tester.pumpAndSettle();
      expect(following.called('startAutoCalibration'), isTrue);
    },
  );

  testWidgets('direction panel permits trial jog and selects near direction', (
    tester,
  ) async {
    final core = FakeCore(
      stateFor(phase: SetupPhase.align, calDirectionPending: true),
    );
    await pumpFollowPage(tester, core);
    expect(find.text('② 选择方向'), findsOneWidget);
    await tapVisible(tester, find.text('+80'));
    expect(core.args['jog']?['delta'], 80);
    await tapVisible(tester, find.text('+ 方向变近'));
    expect(core.args['setDir']?['dir'], -1);
    expect(find.text('确认为焦距最近点'), findsNothing);
  });

  testWidgets('five-point calibration displays chart and starts follow', (
    tester,
  ) async {
    final core = FakeCore(stateFor(phase: SetupPhase.calibrate));
    await pumpFollowPage(tester, core);
    expect(find.text('物距—旋转位置图表'), findsOneWidget);
    await tapVisible(tester, find.text('开始跟焦'));
    expect(core.called('startFollow'), isTrue);
  });

  testWidgets(
    'follow phase shows motor controls and no software origin action',
    (tester) async {
      final core = FakeCore(stateFor());
      await pumpFollowPage(tester, core);
      expect(find.text('手动焦点'), findsOneWidget);
      expect(find.text('物距变近方向'), findsOneWidget);
      expect(find.text('设当前位置为原点'), findsNothing);
      await tapVisible(tester, find.text('停'));
      expect(core.called('stopPressed'), isTrue);
    },
  );

  testWidgets('jog buttons send relative steps', (tester) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);

    await tapVisible(tester, find.text('+80'));
    expect(core.args['jog']?['delta'], 80);

    await tapVisible(tester, find.text('-800'));
    expect(core.args['jog']?['delta'], -800);
  });

  testWidgets('the 走圈 button converts revs to steps for the core', (
    tester,
  ) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);

    await tester.enterText(find.widgetWithText(TextField, '1').last, '0.5');
    await tapVisible(tester, find.text('移动'));

    // 0.5 行程 × 6400 脉冲/圈 = 3200。圈→步的换算是 UI 唯一的算术。
    expect(core.args['jog']?['delta'], 2048);
  });

  testWidgets(
    'auto focus chip requires completed setup and a valid five-point map',
    (tester) async {
      // 还没对齐：禁用
      final notAligned = FakeCore(
        stateFor(phase: SetupPhase.align, nearSteps: null),
      );
      await pumpFollowPage(tester, notAligned);
      expect(find.text('自动(先完成标定)'), findsOneWidget);
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '自动(先完成标定)'))
            .onSelected,
        isNull,
      );

      // 对齐了但距离标定只有一点：仍禁用
      final onePoint = FakeCore(stateFor(lutReady: false));
      await pumpFollowPage(tester, onePoint);
      expect(find.text('自动(需5点标定)'), findsOneWidget);

      // 对齐 + 两点：可用
      final ready = FakeCore(stateFor());
      await pumpFollowPage(tester, ready);
      await tapVisible(tester, find.text('自动跟焦'));
      expect(ready.args['setAuto']?['on'], true);
    },
  );

  testWidgets('manual slider is disabled while auto focus is on', (
    tester,
  ) async {
    final core = FakeCore(stateFor(auto: true));
    await pumpFollowPage(tester, core);

    expect(find.text('手动滑条（自动开时无效）'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider).first).onChanged, isNull);
  });

  testWidgets('recording a distance point goes to the core', (tester) async {
    final core = FakeCore(stateFor(distanceM: '2.34'));
    await pumpFollowPage(tester, core);

    await tapVisible(tester, find.text('记录当前'));
    expect(core.called('addLutPoint'), isTrue);
  });

  testWidgets('recording is disabled without a distance reading', (
    tester,
  ) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);

    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '记录当前'))
          .onPressed,
      isNull,
      reason: '没测到距离时不该能记录标定点',
    );
  });

  testWidgets('recalibrating the stroke is behind a long press and a confirm', (
    tester,
  ) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);

    // 需要先滚到“重新标定行程”。
    await scrollTo(tester, find.text('重置距离标定（长按）'));
    await tester.longPress(find.text('重置距离标定（长按）'));
    await tester.pumpAndSettle();
    expect(find.text('清空距离标定表？'), findsOneWidget, reason: '防误触：要先确认');

    await tester.tap(find.text('清空重标'));
    await tester.pumpAndSettle();
    expect(core.called('resetLensCalibration'), isTrue);
  });

  testWidgets('cancelling the recalibrate confirm changes nothing', (
    tester,
  ) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);

    await scrollTo(tester, find.text('重置距离标定（长按）'));
    await tester.longPress(find.text('重置距离标定（长按）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(core.called('resetLensCalibration'), isFalse);
  });

  testWidgets('diagnostics render from the snapshot, not from UI logic', (
    tester,
  ) async {
    final core = FakeCore(
      stateFor(
        fm03: const FfFm03(
          online: true,
          stage: 3,
          value: 0,
          maxSpeed: 64,
          tolerance: 4,
          gain: 4,
          rawPosition: 1000,
          txFailures: 0,
          rxMissed: 0,
          feedbackAge: 12,
          logLine: 'rms=800mA',
        ),
        fm03Log: ['12:00:00  rms=800mA'],
      ),
    );
    await pumpFollowPage(tester, core);

    await tapVisible(tester, find.text('功能可用性诊断'));
    // 尚未发过控制命令 → 序号回显那行直接说明这一点（文本来自快照，不是 UI 判断）。
    expect(find.text('尚未发送控制命令'), findsOneWidget);

    await tapVisible(tester, find.text('DJI FM03 · CAN'));
    expect(find.text('最大拨轮速度  64'), findsOneWidget);
    expect(find.text('12:00:00  rms=800mA'), findsOneWidget);
  });

  testWidgets('FM03 tolerance edits go to the core', (tester) async {
    final core = FakeCore(
      stateFor(
        fm03: const FfFm03(
          online: true,
          stage: 3,
          value: 0,
          maxSpeed: 64,
          tolerance: 4,
          gain: 4,
          rawPosition: 1000,
          txFailures: 0,
          rxMissed: 0,
          feedbackAge: 12,
          logLine: 'CAN 在线',
        ),
      ),
    );
    await pumpFollowPage(tester, core);
    await tapVisible(tester, find.text('DJI FM03 · CAN'));
    expect(find.textContaining('TMC2209'), findsNothing);
    await tapVisible(tester, find.text('到位容差  4'));
    await tester.enterText(find.byType(TextField).last, '8');
    await tester.tap(find.text('写入'));
    await tester.pumpAndSettle();
    expect(core.args['setFm03'], {'key': kFm03Tolerance, 'value': 8});
  });

  testWidgets('face toggle is disabled when LiDAR is unavailable', (
    tester,
  ) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);
    // macOS 主机上 Platform.isIOS 为 false，所以 LiDAR 不可用 → 人脸开关禁用。
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, '人脸'))
          .onSelected,
      isNull,
    );
  });
  testWidgets('manual measured distance can record without LiDAR', (
    tester,
  ) async {
    final core = FakeCore(stateFor(phase: SetupPhase.calibrate));
    await pumpFollowPage(tester, core);
    await scrollTo(tester, find.widgetWithText(TextField, '物距（m，可手动输入）'));
    await tester.enterText(
      find.widgetWithText(TextField, '物距（m，可手动输入）'),
      '2.5',
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('记录当前'));
    expect(core.args['addLutPoint']?['meters'], 2.5);
  });
}
