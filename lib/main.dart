import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'device_page.dart';
import 'ff_protocol.dart';
import 'lens.dart';
import 'lens_lut.dart';
import 'lens_page.dart';
import 'lidar.dart';
import 'motor_cal.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await LensStore.load();
  runApp(FollowApp(store: store));
}

class FollowApp extends StatelessWidget {
  final LensStore store;

  const FollowApp({super.key, required this.store});

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
      home: LensPage(
        store: store,
        open: (ctx, lens) => Navigator.of(ctx).push(
          MaterialPageRoute(
            builder: (_) => FollowPage(lens: lens, store: store),
          ),
        ),
      ),
    );
  }
}

/// 跟焦前必须过的三步：新镜头标定行程 → 单侧对齐 → 跟焦。
enum SetupPhase { stroke, align, follow }

class FollowPage extends StatefulWidget {
  final Lens lens;
  final LensStore store;

  const FollowPage({super.key, required this.lens, required this.store});

  @override
  State<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<FollowPage> {
  final _link = MotorLink();
  final _lidar = LidarChannel();
  final _filter = DistFilter();

  late Lens _lens;
  LensLut get _lut => _lens.lut;

  /// 本次会话的对齐结果：焦距最近点的电机步数，以及“焦距变远”的方向。
  /// 对齐是会话量（开环步数掉电就丢），不持久化，每次进入都要重做。
  bool _aligned = false;
  int? _nearSteps;
  int _dir = 1;

  /// 行程标定中记下的第一个端点。
  int? _strokeA;

  bool _lidarOk = false;
  bool _auto = false;
  bool _faces = false;
  bool _enabled = false;
  bool _moving = false;
  bool _uartOk = false;
  bool _open = false;
  /// 选定的控制目标。由设备页/发现结果填充，不再是写死的 192.168.4.1。
  FfDiscovery? _device;
  bool _previewExpanded = true;
  int _pos = 0;
  int _target = 0;
  // 速度和加速度都用**物理单位**（圈/秒、圈/秒²），再乘脉冲/圈换成步。
  // 用步/秒做单位的话，换细分会让同一数值的物理速度差 16 倍——这就是
  // “换成 1/256 后变得很慢”的原因。
  double _speedRevS = 1.2;
  // 短行程跑不到巡航速度，峰值 ≈ √(2×加速度×步数)，所以加速度才是“快慢”的主要旋钮。
  double _accelRevS2 = 30;
  int _appliedSpr = 0;
  bool _standbyFeature = true; // 待机自动断电开关（固件默认开）
  bool _standbyOff = false; // 当前是否已断电（来自固件状态位）
  bool _positionTrusted = false;
  // 用户意图：板子重启后固件 enabled 会归零，这里负责自动补一次使能，
  // 否则点“走步”会被电机端的 `if (!enabled) return;` 静默忽略。
  bool _wantEnabled = false;
  int _pendingJog = 0;
  DateTime _lastEnableAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  // 自动跟焦的去抖：距离抖动会让目标每 20ms 变几步，变成“一直慢慢转停不下来”。
  DateTime _lastAutoSend = DateTime.fromMillisecondsSinceEpoch(0);
  // 停机闩锁：点“停”之后不再自动重发目标，否则自动跟焦会在 20ms 内把它覆盖掉。
  bool _stopLatched = false;
  final _cal = const MotorCal();
  final _revsText = TextEditingController(text: '1');
  final _stepsText = TextEditingController(text: '800');
  double _slider = 0.5;
  double? _distance;
  double _u = 0.5;
  double _v = 0.5;
  Rect? _face;
  int? _lastSent;
  bool _sliderDirty = false;
  DateTime _lastQuery = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastProbe = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastStatusAt;
  int _lastSentSequence = 0;
  int _lastEchoedSequence = 0;
  int _commandResult = kResultIdle;
  Timer? _tick;
  String _msg = '连手机热点 FF-XXXXXX / change-me';
  TmcDump? _tmc;
  final _tmcLog = <String>[];
  Object? _socketError;
  DateTime? _socketErrorAt;
  List<String> _localAddrs = const [];
  DateTime _lastTmc = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _lens = widget.lens;
    _dir = _lens.dir;
    _link.onStatus = (s) {
      if (!mounted) return;
      setState(() {
        _lastStatusAt = DateTime.now();
        _lastEchoedSequence = s.sequence;
        _commandResult = s.result;
        _pos = s.pos;
        _target = s.target;
        _enabled = s.enabled;
        _moving = s.moving;
        _uartOk = s.uartOk;
        _standbyOff = s.standby;
        if (s.enabled && _pendingJog != 0) {
          final delta = _pendingJog;
          _pendingJog = 0;
          _takeManual('走步');
          _stopLatched = false;
          _lastSent = null;
          _sliderDirty = false;
          _link.jog(delta);
        }
        if (s.limited) {
          _msg = '已到软限位：$s.pos 步';
        }
      });
    };
    _link.onStatusV2 = (s) {
      if (!mounted) return;
      setState(() {
        _positionTrusted = s.positionTrusted ?? false;
        _pos = s.pos;
        _target = s.target;
      });
    };
    _link.onSent = (sequence) {
      if (!mounted) return;
      setState(() => _lastSentSequence = sequence);
    };
    _link.onSocketError = (e) {
      if (!mounted) return;
      setState(() {
        _socketError = e;
        _socketErrorAt = DateTime.now();
      });
    };
    _link.onTmc = (d) {
      if (!mounted) return;
      final t = DateTime.now();
      final ts =
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
      setState(() {
        _tmc = d;
        _tmcLog.insert(0, '$ts  ${d.logLine()}');
        if (_tmcLog.length > 40) _tmcLog.removeLast();
      });
    };
    _bootLidar();
    _tick = Timer.periodic(const Duration(milliseconds: 20), (_) => _onTick());
  }

  Future<void> _bootLidar() async {
    _lidarOk = await _lidar.available();
    if (_lidarOk) {
      await _lidar.listen(_onLidar);
      await _lidar.start(trackFaces: _faces);
    }
    if (mounted) setState(() {});
  }

  void _onLidar(LidarSample s) {
    if (!mounted) return;
    final raw = s.distanceM;
    final filtered = raw == null ? _distance : _filter.update(raw);
    setState(() {
      _distance = filtered;
      _u = s.u;
      _v = s.v;
      if (s.faceU != null &&
          s.faceV != null &&
          s.faceW != null &&
          s.faceH != null) {
        _face = Rect.fromLTWH(s.faceU!, s.faceV!, s.faceW!, s.faceH!);
      } else {
        _face = null;
      }
    });
  }

  void _onTick() {
    if (!_link.isOpen) return;
    final now = DateTime.now();
    if (now.difference(_lastQuery) > const Duration(milliseconds: 200)) {
      _lastQuery = now;
      _link.query();
    }
    // 链路探测：固件会把非协议包原样回显（HANDOFF §6）。
    // 「已连接」只代表本地 bind 成功，UDP 从不验证对端，所以必须靠回显判断连通性。
    if (now.difference(_lastProbe) > const Duration(seconds: 1)) {
      _lastProbe = now;
      _link.probe();
      final echo = _link.lastEchoAt;
      debugPrint(
        'LINK open=$_open local=${_link.localPort} rx=${_link.rxPackets} '
        'echo=${echo == null ? "NONE" : "${now.difference(echo).inMilliseconds}ms"} '
        'sent=$_lastSentSequence echoed=$_lastEchoedSequence err=$_socketError',
      );
    }
    if (now.difference(_lastTmc) > const Duration(seconds: 1)) {
      _lastTmc = now;
      _link.queryTmc();
    }
    // 细分变化会改变“步”的尺度：重算速度，并把软限位按新细分重新下发。
    if (_spr != _appliedSpr) {
      _appliedSpr = _spr;
      _applySpeed();
      _applyLimits();
    }
    // 板子重启后固件 enabled=0，App 这边补一次使能，让状态自愈。
    if (_wantEnabled &&
        !_enabled &&
        now.difference(_lastEnableAttempt) > const Duration(seconds: 1)) {
      _lastEnableAttempt = now;
      _link.enable(true);
    }
    if (!_enabled) return;
    if (_stopLatched) return; // 点了“停”，不要被自动跟焦重新拉起来
    int? want;
    if (_auto) {
      final d = _distance;
      if (d != null) want = _autoSteps(d);
    } else if (_sliderDirty) {
      want = _sliderSteps();
      _sliderDirty = false;
    }
    if (want == null) return;

    // 自动模式下必须有死区和最小间隔：
    // 距离微抖会让目标每 tick 变几步，每一段都是三角形微动，
    // 表现就是“一直缓慢转动、永远停不下来”。
    if (_auto) {
      if ((want - (_lastSent ?? want)).abs() < kAutoDeadbandSteps) return;
      if (now.difference(_lastAutoSend) < const Duration(milliseconds: 60)) {
        return;
      }
      _lastAutoSend = now;
    } else if (want == _lastSent) {
      return;
    }
    _lastSent = want;
    _link.setPos(want);
  }

  /// 用户手动介入（走步/拖滑条/停机）时退出自动跟焦。
  /// 不这样做的话自动逻辑会在下一个 tick 把手工动作拉回去，
  /// 看起来就像“操作完还在自己转”。
  void _takeManual(String why) {
    if (_auto) {
      _auto = false;
      _filter.reset();
      _msg = '已退出自动跟焦（$why）';
    }
  }

  /// 作废本次对齐，并把固件软限位恢复成默认值。
  ///
  /// 必须真正下发默认限位：否则固件还留着上一轮对齐的窄区间，
  /// 对齐阶段“自由微调”会在旧边界被夹住，表现是微调不动。
  void _unalign(String msg) {
    setState(() {
      _aligned = false;
      _nearSteps = null;
      _auto = false;
      _lastSent = null;
      _msg = msg;
    });
    _applyLimits();
  }

  /// 软件置零会把当前位置变成 0，对齐建立的最近点参考随之失效，必须重对齐。
  void _homePressed() {
    _link.home();
    _unalign('已软件置零，请重新对齐最近点');
  }

  void _stopPressed() {
    _link.stop();
    _takeManual('停机');
    _stopLatched = true;
    _lastSent = null;
    _sliderDirty = false;
    setState(() => _msg = '已停机');
  }

  int get _ms => _tmc?.microsteps ?? 16;
  int get _spr => _cal.stepsPerRev(_ms);

  /// 把物理单位换算成固件要的步/秒、步/秒²。
  void _applySpeed() {
    if (!_link.isOpen) return;
    final spd = (_speedRevS * _spr).round();
    final acc = (_accelRevS2 * _spr).round();
    _link.setSpeed(spd.clamp(100, 40000), acc.clamp(100, 1000000));
  }

  /// 走步/走圈都走同一条相对运动命令（JOG），不在固件里另加指令。
  void _jog(int delta) {
    if (!_open || delta == 0) return;
    // 提前拦下会被固件软限位夹掉的命令——否则表现就是“点了没反应”。
    final lo = _lo();
    final hi = _hi();
    final want = _pos + delta;
    if (want < lo || want > hi) {
      setState(
        () => _msg =
            '超出软限位 $lo..$hi 步（当前 $_pos，请求 $want）。'
            '换细分会改变步数尺度；可先回中点，或完成标定后由标定值决定限位。',
      );
      return;
    }
    if (!_enabled) {
      // 板子重启后固件是关的；先补使能，并保留这次 JOG，待状态确认后执行。
      _pendingJog += delta;
      _wantEnabled = true;
      _lastEnableAttempt = DateTime.now();
      _link.enable(true);
      setState(
        () => _msg = '正在使能，已暂存 ${_pendingJog > 0 ? '+' : ''}$_pendingJog 步',
      );
      return;
    }
    _takeManual('走步');
    _stopLatched = false;
    _lastSent = null;
    _link.jog(delta);
    _sliderDirty = false;
  }

  void _goSteps(int sign) {
    final n = int.tryParse(_stepsText.text.trim());
    if (n == null || n == 0) return;
    _jog(sign * n.abs());
  }

  void _goRevs(int sign) {
    final r = double.tryParse(_revsText.text.trim());
    if (r == null || r == 0) return;
    _jog(sign * _cal.revsToSteps(r.abs(), _ms));
  }

  /// 标定值按当前细分换算后的视图。
  LensLut get _lutNow => _lens.lut.scaledTo(_ms);

  SetupPhase get _phase {
    if (!_lens.calibrated) return SetupPhase.stroke;
    if (!_aligned || _nearSteps == null) return SetupPhase.align;
    return SetupPhase.follow;
  }

  /// 软限位：对齐后只有“最近点 → 远端”这一侧，绝不超过标定行程；
  /// 未对齐（标定/对齐阶段）用和固件默认一致的 ±20 圈，好让跟焦器自由微调。
  ({int lo, int hi}) _limitsFor(int ms) {
    final near = _nearSteps;
    if (_aligned && near != null) {
      return alignedRange(near, _dir, _lens.strokeAt(ms));
    }
    final span = _cal.defaultLimitSpan(ms);
    return (lo: -span, hi: span);
  }

  int _lo() => _limitsFor(_ms).lo;
  int _hi() => _limitsFor(_ms).hi;

  void _applyLimits() {
    if (!_link.isOpen) return;
    final (lo: lo, hi: hi) = _limitsFor(_ms);
    _link.setLimits(lo, hi);
  }

  /// 自动跟焦目标：距离标定表查表，再夹进对齐软限位里，保证不超过行程。
  int? _autoSteps(double meters) {
    final v = _lutNow.stepsFor(meters);
    if (v == null) return null;
    return v.clamp(_lo(), _hi()).toInt();
  }

  void _updateLens(Lens next) {
    _lens = widget.store.upsert(next);
    widget.store.save();
    setState(() {});
  }

  /// 确认焦距最近点。方向默认用距离标定表推断（表里距离越远步数越大就是 +方向），
  /// 没有表就用上次选过的方向。
  void _confirmNear() {
    setState(() {
      _nearSteps = _pos;
      _dir = inferDir(_lens.lut) ?? _lens.dir;
      _msg = '最近点 = $_pos 步，选好变远方向后开始';
    });
  }

  /// 选定方向后真正进入跟焦：把距离标定表锚到本次会话的坐标系，再下发软限位。
  void _startFollow() {
    final near = _nearSteps;
    if (near == null) return;
    final lutNow = _lens.lut.scaledTo(_ms);
    final delta = lutRebaseDelta(near, lutNow);
    _updateLens(_lens.copyWith(
      dir: _dir,
      lut: delta == 0 ? _lens.lut : lutNow.shifted(delta),
    ));
    _aligned = true;
    _applyLimits();
    setState(() {
      _slider = 0;
      _sliderDirty = false;
      _lastSent = null;
      _auto = false;
      _msg = '对齐完成，可开始跟焦';
    });
  }

  void _setDir(int d) {
    _updateLens(_lens.copyWith(dir: d));
    setState(() {
      _dir = d;
      _lastSent = null;
    });
    _applyLimits();
  }

  /// 行程标定：先记一端，再记另一端，两点距离就是行程长度。
  void _recordStrokeA() {
    setState(() {
      _strokeA = _pos;
      _msg = '已记录端点 A = $_pos 步，请转到行程另一端再记录';
    });
  }

  void _finishStroke() {
    final a = _strokeA;
    if (a == null) return;
    final stroke = (_pos - a).abs();
    if (stroke < 1) {
      setState(() => _msg = 'A 和 B 几乎在同一位置，请转到行程另一端再记录');
      return;
    }
    _updateLens(_lens.copyWith(strokeSteps: stroke, strokeMicrosteps: _ms));
    setState(() {
      _strokeA = null;
      _msg = '行程已标定：$stroke 步'
          '（${_cal.stepsToRevs(stroke, _ms).toStringAsFixed(2)} 圈），接下来对齐最近点';
    });
  }

  /// 行程标定的防误触：清空重标要长按再确认，避免碰到就把行程弄丢。
  Future<void> _confirmRecalibrate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空行程标定？'),
        content: Text(
          '${_lens.name} 的行程 ${_lens.strokeAt(_ms)} 步会被清空，'
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
    if (ok != true) return;
    _updateLens(_lens.withoutStroke());
    setState(() => _strokeA = null);
    _unalign('行程已清空，请重新标定');
  }

  int _sliderSteps() {
    final lo = _lo();
    final hi = _hi();
    if (hi == lo) return lo;
    return (lo + _slider * (hi - lo)).round();
  }

  /// 选定控制目标：地址取回包源地址，UDP 端口取固件上报值。
  void _selectDevice(FfDiscovery d) {
    _device = d;
    _link.useDevice(d);
  }

  Future<void> _openDevicePage() async {
    final picked = await Navigator.push<FfDiscovery>(
      context,
      MaterialPageRoute(
        builder: (_) => DevicePage(selected: _device, linkOpen: _open),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectDevice(picked);
      _msg = '已选 ${picked.deviceId}（${picked.host.address}:${picked.udpPort}）';
    });
  }

  /// 连接前确保已选定设备。没选过就先扫描：只发现一台直接选，
  /// 否则打开设备页让用户决定（0 台时那里有切换 Wi-Fi 的指引）。
  Future<bool> _ensureDevice() async {
    if (_device != null) return true;
    final found = await discoverBoards();
    if (!mounted) return false;
    if (found.length == 1) {
      setState(() => _selectDevice(found.first));
      return true;
    }
    await _openDevicePage();
    return _device != null;
  }

  Future<void> _connect() async {
    if (!await _ensureDevice()) {
      if (mounted) {
        setState(() => _msg = '还没选设备：先在设备页扫描并选用');
      }
      return;
    }
    try {
      await _link.open();
      _applySpeed();
      _applyLimits();
      _link.setTmc(kTmcStandby, _standbyFeature ? 1 : 0);
      _wantEnabled = true;
      _lastEnableAttempt = DateTime.now();
      _link.enable(true);
      _link.query();
      _link.queryTmc();
      // 列出本机各网卡地址：确认 App 是否真的看到 192.168.4.x 这块网卡。
      try {
        final ifs = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        _localAddrs = [
          for (final i in ifs)
            for (final a in i.addresses) '${i.name}=${a.address}',
        ];
      } catch (e) {
        _localAddrs = ['枚举失败 $e'];
      }
      setState(() {
        _open = true;
        _msg = '已连接 ${_link.host?.address}:${_link.port}';
      });
    } catch (e) {
      setState(() {
        _open = false;
        _msg = '连接失败 $e';
      });
    }
  }

  void _setLut(LensLut next) {
    // 距离标定表不再决定软限位；限位只由“行程 + 对齐”决定。
    _updateLens(_lens.copyWith(lut: next));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _lidar.dispose();
    _link.close();
    _revsText.dispose();
    _stepsText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final distText = _distance == null
        ? '--'
        : '${_distance!.toStringAsFixed(2)} m';
    return Scaffold(
      appBar: AppBar(
        title: const Text('跟焦器'),
        actions: [
          IconButton(
            tooltip: '设备',
            onPressed: _openDevicePage,
            icon: Icon(_device == null ? Icons.router_outlined : Icons.router),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                _open
                    ? '${_enabled ? "EN" : "OFF"} ${_moving ? "RUN" : (_standbyOff ? "SLP" : "IDLE")} ${_uartOk ? "UART" : ""}'
                    : (_device == null ? '未选设备' : '${_device!.deviceId} · 未连接'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
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
                    '电机 $_pos → $_target    $_msg',
                    style: const TextStyle(fontSize: 13),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '镜头 ${_lens.name}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Text(
                        switch (_phase) {
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
                        onPressed: _connect,
                        child: Text(_open ? '重连' : '连接电机'),
                      ),
                      FilterChip(
                        label: const Text('使能'),
                        selected: _enabled,
                        onSelected: (v) {
                          _wantEnabled = v;
                          _stopLatched = false;
                          _link.enable(v);
                          if (!v) _lastSent = null;
                        },
                      ),
                      FilterChip(
                        // 自动跟焦要先对齐、还要有两点距离标定，否则没有可信的目标。
                        label: Text(
                          _phase != SetupPhase.follow
                              ? '自动(先对齐)'
                              : (_lut.ready ? '自动跟焦' : '自动(需2点标定)'),
                        ),
                        selected: _auto && _phase == SetupPhase.follow,
                        onSelected: _lut.ready && _phase == SetupPhase.follow
                            ? (v) => setState(() {
                                _auto = v;
                                _lastSent = null;
                                _stopLatched = false;
                                _lastAutoSend =
                                    DateTime.fromMillisecondsSinceEpoch(0);
                                _filter.reset();
                              })
                            : null,
                      ),
                      FilterChip(
                        label: const Text('人脸'),
                        selected: _faces,
                        onSelected: _lidarOk
                            ? (v) {
                                setState(() => _faces = v);
                                _lidar.setTrackFaces(v);
                              }
                            : null,
                      ),
                      OutlinedButton(
                        onPressed: _open ? _stopPressed : null,
                        child: const Text('停'),
                      ),
                      OutlinedButton(
                        onPressed: _open && !_moving ? _homePressed : null,
                        child: Text(_positionTrusted ? '已校零' : '设当前位置为原点'),
                      ),
                    ],
                  ),
                  _setupPanel(),
                  if (_phase == SetupPhase.follow) ...[
                    Text(_auto ? '手动滑条（自动开时无效）' : '手动焦点'),
                    Slider(
                      value: _slider,
                      onChanged: _auto
                          ? null
                          : (v) => setState(() {
                                _slider = v;
                                _sliderDirty = true;
                                _stopLatched = false;
                                _lastSent = null;
                              }),
                    ),
                    _jogControls(),
                    Text(
                      '每个脉冲约 ${(360 / _spr).toStringAsFixed(4)}°；'
                      '8 脉冲 = ${(360 * 8 / _spr).toStringAsFixed(3)}°',
                      style: const TextStyle(fontSize: 11),
                    ),
                    // 直接说明“为什么 80 步比 800 步慢”：峰值速度由距离决定。
                    _peakHint(),
                    Text(
                      '速度 ${_speedRevS.toStringAsFixed(2)} 圈/秒'
                      '（${(_speedRevS * 60).round()} 转/分 · ${(_speedRevS * _spr).round()} 脉冲/秒）',
                    ),
                    Slider(
                      min: 0.05,
                      max: 3.0,
                      value: _speedRevS.clamp(0.05, 3.0),
                      onChanged: (v) => setState(() => _speedRevS = v),
                      onChangeEnd: (v) {
                        _speedRevS = v;
                        _applySpeed();
                      },
                    ),
                    if (_speedRevS > _cal.maxRevsPerSec(_ms))
                      Text(
                        '⚠ 1/$_ms 细分下最高只有 '
                        '${_cal.maxRevsPerSec(_ms).toStringAsFixed(2)} 圈/秒'
                        '（固件上限 $kMaxStepHz 脉冲/秒）。'
                        '要更快就用更低细分：1/16 配「微步插值」内部同样是 1/256，'
                        '但脉冲只有 1/16。',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFFFFAB40),
                        ),
                      ),
                    Text('加速度 ${_accelRevS2.toStringAsFixed(0)} 圈/秒²'),
                    Slider(
                      min: 2,
                      max: 100,
                      value: _accelRevS2.clamp(2, 100),
                      onChanged: (v) => setState(() => _accelRevS2 = v),
                      onChangeEnd: (v) {
                        _accelRevS2 = v;
                        _applySpeed();
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
                          onPressed: _distance == null
                              ? null
                              : () => _setLut(
                                  _lut.adding(
                                    LutPoint(meters: _distance!, steps: _pos),
                                    microsteps: _ms,
                                  ),
                                ),
                          child: const Text('记录当前'),
                        ),
                      ],
                    ),
                    const Text(
                      'Jog 到实焦后点记录。至少两点；按 1/距离 插值。'
                      '标定与当前细分绑定，换细分会自动换算。',
                    ),
                    for (var i = 0; i < _lutNow.points.length; i++)
                      ListTile(
                        dense: true,
                        title: Text(
                          '${_lutNow.points[i].meters.toStringAsFixed(2)} m  →  '
                          '${_lutNow.points[i].steps} 步'
                          '（${_cal.stepsToRevs(_lutNow.points[i].steps, _ms).toStringAsFixed(2)} 圈）',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () => _setLut(_lut.removingAt(i)),
                        ),
                      ),
                    if (_lut.points.isEmpty) const Text('还没有标定点。'),
                    _recalibrateTile(),
                  ],
                  const SizedBox(height: 8),
                  _diagnosticPanel(),
                  _tmcPanel(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
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
                onPressed: () => _jog(d),
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
          '输入单位：脉冲/微步；脉冲/圈 $_spr（0.9° 电机 = ${_cal.fullStepsPerRev} 整步/圈 × '
          '1/$_ms 细分）；当前位置 '
          '${_cal.stepsToRevs(_pos, _ms).toStringAsFixed(2)} 圈',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }

  Widget _setupPanel() {
    switch (_phase) {
      case SetupPhase.stroke:
        return _strokePanel();
      case SetupPhase.align:
        return _alignPanel();
      case SetupPhase.follow:
        return const SizedBox.shrink();
    }
  }

  /// ① 新镜头：手动量出行程（两个端点之间的距离）。
  Widget _strokePanel() {
    final a = _strokeA;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        const Text('① 标定行程', style: TextStyle(fontWeight: FontWeight.bold)),
        const Text(
          '新镜头要先量出行程：把跟焦器转到对焦环的一端，记录 A；'
          '再转到另一端，记录 B。两点之间的距离就是行程，'
          '之后跟焦的转动范围永远不会超过它。',
        ),
        Text('当前位置 $_pos 步（${_cal.stepsToRevs(_pos, _ms).toStringAsFixed(2)} 圈）'),
        _jogControls(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _open ? _recordStrokeA : null,
              child: Text(a == null ? '记录这一端 A' : 'A = $a 步（重记）'),
            ),
            FilledButton(
              onPressed: _open && a != null ? _finishStroke : null,
              child: const Text('记录另一端 B，完成标定'),
            ),
          ],
        ),
        if (!_open)
          const Text('先在上面“连接电机”，再用这里自由微调到行程两端。')
        else if (a != null)
          const Text('把跟焦器转到行程另一端，再点右边按钮。'),
      ],
    );
  }

  /// ② 已标定行程的镜头：每次进入都先做单侧对齐。
  Widget _alignPanel() {
    final near = _nearSteps;
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
              '行程 ${_cal.stepsToRevs(_lens.strokeAt(_ms), _ms).toStringAsFixed(2)} 圈',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        const Text(
          '跟焦器没有绝对位置，每次进入都要对齐一次：手动微调到画面最近对焦，'
          '把当前位置认成“焦距最近点”，再选哪边是焦距变远的方向。'
          '这样只会在这段行程内转，不会拧反、也不会超行程。',
        ),
        if (near == null) ...[
          Text(
            '当前 $_pos 步（${_cal.stepsToRevs(_pos, _ms).toStringAsFixed(2)} 圈）',
          ),
          _jogControls(),
          FilledButton(
            onPressed: _open ? _confirmNear : null,
            child: const Text('确认为焦距最近点'),
          ),
          if (!_open) const Text('先连接电机，再自由微调到最近对焦。'),
        ] else ...[
          Text('最近点 = $near 步'),
          const SizedBox(height: 8),
          const Text('从最近点往哪个旋转方向是“焦距变远”？'),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('+ 方向变远')),
              ButtonSegment(value: -1, label: Text('- 方向变远')),
            ],
            selected: {_dir},
            onSelectionChanged: (s) => setState(() => _dir = s.first),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _open ? _startFollow : null,
                child: const Text('开始跟焦'),
              ),
              OutlinedButton(
                onPressed: () => setState(() => _nearSteps = null),
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
              onPressed: () => _unalign('重新对齐最近点'),
              child: const Text('重新对齐'),
            ),
          ],
        ),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('+ 方向变远')),
            ButtonSegment(value: -1, label: Text('- 方向变远')),
          ],
          selected: {_dir},
          onSelectionChanged: (s) => _setDir(s.first),
        ),
        Text(
          '允许 $_lo..$_hi 步（最近点 $_nearSteps · 行程 ${_lens.strokeAt(_ms)} 步）',
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
    final statusAge = _lastStatusAt == null
        ? null
        : DateTime.now().difference(_lastStatusAt!);
    final statusLive =
        _open && statusAge != null && statusAge < const Duration(seconds: 1);
    final sequenceOk =
        _lastSentSequence != 0 && _lastSentSequence == _lastEchoedSequence;
    final linkLive = statusLive;
    final echoAge = _link.lastEchoAt == null
        ? null
        : DateTime.now().difference(_link.lastEchoAt!);
    final echoLive = echoAge != null && echoAge < const Duration(seconds: 3);
    final rows = <({String name, bool ok, String detail})>[
      (
        name: '链路探测（非协议包回显）',
        ok: echoLive,
        detail: !_open
            ? '未连接'
            : '发 ${_link.probeTx} / 收 ${_link.rxPackets} · '
                  '${echoAge == null ? "无回显" : "${echoAge.inMilliseconds} ms 前"}',
      ),
      (
        name: '本机 UDP 端口',
        ok: _open,
        detail: _link.localPort == null
            ? '未绑定'
            : '${_link.localAddr}:${_link.localPort}',
      ),
      (
        name: '本机网卡地址',
        ok: _localAddrs.any((a) => a.contains('192.168.4.')),
        detail: _localAddrs.isEmpty ? '未枚举' : _localAddrs.join(', '),
      ),
      if (_socketError != null)
        (
          name: '套接字错误',
          ok: false,
          detail: _socketErrorAt == null
              ? '$_socketError'
              : '${DateTime.now().difference(_socketErrorAt!).inSeconds}s 前：'
                    '$_socketError',
        ),
      (
        name: 'UDP 状态回包',
        ok: statusLive,
        detail: statusAge == null ? '尚未收到' : '${statusAge.inMilliseconds} ms 前',
      ),
      (
        name: '请求序号回显',
        ok: sequenceOk,
        detail: _lastSentSequence == 0
            ? '尚未发送控制命令'
            : '发送 $_lastSentSequence / 回显 $_lastEchoedSequence',
      ),
      (name: 'TMC2209 UART', ok: _uartOk, detail: _uartOk ? '通讯正常' : '未确认'),
      (
        name: '软限位反馈',
        ok: _open && _lastStatusAt != null,
        detail: _open
            ? (_target == _lo() || _target == _hi() ? '当前目标在边界' : '已启用')
            : '未连接',
      ),
      (
        name: '待机唤醒',
        ok: _open && (_enabled || _standbyOff),
        detail: _standbyOff ? '待机释放，运动时自动唤醒' : '可用',
      ),
      (
        name: '目标追踪',
        ok: _open && _target == _pos && !_moving,
        detail: _moving ? '正在追踪 $_target' : '位置 $_pos / 目标 $_target',
      ),
      (
        name: '最近命令结果',
        ok: _commandResult != kResultRejected,
        detail: _commandResultLabel(_commandResult),
      ),
    ];
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('功能可用性诊断'),
      subtitle: Text(linkLive ? '链路正常' : (_open ? '状态超时，请检查 Wi-Fi' : '等待设备连接')),
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

  String _commandResultLabel(int result) {
    switch (result) {
      case kResultAccepted:
        return '已接受 / 执行中';
      case kResultCompleted:
        return '已完成';
      case kResultLimited:
        return '已限位夹紧';
      case kResultRejected:
        return '已拒绝（未使能）';
      case kResultStopped:
        return '已停止';
      default:
        return '空闲';
    }
  }

  Widget _tmcPanel() {
    final t = _tmc;
    final live = _open && t?.uartOk == true;
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
                        if (v != null) _link.setTmc(kTmcMicrosteps, v);
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
          onChanged: !live ? null : (v) => _link.setTmc(kTmcStealth, v ? 1 : 0),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('待机自动断电'),
          subtitle: Text(
            '停止约 2.5 秒后释放驱动：不发热、不震动。'
            '代价是待机时没有锁轴力，镜头环若会自己走就关掉它。'
            '${_standbyOff ? "（当前已断电）" : ""}',
            style: const TextStyle(fontSize: 11),
          ),
          value: _standbyFeature,
          onChanged: !_open
              ? null
              : (v) {
                  setState(() => _standbyFeature = v);
                  _link.setTmc(kTmcStandby, v ? 1 : 0);
                },
        ),
        Row(
          children: [
            const Spacer(),
            OutlinedButton(
              onPressed: _open ? _link.queryTmc : null,
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
          child: _tmcLog.isEmpty
              ? const Text(
                  '还没有 TMC 日志',
                  style: TextStyle(fontFamily: 'Consolas', fontSize: 11),
                )
              : ListView.builder(
                  itemCount: _tmcLog.length,
                  itemBuilder: (_, i) => Text(
                    _tmcLog[i],
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
              if (v != null) _link.setTmc(key, v);
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
  Widget _peakHint() {
    final n = int.tryParse(_stepsText.text.trim()) ?? 0;
    if (n <= 0) return const SizedBox.shrink();
    final accelSteps = (_accelRevS2 * _spr).round();
    final cruiseSteps = (_speedRevS * _spr).round();
    final peak = _cal.peakRevsPerSec(n, accelSteps, cruiseSteps, _ms);
    final limited = peak < _speedRevS * 0.98;
    return Text(
      limited
          ? '走 $n 步的峰值约 ${peak.toStringAsFixed(2)} 圈/秒，'
                '达不到巡航 ${_speedRevS.toStringAsFixed(2)} 圈/秒（短行程加不完速）。'
                '想更快就加大加速度。'
          : '走 $n 步可以达到巡航速度 ${_speedRevS.toStringAsFixed(2)} 圈/秒。',
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
          UiKitView(viewType: 'ff.lidar/preview')
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
