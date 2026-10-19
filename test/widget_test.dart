import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:iphone_follow_focus/ff_core.dart';
import 'package:iphone_follow_focus/lens_page.dart';
import 'package:iphone_follow_focus/lidar.dart';
import 'package:iphone_follow_focus/main.dart';
import 'package:iphone_follow_focus/handwheel_page.dart';
import 'package:iphone_follow_focus/device_page.dart';

/// 伪造的核心：只记录命令、按需推快照。
///
/// 控制命令只覆盖 [FfCore.invoke]，外观偏好用内存模拟，所以**不碰平台通道**。
/// 测试断言的是“UI 发出了什么命令”，而不是 UI 里复制了一份逻辑 ——
/// UI 里本来就不该有逻辑。
class FakeCore extends FfCore {
  final calls = <String>[];
  final args = <String, Map<String, Object?>?>{};
  final _controller = StreamController<FfState>.broadcast();

  FfState state;
  List<FfDevice> devicesToReturn = const [];
  String? savedThemeMode;
  bool failThemeSave = false;

  FakeCore([this.state = const FfState()]);

  @override
  Future<String?> loadThemeMode() async => savedThemeMode;

  @override
  Future<void> saveThemeMode(String mode) async {
    if (failThemeSave) throw PlatformException(code: 'save_failed');
    await invoke('setThemeMode', {'mode': mode});
    savedThemeMode = mode;
  }

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

class FakeLidar extends LidarChannel {
  void Function(LidarSample)? onSample;
  int starts = 0;
  int disposals = 0;

  @override
  Future<bool> available() async => true;

  @override
  Future<void> listen(void Function(LidarSample) callback) async {
    onSample = callback;
  }

  @override
  Future<void> start({required bool trackFaces}) async {
    starts++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    onSample = null;
  }
}

class DelayedLidar extends FakeLidar {
  final ready = Completer<bool>();
  @override
  Future<bool> available() => ready.future;
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
  bool stopLatched = false,
  bool canResume = false,
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
    stopLatched: stopLatched,
    canResume: canResume,
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
Future<void> pumpFollowPage(
  WidgetTester tester,
  FakeCore core, {
  LidarChannel? lidar,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: FollowPage(
        key: UniqueKey(),
        core: core,
        lensId: core.state.lensId ?? 'L1',
        lidar: lidar,
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
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'leaving before LiDAR availability completes never starts capture',
    (tester) async {
      final lidar = DelayedLidar();
      await pumpFollowPage(tester, FakeCore(stateFor()), lidar: lidar);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      lidar.ready.complete(true);
      await tester.pumpAndSettle();
      expect(lidar.starts, 0);
      expect(lidar.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rotation and collapse retain the native camera and capture session',
    (tester) async {
      final platformCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          platformCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      final lidar = FakeLidar();
      await pumpFollowPage(tester, FakeCore(stateFor()), lidar: lidar);
      final cameraState = tester.state(find.byType(UiKitView));
      expect(platformCalls.where((c) => c.method == 'create'), hasLength(1));
      for (final turns in [-1, 0, 1, 0, -1, 0]) {
        tester.view.physicalSize = turns == 0
            ? const Size(430, 932)
            : const Size(932, 430);
        lidar.onSample!(
          LidarSample(distanceM: 2, u: .2, v: .3, previewQuarterTurns: turns),
        );
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(UiKitView)), same(cameraState));
        expect(
          tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
          turns,
        );
        expect(platformCalls.where((c) => c.method == 'create'), hasLength(1));
        expect(platformCalls.where((c) => c.method == 'dispose'), isEmpty);
      }
      await tester.tap(find.text('摄像头 展开'));
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsNothing);
      expect(
        tester.state(find.byType(UiKitView, skipOffstage: false)),
        same(cameraState),
      );
      await tester.tap(find.text('摄像头 已折叠'));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(UiKitView)), same(cameraState));
      expect(platformCalls.where((c) => c.method == 'create'), hasLength(1));
      expect(lidar.starts, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(platformCalls.where((c) => c.method == 'dispose'), hasLength(1));
      expect(lidar.disposals, 1);
    },
  );

  testWidgets('tap requests orientation, landscape controls keep core state', (
    tester,
  ) async {
    final orientations = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientations.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final core = FakeCore(stateFor(distanceM: '2.34', appVersion: '2.1.0+8'));
    await pumpFollowPage(tester, core);
    await tester.tap(find.byTooltip('切换横屏'));
    await tester.pumpAndSettle();
    expect(orientations.last, ['DeviceOrientation.landscapeLeft']);
    // The OS supplies new metrics after accepting the rotation request.
    tester.view.physicalSize = const Size(932, 430);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('landscape-viewfinder')), findsOneWidget);
    expect(find.text('物距 2.34 m'), findsOneWidget);
    expect(find.text('v2.1.0+8'), findsOneWidget);
    await tester.tap(find.text('手动'));
    expect(core.args['setAuto'], {'on': true});
    await tester.tap(find.text('停止'));
    expect(core.called('stopPressed'), isTrue);
    await tester.tap(find.byTooltip('构图网格'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('控制与标定'));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('+80'));
    expect(core.args['jog'], {'delta': 80});
    await tester.tap(find.byTooltip('关闭控制面板'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换竖屏'));
    await tester.pumpAndSettle();
    expect(orientations.last, ['DeviceOrientation.portraitUp']);
    tester.view.physicalSize = const Size(430, 932);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('landscape-viewfinder')), findsNothing);
    expect(find.text('手动焦点'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(SingleChildScrollView).first).dy,
      932,
    );
    expect(core.called('leaveLens'), isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(
      orientations.last,
      isEmpty,
      reason: 'Leaving the page restores system rotation',
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('viewfinder contrast stays readable in $brightness', (
      tester,
    ) async {
      final core = FakeCore(
        stateFor(phase: SetupPhase.stroke, lutReady: false, distanceM: '2.34'),
      );
      await pumpFollowPage(tester, core, brightness: brightness);

      Color textColor(String text) => Color.alphaBlend(
        tester
            .widget<RichText>(
              find.descendant(
                of: find.text(text),
                matching: find.byType(RichText),
              ),
            )
            .text
            .style!
            .color!,
        Colors.black,
      );

      expect(textColor('摄像头 展开').computeLuminance(), greaterThan(.5));
      tester.view.physicalSize = const Size(932, 430);
      await tester.pumpAndSettle();
      for (final text in ['50mm F1.4', '物距 2.34 m', '1000 → 1000', '0 / 5+']) {
        expect(
          textColor(text).computeLuminance(),
          greaterThan(.5),
          reason: text,
        );
      }
      expect(textColor('手动').computeLuminance(), greaterThan(.25));
      expect(
        Theme.of(tester.element(find.byTooltip('控制与标定'))).brightness,
        Brightness.dark,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '手动'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('控制与标定'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.text('跟焦控制与标定'))).brightness,
        brightness,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('small landscape supports setup, keyboard and disabled auto', (
    tester,
  ) async {
    final core = FakeCore(
      stateFor(phase: SetupPhase.calibrate, lutReady: false),
    );
    await pumpFollowPage(tester, core);
    tester.view.physicalSize = const Size(667, 375);
    tester.view.padding = const FakeViewPadding(
      left: 44,
      right: 44,
      bottom: 21,
    );
    addTearDown(tester.view.resetPadding);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '手动'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('控制与标定'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.widgetWithText(TextField, '物距（m，可手动输入）'));
    await tester.enterText(
      find.widgetWithText(TextField, '物距（m，可手动输入）'),
      '2.5',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 160);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tapVisible(tester, find.text('新增标定点'));
    expect(core.args['addLutPoint'], {'meters': 2.5});
  });

  testWidgets('keyboard can be dismissed in a dialog without losing input', (
    tester,
  ) async {
    final core = FakeCore();
    await tester.pumpWidget(FollowApp(core: core));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动跟焦'));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('添加镜头'));
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
  testWidgets('app starts with an automatic or handwheel mode choice', (
    tester,
  ) async {
    final core = FakeCore();
    await tester.pumpWidget(FollowApp(core: core));
    await tester.pumpAndSettle();
    expect(find.text('自动跟焦'), findsOneWidget);
    expect(find.text('手动跟焦'), findsOneWidget);
    await tester.tap(find.text('自动跟焦'));
    await tester.pumpAndSettle();
    expect(core.args['setControlMode'], {'mode': 'automatic'});
    expect(find.text('镜头库'), findsOneWidget);
    expect(find.text('还没有镜头，点下面新建一个。'), findsOneWidget);
    expect(find.byIcon(LucideIcons.arrowLeft), findsOneWidget);
    expect(find.byIcon(LucideIcons.plus), findsOneWidget);
  });

  testWidgets('home supports both system themes and live connection status', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final core = FakeCore();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpWidget(FollowApp(core: core));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('选择跟焦方式'))).brightness,
      Brightness.light,
    );
    expect(find.text('FM03 未连接'), findsOneWidget);
    for (final removed in ['需支持 LiDAR', '首次使用需标定', '无需 LiDAR', '无需物距标定']) {
      expect(find.text(removed), findsNothing);
    }
    core.push(const FfState(connected: true, linkAlive: true));
    await tester.pumpAndSettle();
    expect(find.text('FM03 已连接'), findsOneWidget);
    core.push(const FfState(connected: true, linkAlive: false));
    await tester.pumpAndSettle();
    expect(find.text('FM03 连接异常'), findsOneWidget);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('选择跟焦方式'))).brightness,
      Brightness.dark,
    );
    await tapVisible(tester, find.text('首次使用？查看连接与标定指南'));
    expect(find.text('连接与标定指南'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('管理'), -200);
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    expect(find.byType(DevicePage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('appearance can override the system and restore a saved choice', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    final core = FakeCore()..savedThemeMode = 'dark';
    await tester.pumpWidget(FollowApp(core: core));
    await tester.pumpAndSettle();
    Brightness appearance() =>
        Theme.of(tester.element(find.text('选择跟焦方式'))).brightness;
    Future<void> choose(String label) async {
      await tester.tap(find.byTooltip('切换外观'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<ThemeMode>, label),
      );
      await tester.pumpAndSettle();
    }

    expect(appearance(), Brightness.dark);
    await choose('浅色模式');
    expect(appearance(), Brightness.light);
    expect(core.savedThemeMode, 'light');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(appearance(), Brightness.light);
    await tester.pumpWidget(FollowApp(key: UniqueKey(), core: core));
    await tester.pumpAndSettle();
    expect(
      appearance(),
      Brightness.light,
      reason: 'restore after app recreation',
    );
    await choose('跟随系统');
    expect(core.savedThemeMode, 'system');
    expect(appearance(), Brightness.dark);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(appearance(), Brightness.light);
    await choose('深色模式');
    expect(appearance(), Brightness.dark);
    expect(core.savedThemeMode, 'dark');
    await tester.tap(find.text('自动跟焦'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('镜头库'))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an invalid appearance falls back and save errors are visible', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    final core = FakeCore()..savedThemeMode = 'invalid';
    await tester.pumpWidget(FollowApp(core: core));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('选择跟焦方式'))).brightness,
      Brightness.light,
    );
    core.failThemeSave = true;
    await tester.tap(find.byTooltip('切换外观'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<ThemeMode>, '深色模式'),
    );
    await tester.pumpAndSettle();
    expect(find.text('外观已切换，但保存失败，重启后可能恢复默认。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home remains scrollable on small screens with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(FollowApp(core: FakeCore()));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('首次使用？查看连接与标定指南'));
    expect(find.text('连接与标定指南'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'stop becomes reset and all manual motion controls stay disabled',
    (tester) async {
      final core = FakeCore(stateFor(stopLatched: true, canResume: true));
      await pumpFollowPage(tester, core);
      await tapVisible(tester, find.text('复位继续跟焦'));
      expect(core.called('resumeControl'), isTrue);
      expect(core.called('stopPressed'), isFalse);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '+80'))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'handwheel entry needs no lens and sends wheel, point and reset intents',
    (tester) async {
      final core = FakeCore(
        const FfState(
          controlMode: 'handwheel',
          wheelReady: true,
          connected: true,
          linkAlive: true,
          canOk: true,
          positionTrusted: true,
          enabled: true,
          pos: 1200,
          target: 1200,
          strokeSteps: 4096,
          wheelA: 1200,
          wheelB: 2800,
        ),
      );
      await tester.pumpWidget(FollowApp(core: core));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('手动跟焦'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动跟焦'));
      await tester.pumpAndSettle();
      expect(core.args['setControlMode'], {'mode': 'handwheel'});
      expect(find.byType(HandwheelPage), findsOneWidget);
      expect(core.called('selectLens'), isFalse);
      final center = tester.getCenter(
        find.byKey(const ValueKey('focus-wheel')),
      );
      final gesture = await tester.startGesture(center + const Offset(120, 0));
      await gesture.moveTo(center + const Offset(105, 65));
      await gesture.moveTo(center + const Offset(60, 110));
      await gesture.moveTo(center + const Offset(0, 120));
      await gesture.up();
      expect(core.called('turnWheel'), isTrue);
      expect((core.args['turnWheel']!['turns'] as double).abs(), lessThan(.5));
      await tapVisible(tester, find.text('重设 A 点'));
      expect(core.args['setWheelPoint'], {'point': 'A'});
      await tapVisible(tester, find.text('拉到 B'));
      expect(core.args['pullWheelTo'], {'point': 'B', 'duration': 2.0});
      core.push(
        const FfState(
          controlMode: 'handwheel',
          connected: true,
          positionTrusted: true,
          strokeSteps: 4096,
          stopLatched: true,
          canResume: true,
        ),
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('复位并继续手轮'));
      expect(core.called('resumeControl'), isTrue);
      final turns = core.countOf('turnWheel');
      final stoppedCenter = tester.getCenter(
        find.byKey(const ValueKey('focus-wheel')),
      );
      await tester.dragFrom(
        stoppedCenter + const Offset(120, 0),
        const Offset(-120, 120),
      );
      expect(core.countOf('turnWheel'), turns);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wheel owns vertical starts and the hub supports fine adjustment',
    (tester) async {
      final turns = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                SizedBox(
                  height: 300,
                  child: WheelDial(
                    enabled: true,
                    haptics: false,
                    actual: .5,
                    target: .5,
                    label: '50%',
                    onTurn: turns.add,
                  ),
                ),
                const SizedBox(height: 1000),
              ],
            ),
          ),
        ),
      );
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final center = tester.getCenter(
        find.byKey(const ValueKey('focus-wheel')),
      );
      final gesture = await tester.startGesture(center + const Offset(120, 0));
      await gesture.moveBy(const Offset(0, 2));
      expect(
        turns,
        hasLength(1),
        reason: 'first movement must not wait for pan slop',
      );
      await gesture.moveBy(const Offset(0, 60));
      await gesture.up();
      expect(scroll.pixels, 0);
      turns.clear();
      final hub = await tester.startGesture(center);
      await hub.moveBy(const Offset(0, -30));
      expect(turns.single, closeTo(.025, 1e-6));
      final second = await tester.startGesture(
        center + const Offset(120, 0),
        pointer: 9,
      );
      await second.moveBy(const Offset(0, 30));
      await second.up();
      expect(
        turns,
        hasLength(1),
        reason: 'second finger must not move the wheel',
      );
      await hub.moveBy(const Offset(0, -30));
      expect(turns, hasLength(2));
      await hub.cancel();
      expect(scroll.pixels, 0);
    },
  );

  testWidgets(
    'wheel stays fixed while controls scroll and stop stays visible',
    (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = FakeCore(const FfState(connected: true, wheelReady: true));
      await tester.pumpWidget(MaterialApp(home: HandwheelPage(core: core)));
      await tester.pumpAndSettle();
      final wheel = find.byKey(const ValueKey('focus-wheel'));
      final origin = tester.getTopLeft(wheel);
      await tester.drag(
        find.byKey(const ValueKey('wheel-controls-scroll')),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(wheel), origin);
      await tester.tap(find.text('停止并锁定'));
      expect(core.called('stopPressed'), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'focus input switches without moving and slider sends live targets with haptics',
    (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pulses = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            pulses.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final core = FakeCore(
        const FfState(
          connected: true,
          wheelReady: true,
          slider: .5,
          wheelA: 2048,
          wheelB: 3686,
        ),
      );
      await tester.pumpWidget(MaterialApp(home: HandwheelPage(core: core)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('滑块'));
      await tester.pumpAndSettle();
      expect(core.calls, isEmpty, reason: '切换控件不能发送目标或重新寻限位');
      expect(find.byKey(const ValueKey('focus-wheel')), findsNothing);
      final slider = find.byKey(const ValueKey('focus-slider'));
      expect(find.text('A 50.0%'), findsOneWidget);
      expect(find.text('B 90.0%'), findsOneWidget);
      expect(find.byKey(const ValueKey('slider-marker-A')), findsOneWidget);
      expect(find.byKey(const ValueKey('slider-marker-B')), findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(45, 0));
      expect(core.countOf('setSlider'), greaterThan(0), reason: '拖动中发送，不等抬手');
      expect(core.args['setSlider']!['value'] as double, greaterThan(.5));
      await tester.pump();
      expect(pulses, contains('HapticFeedbackType.selectionClick'));
      await gesture.up();
      final sent = core.countOf('setSlider');
      await tester.tap(find.text('手轮'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('focus-wheel')), findsOneWidget);
      expect(core.countOf('setSlider'), sent);
      core.push(
        const FfState(connected: true, stopLatched: true, strokeSteps: 4096),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('滑块'));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).onChanged, isNull);
      await tester.drag(slider, const Offset(60, 0));
      expect(core.countOf('setSlider'), sent);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'focus haptic presets change density and strength and can be disabled',
    (tester) async {
      final pulses = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            pulses.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      for (final style in FocusHapticStyle.values) {
        // A fresh gesture travels 1% of a circle: only the dense preset has a detent here.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox.square(
              dimension: 300,
              child: WheelDial(
                enabled: true,
                haptics: true,
                hapticStyle: style,
                actual: .5,
                target: .5,
                label: '50%',
                onTurn: (_) {},
              ),
            ),
          ),
        );
        final wheel = find.byKey(const ValueKey('focus-wheel'));
        final box = tester.getRect(wheel);
        final radius = box.shortestSide * .4;
        final gesture = await tester.startGesture(
          box.center + Offset(radius, 0),
        );
        await gesture.moveTo(box.center + Offset(radius * .998, radius * .063));
        await gesture.up();
        await tester.pump();
      }
      expect(pulses, ['HapticFeedbackType.lightImpact']);
      pulses.clear();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox.square(
            dimension: 300,
            child: WheelDial(
              enabled: true,
              haptics: true,
              hapticStyle: FocusHapticStyle.firm,
              actual: .5,
              target: .5,
              label: '50%',
              onTurn: (_) {},
            ),
          ),
        ),
      );
      final center = tester.getCenter(
        find.byKey(const ValueKey('focus-wheel')),
      );
      final strong = await tester.startGesture(center + const Offset(120, 0));
      await strong.moveTo(center + const Offset(110, 45));
      await strong.up();
      await tester.pump();
      expect(pulses, ['HapticFeedbackType.mediumImpact']);
      pulses.clear();
      final core = FakeCore(
        const FfState(wheelReady: true, wheelArrivalSequence: 0),
      );
      await tester.pumpWidget(MaterialApp(home: HandwheelPage(core: core)));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('手轮响应与设置'));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('focus-haptic-style')),
      );
      await tester.tap(find.text('密集轻触').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('120 格'), findsOneWidget);
      await tapVisible(tester, find.text('触感反馈'));
      core.push(const FfState(wheelReady: true, wheelArrivalSequence: 1));
      await tester.pumpAndSettle();
      final off = tester.getCenter(find.byKey(const ValueKey('focus-wheel')));
      await tester.dragFrom(off, const Offset(0, -80));
      await tester.pump();
      expect(pulses, isEmpty);
      await tester.tap(find.text('滑块'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('focus-slider')),
        const Offset(70, 0),
      );
      await tester.pump();
      expect(pulses, isEmpty);
    },
  );

  testWidgets(
    'wheel settings send speed, acceleration, gain and curve intents',
    (tester) async {
      const fm03 = FfFm03(
        online: true,
        stage: 3,
        value: 0,
        maxSpeed: 64,
        tolerance: 4,
        gain: 4,
        acceleration: 8,
        rawPosition: 1000,
        txFailures: 0,
        rxMissed: 0,
        feedbackAge: 10,
        logLine: '',
      );
      final core = FakeCore(
        const FfState(connected: true, linkAlive: true, fm03: fm03),
      );
      await tester.pumpWidget(MaterialApp(home: HandwheelPage(core: core)));
      await tester.pumpAndSettle();
      final speed = tester.widget<Slider>(
        find.byKey(const ValueKey('wheel-parameter-1')),
      );
      speed.onChangeEnd!(128);
      expect(core.args['setFm03'], {'key': kFm03MaxSpeed, 'value': 128});
      await tapVisible(tester, find.text('手轮响应与设置'));
      await tester.pumpAndSettle();
      final acceleration = tester.widget<Slider>(
        find.byKey(const ValueKey('wheel-parameter-4')),
      );
      acceleration.onChangeEnd!(32);
      expect(core.args['setFm03'], {'key': kFm03Acceleration, 'value': 32});
      final gain = tester.widget<Slider>(
        find.byKey(const ValueKey('wheel-parameter-3')),
      );
      gain.onChangeEnd!(2);
      expect(core.args['setFm03'], {'key': kFm03Gain, 'value': 2});
      final tolerance = tester.widget<Slider>(
        find.byKey(const ValueKey('wheel-parameter-2')),
      );
      tolerance.onChangeEnd!(8);
      expect(core.args['setFm03'], {'key': kFm03Tolerance, 'value': 8});
      final curve = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('wheel-pull-curve')),
      );
      curve.onChanged!('linear');
      expect(core.args['setWheelPullCurve'], {'curve': 'linear'});
      core.push(
        const FfState(
          connected: true,
          linkAlive: true,
          moving: true,
          fm03: fm03,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('wheel-parameter-1')))
            .onChanged,
        isNotNull,
      );
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('wheel-parameter-4')))
            .onChanged,
        isNotNull,
      );
      core.push(
        const FfState(
          connected: true,
          linkAlive: true,
          calStage: 'seek_negative',
          fm03: fm03,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('wheel-parameter-2')))
            .onChanged,
        isNull,
      );
      core.push(
        const FfState(
          connected: true,
          linkAlive: true,
          fm03: FfFm03(
            online: true,
            stage: 3,
            value: 0,
            maxSpeed: 64,
            tolerance: 4,
            gain: 4,
            rawPosition: 1000,
            txFailures: 0,
            rxMissed: 0,
            feedbackAge: 10,
            logLine: '',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('wheel-parameter-4')))
            .onChanged,
        isNull,
      );
      expect(find.text('需要固件 2.1.0 或更新版本。'), findsOneWidget);
    },
  );

  testWidgets(
    'handwheel endpoint haptic follows a new actual-arrival event once',
    (tester) async {
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final core = FakeCore(const FfState(wheelArrivalSequence: 4));
      await tester.pumpWidget(MaterialApp(home: HandwheelPage(core: core)));
      await tester.pumpAndSettle();
      expect(haptics, isEmpty);
      core.push(const FfState(wheelArrival: 'A', wheelArrivalSequence: 5));
      await tester.pumpAndSettle();
      expect(haptics, ['HapticFeedbackType.heavyImpact']);
      core.push(const FfState(wheelArrival: 'A', wheelArrivalSequence: 5));
      await tester.pumpAndSettle();
      expect(haptics, hasLength(1));
    },
  );

  testWidgets(
    'wheel distinguishes settling from a failed goal with small residual error',
    (tester) async {
      final core = FakeCore(
        const FfState(
          connected: true,
          linkAlive: true,
          wheelReady: true,
          positionTrusted: true,
          moving: true,
          pos: 2000,
          target: 2003,
        ),
      );
      await tester.pumpWidget(MaterialApp(home: HandwheelPage(core: core)));
      await tester.pumpAndSettle();
      expect(find.text('正在确认到位'), findsOneWidget);
      expect(find.textContaining('误差 3 / ±4'), findsOneWidget);
      core.push(
        const FfState(
          connected: true,
          linkAlive: true,
          wheelReady: true,
          positionTrusted: true,
          pos: 2000,
          target: 2009,
          result: kResultRejected,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('未到目标 · 已停止'), findsOneWidget);
      expect(find.text('正在拉焦'), findsNothing);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('handwheel theme and text contrast follow $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = FakeCore(
        const FfState(appVersion: '2.6.2+24', msg: '主题对比度测试'),
      )..savedThemeMode = brightness.name;
      await tester.pumpWidget(FollowApp(core: core));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('手动跟焦'));
      await tester.tap(find.text('手动跟焦'));
      await tester.pumpAndSettle();
      final theme = Theme.of(tester.element(find.byType(HandwheelPage)));
      final background = tester
          .widget<Material>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('focus-wheel')),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color;
      expect(background, theme.scaffoldBackgroundColor);
      void readable(String label) {
        final finder = find.text(label);
        final text = tester.widget<RichText>(
          find.descendant(of: finder, matching: find.byType(RichText)),
        );
        final material = tester.widget<Material>(
          find.ancestor(of: finder, matching: find.byType(Material)).first,
        );
        final bg = material.color ?? theme.scaffoldBackgroundColor;
        final fg = Color.alphaBlend(text.text.style!.color!, bg);
        final light = fg.computeLuminance(), dark = bg.computeLuminance();
        final ratio = light > dark
            ? (light + .05) / (dark + .05)
            : (dark + .05) / (light + .05);
        expect(ratio, greaterThanOrEqualTo(4.5), reason: label);
      }

      for (final label in [
        'v2.6.2+24',
        '实际位置 --',
        'FOCUS',
        '等待解锁与电机就绪',
        '停止并锁定',
      ]) {
        readable(label);
      }
      expect(tester.widget<WheelDial>(find.byType(WheelDial)).enabled, isFalse);
      await tester.tap(find.text('滑块'));
      await tester.pumpAndSettle();
      for (final label in ['目标焦点', 'A 未设置', 'B 未设置']) {
        readable(label);
      }
      await tapVisible(tester, find.text('手轮响应与设置'));
      readable('主题对比度测试');
      readable('1×：手轮转一圈对应完整行程；0.25× 用于精细对焦。');
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      core.push(const FfState(connected: true));
      await tester.pumpAndSettle();
      readable('停止并锁定');
    });
  }

  testWidgets(
    'handwheel repaints on a live system theme change without moving',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      final core = FakeCore();
      await tester.pumpWidget(FollowApp(core: core));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('手动跟焦'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动跟焦'));
      await tester.pumpAndSettle();
      final wheelState = tester.state(find.byType(WheelDial));
      final paint = find.descendant(
        of: find.byKey(const ValueKey('focus-wheel')),
        matching: find.byType(CustomPaint),
      );
      final before = tester.widget<CustomPaint>(paint).painter!;
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      final after = tester.widget<CustomPaint>(paint).painter!;
      expect(after.shouldRepaint(before), isTrue);
      expect(tester.state(find.byType(WheelDial)), same(wheelState));
      expect(core.called('turnWheel'), isFalse);
      expect(core.called('setSlider'), isFalse);
      expect(core.called('startAutoCalibration'), isFalse);
    },
  );

  testWidgets('handwheel layout fits portrait and landscape on a small phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final core = FakeCore(const FfState(wheelA: 4096, wheelB: 4094));
    for (final size in [const Size(375, 667), const Size(667, 375)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(MaterialApp(home: HandwheelPage(core: core)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('focus-wheel')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('滑块'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('focus-slider')), findsOneWidget);
      expect(find.text('A 100.0%'), findsOneWidget);
      expect(find.text('B 100.0%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('手轮'));
      await tester.pumpAndSettle();
    }
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
    expect(find.textContaining('距离标定 3 点'), findsOneWidget);
    expect(find.textContaining('物距变近：− 方向'), findsOneWidget);
    expect(find.textContaining('行程 1.00'), findsNothing);
    expect(find.text('首次使用请完成：'), findsOneWidget);
    final steps = ['FM03 自动寻限位', '选择物距变近方向', '确认对焦方向', '完成至少 5 个标定点'];
    for (var i = 1; i < steps.length; i++) {
      expect(
        tester.getTopLeft(find.text(steps[i])).dy,
        greaterThan(tester.getTopLeft(find.text(steps[i - 1])).dy),
      );
    }
    await scrollTo(tester, find.text('85mm'));
    await tester.pumpAndSettle();
    expect(find.text('85mm'), findsOneWidget);
    expect(find.textContaining('待选择物距方向'), findsOneWidget);
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

      await tapVisible(tester, find.text('进入跟焦'));
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

      await tapVisible(tester, find.text('添加镜头'));
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

    await tapVisible(tester, find.text('添加镜头'));
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

    await tester.tap(find.byTooltip('镜头操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除镜头'));
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

    await tapVisible(tester, find.text('新增标定点'));
    expect(core.called('addLutPoint'), isTrue);
  });

  testWidgets('recording is disabled without a distance reading', (
    tester,
  ) async {
    final core = FakeCore(stateFor());
    await pumpFollowPage(tester, core);

    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '新增标定点'))
          .onPressed,
      isNull,
      reason: '没测到距离时不该能记录标定点',
    );
  });

  testWidgets('follow mode offers continuing calibration while auto is on', (
    tester,
  ) async {
    final core = FakeCore(stateFor(auto: true, distanceM: '2'));
    await pumpFollowPage(tester, core);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '新增标定点'))
          .onPressed,
      isNull,
    );
    await tapVisible(tester, find.text('继续新增标定点'));
    expect(core.called('unalign'), isTrue);
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
  testWidgets(
    'manual measured distance can add more than five points without LiDAR',
    (tester) async {
      final core = FakeCore(stateFor(phase: SetupPhase.calibrate));
      await pumpFollowPage(tester, core);
      await scrollTo(tester, find.widgetWithText(TextField, '物距（m，可手动输入）'));
      await tester.enterText(
        find.widgetWithText(TextField, '物距（m，可手动输入）'),
        '2.5',
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('新增标定点'));
      expect(core.args['addLutPoint']?['meters'], 2.5);

      final sixPoints = [
        ...core.state.lutPoints,
        const FfLutPoint(meters: 6, steps: 3900),
      ];
      core.push(stateFor(phase: SetupPhase.calibrate, lutPoints: sixPoints));
      await tester.pumpAndSettle();
      expect(find.textContaining('已记录 6 点'), findsOneWidget);
      expect(find.text('最近标定 0.50 m · 最远标定 6.00 m'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, '物距（m，可手动输入）'),
        '7',
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('新增标定点'));
      expect(core.countOf('addLutPoint'), 2);
      expect(core.args['addLutPoint']?['meters'], 7.0);
    },
  );
}
