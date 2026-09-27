import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/app_dialog.dart';
import 'package:iphone_follow_focus/device_page.dart';
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
  calibrated: calibrated,
  strokeSteps: (strokeRevs * 6400).round(),
  strokeRevs: strokeRevs,
  lutCount: lutCount,
);

/// 跟焦页需要的完整状态。
FfState stateFor({
  FfLens? current,
  SetupPhase phase = SetupPhase.follow,
  FfTmc? tmc,
  String? distanceM,
  int pos = 1000,
  int? nearSteps = 1000,
  bool connected = true,
  bool enabled = true,
  bool auto = false,
  bool lutReady = true,
  List<FfLutPoint>? lutPoints,
  List<String> tmcLog = const [],
  int limitLo = 1000,
  int limitHi = 7400,
}) {
  final l = current ?? lens();
  return FfState(
    connected: connected,
    enabled: enabled,
    pos: pos,
    target: pos,
    phase: phase,
    lensId: l.id,
    lensName: l.name,
    lenses: [l],
    nearSteps: nearSteps,
    dir: l.dir,
    strokeSteps: l.strokeSteps,
    strokeRevs: l.strokeRevs,
    lutPoints:
        lutPoints ??
        (lutReady
            ? const [
                FfLutPoint(meters: 1, steps: 1000),
                FfLutPoint(meters: 2, steps: 4200),
              ]
            : const []),
    limitLo: limitLo,
    limitHi: limitHi,
    distanceM: distanceM == null ? null : double.parse(distanceM),
    auto: auto,
    microsteps: 16,
    stepsPerRev: 6400,
    maxRevsPerSec: 6.25,
    posRevs: pos / 6400,
    tmc: tmc,
    tmcLog: tmcLog,
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
  testWidgets('app follows system brightness with distinct themes', (
    tester,
  ) async {
    await tester.pumpWidget(FollowApp(core: FakeCore()));
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(
      app.theme!.scaffoldBackgroundColor,
      isNot(app.darkTheme!.scaffoldBackgroundColor),
    );
  });

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
    // 已标定：显示行程圈数；未标定：明说未标定。
    expect(
      find.textContaining('行程 1.00 圈'),
      findsOneWidget,
      reason: '已标定行程要显示圈数',
    );
    expect(find.textContaining('未标定行程'), findsOneWidget);
    expect(find.textContaining('距离标定 3 点'), findsOneWidget);
    expect(find.textContaining('焦距变远：- 方向'), findsOneWidget);
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
    expect(find.byType(AppActionDialog), findsOneWidget);
    expect(find.text('此操作无法撤销'), findsNothing);
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
    expect(find.text('此操作无法撤销'), findsOneWidget);
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(
      (dialog.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(16),
    );
    expect(
      tester.getSize(find.widgetWithText(FilledButton, '取消')).width,
      tester.getSize(find.widgetWithText(FilledButton, '删除镜头')).width,
    );
    await tester.tap(find.widgetWithText(FilledButton, '删除镜头'));
    await tester.pumpAndSettle();

    expect(core.args['deleteLens']?['id'], 'L1');
  });

  testWidgets('an uncalibrated lens opens into stroke calibration', (
    tester,
  ) async {
    final core = FakeCore(
      stateFor(
        current: lens(calibrated: false, strokeRevs: 0),
        phase: SetupPhase.stroke,
        nearSteps: null,
      ),
    );
    await pumpFollowPage(tester, core);

    // 顶部相位标签和面板标题都会写“① 标定行程”，所以是两个。
    expect(find.text('① 标定行程'), findsNWidgets(2));
    expect(find.text('记录这一端 A'), findsOneWidget);
    expect(find.text('记录另一端 B，完成标定'), findsOneWidget);
    // 标定阶段的按钮不能提前可用。
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
      isNull,
      reason: '还没记录 A 就不能完成标定',
    );
    expect(find.textContaining('② 单侧对齐'), findsNothing);
  });

  testWidgets('a calibrated lens opens straight into single-side alignment', (
    tester,
  ) async {
    final core = FakeCore(stateFor(phase: SetupPhase.align, nearSteps: null));
    await pumpFollowPage(tester, core);

    expect(find.text('② 单侧对齐'), findsNWidgets(2));
    expect(find.text('确认为焦距最近点'), findsOneWidget);
    expect(find.text('开始跟焦'), findsNothing, reason: '还没确认最近点，不该出现“开始跟焦”');
    expect(find.text('焦距变远方向'), findsNothing);
  });

  testWidgets('after confirming the nearest point it asks for the direction', (
    tester,
  ) async {
    final core = FakeCore(stateFor(phase: SetupPhase.align, nearSteps: 1000));
    await pumpFollowPage(tester, core);

    expect(find.text('最近点 = 1000 步'), findsOneWidget);
    expect(find.text('从最近点往哪个旋转方向是“焦距变远”？'), findsOneWidget);
    expect(find.text('+ 方向变远'), findsOneWidget);

    await tapVisible(tester, find.text('开始跟焦'));
    expect(core.called('startFollow'), isTrue);
  });

  testWidgets('alignment actions go to the core', (tester) async {
    final core = FakeCore(stateFor(phase: SetupPhase.align, nearSteps: null));
    await pumpFollowPage(tester, core);

    await tapVisible(tester, find.text('确认为焦距最近点'));
    expect(core.called('confirmNear'), isTrue);
  });

  testWidgets('follow phase shows focus controls, not calibration panels', (
    tester,
  ) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);

    expect(find.text('手动焦点'), findsOneWidget);
    await tapVisible(tester, find.text('距离标定与方向'));
    expect(find.text('距离标定'), findsOneWidget);
    expect(find.text('焦距变远方向'), findsOneWidget);
    expect(find.text('① 标定行程'), findsNothing);
    expect(find.text('② 单侧对齐'), findsNothing);
    // 软限位区间来自核心，UI 只显示。
    expect(find.textContaining('允许 1000..7400 步'), findsOneWidget);
  });

  testWidgets('stop and home go to the core', (tester) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);

    await tester.tap(find.text('停止电机'));
    expect(core.called('stopPressed'), isTrue);

    await tapVisible(tester, find.text('设当前位置为原点'));
    expect(core.called('homePressed'), isTrue);
  });

  testWidgets('selecting a discovered device reconnects through the core', (
    tester,
  ) async {
    final core = FakeCore(stateFor())
      ..devicesToReturn = const [
        FfDevice(
          deviceId: 'FF-DEMO01',
          mac: 'AA:BB:CC:00:00:01',
          udpPort: 4210,
          firmware: 'demo',
          host: '192.168.4.1',
        ),
      ];
    await pumpFollowPage(tester, core);
    await tester.tap(find.text('已连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FF-DEMO01'));
    await tester.pumpAndSettle();

    expect(core.args['selectDevice']?['device_id'], 'FF-DEMO01');
    expect(core.called('connect'), isTrue);
  });

  testWidgets('jog buttons send relative steps', (tester) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);

    await tapVisible(tester, find.text('微调与运动参数'));
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

    await tapVisible(tester, find.text('微调与运动参数'));
    await tester.enterText(find.byType(TextField).last, '0.5');
    await tapVisible(tester, find.text('走圈'));

    // 0.5 圈 × 6400 脉冲/圈 = 3200。圈→步的换算是 UI 唯一的算术。
    expect(core.args['jog']?['delta'], 3200);
  });

  testWidgets('auto focus chip is only enabled once aligned with two points', (
    tester,
  ) async {
    // 还没对齐：不显示自动控制
    final notAligned = FakeCore(
      stateFor(phase: SetupPhase.align, nearSteps: null),
    );
    await pumpFollowPage(tester, notAligned);
    expect(find.text('自动跟焦'), findsNothing);

    // 对齐了但距离标定只有一点：仍禁用
    final onePoint = FakeCore(stateFor(lutReady: false));
    await pumpFollowPage(tester, onePoint);
    expect(find.text('自动(需2点标定)'), findsOneWidget);

    // 对齐 + 两点：可用
    final ready = FakeCore(stateFor());
    await pumpFollowPage(tester, ready);
    await tapVisible(tester, find.text('自动跟焦'));
    expect(ready.args['setAuto']?['on'], true);
  });

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

    await tapVisible(tester, find.text('距离标定与方向'));
    await tapVisible(tester, find.text('记录当前'));
    expect(core.called('addLutPoint'), isTrue);
  });

  testWidgets('recording is disabled without a distance reading', (
    tester,
  ) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);

    await tapVisible(tester, find.text('距离标定与方向'));
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

    await tapVisible(tester, find.text('距离标定与方向'));
    await scrollTo(tester, find.text('重新标定行程（长按）'));
    await tester.longPress(find.text('重新标定行程（长按）'));
    await tester.pumpAndSettle();
    expect(find.text('清空行程标定？'), findsOneWidget, reason: '防误触：要先确认');

    await tester.tap(find.text('清空重标'));
    await tester.pumpAndSettle();
    expect(core.called('recalibrateStroke'), isTrue);
  });

  testWidgets('cancelling the recalibrate confirm changes nothing', (
    tester,
  ) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);

    await tapVisible(tester, find.text('距离标定与方向'));
    await scrollTo(tester, find.text('重新标定行程（长按）'));
    await tester.longPress(find.text('重新标定行程（长按）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(core.called('recalibrateStroke'), isFalse);
  });

  testWidgets('diagnostics render from the snapshot, not from UI logic', (
    tester,
  ) async {
    final core = FakeCore(
      stateFor(
        tmc: const FfTmc(
          uartOk: true,
          stealth: true,
          rmsMa: 800,
          microsteps: 16,
          toff: 5,
          ihold: 8,
          irun: 16,
          version: 33,
          csActual: 12,
          sg: 7,
          tstep: 100,
          ot: false,
          otpw: false,
          ola: false,
          olb: false,
          shorted: false,
          standstill: true,
          logLine: 'rms=800mA',
        ),
        tmcLog: ['12:00:00  rms=800mA'],
      ),
    );
    await pumpFollowPage(tester, core);

    await tapVisible(tester, find.text('功能可用性诊断'));
    // 尚未发过控制命令 → 序号回显那行直接说明这一点（文本来自快照，不是 UI 判断）。
    expect(find.text('尚未发送控制命令'), findsOneWidget);

    await tapVisible(tester, find.textContaining('ver=0x'));
    expect(find.text('800 mA'), findsOneWidget);
    expect(find.text('12:00:00  rms=800mA'), findsOneWidget);
  });

  testWidgets('microstep change and standby switch go to the core', (
    tester,
  ) async {
    final core = FakeCore(
      stateFor(
        tmc: const FfTmc(
          uartOk: true,
          stealth: true,
          rmsMa: 800,
          microsteps: 16,
          toff: 5,
          ihold: 8,
          irun: 16,
          version: 33,
          csActual: 12,
          sg: 7,
          tstep: 100,
          ot: false,
          otpw: false,
          ola: false,
          olb: false,
          shorted: false,
          standstill: false,
          logLine: '',
        ),
      ),
    );
    await pumpFollowPage(tester, core);

    await tapVisible(tester, find.textContaining('ver=0x'));

    await tapVisible(tester, find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1/256').last);
    await tester.pumpAndSettle();
    expect(core.args['setMicrosteps']?['value'], 256);

    await tapVisible(tester, find.widgetWithText(SwitchListTile, '待机自动断电'));
    expect(core.args['setStandbyFeature']?['on'], false);
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

  testWidgets('primary actions fit narrow screens in every phase', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final width in [390.0, 320.0]) {
      await tester.binding.setSurfaceSize(Size(width, 844));
      for (final phase in SetupPhase.values) {
        final core = FakeCore(
          stateFor(
            phase: phase,
            nearSteps: phase == SetupPhase.align ? null : 1000,
            connected: phase != SetupPhase.stroke,
          ),
        );
        await pumpFollowPage(tester, core);
        expect(find.text('停止电机'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$width px, $phase');
        if (width == 320 && phase != SetupPhase.follow) {
          final action = phase == SetupPhase.stroke ? '记录这一端 A' : '确认为焦距最近点';
          expect(
            tester.getRect(find.text(action)).bottom,
            lessThan(tester.getRect(find.text('停止电机')).top),
            reason: '$action should be visible above the fixed stop button',
          );
        }
      }
    }
  });

  testWidgets('lens and device lists fit narrow screens', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final width in [390.0, 320.0]) {
      await tester.binding.setSurfaceSize(Size(width, 844));
      final core = FakeCore(FfState(lenses: [lens(lutCount: 2)]))
        ..devicesToReturn = const [
          FfDevice(
            deviceId: 'FF-DEMO01',
            mac: 'AA:BB:CC:00:00:01',
            udpPort: 4210,
            firmware: 'demo',
            host: '192.168.4.1',
          ),
        ];
      await pumpLensPage(tester, core);
      expect(tester.takeException(), isNull, reason: 'lens list at $width px');
      await tester.pumpWidget(
        MaterialApp(home: DevicePage(core: core, linkOpen: true)),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'device list at $width px',
      );
    }
  });
}
