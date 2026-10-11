import 'dart:async';

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
      _face =
          (s.faceU != null &&
              s.faceV != null &&
              s.faceW != null &&
              s.faceH != null)
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
    // 行程 → 坐标：脉冲/圈由核心给出，UI 只做这一次乘法。
    widget.core.jog(sign * (r.abs() * _s.stepsPerRev).round());
  }

  Future<void> _confirmRecalibrate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空行程标定？'),
        content: Text(
          '${_s.lensName} 的行程 ${_s.strokeSteps} 坐标会被清空，'
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
  /// - 通着：报使能 / 运动 / 待机 / CAN。
  ///
  /// 旧版把后两种都说成"连着"，于是顶栏显示 `EN SLP CAN` 而实际一个包都不通 ——
  /// 会被带去查错的方向（`connected` 只是 socket bind 成功；`enabled/standby/canOk`
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
      '${_s.moving ? "RUN" : "IDLE"} '
      '${_s.canOk ? "CAN" : ""}',
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
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '设备',
            onPressed: _calRunning || _s.calDirectionPending
                ? null
                : _openDevicePage,
            icon: Icon(
              _s.deviceId == null ? Icons.router_outlined : Icons.router,
            ),
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
                      Text(switch (_s.phase) {
                        SetupPhase.stroke => '① 标定行程',
                        SetupPhase.align => '② 单侧对齐',
                        SetupPhase.follow => '③ 跟焦',
                      }, style: const TextStyle(fontSize: 12)),
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
                        selected: _s.enabled,
                        onSelected: _calRunning || _s.calDirectionPending
                            ? null
                            : (v) => widget.core.enable(v),
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
                            !_calRunning &&
                                !_s.calDirectionPending &&
                                _s.lutReady &&
                                _s.phase == SetupPhase.follow
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
                        onPressed:
                            _s.connected &&
                                !_s.moving &&
                                !_calRunning &&
                                !_s.calDirectionPending
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
                      '最大拨轮速度 ${((_speedDrag ?? _s.speedRevS) * 4096).round()} / 256',
                    ),
                    Slider(
                      min: 1 / 4096,
                      max: 256 / 4096,
                      divisions: 255,
                      value: (_speedDrag ?? _s.speedRevS).clamp(
                        1 / 4096,
                        256 / 4096,
                      ),
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
                      '使用 FM03 坐标；重做内部行程校准后请重新记录。',
                    ),
                    for (var i = 0; i < _s.lutPoints.length; i++)
                      ListTile(
                        dense: true,
                        title: Text(
                          '${_s.lutPoints[i].meters.toStringAsFixed(2)} m  →  '
                          '${_s.lutPoints[i].steps} 坐标'
                          '（${(_s.lutPoints[i].steps / _s.stepsPerRev).toStringAsFixed(2)} 行程）',
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
                  AbsorbPointer(
                    absorbing: _calRunning || _s.calDirectionPending,
                    child: _fm03Panel(),
                  ),
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
        // 脉冲 / 行程。这里的“步”是 STEP 脉冲（微步），不是整步。
        Row(
          children: [
            const Text('坐标增量'),
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
            const Text('行程比例'),
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
          '需要立即中止时切断电机电源。完成后坐标为 0～4096，距离标定需重做。',
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
      await widget.core.startAutoCalibration(threshold: 0, maxRevs: 0);
    }
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
        const Text('自动识别行程', style: TextStyle(fontWeight: FontWeight.bold)),
        if (_s.calDirectionPending) ...[
          Text('已校准坐标行程 0～${_s.calSafeSpan}'),
          const Text('请观察对焦环：正坐标移动时，对焦距离会怎样变化？'),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: () => widget.core.setDir(1),
                child: const Text('正坐标变远'),
              ),
              FilledButton(
                onPressed: () => widget.core.setDir(-1),
                child: const Text('正坐标变近'),
              ),
            ],
          ),
          const Text('确认方向后仍需重新记录距离标定点。'),
        ] else ...[
          Text(labels[_s.calStage] ?? '正在标定'),
          const LinearProgressIndicator(),
        ],
        TextButton(
          onPressed: () => widget.core.cancelAutoCalibration(),
          child: const Text('停止观察（不取消内部校准）'),
        ),
      ],
    );
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
          Text('当前位置 ${_s.pos} 坐标（${_s.posRevs.toStringAsFixed(2)} 行程）'),
          _jogControls(),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _s.connected
                    ? () => widget.core.recordStrokeA()
                    : null,
                child: Text(a == null ? '记录这一端 A' : 'A = $a 坐标（重记）'),
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
            const Text('② 单侧对齐', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(
              '行程 ${_s.strokeRevs.toStringAsFixed(2)} 行程',
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
          Text('当前 ${_s.pos} 坐标（${_s.posRevs.toStringAsFixed(2)} 行程）'),
          _jogControls(),
          FilledButton(
            onPressed: _s.connected ? () => widget.core.confirmNear() : null,
            child: const Text('确认为焦距最近点'),
          ),
          if (!_s.connected) const Text('先连接电机，再自由微调到最近对焦。'),
        ] else ...[
          Text('最近点 = $near 坐标'),
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
                onPressed: _s.connected
                    ? () => widget.core.startFollow()
                    : null,
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
            const Text('焦距变远方向', style: TextStyle(fontWeight: FontWeight.bold)),
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
          '允许 ${_s.limitLo}..${_s.limitHi} 坐标'
          '（最近点 ${_s.nearSteps} · 行程 ${_s.strokeSteps} 坐标）',
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
      subtitle: Text(
        statusLive ? '链路正常' : (_s.connected ? '状态超时，请检查 Wi-Fi' : '等待设备连接'),
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

  Widget _fm03Panel() {
    final t = _s.fm03;
    final live = _s.connected && t?.online == true && !_s.moving;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('DJI FM03 · CAN'),
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
