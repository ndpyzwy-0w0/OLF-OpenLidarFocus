import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'device_page.dart';
import 'ff_core.dart';
import 'ff_core_demo.dart';
import 'lens_page.dart';
import 'lidar.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // web 上没有 `ff.core` 的实现（那是 iOS 侧的 Swift 插件），用演示核心把界面撑起来；
  // 真机和模拟器一律走真的 FfCore。
  final core = kIsWeb ? FfCoreDemo() : FfCore();
  // 功能层起来后自己会连 LiDAR 和控制回路，UI 不等它。
  unawaited(core.start());
  runApp(FollowApp(core: core));
}

class FollowApp extends StatelessWidget {
  final FfCore core;

  const FollowApp({super.key, required this.core});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '跟焦器',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4CAF50),
          brightness: Brightness.dark,
        ),
      ),
      home: LensPage(core: core),
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

  const FollowPage({super.key, required this.core, required this.lensId});

  @override
  State<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<FollowPage> {
  final _lidar = LidarChannel();
  final _revsText = TextEditingController(text: '1');
  final _stepsText = TextEditingController(text: '800');
  StreamSubscription<FfState>? _sub;

  FfState _s = const FfState();

  bool _lidarOk = false;
  bool _previewExpanded = true;

  /// 纯界面覆盖值：拖动中先用本地值，松手后回到快照，避免 20Hz 回读造成卡顿。
  double? _sliderDrag;
  double? _speedDrag;
  double? _accelDrag;

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
    if (ok) {
      await _lidar.listen(_onLidar);
      await _lidar.start(trackFaces: _s.faces);
    }
    if (mounted) setState(() => _lidarOk = ok);
  }

  void _onLidar(LidarSample s) {
    if (!mounted) return;
    setState(() {
      _u = s.u;
      _v = s.v;
      _face = (s.faceU != null && s.faceV != null && s.faceW != null && s.faceH != null)
          ? Rect.fromLTWH(s.faceU!, s.faceV!, s.faceW!, s.faceH!)
          : null;
    });
  }

  @override
  void dispose() {
    widget.core.leaveLens();
    _sub?.cancel();
    _lidar.dispose();
    _revsText.dispose();
    _stepsText.dispose();
    super.dispose();
  }

  void _goSteps(int sign) {
    final n = int.tryParse(_stepsText.text.trim());
    if (n == null || n == 0) return;
    widget.core.jog(sign * n.abs());
  }

  void _goRevs(int sign) {
    final r = double.tryParse(_revsText.text.trim());
    if (r == null || r == 0) return;
    // 圈 → 步：脉冲/圈由核心给出，UI 只做这一次乘法。
    widget.core.jog(sign * (r.abs() * _s.stepsPerRev).round());
  }

  Future<void> _confirmRecalibrate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空行程标定？'),
        content: Text(
          '${_s.lensName} 的行程 ${_s.strokeSteps} 步会被清空，'
          '之后要重新量一次行程才能跟焦。',
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
    if (ok == true) await widget.core.recalibrateStroke();
  }

  /// 顶栏右侧的链路状态。**三种情况必须分开**：
  ///
  /// - 没连：socket 都没开（或还没选设备）；
  /// - 失去回包：socket 开着，但没有状态回包（掉出板子热点、App 刚回前台、板子重启）；
  /// - 通着：报使能 / 运动 / 待机 / UART。
  ///
  /// 旧版把后两种都说成"连着"，于是顶栏显示 `EN SLP UART` 而实际一个包都不通 ——
  /// 会被带去查错的方向（`connected` 只是 socket bind 成功；`enabled/standby/uartOk`
  /// 是收到过就不再失效的字段）。
  Widget _linkStatusText() {
    if (!_s.connected) {
      return Text(
        _s.deviceId == null ? '未选设备' : '${_s.deviceId} · 未连接',
        style: const TextStyle(fontSize: 12),
      );
    }
    if (!_s.linkAlive) {
      final age = _s.statusAgeMs;
      final secs = age == null ? '' : ' ${(age / 1000).round()}s';
      return Text(
        '${_s.deviceId ?? "已连接"} · 失去回包$secs',
        style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
      );
    }
    return Text(
      '${_s.enabled ? "EN" : "OFF"} '
      '${_s.moving ? "RUN" : (_s.standby ? "SLP" : "IDLE")} '
      '${_s.uartOk ? "UART" : ""}',
      style: const TextStyle(fontSize: 12),
    );
  }

  @override
  Widget build(BuildContext context) {
    final distText = _s.distanceM == null
        ? '--'
        : '${_s.distanceM!.toStringAsFixed(2)} m';
    return Scaffold(
      appBar: AppBar(
        // 标题里带上 App 版本（`pubspec.yaml` 的 `version:`，由 iOS 壳从 Bundle 读出来）。
        // 装在手机上的到底是哪一版，一眼可见，不用去 设置→通用 里翻。
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('跟焦器'),
            Text(
              _s.appVersion.isEmpty ? '版本未知' : 'v${_s.appVersion}',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '设备',
            onPressed: _calRunning || _s.calDirectionPending ? null : _openDevicePage,
            icon: Icon(_s.deviceId == null ? Icons.router_outlined : Icons.router),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: _linkStatusText()),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_previewExpanded)
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _preview(),
                  Positioned(left: 12, top: 8, child: _previewToggle(distText)),
                ],
              ),
            )
          else
            _previewToggle(distText, compact: true),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '电机 ${_s.pos} → ${_s.target}    ${_s.msg}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '镜头 ${_s.lensName}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Text(
                        switch (_s.phase) {
                          SetupPhase.stroke => '① 标定行程',
                          SetupPhase.align => '② 单侧对齐',
                          SetupPhase.follow => '③ 跟焦',
                        },
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _calRunning || _s.calDirectionPending ? null : () => widget.core.connect(),
                        child: Text(_s.connected ? '重连' : '连接电机'),
                      ),
                      FilterChip(
                        label: const Text('使能'),
                        selected: _s.enabled,
                        onSelected: _calRunning || _s.calDirectionPending ? null : (v) => widget.core.enable(v),
                      ),
                      FilterChip(
                        // 自动跟焦要先对齐、还要有两点距离标定，否则没有可信的目标。
                        // 能不能开由核心决定（setAuto 会自己拒绝），这里只管显示。
                        label: Text(
                          _s.phase != SetupPhase.follow
                              ? '自动(先对齐)'
                              : (_s.lutReady ? '自动跟焦' : '自动(需2点标定)'),
                        ),
                        selected: _s.auto && _s.phase == SetupPhase.follow,
                        onSelected:
                            !_calRunning && !_s.calDirectionPending &&
                            _s.lutReady && _s.phase == SetupPhase.follow
                            ? (v) => widget.core.setAuto(v)
                            : null,
                      ),
                      FilterChip(
                        label: const Text('人脸'),
                        selected: _s.faces,
                        onSelected: _lidarOk
                            ? (v) => widget.core.setTrackFaces(v)
                            : null,
                      ),
                      OutlinedButton(
                        onPressed: _s.connected
                            ? () => widget.core.stopPressed()
                            : null,
                        child: const Text('停'),
                      ),
                      OutlinedButton(
                        onPressed: _s.connected && !_s.moving && !_calRunning && !_s.calDirectionPending
                            ? () => widget.core.homePressed()
                            : null,
                        child: Text(_s.positionTrusted ? '已校零' : '设当前位置为原点'),
                      ),
                    ],
                  ),
                  _setupPanel(),
                  if (_s.phase == SetupPhase.follow) ...[
                    Text(_s.auto ? '手动滑条（自动开时无效）' : '手动焦点'),
                    Slider(
                      value: _sliderDrag ?? _s.slider,
                      onChanged: _s.auto
                          ? null
                          : (v) {
                              setState(() => _sliderDrag = v);
                              widget.core.setSlider(v);
                            },
                      onChangeEnd: _s.auto
                          ? null
                          : (v) {
                              widget.core.setSlider(v);
                              setState(() => _sliderDrag = null);
                            },
                    ),
                    _jogControls(),
                    Text(
                      '每个脉冲约 ${(360 / _s.stepsPerRev).toStringAsFixed(4)}°；'
                      '8 脉冲 = ${(360 * 8 / _s.stepsPerRev).toStringAsFixed(3)}°',
                      style: const TextStyle(fontSize: 11),
                    ),
                    // 直接说明“为什么 80 步比 800 步慢”：峰值速度由距离决定。
                    _peakHint(),
                    Text(
                      '速度 ${(_speedDrag ?? _s.speedRevS).toStringAsFixed(2)} 圈/秒'
                      '（${((_speedDrag ?? _s.speedRevS) * 60).round()} 转/分 · '
                      '${((_speedDrag ?? _s.speedRevS) * _s.stepsPerRev).round()} 脉冲/秒）',
                    ),
                    Slider(
                      min: 0.05,
                      max: 3.0,
                      value: (_speedDrag ?? _s.speedRevS).clamp(0.05, 3.0),
                      onChanged: (v) => setState(() => _speedDrag = v),
                      onChangeEnd: (v) {
                        setState(() => _speedDrag = null);
                        widget.core.setSpeed(
                          revsPerSec: v,
                          accelRevsPerSec2: _accelDrag ?? _s.accelRevS2,
                        );
                      },
                    ),
                    if ((_speedDrag ?? _s.speedRevS) > _s.maxRevsPerSec)
                      Text(
                        '⚠ 1/${_s.microsteps} 细分下最高只有 '
                        '${_s.maxRevsPerSec.toStringAsFixed(2)} 圈/秒'
                        '（固件上限脉冲/秒）。'
                        '要更快就用更低细分：1/16 配「微步插值」内部同样是 1/256，'
                        '但脉冲只有 1/16。',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFFFFAB40),
                        ),
                      ),
                    Text(
                      '加速度 ${(_accelDrag ?? _s.accelRevS2).toStringAsFixed(0)} 圈/秒²',
                    ),
                    Slider(
                      min: 2,
                      max: 100,
                      value: (_accelDrag ?? _s.accelRevS2).clamp(2, 100),
                      onChanged: (v) => setState(() => _accelDrag = v),
                      onChangeEnd: (v) {
                        setState(() => _accelDrag = null);
                        widget.core.setSpeed(
                          revsPerSec: _speedDrag ?? _s.speedRevS,
                          accelRevsPerSec2: v,
                        );
                      },
                    ),
                    const Text(
                      '速度和加速度按“圈/秒”给，换细分不会改变物理速度。'
                      '1600 脉冲会先加速、达到巡航后再减速，'
                      '中途降速是正常减速段；短行程会更早进入减速。',
                      style: TextStyle(fontSize: 11),
                    ),
                    const Text(
                      '手动 JOG 会先清除正在执行的旧目标，再从当前位置精确执行本次脉冲，'
                      '用于验证 +8 与 +80 的实际差异；自动跟焦仍使用 SET_POS 平滑追踪。',
                      style: TextStyle(fontSize: 11),
                    ),
                    _directionRow(),
                    Row(
                      children: [
                        const Text(
                          '距离标定',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        FilledButton.tonal(
                          onPressed: _s.distanceM == null
                              ? null
                              : () => widget.core.addLutPoint(),
                          child: const Text('记录当前'),
                        ),
                      ],
                    ),
                    const Text(
                      'Jog 到实焦后点记录。至少两点；按 1/距离 插值。'
                      '标定与当前细分绑定，换细分会自动换算。',
                    ),
                    for (var i = 0; i < _s.lutPoints.length; i++)
                      ListTile(
                        dense: true,
                        title: Text(
                          '${_s.lutPoints[i].meters.toStringAsFixed(2)} m  →  '
                          '${_s.lutPoints[i].steps} 步'
                          '（${(_s.lutPoints[i].steps / _s.stepsPerRev).toStringAsFixed(2)} 圈）',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () => widget.core.removeLutPoint(i),
                        ),
                      ),
                    if (_s.lutPoints.isEmpty) const Text('还没有标定点。'),
                    _recalibrateTile(),
                  ],
                  const SizedBox(height: 8),
                  _diagnosticPanel(),
                  AbsorbPointer(absorbing: _calRunning || _s.calDirectionPending,
                    child: _tmcPanel()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDevicePage() async {
    final picked = await Navigator.push<FfDevice>(
      context,
      MaterialPageRoute(
        builder: (_) => DevicePage(
          core: widget.core,
          selected: _s.devices.where((d) => d.deviceId == _s.deviceId).firstOrNull,
          linkOpen: _s.connected,
        ),
      ),
    );
    if (picked == null) return;
    await widget.core.selectDevice(picked);
    await widget.core.connect();
  }

  /// 自由微调：走步/走圈/脉冲。标定和对齐阶段靠它把跟焦器转到想要的位置。
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
                onPressed: () => widget.core.jog(d),
                child: Text(d > 0 ? '+$d' : '$d'),
              ),
          ],
        ),
        const Divider(height: 16),
        // 脉冲 / 圈。这里的“步”是 STEP 脉冲（微步），不是整步。
        Row(
          children: [
            const Text('脉冲'),
            const SizedBox(width: 6),
            SizedBox(
              width: 90,
              child: TextField(
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
              child: const Text('走步'),
            ),
            OutlinedButton(
              onPressed: () => _goSteps(-1),
              child: const Text('反向'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('圈'),
            const SizedBox(width: 6),
            SizedBox(
              width: 90,
              child: TextField(
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
              child: const Text('走圈'),
            ),
            OutlinedButton(
              onPressed: () => _goRevs(-1),
              child: const Text('反向'),
            ),
          ],
        ),
        Text(
          '输入单位：脉冲/微步；脉冲/圈 ${_s.stepsPerRev}（0.9° 电机 = 400 整步/圈 × '
          '1/${_s.microsteps} 细分）；当前位置 '
          '${_s.posRevs.toStringAsFixed(2)} 圈',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }

  Widget _setupPanel() {
    if (_s.calDirectionPending || _calRunning) return _autoCalibrationPanel();
    switch (_s.phase) {
      case SetupPhase.stroke:
        return _strokePanel();
      case SetupPhase.align:
        return _alignPanel();
      case SetupPhase.follow:
        return const SizedBox.shrink();
    }
  }

  bool get _calRunning => const {
    'preparing', 'starting', 'seek_negative', 'backoff_negative',
    'seek_positive', 'backoff_positive',
  }.contains(_s.calStage);

  Future<void> _startAutoCalibration() async {
    final threshold = TextEditingController(text: '60');
    final maxRevs = TextEditingController(text: '2');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自动识别行程'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('仅适用于有机械挡块的对焦环。请确认齿轮已啮合、两端没有障碍物；识别过程中电机会自行转动。'),
            TextField(controller: threshold, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '堵转阈值 SGTHRS（1–255，默认 60）')),
            TextField(controller: maxRevs, keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: '每段最大电机圈数（0.5–10，默认 2）')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('返回')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认开始转动')),
        ],
      ),
    );
    if (ok != true) return;
    final t = int.tryParse(threshold.text.trim());
    final r = double.tryParse(maxRevs.text.trim());
    if (t == null || t < 1 || t > 255 || r == null || r < 0.5 || r > 10) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入有效的阈值和电机圈数')));
      }
      return;
    }
    await widget.core.startAutoCalibration(threshold: t, maxRevs: r);
  }

  Widget _autoCalibrationEntry() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_s.calSupported)
        OutlinedButton.icon(
          onPressed: _s.connected ? _startAutoCalibration : null,
          icon: const Icon(Icons.auto_fix_high),
          label: const Text('自动识别行程'),
        )
      else
        const Text('此固件不支持自动识别行程，可继续手动标定。'),
      if (_s.calStage == 'failed' || _s.calStage == 'cancelled')
        Text(_s.msg, style: const TextStyle(color: Colors.orangeAccent)),
    ],
  );

  Widget _autoCalibrationPanel() {
    const labels = {
      'preparing': '正在检查电机', 'starting': '正在启动标定',
      'seek_negative': '寻找第一端', 'backoff_negative': '从第一端退回',
      'seek_positive': '寻找第二端', 'backoff_positive': '从第二端退回',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(height: 16),
      const Text('自动识别行程', style: TextStyle(fontWeight: FontWeight.bold)),
      if (_s.calDirectionPending) ...[
        Text('安全行程 ${_s.calSafeSpan} 步；估计机械行程 ${_s.calTravel} 步。'),
        const Text('请观察对焦环：正步数移动时，对焦距离会怎样变化？'),
        Wrap(spacing: 8, children: [
          FilledButton(onPressed: () => widget.core.setDir(1),
            child: const Text('正步数变远')),
          FilledButton(onPressed: () => widget.core.setDir(-1),
            child: const Text('正步数变近')),
        ]),
        const Text('确认方向后仍需重新记录距离标定点。'),
      ] else ...[
        Text(labels[_s.calStage] ?? '正在标定'),
        const LinearProgressIndicator(),
      ],
      TextButton(onPressed: () => widget.core.cancelAutoCalibration(),
        child: const Text('取消并释放电机')),
    ]);
  }

  /// ① 新镜头：手动量出行程（两个端点之间的距离）。
  Widget _strokePanel() {
    final a = _s.strokeA;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        const Text('① 标定行程', style: TextStyle(fontWeight: FontWeight.bold)),
        _autoCalibrationEntry(),
        if (_s.strokeSteps > 0) ...[
          const Text('上次行程的坐标已失效。可重新自动识别，或长按下面入口清空旧行程并改用手动标定。'),
          _recalibrateTile(),
        ] else ...[
        const Text(
          '新镜头要先量出行程：把跟焦器转到对焦环的一端，记录 A；'
          '再转到另一端，记录 B。两点之间的距离就是行程，'
          '之后跟焦的转动范围永远不会超过它。',
        ),
        Text('当前位置 ${_s.pos} 步（${_s.posRevs.toStringAsFixed(2)} 圈）'),
        _jogControls(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _s.connected
                  ? () => widget.core.recordStrokeA()
                  : null,
              child: Text(a == null ? '记录这一端 A' : 'A = $a 步（重记）'),
            ),
            FilledButton(
              onPressed: _s.connected && a != null
                  ? () => widget.core.finishStroke()
                  : null,
              child: const Text('记录另一端 B，完成标定'),
            ),
          ],
        ),
        if (!_s.connected)
          const Text('先在上面“连接电机”，再用这里自由微调到行程两端。')
        else if (a != null)
          const Text('把跟焦器转到行程另一端，再点右边按钮。'),
        ],
      ],
    );
  }

  /// ② 已标定行程的镜头：每次进入都先做单侧对齐。
  Widget _alignPanel() {
    final near = _s.nearSteps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        Row(
          children: [
            const Text(
              '② 单侧对齐',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            Text(
              '行程 ${_s.strokeRevs.toStringAsFixed(2)} 圈',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        const Text(
          '跟焦器没有绝对位置，每次进入都要对齐一次：手动微调到画面最近对焦，'
          '把当前位置认成“焦距最近点”，再选哪边是焦距变远的方向。'
          '这样只会在这段行程内转，不会拧反、也不会超行程。',
        ),
        _autoCalibrationEntry(),
        if (near == null) ...[
          Text('当前 ${_s.pos} 步（${_s.posRevs.toStringAsFixed(2)} 圈）'),
          _jogControls(),
          FilledButton(
            onPressed: _s.connected ? () => widget.core.confirmNear() : null,
            child: const Text('确认为焦距最近点'),
          ),
          if (!_s.connected) const Text('先连接电机，再自由微调到最近对焦。'),
        ] else ...[
          Text('最近点 = $near 步'),
          const SizedBox(height: 8),
          const Text('从最近点往哪个旋转方向是“焦距变远”？'),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('+ 方向变远')),
              ButtonSegment(value: -1, label: Text('- 方向变远')),
            ],
            selected: {_s.dir},
            onSelectionChanged: (s) => widget.core.setDir(s.first),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _s.connected ? () => widget.core.startFollow() : null,
                child: const Text('开始跟焦'),
              ),
              OutlinedButton(
                onPressed: () => widget.core.unalign(),
                child: const Text('重选最近点'),
              ),
            ],
          ),
        ],
        _recalibrateTile(),
      ],
    );
  }

  /// 焦距变远方向只决定对齐后的软限位区间：选错会把区间放在错误的一侧，
  /// 表现是往远端走不动，改回来即可，不会真的拧过行程。
  Widget _directionRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        Row(
          children: [
            const Text(
              '焦距变远方向',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => widget.core.unalign(),
              child: const Text('重新对齐'),
            ),
          ],
        ),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('+ 方向变远')),
            ButtonSegment(value: -1, label: Text('- 方向变远')),
          ],
          selected: {_s.dir},
          onSelectionChanged: (s) => widget.core.setDir(s.first),
        ),
        Text(
          '允许 ${_s.limitLo}..${_s.limitHi} 步'
          '（最近点 ${_s.nearSteps} · 行程 ${_s.strokeSteps} 步）',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }

  /// 行程标定的防误触入口：标过之后要长按再确认才能清空重标。
  Widget _recalibrateTile() {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.straighten, size: 20),
      title: const Text('重新标定行程（长按）'),
      subtitle: const Text('标定过就不怕误触：长按 1 秒，再确认才会清空行程重来。'),
      onLongPress: _confirmRecalibrate,
    );
  }

  Widget _diagnosticPanel() {
    final statusAge = _s.statusAgeMs;
    final statusLive = _s.connected && statusAge != null && statusAge < 1000;
    final sequenceOk =
        _s.lastSentSequence != 0 && _s.lastSentSequence == _s.lastEchoedSequence;
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
      (name: 'TMC2209 UART', ok: _s.uartOk, detail: _s.uartOk ? '通讯正常' : '未确认'),
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
        name: '待机唤醒',
        ok: _s.connected && (_s.enabled || _s.standby),
        detail: _s.standby ? '待机释放，运动时自动唤醒' : '可用',
      ),
      (
        name: '目标追踪',
        ok: _s.connected && _s.target == _s.pos && !_s.moving,
        detail: _s.moving ? '正在追踪 ${_s.target}' : '位置 ${_s.pos} / 目标 ${_s.target}',
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
      subtitle: Text(
        statusLive
            ? '链路正常'
            : (_s.connected ? '状态超时，请检查 Wi-Fi' : '等待设备连接'),
      ),
      children: [
        for (final row in rows)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              row.ok ? Icons.check_circle : Icons.error_outline,
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

  Widget _tmcPanel() {
    final t = _s.tmc;
    final live = _s.connected && t?.uartOk == true;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
        t == null
            ? 'TMC2209 驱动参数'
            : (t.uartOk
                  ? 'TMC2209 UART  ver=0x${t.version.toRadixString(16)}'
                  : 'TMC2209 无 UART（仅待机设置可用）'),
      ),
      subtitle: t == null
          ? const Text('连接后自动刷新')
          : Text(
              '${t.rmsMa} mA · 1/${t.microsteps} · '
              '${t.stealth ? "StealthChop 静音" : "SpreadCycle"}',
            ),
      children: [
        // 每个可编辑参数：中文名 + 当前值 + 一行中文说明，点一下写入。
        _tmcRow(
          '运行电流',
          t == null ? '--' : '${t.rmsMa} mA',
          kTmcRms,
          live,
          t?.rmsMa,
          '电机转动时的电流。越大越有力，也越热。建议 300–1200 mA，默认 800。',
        ),
        _tmcRow(
          '保持电流',
          t == null ? '--' : '${t.ihold} / 31',
          kTmcIhold,
          live,
          t?.ihold,
          '停止时维持的电流档位（相对运行电流）。0 = 完全不锁轴，不发热也不震。',
        ),
        _tmcRow(
          '运行电流档',
          t == null ? '--' : '${t.irun} / 31',
          kTmcIrun,
          live,
          t?.irun,
          '直接写 IRUN 的 CS 值 0–31。一般不用改，改上面的“运行电流”就行。',
        ),
        _tmcRow(
          'toff 关断时间',
          t == null ? '--' : '${t.toff}',
          kTmcToff,
          live,
          t?.toff,
          '斩波器关断时间 1–15。影响电流纹波与噪声，一般 3–5。',
        ),
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Row(
            children: [
              const Text('细分  '),
              Text(
                '1/${t?.microsteps ?? "--"}',
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              DropdownButton<int>(
                value: _msValue(t?.microsteps),
                hint: const Text('改'),
                items: const [8, 16, 32, 64, 128, 256]
                    .map((n) => DropdownMenuItem(value: n, child: Text('1/$n')))
                    .toList(),
                onChanged: !live
                    ? null
                    : (v) {
                        if (v != null) widget.core.setMicrosteps(v);
                      },
              ),
            ],
          ),
          subtitle: const Text(
            '每个整步细分成多少微步。越高越平滑越安静，但同样转速需要更多脉冲。',
            style: TextStyle(fontSize: 11),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('StealthChop 静音'),
          subtitle: const Text(
            '开 = 安静模式（静止时可能有轻微嗡声）；关 = SpreadCycle，响一点但力矩更硬。',
            style: TextStyle(fontSize: 11),
          ),
          value: t?.stealth ?? true,
          onChanged: !live
              ? null
              : (v) => widget.core.setTmc(kTmcStealth, v ? 1 : 0),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('待机自动断电'),
          subtitle: Text(
            '停止约 2.5 秒后释放驱动：不发热、不震动。'
            '代价是待机时没有锁轴力，镜头环若会自己走就关掉它。'
            '${_s.standby ? "（当前已断电）" : ""}',
            style: const TextStyle(fontSize: 11),
          ),
          value: _s.standbyFeature,
          onChanged: !_s.connected
              ? null
              : (v) => widget.core.setStandbyFeature(v),
        ),
        Row(
          children: [
            const Spacer(),
            OutlinedButton(
              onPressed: _s.connected ? () => widget.core.queryTmc() : null,
              child: const Text('刷新日志'),
            ),
          ],
        ),
        if (t != null)
          Text(
            [
              if (t.ot) '过热切断',
              if (t.otpw) '过热预警',
              if (t.ola || t.olb) '开路',
              if (t.shorted) '短路',
              if (t.standstill) '静止',
              'cs=${t.csActual} sg=${t.sg} tstep=${t.tstep}',
            ].join('  '),
            style: const TextStyle(fontSize: 12),
          ),
        const SizedBox(height: 6),
        const Text('日志', style: TextStyle(fontWeight: FontWeight.bold)),
        Container(
          height: 140,
          width: double.infinity,
          color: const Color(0xFF111111),
          padding: const EdgeInsets.all(8),
          child: _s.tmcLog.isEmpty
              ? const Text(
                  '还没有 TMC 日志',
                  style: TextStyle(fontFamily: 'Consolas', fontSize: 11),
                )
              : ListView.builder(
                  itemCount: _s.tmcLog.length,
                  itemBuilder: (_, i) => Text(
                    _s.tmcLog[i],
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 11,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  int? _msValue(int? ms) {
    const ok = [8, 16, 32, 64, 128, 256];
    if (ms == null || !ok.contains(ms)) return null;
    return ms;
  }

  Widget _tmcRow(
    String name,
    String value,
    int key,
    bool live,
    int? cur,
    String hint,
  ) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Text('$name  '),
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          if (live) const Icon(Icons.edit, size: 14),
        ],
      ),
      subtitle: Text(hint, style: const TextStyle(fontSize: 11)),
      onTap: !live
          ? null
          : () async {
              final v = await _askInt(name, cur);
              if (v != null) widget.core.setTmc(key, v);
            },
    );
  }

  Future<int?> _askInt(String title, int? cur) {
    final c = TextEditingController(text: cur?.toString() ?? '');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('设置 $title'),
        content: TextField(
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

  /// 为什么“走 80 脉冲比走 800 脉冲慢”：峰值速度 ≈ √(加速度 × 距离)，
  /// 短行程根本来不及加到巡航速度。把预测值摆出来，用户就知道该调哪个旋钮。
  ///
  /// 这里只用纯显示公式（不驱动任何决策），因为输入是 UI 自己的文本框。
  Widget _peakHint() {
    final n = int.tryParse(_stepsText.text.trim()) ?? 0;
    if (n <= 0) return const SizedBox.shrink();
    final accelSteps = _s.accelRevS2 * _s.stepsPerRev;
    final cruiseSteps = _s.speedRevS * _s.stepsPerRev;
    // 短行程走不到巡航速度：峰值取 √(加速度×距离) 与巡航速度的较小值。
    final peak =
        math.min(math.sqrt(math.max(accelSteps * n, 0)), cruiseSteps) /
        _s.stepsPerRev;
    final limited = peak < _s.speedRevS * 0.98;
    return Text(
      limited
          ? '走 $n 步的峰值约 ${peak.toStringAsFixed(2)} 圈/秒，'
                '达不到巡航 ${_s.speedRevS.toStringAsFixed(2)} 圈/秒（短行程加不完速）。'
                '想更快就加大加速度。'
          : '走 $n 步可以达到巡航速度 ${_s.speedRevS.toStringAsFixed(2)} 圈/秒。',
      style: TextStyle(
        fontSize: 11,
        color: limited ? const Color(0xFFFFAB40) : null,
      ),
    );
  }

  Widget _preview() {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_lidarOk)
          const UiKitView(viewType: 'ff.lidar/preview')
        else
          const ColoredBox(
            color: Color(0xFF1A1A1A),
            child: Center(child: Text('LiDAR 需 iPhone Pro')),
          ),
        IgnorePointer(
          child: CustomPaint(
            painter: _OverlayPainter(u: _u, v: _v, face: _face),
            child: const SizedBox.expand(),
          ),
        ),
      ],
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
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                size: 18,
              ),
              const SizedBox(width: 4),
              Text('摄像头 ${_previewExpanded ? "展开" : "已折叠"}'),
              const SizedBox(width: 10),
              Text('距离 $distance', style: const TextStyle(fontSize: 12)),
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

  _OverlayPainter({required this.u, required this.v, required this.face});

  @override
  void paint(Canvas canvas, Size size) {
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
      old.u != u || old.v != v || old.face != face;
}
