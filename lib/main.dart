import 'dart:async';

import 'package:flutter/material.dart';

import 'ff_protocol.dart';
import 'lens_lut.dart';
import 'lidar.dart';
import 'motor_cal.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final lut = await LensLut.load();
  runApp(FollowApp(lut: lut));
}

class FollowApp extends StatelessWidget {
  final LensLut lut;

  const FollowApp({super.key, required this.lut});

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
      home: FollowPage(initialLut: lut),
    );
  }
}

class FollowPage extends StatefulWidget {
  final LensLut initialLut;

  const FollowPage({super.key, required this.initialLut});

  @override
  State<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<FollowPage> {
  final _link = MotorLink();
  final _lidar = LidarChannel();
  final _filter = DistFilter();

  late LensLut _lut;
  bool _lidarOk = false;
  bool _auto = false;
  bool _faces = false;
  bool _enabled = false;
  bool _moving = false;
  bool _uartOk = false;
  bool _open = false;
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
  bool _standbyOff = false;    // 当前是否已断电（来自固件状态位）
  // 用户意图：板子重启后固件 enabled 会归零，这里负责自动补一次使能，
  // 否则点“走步”会被电机端的 `if (!enabled) return;` 静默忽略。
  bool _wantEnabled = false;
  DateTime _lastEnableAttempt = DateTime.fromMillisecondsSinceEpoch(0);
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
  Timer? _tick;
  String _msg = '连手机热点 FF-debug / ffdebug1';
  TmcDump? _tmc;
  final _tmcLog = <String>[];
  DateTime _lastTmc = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _lut = widget.initialLut;
    _link.onStatus = (s) {
      if (!mounted) return;
      setState(() {
        _pos = s.pos;
        _target = s.target;
        _enabled = s.enabled;
        _moving = s.moving;
        _uartOk = s.uartOk;
        _standbyOff = s.standby;
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
      if (s.faceU != null && s.faceV != null && s.faceW != null && s.faceH != null) {
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
    if (now.difference(_lastTmc) > const Duration(seconds: 1)) {
      _lastTmc = now;
      _link.queryTmc();
    }
    // 细分变化会改变“步”的尺度：重算速度、并把标定限位按新细分重新下发。
    if (_spr != _appliedSpr) {
      _appliedSpr = _spr;
      _applySpeed();
      if (_lut.ready) {
        _link.setLimits(_lutNow.minSteps!, _lutNow.maxSteps!);
      }
    }
    // 板子重启后固件 enabled=0，App 这边补一次使能，让状态自愈。
    if (_wantEnabled && !_enabled &&
        now.difference(_lastEnableAttempt) > const Duration(seconds: 1)) {
      _lastEnableAttempt = now;
      _link.enable(true);
    }
    if (!_enabled) return;
    int? want;
    if (_auto) {
      final d = _distance;
      if (d != null) want = _lutNow.stepsFor(d);
    } else if (_sliderDirty) {
      want = _sliderSteps();
      _sliderDirty = false;
    }
    if (want == null || want == _lastSent) return;
    _lastSent = want;
    _link.setPos(want);
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
    if (!_enabled) {
      // 板子重启后固件是关的；先补使能，否则这一步会被静默忽略。
      _wantEnabled = true;
      _lastEnableAttempt = DateTime.now();
      _link.enable(true);
      setState(() => _msg = '已发送使能，再点一次走步');
      return;
    }
    // 提前拦下会被固件软限位夹掉的命令——否则表现就是“点了没反应”。
    final lo = _lo();
    final hi = _hi();
    final want = _pos + delta;
    if (want < lo || want > hi) {
      setState(() => _msg = '超出软限位 $lo..$hi 步（当前 $_pos，请求 $want）。'
          '换细分会改变步数尺度；可先回中点，或完成标定后由标定值决定限位。');
      return;
    }
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
  LensLut get _lutNow => _lut.scaledTo(_ms);

  int _lo() => _lutNow.minSteps ?? -_cal.defaultLimitSpan(_ms);
  int _hi() => _lutNow.maxSteps ?? _cal.defaultLimitSpan(_ms);

  int _sliderSteps() {
    final lo = _lo();
    final hi = _hi();
    if (hi == lo) return lo;
    return (lo + _slider * (hi - lo)).round();
  }

  Future<void> _connect() async {
    try {
      await _link.open();
      _applySpeed();
      _link.setTmc(kTmcStandby, _standbyFeature ? 1 : 0);
      _wantEnabled = true;
      _lastEnableAttempt = DateTime.now();
      _link.enable(true);
      _link.query();
      _link.queryTmc();
      setState(() {
        _open = true;
        _msg = '已连接 192.168.4.1:4210';
      });
    } catch (e) {
      setState(() {
        _open = false;
        _msg = '连接失败 $e';
      });
    }
  }

  Future<void> _setLut(LensLut next) async {
    _lut = next;
    await next.save();
    if (next.ready) {
      final now = next.scaledTo(_ms);
      _link.setLimits(now.minSteps!, now.maxSteps!);
    }
    setState(() {});
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
    final distText = _distance == null ? '--' : '${_distance!.toStringAsFixed(2)} m';
    return Scaffold(
      appBar: AppBar(
        title: const Text('跟焦器'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                _open
                    ? '${_enabled ? "EN" : "OFF"} ${_moving ? "RUN" : (_standbyOff ? "SLP" : "IDLE")} ${_uartOk ? "UART" : ""}'
                    : '未连接',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _preview(),
                Positioned(
                  left: 12,
                  top: 8,
                  child: Text(
                    distText,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          shadows: const [Shadow(blurRadius: 8, color: Colors.black)],
                        ),
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('电机 $_pos → $_target    $_msg', style: const TextStyle(fontSize: 13)),
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
                          _link.enable(v);
                          if (!v) _lastSent = null;
                        },
                      ),
                      FilterChip(
                        label: Text(_lut.ready ? '自动跟焦' : '自动(需2点标定)'),
                        selected: _auto && _lut.ready,
                        onSelected: _lut.ready
                            ? (v) => setState(() {
                                  _auto = v;
                                  _lastSent = null;
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
                      OutlinedButton(onPressed: _link.stop, child: const Text('停')),
                    ],
                  ),
                  Text(_auto ? '手动滑条（自动开时无效）' : '手动焦点'),
                  Slider(
                    value: _slider,
                    onChanged: _auto
                        ? null
                        : (v) => setState(() {
                              _slider = v;
                              _sliderDirty = true;
                              _lastSent = null;
                            }),
                  ),
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
                  // 步 / 圈，对照 esp32s3-tb6600-stepper 上位机。
                  Row(
                    children: [
                      const Text('步'),
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
                      OutlinedButton(onPressed: () => _goSteps(1), child: const Text('走步')),
                      OutlinedButton(onPressed: () => _goSteps(-1), child: const Text('反向')),
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
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(onPressed: () => _goRevs(1), child: const Text('走圈')),
                      OutlinedButton(onPressed: () => _goRevs(-1), child: const Text('反向')),
                    ],
                  ),
                  Text(
                    '脉冲/圈 $_spr（0.9° 电机 = ${_cal.fullStepsPerRev} 整步/圈 × '
                    '1/${_tmc?.microsteps ?? 16} 细分）；当前位置 '
                    '${_cal.stepsToRevs(_pos, _ms).toStringAsFixed(2)} 圈',
                    style: const TextStyle(fontSize: 11),
                  ),
                  Text('速度 ${_speedRevS.toStringAsFixed(2)} 圈/秒'
                      '（${(_speedRevS * 60).round()} 转/分 · ${(_speedRevS * _spr).round()} 步/秒）'),
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
                      '（固件上限 $kMaxStepHz 步/秒）。'
                      '要更快就用更低细分：1/16 配「微步插值」内部同样是 1/256，'
                      '但脉冲只有 1/16。',
                      style: const TextStyle(fontSize: 11, color: Color(0xFFFFAB40)),
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
                    '短行程达不到巡航速度（峰值 ≈ √(2×加速度×步数)），'
                    '80/800 步这种 Jog 想更快就加大加速度。',
                    style: TextStyle(fontSize: 11),
                  ),
                  Row(
                    children: [
                      const Text('镜头标定', style: TextStyle(fontWeight: FontWeight.bold)),
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
                  const Text('Jog 到实焦后点记录。至少两点；按 1/距离 插值。'
                      '标定与当前细分绑定，换细分会自动换算。'),
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
                  const SizedBox(height: 8),
                  _tmcPanel(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
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
          : Text('${t.rmsMa} mA · 1/${t.microsteps} · '
              '${t.stealth ? "StealthChop 静音" : "SpreadCycle"}'),
      children: [
        // 每个可编辑参数：中文名 + 当前值 + 一行中文说明，点一下写入。
        _tmcRow('运行电流', t == null ? '--' : '${t.rmsMa} mA', kTmcRms, live, t?.rmsMa,
            '电机转动时的电流。越大越有力，也越热。建议 300–1200 mA，默认 800。'),
        _tmcRow('保持电流', t == null ? '--' : '${t.ihold} / 31', kTmcIhold, live, t?.ihold,
            '停止时维持的电流档位（相对运行电流）。0 = 完全不锁轴，不发热也不震。'),
        _tmcRow('运行电流档', t == null ? '--' : '${t.irun} / 31', kTmcIrun, live, t?.irun,
            '直接写 IRUN 的 CS 值 0–31。一般不用改，改上面的“运行电流”就行。'),
        _tmcRow('toff 关断时间', t == null ? '--' : '${t.toff}', kTmcToff, live, t?.toff,
            '斩波器关断时间 1–15。影响电流纹波与噪声，一般 3–5。'),
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Row(
            children: [
              const Text('细分  '),
              Text('1/${t?.microsteps ?? "--"}',
                  style: const TextStyle(fontFamily: 'Consolas', fontWeight: FontWeight.bold)),
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
                onPressed: _open ? _link.queryTmc : null, child: const Text('刷新日志')),
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
              ? const Text('还没有 TMC 日志', style: TextStyle(fontFamily: 'Consolas', fontSize: 11))
              : ListView.builder(
                  itemCount: _tmcLog.length,
                  itemBuilder: (_, i) => Text(
                    _tmcLog[i],
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
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

  Widget _tmcRow(String name, String value, int key, bool live, int? cur, String hint) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Text('$name  '),
          Text(value,
              style: const TextStyle(fontFamily: 'Consolas', fontWeight: FontWeight.bold)),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
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
