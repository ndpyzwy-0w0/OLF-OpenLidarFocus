import 'dart:async';

import 'ff_core.dart';

/// **只在 web 上使用**的演示核心（选择逻辑见 `main.dart` 的 `kIsWeb` 分支）。
///
/// web 里没有 `ff.core` 的实现 —— 那是 iOS 侧的 Swift 插件（`FollowFocusCorePlugin`）。
/// 真的 [FfCore] 在浏览器里 `snapshot()` 拿不到快照、命令会抛
/// `MissingPluginException`，界面只能停在「选择镜头」的空列表上。
///
/// 这个类预置一个已标定镜头，并把按钮接到一个**够看**的状态机上：三个相位
/// （标定行程 / 单侧对齐 / 跟焦）、滑条、诊断面板、FM03 CAN 面板都能点开。
///
/// 它**不是**第二份控制逻辑：没有软限位夹紧、没有自动跟焦死区、没有看门狗保活、
/// 也没有运动规划 —— 只有单位换算和相位推进。真机永远走 [FfCore]。
class FfCoreDemo extends FfCore {
  /// 完整标定行程：4096 坐标。
  static const _stepsPerRevBase = 4096;

  final _events = StreamController<FfState>.broadcast();

  final _lenses = <_DemoLens>[
    _DemoLens('demo', '演示镜头 50mm F1.4', params: 'F1.4')
      ..calibrated = true
      ..strokeRevs = 1.0
      ..nearSteps = 1000
      ..lut.addAll(const [
        (meters: 1.0, revs: 0.15625),
        (meters: 2.0, revs: 0.65625),
      ]),
  ];
  String _currentId = 'demo';

  // 会话级状态。位置存坐标；行程和标定点使用归一化行程比例。
  bool _connected = true;
  bool _enabled = true;
  bool _auto = false;
  bool _faces = false;
  bool _following = true;
  bool _stopLatched = false;
  String _calStage = 'idle';
  bool _calDirectionPending = false;
  int _calSafeSpan = 0;
  int _calTravel = 0;
  int _pos = 1000;
  final int _microsteps = 1;
  double _slider = 0.5;
  double _speedRevS = 64 / 4096;
  double _accelRevS2 = 30;
  double? _distanceM = 1.80;
  final _fm03Log = <String>[];

  /// 镜头被全部删掉时的占位，只为让下面的取值有东西可读；不进 lenses 列表。
  final _none = _DemoLens('', '');

  _DemoLens get _cur => _lenses.isEmpty
      ? _none
      : _lenses.firstWhere(
          (l) => l.id == _currentId,
          orElse: () => _lenses.first,
        );

  int get _stepsPerRev => _stepsPerRevBase * _microsteps;
  int _toSteps(double revs) => (revs * _stepsPerRev).round();

  /// 软限位区间。**只有对齐之后才有** —— 标定行程时跟焦器要能自由转，
  /// 那时候必须是 null，否则 jog 会被夹死在一端（真核心也是这个语义）。
  (int, int)? get _softLimits {
    final near = _cur.nearSteps;
    if (near == null) return null;
    final far = near + _cur.dir * _toSteps(_cur.strokeRevs);
    return far > near ? (near, far) : (far, near);
  }

  /// 相位由镜头自身状态决定：没标定 → 标定；标定过没对齐 → 对齐；
  /// 对齐后点过「开始跟焦」→ 跟焦。
  SetupPhase get _phase {
    if (!_cur.calibrated) return SetupPhase.stroke;
    return _following ? SetupPhase.follow : SetupPhase.align;
  }

  /// 滑条位置 → 目标步数。滑条两端就是软限位两端。
  int get _target {
    final r = _softLimits;
    if (r == null) return _pos;
    final (lo, hi) = r;
    return (lo + (hi - lo) * _slider).round();
  }

  /// 位置变了以后把滑条挪到对应位置，免得两者对不上。
  void _syncSlider() {
    final r = _softLimits;
    if (r == null) return;
    final (lo, hi) = r;
    _slider = ((_pos - lo) / (hi - lo)).clamp(0.0, 1.0);
  }

  // MARK: - 读路径

  @override
  Future<FfState> snapshot() async => _build();

  @override
  Stream<FfState> states() async* {
    yield _build();
    yield* _events.stream;
  }

  @override
  Future<List<FfDevice>> discover() async => const [
    FfDevice(
      deviceId: 'FF-DEMO01',
      mac: 'AA:BB:CC:00:00:01',
      udpPort: 4210,
      firmware: 'demo',
      host: '192.168.4.1',
    ),
  ];

  // MARK: - 写路径

  /// 命令全部照单全收，只挑几条让界面看起来是活的。
  @override
  Future<void> invoke(String method, [Map<String, Object?>? a]) async {
    switch (method) {
      case 'connect':
        _connected = true;
      case 'disconnect':
        _connected = false;
      case 'enable':
        _enabled = a?['on'] == true;
      case 'stopPressed':
        _stopLatched = true;
        _auto = false;
      case 'homePressed':
        _pos = 0;
        _syncSlider();
      case 'jog':
        final delta = a?['delta'] as int? ?? 0;
        final r = _softLimits;
        _pos = r == null ? _pos + delta : (_pos + delta).clamp(r.$1, r.$2);
        _syncSlider();
      case 'setSlider':
        _slider = (a?['value'] as double? ?? 0.5).clamp(0.0, 1.0);
        _pos = _target;
        _stopLatched = false;
      case 'setAuto':
        _auto = a?['on'] == true;
      case 'setSpeed':
        _speedRevS = a?['revsPerSec'] as double? ?? _speedRevS;
        _accelRevS2 = a?['accelRevsPerSec2'] as double? ?? _accelRevS2;
      case 'setFm03':
        _fm03Log.add('demo FM03 key=${a?['key']} value=${a?['value']}');
      case 'queryFm03':
        _fm03Log.add('demo CAN 反馈刷新');
      case 'setTrackFaces':
        _faces = a?['on'] == true;
      case 'ingestDistance':
        _distanceM = a?['meters'] as double?;

      // 镜头
      case 'selectLens':
        _currentId = a?['id'] as String? ?? _currentId;
        _following = false;
        _calDirectionPending = false;
      case 'createLens':
        final id = 'demo-${_lenses.length + 1}';
        _lenses.add(
          _DemoLens(
            id,
            (a?['name'] as String?) ?? '',
            params: (a?['params'] as String?) ?? '',
          ),
        );
        _currentId = id;
        _following = false;
      case 'deleteLens':
        _lenses.removeWhere((l) => l.id == a?['id']);
        if (_lenses.isNotEmpty && _currentId == a?['id']) {
          _currentId = _lenses.first.id;
        }

      // ① 行程标定
      case 'recordStrokeA':
        _cur.aRevs = _pos / _stepsPerRev;
      case 'finishStroke':
        final a0 = _cur.aRevs;
        if (a0 != null) {
          _cur.strokeRevs = (a0 - _pos / _stepsPerRev).abs();
          _cur.calibrated = true;
        }
      case 'recalibrateStroke':
        _cur
          ..calibrated = false
          ..aRevs = null
          ..strokeRevs = 0
          ..nearSteps = null;
        _cur.lut.clear();
        _following = false;
      case 'startAutoCalibration':
        _calStage = 'completed';
        _calDirectionPending = true;
        _calSafeSpan = 4096;
        _calTravel = 4096;
        _cur
          ..calibrated = true
          ..strokeRevs = 1
          ..nearSteps = null;
        _cur.lut.clear();
        _pos = _calSafeSpan;
        _following = false;
      case 'cancelAutoCalibration':
        _calStage = 'cancelled';
        _calDirectionPending = false;
        _cur.nearSteps = null;
        _following = false;
      case 'leaveLens':
        _calDirectionPending = false;
        _enabled = false;
        _following = false;

      // ② 单侧对齐
      case 'confirmNear':
        _cur.nearSteps = _pos;
        _following = false;
      case 'setDir':
        _cur.dir = a?['dir'] as int? ?? 1;
        if (_calDirectionPending) {
          _cur.nearSteps = _cur.dir > 0 ? 0 : _calSafeSpan;
          _calDirectionPending = false;
        }
      case 'startFollow':
        _following = true;
      case 'unalign':
        _cur.nearSteps = null;
        _following = false;

      // ③ 距离标定
      case 'addLutPoint':
        final m = _distanceM;
        if (m != null) _cur.lut.add((meters: m, revs: _pos / _stepsPerRev));
      case 'removeLutPoint':
        final i = a?['index'] as int? ?? -1;
        if (i >= 0 && i < _cur.lut.length) _cur.lut.removeAt(i);
    }
    _events.add(_build());
  }

  // MARK: - 快照

  FfLens _lensOf(_DemoLens l) => FfLens(
    id: l.id,
    name: l.name,
    params: l.params,
    dir: l.dir,
    calibrated: l.calibrated,
    strokeSteps: _toSteps(l.strokeRevs),
    strokeRevs: l.strokeRevs,
    lutCount: l.lut.length,
  );

  FfState _build() {
    final l = _cur;
    final r = _softLimits;
    return FfState(
      appVersion: '0.0.0+demo',
      calSupported: true,
      calStage: _calStage,
      calSafeSpan: _calSafeSpan,
      calTravel: _calTravel,
      calDirectionPending: _calDirectionPending,
      connected: _connected,
      linkAlive: _connected,
      deviceId: 'FF-DEMO01',
      host: '192.168.4.1',
      port: 4210,
      localPort: 51234,
      localAddrs: const ['192.168.4.2'],
      rxPackets: 42,
      probeTx: 42,
      pos: _pos,
      target: _pos,
      enabled: _enabled,
      canOk: true,
      result: kResultIdle,
      positionTrusted: true,
      microsteps: _microsteps,
      stepsPerRev: _stepsPerRev,
      maxRevsPerSec: 6.25,
      posRevs: _pos / _stepsPerRev,
      strokeRevs: l.strokeRevs,
      auto: _auto,
      stopLatched: _stopLatched,
      slider: _slider,
      speedRevS: _speedRevS,
      accelRevS2: _accelRevS2,
      standbyFeature: true,
      faces: _faces,
      lensId: l.id.isEmpty ? null : l.id,
      lensName: l.name,
      lenses: [for (final x in _lenses) _lensOf(x)],
      phase: _phase,
      nearSteps: l.nearSteps,
      dir: l.dir,
      strokeSteps: _toSteps(l.strokeRevs),
      lutPoints: [
        for (final p in l.lut)
          FfLutPoint(meters: p.meters, steps: _toSteps(p.revs)),
      ],
      limitLo: r?.$1 ?? 0,
      limitHi: r?.$2 ?? 0,
      strokeA: l.aRevs == null ? null : _toSteps(l.aRevs!),
      distanceM: _distanceM,
      statusAgeMs: 12,
      echoAgeMs: 12,
      lastSentSequence: 7,
      lastEchoedSequence: 7,
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
        logLine: 'CAN 在线 stage=3 raw=1000',
      ),
      fm03Log: List.unmodifiable(_fm03Log),
      msg: 'web 演示核心（没有真实硬件）',
    );
  }
}

/// 演示用的镜头存档。对齐结果和行程都挂在镜头上，切镜头会自动回到该镜头的状态。
class _DemoLens {
  _DemoLens(this.id, this.name, {this.params = ''});

  final String id;
  String name;
  String params;
  bool calibrated = false;
  double strokeRevs = 0;
  double? aRevs;
  int? nearSteps;
  int dir = 1;
  final lut = <({double meters, double revs})>[];
}
