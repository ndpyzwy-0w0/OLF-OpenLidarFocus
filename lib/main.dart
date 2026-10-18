import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';

import 'device_page.dart';
import 'ff_core.dart';
import 'ff_core_demo.dart';
import 'mode_page.dart';
import 'lidar.dart';
import 'lens_chart.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // web 上没有 `ff.core` 的实现（那是 iOS 侧的 Swift 插件），用演示核心把界面撑起来；
  // 真机和模拟器一律走真的 FfCore。
  final core = kIsWeb ? FfCoreDemo() : FfCore();
  // 功能层起来后自己会连 LiDAR 和控制回路，UI 不等它。
  unawaited(core.start());
  runApp(FollowApp(core: core));
}

class FollowApp extends StatefulWidget {
  final FfCore core;

  const FollowApp({super.key, required this.core});

  @override
  State<FollowApp> createState() => _FollowAppState();

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final theme = ThemeData(
      brightness: brightness,
      actionIconTheme: ActionIconThemeData(
        backButtonIconBuilder: (_) => const Icon(LucideIcons.arrowLeft),
        closeButtonIconBuilder: (_) => const Icon(LucideIcons.x),
        drawerButtonIconBuilder: (_) => const Icon(LucideIcons.menu),
        endDrawerButtonIconBuilder: (_) =>
            const Icon(LucideIcons.slidersHorizontal),
      ),
      scaffoldBackgroundColor: Color(dark ? 0xFF0B1510 : 0xFFF4F8F5),
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: const Color(0xFF16A889),
            brightness: brightness,
          ).copyWith(
            primary: Color(dark ? 0xFF59E4C3 : 0xFF087C63),
            surface: Color(dark ? 0xFF16221B : 0xFFFFFFFF),
            onSurface: Color(dark ? 0xFFF4F7F4 : 0xFF17251D),
            onSurfaceVariant: Color(dark ? 0xFFADB8B1 : 0xFF56675D),
            outlineVariant: Color(dark ? 0xFF2B3C31 : 0xFFD8E4DC),
          ),
    );
    return theme.copyWith(
      typography: theme.typography.copyWith(
        englishLike: theme.typography.englishLike.apply(fontSizeFactor: .9),
        dense: theme.typography.dense.apply(fontSizeFactor: .9),
        tall: theme.typography.tall.apply(fontSizeFactor: .9),
      ),
    );
  }
}

class _FollowAppState extends State<FollowApp> {
  ThemeMode? _themeMode;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    unawaited(_loadThemeMode());
  }

  Future<void> _loadThemeMode() async {
    try {
      final saved = await widget.core.loadThemeMode();
      if (mounted && _themeMode == null) {
        setState(() {
          _themeMode =
              ThemeMode.values
                  .where((mode) => mode.name == saved)
                  .firstOrNull ??
              ThemeMode.system;
        });
      }
    } on PlatformException {
      // A missing or unreadable preference falls back to the system appearance.
    }
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    try {
      await widget.core.saveThemeMode(mode.name);
    } on PlatformException {
      if (mounted) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('外观已切换，但保存失败，重启后可能恢复默认。')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '跟焦器',
      scaffoldMessengerKey: _messengerKey,
      debugShowCheckedModeBanner: false,
      theme: FollowApp._theme(Brightness.light),
      darkTheme: FollowApp._theme(Brightness.dark),
      themeMode: _themeMode ?? ThemeMode.system,
      builder: (context, child) {
        final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
        return Stack(
          fit: StackFit.expand,
          children: [
            child!,
            if (keyboardHeight > 0)
              Positioned(
                right: 12,
                bottom: keyboardHeight + 8,
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                  child: TextButton.icon(
                    onPressed: () =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    icon: const Icon(LucideIcons.keyboardOff),
                    label: const Text('收起键盘'),
                  ),
                ),
              ),
          ],
        );
      },
      home: ModePage(
        core: widget.core,
        themeMode: _themeMode ?? ThemeMode.system,
        onThemeChanged: _setThemeMode,
      ),
    );
  }
}

/// 跟焦页：**纯 UI**。
///
/// 所有状态来自 `ff.core` 的快照，所有动作是 `ff.core` 的方法调用。
/// 这里不允许出现限位计算、自动跟焦判定、相位切换 —— 那些都在
/// Swift 的 `FollowFocusSession` 里。页面只保留“纯界面状态”：
/// 折叠开关、输入框、拖动中的临时值。
class FollowPage extends StatefulWidget {
  final FfCore core;
  final String lensId;
  final LidarChannel? lidar;

  const FollowPage({
    super.key,
    required this.core,
    required this.lensId,
    this.lidar,
  });

  @override
  State<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<FollowPage> {
  // The camera overlays stay black even when the rest of the app is light.
  static final _viewfinderTheme = FollowApp._theme(Brightness.dark).copyWith(
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white60,
      ),
    ),
  );
  bool get _paused => _s.stopLatched && _s.strokeSteps > 0;
  Future<void> _stopOrResume() async {
    setState(() => _sliderDrag = null);
    if (_paused) {
      await widget.core.resumeControl();
    } else {
      await widget.core.stopPressed();
    }
  }

  late final _lidar = widget.lidar ?? LidarChannel();
  final _revsText = TextEditingController(text: '1');
  final _stepsText = TextEditingController(text: '80');
  final _distanceText = TextEditingController();
  StreamSubscription<FfState>? _sub;

  FfState _s = const FfState();

  bool _lidarOk = false;
  bool _previewExpanded = true;
  bool _diagnosticExpanded = false;
  bool _fm03Expanded = false;
  bool _showGrid = false;
  bool? _webLandscape;
  bool _rotating = false;
  int _previewQuarterTurns = 0;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 纯界面覆盖值：拖动中先用本地值，松手后回到快照，避免 20Hz 回读造成卡顿。
  double? _sliderDrag;
  double? _speedDrag;

  /// 覆盖层只画 LiDAR 的取景点/人脸框；距离用快照里滤波后的值。
  double _u = 0.5;
  double _v = 0.5;
  Rect? _face;

  @override
  void initState() {
    super.initState();
    _sub = widget.core.states().listen((s) {
      if (mounted) setState(() => _s = s);
    });
    _bootLidar();
  }

  Future<void> _bootLidar() async {
    final ok = await _lidar.available();
    if (!mounted) return;
    if (ok) {
      await _lidar.listen(_onLidar);
      if (!mounted) return;
      await _lidar.start(trackFaces: _s.faces);
    }
    if (mounted) setState(() => _lidarOk = ok);
  }

  void _onLidar(LidarSample s) {
    if (!mounted) return;
    final face =
        (s.faceU != null &&
            s.faceV != null &&
            s.faceW != null &&
            s.faceH != null)
        ? Rect.fromLTWH(s.faceU!, s.faceV!, s.faceW!, s.faceH!)
        : null;
    if (_previewQuarterTurns == s.previewQuarterTurns &&
        _u == s.u &&
        _v == s.v &&
        _face == face) {
      return;
    }
    setState(() {
      _previewQuarterTurns = s.previewQuarterTurns;
      _u = s.u;
      _v = s.v;
      _face = face;
    });
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setPreferredOrientations([]));
    widget.core.leaveLens();
    _sub?.cancel();
    _lidar.dispose();
    _revsText.dispose();
    _stepsText.dispose();
    _distanceText.dispose();
    super.dispose();
  }

  void _goSteps(int sign) {
    final n = int.tryParse(_stepsText.text.trim());
    if (n == null || n == 0 || n.abs() > 4096) return;
    widget.core.jog(sign * n.abs());
  }

  void _goRevs(int sign) {
    final r = double.tryParse(_revsText.text.trim());
    if (r == null || !r.isFinite || r == 0 || r.abs() > 1) return;
    // 归一化行程比例 → FM03 坐标增量。
    widget.core.jog(sign * (r.abs() * _s.stepsPerRev).round());
  }

  Future<void> _confirmRecalibrate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空距离标定表？'),
        content: Text(
          '${_s.lensName} 的物距—旋转位置图表和方向选择会被清空，'
          '需要重新记录至少五个点。FM03 内部限位由电机保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空重标'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.core.resetLensCalibration();
  }

  /// 顶栏右侧的链路状态。**三种情况必须分开**：
  ///
  /// - 没连：socket 都没开（或还没选设备）；
  /// - 失去回包：socket 开着，但没有状态回包（掉出板子热点、App 刚回前台、板子重启）；
  /// - 通着：报使能 / 运动 / 待机 / CAN。
  ///
  /// 旧版把后两种都说成"连着"，于是顶栏显示 `EN SLP CAN` 而实际一个包都不通 ——
  /// 会被带去查错的方向（`connected` 只是 socket bind 成功；`enabled/standby/canOk`
  /// 是收到过就不再失效的字段）。
  Widget _linkStatusText() {
    if (!_s.connected) {
      return Text(
        _s.deviceId == null ? '未选设备' : '${_s.deviceId} · 未连接',
        style: const TextStyle(fontSize: 11),
      );
    }
    if (!_s.linkAlive) {
      final age = _s.statusAgeMs;
      final secs = age == null ? '' : ' ${(age / 1000).round()}s';
      return Text(
        '${_s.deviceId ?? "已连接"} · 失去回包$secs',
        style: const TextStyle(fontSize: 11, color: Colors.orangeAccent),
      );
    }
    return Text(
      '${_s.enabled ? "EN" : "OFF"} '
      '${_s.moving ? "RUN" : "IDLE"} '
      '${_s.canOk ? "CAN" : ""}',
      style: const TextStyle(fontSize: 11),
    );
  }

  @override
  Widget build(BuildContext context) {
    final distText = _s.distanceM == null
        ? '--'
        : '${_s.distanceM!.toStringAsFixed(2)} m';
    final landscape = _isLandscape;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.black,
      endDrawer: landscape ? _settingsDrawer() : null,
      appBar: landscape
          ? null
          : AppBar(
              // 标题里带上 App 版本（`pubspec.yaml` 的 `version:`，由 iOS 壳从 Bundle 读出来）。
              // 装在手机上的到底是哪一版，一眼可见，不用去 设置→通用 里翻。
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('跟焦器'),
                  Text(
                    _s.appVersion.isEmpty ? '版本未知' : 'v${_s.appVersion}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ],
              ),
              actions: [
                _orientationButton(),
                IconButton(
                  tooltip: '设备',
                  onPressed: _calRunning || _s.calDirectionPending
                      ? null
                      : _openDevicePage,
                  icon: const Icon(LucideIcons.router),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(child: _linkStatusText()),
                ),
              ],
            ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final padding = MediaQuery.paddingOf(context);
          final availableHeight = (constraints.maxHeight - padding.bottom)
              .clamp(0, double.infinity);
          final controlsHeight = _previewExpanded
              ? (availableHeight * .5).clamp(0, 340).toDouble()
              : (availableHeight - 40).clamp(0, double.infinity).toDouble();
          return Stack(
            fit: StackFit.expand,
            children: [
              // Keep the native camera in the same tree slot across layouts.
              // Recreating UiKitView also recreates its capture preview layer.
              Positioned.fill(
                left: landscape ? 0 : padding.left,
                right: landscape ? 0 : padding.right,
                bottom: landscape || !_previewExpanded
                    ? 0
                    : controlsHeight + padding.bottom,
                child: Offstage(
                  offstage: !landscape && !_previewExpanded,
                  child: _preview(),
                ),
              ),
              if (landscape)
                Theme(data: _viewfinderTheme, child: _landscapeView(distText))
              else
                SafeArea(
                  top: false,
                  child: Column(
                    children: [
                      if (_previewExpanded)
                        Expanded(
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 12, top: 8),
                              child: Theme(
                                data: _viewfinderTheme,
                                child: _previewToggle(distText),
                              ),
                            ),
                          ),
                        )
                      else
                        _previewToggle(distText, compact: true),
                      SizedBox(
                        height: controlsHeight,
                        child: Material(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(20),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: _controls(),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _controls() => SingleChildScrollView(
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '电机 ${_s.pos} → ${_s.target}    ${_s.msg}',
          style: const TextStyle(fontSize: 12),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '镜头 ${_s.lensName}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Text(switch (_s.phase) {
              SetupPhase.stroke => '① 自动寻限位',
              SetupPhase.align => '② 选择方向',
              SetupPhase.calibrate => '③ 标定物距',
              SetupPhase.follow => '④ 跟焦',
            }, style: const TextStyle(fontSize: 11)),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: _calRunning || _s.calDirectionPending
                  ? null
                  : () => widget.core.connect(),
              child: Text(_s.connected ? '重连' : '连接电机'),
            ),
            FilterChip(
              label: const Text('使能'),
              showCheckmark: false,
              avatar: _s.enabled
                  ? const Icon(LucideIcons.check, size: 18)
                  : null,
              selected: _s.enabled,
              onSelected: _calRunning || _s.calDirectionPending || _paused
                  ? null
                  : (v) => widget.core.enable(v),
            ),
            FilterChip(
              showCheckmark: false,
              avatar: _s.auto && _s.phase == SetupPhase.follow
                  ? const Icon(LucideIcons.check, size: 18)
                  : null,
              // 核心决定图表是否可用，UI 只显示五点标定门槛。
              // 能不能开由核心决定（setAuto 会自己拒绝），这里只管显示。
              label: Text(
                _s.phase != SetupPhase.follow
                    ? '自动(先完成标定)'
                    : (_s.lutReady ? '自动跟焦' : '自动(需5点标定)'),
              ),
              selected: _s.auto && _s.phase == SetupPhase.follow,
              onSelected:
                  !_calRunning &&
                      !_paused &&
                      !_s.calDirectionPending &&
                      _s.lutReady &&
                      _s.phase == SetupPhase.follow
                  ? (v) => widget.core.setAuto(v)
                  : null,
            ),
            FilterChip(
              label: const Text('人脸'),
              showCheckmark: false,
              avatar: _s.faces ? const Icon(LucideIcons.check, size: 18) : null,
              selected: _s.faces,
              onSelected: _lidarOk ? (v) => widget.core.setTrackFaces(v) : null,
            ),
            OutlinedButton(
              onPressed: _s.connected && (!_paused || _s.canResume)
                  ? _stopOrResume
                  : null,
              child: Text(_paused ? '复位继续跟焦' : '停'),
            ),
          ],
        ),
        _autoCalibrationEntry(),
        _setupPanel(),
        if ((_s.phase == SetupPhase.calibrate ||
                _s.phase == SetupPhase.follow ||
                _s.phase == SetupPhase.align) &&
            !_calRunning) ...[
          Text(_s.auto ? '手动滑条（自动开时无效）' : '手动焦点'),
          Slider(
            value: _sliderDrag ?? _s.slider,
            onChanged: _s.auto || _paused
                ? null
                : (v) {
                    setState(() => _sliderDrag = v);
                    widget.core.setSlider(v);
                  },
            onChangeEnd: _s.auto || _paused
                ? null
                : (v) {
                    widget.core.setSlider(v);
                    setState(() => _sliderDrag = null);
                  },
          ),
          _jogControls(),
          Text('最大拨轮速度 ${((_speedDrag ?? _s.speedRevS) * 4096).round()} / 256'),
          Slider(
            min: 1 / 4096,
            max: 256 / 4096,
            divisions: 255,
            value: (_speedDrag ?? _s.speedRevS).clamp(1 / 4096, 256 / 4096),
            onChanged: (v) => setState(() => _speedDrag = v),
            onChangeEnd: (v) {
              setState(() => _speedDrag = null);
              widget.core.setFm03(kFm03MaxSpeed, (v * 4096).round());
            },
          ),
          const Text(
            'FM03 采用坐标反馈到位，接近目标时自动减速。'
            '拨轮速度是协议值，不是角速度；0～4096 表示已校准的整个行程。',
            style: TextStyle(fontSize: 11),
          ),
          _directionRow(),
          if (_s.phase != SetupPhase.align) _distanceCalibrationPanel(),
        ],
        if (_s.phase == SetupPhase.stroke && _s.lutPoints.isNotEmpty)
          LensChart(points: _s.lutPoints, curve: _s.lutCurve),
        if (!_calRunning) _recalibrateTile(),
        const SizedBox(height: 8),
        _diagnosticPanel(),
        AbsorbPointer(
          absorbing: _calRunning || _s.calDirectionPending,
          child: _fm03Panel(),
        ),
      ],
    ),
  );

  bool get _isLandscape =>
      _webLandscape ??
      MediaQuery.orientationOf(context) == Orientation.landscape;

  Future<void> _toggleOrientation() async {
    if (_rotating) return;
    final landscape = !_isLandscape;
    FocusManager.instance.primaryFocus?.unfocus();
    _scaffoldKey.currentState?.closeEndDrawer();
    setState(() => _rotating = true);
    try {
      await SystemChrome.setPreferredOrientations([
        landscape
            ? DeviceOrientation.landscapeLeft
            : DeviceOrientation.portraitUp,
      ]);
      if (mounted && kIsWeb) setState(() => _webLandscape = landscape);
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('屏幕切换失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _rotating = false);
    }
  }

  Widget _orientationButton() => IconButton(
    tooltip: _isLandscape ? '切换竖屏' : '切换横屏',
    onPressed: _rotating ? null : _toggleOrientation,
    icon: Icon(
      _isLandscape ? LucideIcons.smartphone : LucideIcons.rectangleHorizontal,
    ),
  );

  Widget _settingsDrawer() => Drawer(
    width: MediaQuery.sizeOf(context).width.clamp(0, 440).toDouble(),
    child: SafeArea(
      child: Column(
        children: [
          ListTile(
            title: const Text('跟焦控制与标定'),
            trailing: IconButton(
              tooltip: '关闭控制面板',
              onPressed: () => _scaffoldKey.currentState?.closeEndDrawer(),
              icon: const Icon(LucideIcons.x),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _controls()),
        ],
      ),
    ),
  );

  Widget _landscapeView(String distance) => Stack(
    key: const ValueKey('landscape-viewfinder'),
    fit: StackFit.expand,
    children: [
      SafeArea(
        child: Column(
          children: [
            Material(
              color: Colors.black.withValues(alpha: .8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回镜头列表',
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(LucideIcons.arrowLeft, size: 20),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _s.lensName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _s.appVersion.isEmpty ? '跟焦器' : 'v${_s.appVersion}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _orientationButton(),
                  IconButton(
                    tooltip: '人脸追踪',
                    isSelected: _s.faces,
                    onPressed: _lidarOk
                        ? () => widget.core.setTrackFaces(!_s.faces)
                        : null,
                    icon: const Icon(LucideIcons.scanFace),
                  ),
                  IconButton(
                    tooltip: '构图网格',
                    isSelected: _showGrid,
                    style: IconButton.styleFrom(
                      backgroundColor: _showGrid
                          ? const Color(0xFF16A889)
                          : null,
                    ),
                    onPressed: () => setState(() => _showGrid = !_showGrid),
                    icon: const Icon(LucideIcons.grid3x3),
                  ),
                  IconButton(
                    tooltip: '设备',
                    onPressed: _calRunning || _s.calDirectionPending
                        ? null
                        : _openDevicePage,
                    icon: const Icon(LucideIcons.wifi),
                  ),
                  IconButton(
                    tooltip: '控制与标定',
                    onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                    icon: const Icon(LucideIcons.slidersHorizontal),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '物距 $distance',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  _calRunning ? '正在自动寻限位 · 请等待' : _s.msg,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 96,
                    child: Center(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _roundAction(
                              label: _paused ? '复位继续' : '停止',
                              icon: _paused
                                  ? LucideIcons.rotateCcw
                                  : LucideIcons.square,
                              color: _paused
                                  ? const Color(0xFF16A889)
                                  : const Color(0xFFAF4147),
                              onPressed:
                                  _s.connected && (!_paused || _s.canResume)
                                  ? _stopOrResume
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            _roundAction(
                              label: _s.auto ? '自动' : '手动',
                              icon: _s.auto
                                  ? LucideIcons.focus
                                  : LucideIcons.hand,
                              color: _s.auto
                                  ? const Color(0xFF16A889)
                                  : const Color(0xFF303638),
                              onPressed:
                                  !_calRunning &&
                                      !_paused &&
                                      !_s.calDirectionPending &&
                                      _s.lutReady &&
                                      _s.phase == SetupPhase.follow
                                  ? () => widget.core.setAuto(!_s.auto)
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Material(
              color: Colors.black.withValues(alpha: .8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _statusItem('电机链路', _linkStatusText()),
                    ),
                    Expanded(
                      flex: 2,
                      child: _statusItem(
                        '位置 → 目标',
                        Text('${_s.pos} → ${_s.target}'),
                      ),
                    ),
                    Expanded(
                      flex: 4,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _paused
                                ? '已停止锁定，请复位'
                                : _calRunning
                                ? '正在寻限位'
                                : _s.phase == SetupPhase.stroke
                                ? '先完成寻限位'
                                : _s.auto
                                ? '自动跟焦中'
                                : '手动焦点',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white70,
                            ),
                          ),
                          SizedBox(
                            height: 32,
                            child: Slider(
                              value: _sliderDrag ?? _s.slider,
                              onChanged:
                                  _s.auto ||
                                      _paused ||
                                      _calRunning ||
                                      _s.phase == SetupPhase.stroke
                                  ? null
                                  : (v) {
                                      setState(() => _sliderDrag = v);
                                      widget.core.setSlider(v);
                                    },
                              onChangeEnd:
                                  _paused ||
                                      _s.auto ||
                                      _calRunning ||
                                      _s.phase == SetupPhase.stroke
                                  ? null
                                  : (v) {
                                      widget.core.setSlider(v);
                                      setState(() => _sliderDrag = null);
                                    },
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _statusItem(
                        '标定点',
                        Text('${_s.lutPoints.length} / 5+'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _statusItem(String label, Widget value) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.white54)),
      const SizedBox(height: 4),
      value,
    ],
  );

  Widget _roundAction({
    required String label,
    required IconData icon,
    required Color color,
    VoidCallback? onPressed,
  }) => SizedBox(
    width: 72,
    height: 72,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white60,
        disabledBackgroundColor: color.withValues(alpha: .45),
        padding: EdgeInsets.zero,
        shape: const CircleBorder(),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 26),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    ),
  );

  Future<void> _openDevicePage() async {
    final picked = await Navigator.push<FfDevice>(
      context,
      MaterialPageRoute(
        builder: (_) => DevicePage(
          core: widget.core,
          selected: _s.devices
              .where((d) => d.deviceId == _s.deviceId)
              .firstOrNull,
          linkOpen: _s.connected,
        ),
      ),
    );
    if (picked == null) return;
    await widget.core.selectDevice(picked);
    await widget.core.connect();
  }

  /// 按 FM03 坐标增量手动微调，观察相机画面进行实焦标定。
  Widget _jogControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final d in [-800, -80, -8, 8, 80, 800])
              OutlinedButton(
                onPressed: _paused ? null : () => widget.core.jog(d),
                child: Text(d > 0 ? '+$d' : '$d'),
              ),
          ],
        ),
        const Divider(height: 16),
        // 原始坐标增量与归一化行程比例。
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 6,
          children: [
            const Text('坐标增量'),
            const SizedBox(width: 6),
            SizedBox(
              width: 90,
              child: TextField(
                textInputAction: TextInputAction.done,
                onSubmitted: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                onTapOutside: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                controller: _stepsText,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _goSteps(1),
              child: const Text('移动坐标'),
            ),
            OutlinedButton(
              onPressed: () => _goSteps(-1),
              child: const Text('反向'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 6,
          children: [
            const Text('行程比例'),
            const SizedBox(width: 6),
            SizedBox(
              width: 90,
              child: TextField(
                textInputAction: TextInputAction.done,
                onSubmitted: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                onTapOutside: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                controller: _revsText,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _goRevs(1),
              child: const Text('移动'),
            ),
            OutlinedButton(
              onPressed: () => _goRevs(-1),
              child: const Text('反向'),
            ),
          ],
        ),
        Text(
          '输入单位：FM03 坐标；4096 对应完整标定行程，当前位置 ${_s.pos}',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }

  Widget _setupPanel() {
    if (_calRunning) return _autoCalibrationPanel();
    switch (_s.phase) {
      case SetupPhase.stroke:
        return _strokePanel();
      case SetupPhase.align:
        return _alignPanel();
      case SetupPhase.calibrate:
      case SetupPhase.follow:
        return const SizedBox.shrink();
    }
  }

  bool get _calRunning => const {
    'preparing',
    'starting',
    'seek_negative',
    'backoff_negative',
    'seek_positive',
    'backoff_positive',
  }.contains(_s.calStage);

  Future<void> _startAutoCalibration() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('FM03 内部行程校准'),
        content: const Text(
          '确认齿轮已啮合、镜头有机械挡块，RS3 已断开。'
          '电机会自行寻找两端。内部校准暂无已验证的软件取消指令；'
          '需要立即中止时切断电机电源。完成后使用 0～4096 归一化坐标。'
          '已有距离表保留；更换齿轮安装位置或镜头后请长按重置重新标定。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始校准'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.core.startAutoCalibration();
    }
  }

  Widget _autoCalibrationEntry() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      OutlinedButton.icon(
        onPressed: _s.connected && _s.calSupported && !_calRunning
            ? _startAutoCalibration
            : null,
        icon: const Icon(LucideIcons.wandSparkles),
        label: const Text('FM03 自动寻限位'),
      ),
      if (!_s.connected)
        const Text('先连接电机，再开始自动寻限位。')
      else if (!_s.calSupported)
        const Text('请扫描并选择 FM03 2.x 固件设备。'),
      if (_s.calStage == 'failed' || _s.calStage == 'cancelled')
        Text(_s.msg, style: const TextStyle(color: Colors.orangeAccent)),
    ],
  );

  Widget _autoCalibrationPanel() {
    const labels = {
      'preparing': '正在检查电机',
      'starting': '正在启动标定',
      'seek_negative': 'FM03 校准阶段 1',
      'backoff_negative': 'FM03 校准阶段 1',
      'seek_positive': 'FM03 校准阶段 2',
      'backoff_positive': 'FM03 校准阶段 2',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        const Text(
          'FM03 正在自动寻限位',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        Text(labels[_s.calStage] ?? '正在寻限位'),
        const LinearProgressIndicator(),
        TextButton(
          onPressed: () => widget.core.cancelAutoCalibration(),
          child: const Text('停止观察（不取消内部校准）'),
        ),
      ],
    );
  }

  Widget _strokePanel() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 8),
    child: Text(
      '① 新镜头、重新连接或换镜头后，先让 FM03 自动寻找两端限位。'
      '限位保存在电机内部，App 不保存机械行程。',
    ),
  );

  Widget _alignPanel() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 8),
    child: Text('② 用下方 + / − 按钮低速试转，结合相机画面判断哪个方向使物距变近，再选择方向。'),
  );

  Widget _directionRow() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Divider(height: 16),
      const Text('物距变近方向', style: TextStyle(fontWeight: FontWeight.bold)),
      const Text('+ / − 表示 FM03 坐标增减。改变方向会清空距离表。'),
      Wrap(
        spacing: 8,
        children: [
          for (final d in [-1, 1])
            ChoiceChip(
              label: Text(d == -1 ? '+ 方向变近' : '− 方向变近'),
              selected: !_s.calDirectionPending && _s.dir == d,
              onSelected: _s.moving ? null : (_) => widget.core.setDir(d),
            ),
        ],
      ),
      Text(
        'FM03 当前归一化坐标 ${_s.pos} / 4096',
        style: const TextStyle(fontSize: 11),
      ),
    ],
  );

  Widget _distanceCalibrationPanel() {
    final manual = _distanceText.text.trim();
    final meters = double.tryParse(manual);
    final validManual =
        meters != null && meters.isFinite && meters >= 0.05 && meters <= 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        const Text('距离标定', style: TextStyle(fontWeight: FontWeight.bold)),
        const Text(
          '用手机手动旋转电机，观察相机画面，实焦停稳后记录。'
          '至少 5 点，达到 5 点后仍可继续新增，建议覆盖近、中、远距离。'
          '相差不足 2 cm 的物距会更新原点位。'
          '按 1/物距分段插值；自动跟焦时，小于最小标定物距使用最近标定点，'
          '大于最大标定物距使用最远标定点。',
        ),
        TextField(
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          controller: _distanceText,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: '物距（m，可手动输入）',
            hintText: _s.distanceM == null
                ? '输入实测距离'
                : '留空使用 LiDAR ${_s.distanceM!.toStringAsFixed(2)} m',
            errorText: manual.isNotEmpty && !validManual
                ? '请输入 0.05～1000 m'
                : null,
          ),
        ),
        FilledButton.tonalIcon(
          onPressed:
              _s.connected &&
                  _s.positionTrusted &&
                  !_s.moving &&
                  !_s.auto &&
                  (manual.isEmpty ? _s.distanceM != null : validManual)
              ? () => widget.core.addLutPoint(
                  meters: manual.isEmpty ? null : meters,
                )
              : null,
          icon: const Icon(LucideIcons.plus),
          label: const Text('新增标定点'),
        ),
        Text(
          '已记录 ${_s.lutPoints.length} 点 · 至少 5 点，可继续新增 · ${_s.lutReady ? "图表可用于跟焦" : "请继续标定"}',
        ),
        if (_s.lutPoints.isNotEmpty)
          Text(
            '最近标定 ${_s.lutPoints.first.meters.toStringAsFixed(2)} m · '
            '最远标定 ${_s.lutPoints.last.meters.toStringAsFixed(2)} m',
          ),
        LensChart(points: _s.lutPoints, curve: _s.lutCurve),
        for (var i = 0; i < _s.lutPoints.length; i++)
          ListTile(
            dense: true,
            title: Text(
              '${_s.lutPoints[i].meters.toStringAsFixed(2)} m → ${_s.lutPoints[i].steps} 坐标',
            ),
            trailing: IconButton(
              icon: const Icon(LucideIcons.trash2),
              onPressed: () => widget.core.removeLutPoint(i),
            ),
          ),
        if (_s.lutPoints.isEmpty) const Text('还没有标定点。'),
        if (_s.phase == SetupPhase.calibrate)
          FilledButton(
            onPressed: _s.lutReady && _s.positionTrusted && !_s.moving
                ? widget.core.startFollow
                : null,
            child: const Text('开始跟焦'),
          ),
        if (_s.phase == SetupPhase.follow)
          TextButton(
            onPressed: widget.core.unalign,
            child: const Text('继续新增标定点'),
          ),
      ],
    );
  }

  Widget _recalibrateTile() => ListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    leading: const Icon(LucideIcons.rotateCcw, size: 20),
    title: const Text('重置距离标定（长按）'),
    subtitle: const Text('长按并确认后清空图表、重新选择方向；电机内部限位由 FM03 保留。'),
    onLongPress: _confirmRecalibrate,
  );

  Widget _diagnosticPanel() {
    final statusAge = _s.statusAgeMs;
    final statusLive = _s.connected && statusAge != null && statusAge < 1000;
    final sequenceOk =
        _s.lastSentSequence != 0 &&
        _s.lastSentSequence == _s.lastEchoedSequence;
    final echoAge = _s.echoAgeMs;
    final echoLive = echoAge != null && echoAge < 3000;
    final rows = <({String name, bool ok, String detail})>[
      (
        name: '链路探测（非协议包回显）',
        ok: echoLive,
        detail: !_s.connected
            ? '未连接'
            : '发 ${_s.probeTx} / 收 ${_s.rxPackets} · '
                  '${echoAge == null ? "无回显" : "$echoAge ms 前"}',
      ),
      (
        name: '本机 UDP 端口',
        ok: _s.connected,
        detail: _s.localPort == null ? '未绑定' : '${_s.localPort}',
      ),
      (
        name: '本机网卡地址',
        ok: _s.localAddrs.any((a) => a.contains('192.168.4.')),
        detail: _s.localAddrs.isEmpty ? '未枚举' : _s.localAddrs.join(', '),
      ),
      if (_s.socketError != null)
        (name: '套接字错误', ok: false, detail: _s.socketError!),
      (
        name: 'UDP 状态回包',
        ok: statusLive,
        detail: statusAge == null ? '尚未收到' : '$statusAge ms 前',
      ),
      (
        name: '请求序号回显',
        ok: sequenceOk,
        detail: _s.lastSentSequence == 0
            ? '尚未发送控制命令'
            : '发送 ${_s.lastSentSequence} / 回显 ${_s.lastEchoedSequence}',
      ),
      (name: 'FM03 CAN', ok: _s.canOk, detail: _s.canOk ? '通讯正常' : '未确认'),
      (
        name: '软限位反馈',
        ok: _s.connected && statusAge != null,
        detail: _s.connected
            ? (_s.target == _s.limitLo || _s.target == _s.limitHi
                  ? '当前目标在边界'
                  : '已启用')
            : '未连接',
      ),
      (
        name: '目标追踪',
        ok: _s.connected && _s.target == _s.pos && !_s.moving,
        detail: _s.moving
            ? '正在追踪 ${_s.target}'
            : '位置 ${_s.pos} / 目标 ${_s.target}',
      ),
      (
        name: '最近命令结果',
        ok: _s.result != kResultRejected,
        detail: _s.resultLabel,
      ),
    ];
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('功能可用性诊断'),
      trailing: Icon(
        _diagnosticExpanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
      ),
      onExpansionChanged: (expanded) =>
          setState(() => _diagnosticExpanded = expanded),
      subtitle: Text(
        statusLive ? '链路正常' : (_s.connected ? '状态超时，请检查 Wi-Fi' : '等待设备连接'),
      ),
      children: [
        for (final row in rows)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              row.ok ? LucideIcons.circleCheck : LucideIcons.circleAlert,
              color: row.ok ? Colors.greenAccent : Colors.orangeAccent,
              size: 20,
            ),
            title: Text(row.name),
            trailing: Text(
              row.detail,
              style: const TextStyle(fontSize: 11),
              textAlign: TextAlign.right,
            ),
          ),
      ],
    );
  }

  Widget _fm03Panel() {
    final t = _s.fm03;
    final live = _s.connected && t?.online == true && !_s.moving;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('DJI FM03 · CAN'),
      trailing: Icon(
        _fm03Expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
      ),
      onExpansionChanged: (expanded) =>
          setState(() => _fm03Expanded = expanded),
      subtitle: Text(
        t == null
            ? '等待电机反馈'
            : '${t.online ? "在线" : "离线"} · 阶段 ${t.stage} · 原始坐标 ${t.rawPosition}',
      ),
      children: [
        const Text('1 Mbps · GPIO4 TX / GPIO5 RX · 50 ms 控制周期'),
        _fm03Row(
          '最大拨轮速度',
          t?.maxSpeed,
          kFm03MaxSpeed,
          live,
          '协议速度值 1～256，默认 64。建议从低速验证机械响应。',
        ),
        _fm03Row(
          '到位容差',
          t?.tolerance,
          kFm03Tolerance,
          live,
          '坐标误差 1～64，默认 4。误差进入容差后归零并等待 400 ms 稳定。',
        ),
        _fm03Row(
          '接近减速系数',
          t?.gain,
          kFm03Gain,
          live,
          '1～64，默认 4。数值越大，接近目标时速度越低。',
        ),
        if (t != null)
          Text(
            '反馈 ${t.feedbackAge} ms · 输出 ${t.value} · '
            '发送失败 ${t.txFailures} · 接收丢帧 ${t.rxMissed}',
          ),
        const Text('速度归零和禁用只停止普通控制；内部行程校准须等待完成或切断电机电源。'),
        OutlinedButton(
          onPressed: _s.connected ? widget.core.queryFm03 : null,
          child: const Text('刷新 CAN 状态'),
        ),
        SizedBox(
          height: 140,
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              for (final line in _s.fm03Log)
                Text(line, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fm03Row(String name, int? value, int key, bool live, String hint) =>
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text('$name  ${value ?? "--"}'),
        subtitle: Text(hint),
        onTap: !live
            ? null
            : () async {
                final next = await _askInt(name, value);
                if (next != null) await widget.core.setFm03(key, next);
              },
      );

  Future<int?> _askInt(String title, int? cur) {
    final c = TextEditingController(text: cur?.toString() ?? '');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('设置 $title'),
        content: TextField(
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          controller: c,
          keyboardType: TextInputType.number,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(c.text.trim())),
            child: const Text('写入'),
          ),
        ],
      ),
    );
  }

  Widget _preview() {
    return ColoredBox(
      key: const ValueKey('camera-preview'),
      color: Colors.black,
      child: Center(
        child: _lidarOk
            ? RotatedBox(
                quarterTurns: _previewQuarterTurns,
                // VGA frames and LiDAR samples use portrait coordinates.
                // Keep the image, tap target and overlay in the same 3:4 space.
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const UiKitView(viewType: 'ff.lidar/preview'),
                      IgnorePointer(
                        child: CustomPaint(
                          painter: _OverlayPainter(
                            u: _u,
                            v: _v,
                            face: _face,
                            grid: _showGrid,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.crosshair,
                          size: 44,
                          color: Colors.white24,
                        ),
                        SizedBox(height: 12),
                        Text(
                          'LiDAR 需 iPhone Pro',
                          style: TextStyle(color: Colors.white38),
                        ),
                      ],
                    ),
                  ),
                  IgnorePointer(
                    child: CustomPaint(
                      painter: _OverlayPainter(
                        u: _u,
                        v: _v,
                        face: _face,
                        grid: _showGrid,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _previewToggle(String distance, {bool compact = false}) {
    return Material(
      color: compact ? Theme.of(context).colorScheme.surface : Colors.black54,
      child: InkWell(
        onTap: () => setState(() => _previewExpanded = !_previewExpanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _previewExpanded
                    ? LucideIcons.chevronUp
                    : LucideIcons.chevronDown,
                size: 18,
              ),
              const SizedBox(width: 4),
              Text('摄像头 ${_previewExpanded ? "展开" : "已折叠"}'),
              const SizedBox(width: 10),
              Text('距离 $distance', style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final double u;
  final double v;
  final Rect? face;
  final bool grid;

  _OverlayPainter({
    required this.u,
    required this.v,
    required this.face,
    required this.grid,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (grid) {
      final lines = Paint()
        ..color = Colors.white24
        ..strokeWidth = 1;
      for (final fraction in [1 / 3, 2 / 3]) {
        canvas.drawLine(
          Offset(size.width * fraction, 0),
          Offset(size.width * fraction, size.height),
          lines,
        );
        canvas.drawLine(
          Offset(0, size.height * fraction),
          Offset(size.width, size.height * fraction),
          lines,
        );
      }
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFF69F0AE);
    final fill = Paint()..color = const Color(0xFF69F0AE);
    if (face != null) {
      canvas.drawRect(
        Rect.fromLTWH(
          face!.left * size.width,
          face!.top * size.height,
          face!.width * size.width,
          face!.height * size.height,
        ),
        stroke..color = const Color(0xFFFFF176),
      );
    }
    final c = Offset(u * size.width, v * size.height);
    canvas.drawCircle(c, 10, stroke..color = const Color(0xFF69F0AE));
    canvas.drawCircle(c, 3, fill);
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) =>
      old.u != u || old.v != v || old.face != face || old.grid != grid;
}
