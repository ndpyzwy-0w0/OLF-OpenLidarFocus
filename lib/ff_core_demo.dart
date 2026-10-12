import 'dart:async';

import 'ff_core.dart';

/// Web 界面预览的假数据，不参与真机协议或跟焦控制。
class FfCoreDemo extends FfCore {
  final _events = StreamController<FfState>.broadcast();
  final _lenses = <_DemoLens>[
    _DemoLens('demo', '演示镜头 50mm F1.4', 'F1.4')
      ..directionConfirmed = true
      ..points.addAll(const [
        FfLutPoint(meters: 0.5, steps: 200),
        FfLutPoint(meters: 1, steps: 1800),
        FfLutPoint(meters: 2, steps: 2800),
        FfLutPoint(meters: 3, steps: 3200),
        FfLutPoint(meters: 5, steps: 3800),
      ]),
  ];
  String _id = 'demo';
  final _none = _DemoLens('', '', '');
  _DemoLens get _cur => _lenses.where((l) => l.id == _id).firstOrNull ?? _none;
  bool _connected = true, _enabled = true, _valid = true, _following = true;
  bool _auto = false, _faces = false, _pending = false, _stopLatched = false;
  bool _resumeAuto = false,
      _wheel = false,
      _wheelRange = false,
      _wheelReversed = false;
  int? _a, _b;
  double _sensitivity = 1;
  int _arrivalSequence = 0;
  String _arrival = '';
  String _stage = 'idle';
  String _pullCurve = 'smooth';
  int _gain = 4, _acceleration = 8;
  int _pos = 1000;
  double _speed = 64 / 4096;
  double? _distance = 1.8;
  final _log = <String>[];

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
      firmware: '2.0.0',
      host: '192.168.4.1',
    ),
  ];

  @override
  Future<void> invoke(String method, [Map<String, Object?>? args]) async {
    final a = args;
    switch (method) {
      case 'connect':
        _connected = true;
      case 'disconnect':
        _connected = false;
        _valid = false;
        _auto = false;
      case 'enable':
        _enabled = a?['on'] == true;
      case 'stopPressed':
        if (!_stopLatched) _resumeAuto = _auto;
        _stopLatched = true;
        _enabled = false;
        _auto = false;
      case 'resumeControl':
        if (_valid) {
          _stopLatched = false;
          _enabled = true;
          _auto = _resumeAuto;
          _resumeAuto = false;
        }
      case 'setControlMode':
        final wheel = a?['mode'] == 'handwheel';
        if (wheel != _wheel) {
          _wheel = wheel;
          _valid = false;
          _auto = false;
          _enabled = false;
          _a = _b = null;
          _wheelRange = false;
          _stopLatched = true;
        }
      case 'turnWheel':
        if (_wheel && _valid && _enabled && !_stopLatched) {
          _wheelPosition(
            _pos +
                ((a?['turns'] as double? ?? 0) *
                        4096 *
                        _sensitivity *
                        (_wheelReversed ? -1 : 1))
                    .round(),
          );
        }
      case 'setWheelPoint':
        if (_valid) {
          if (a?['point'] == 'A') {
            _a = _pos;
          } else {
            _b = _pos;
          }
        }
      case 'clearWheelPoints':
        _a = _b = null;
        _wheelRange = false;
      case 'setWheelRange':
        _wheelRange = a?['on'] == true && _a != null && _b != null;
      case 'setWheelSensitivity':
        _sensitivity = a?['value'] as double? ?? 1;
      case 'setWheelReversed':
        _wheelReversed = a?['on'] == true;
      case 'setWheelPullCurve':
        _pullCurve = a?['curve'] as String? ?? 'smooth';
      case 'pullWheelTo':
        final target = a?['point'] == 'A' ? _a : _b;
        if (target != null && _valid && !_stopLatched) _wheelPosition(target);
      case 'jog':
        if (_valid && !_stopLatched) {
          _pos = (_pos + (a?['delta'] as int? ?? 0)).clamp(0, 4096);
          _auto = false;
        }
      case 'setSlider':
        if (_valid && !_stopLatched) {
          _pos = ((a?['value'] as double? ?? 0.5) * 4096).round().clamp(
            0,
            4096,
          );
          _stopLatched = false;
        }
      case 'setAuto':
        _auto =
            !_stopLatched &&
            !_wheel &&
            _following &&
            _cur.points.length >= 5 &&
            a?['on'] == true;
      case 'setSpeed':
        _speed = a?['revsPerSec'] as double? ?? _speed;
      case 'setFm03':
        if (a?['key'] == kFm03MaxSpeed) _speed = (a?['value'] as int) / 4096;
        if (a?['key'] == kFm03Gain) _gain = a?['value'] as int;
        if (a?['key'] == kFm03Acceleration) _acceleration = a?['value'] as int;
        _log.add('demo FM03 key=${a?['key']} value=${a?['value']}');
      case 'queryFm03':
        _log.add('demo CAN 反馈刷新');
      case 'setTrackFaces':
        _faces = a?['on'] == true;
      case 'ingestDistance':
        _distance = a?['meters'] as double?;
      case 'selectLens':
        _id = a?['id'] as String? ?? _id;
        _valid = false;
        _following = false;
        _pending = false;
        _auto = false;
      case 'createLens':
        _id = 'demo-${DateTime.now().microsecondsSinceEpoch}';
        _lenses.add(
          _DemoLens(
            _id,
            a?['name'] as String? ?? '',
            a?['params'] as String? ?? '',
          ),
        );
        _valid = false;
        _following = false;
        _pending = false;
      case 'deleteLens':
        _lenses.removeWhere((l) => l.id == a?['id']);
      case 'resetLensCalibration':
        _cur.points.clear();
        _cur.directionConfirmed = false;
        _following = false;
        _pending = _valid;
      case 'startAutoCalibration':
        _stopLatched = false;
        _a = _b = null;
        _wheelRange = false;
        _stage = 'completed';
        _valid = true;
        _enabled = true;
        _following = false;
        _pending = !_wheel && !_cur.directionConfirmed;
        _pos = 3789;
      case 'cancelAutoCalibration':
        _stage = 'cancelled';
        _valid = false;
        _pending = false;
      case 'leaveLens':
        _a = _b = null;
        _wheelRange = false;
        _valid = false;
        _enabled = false;
        _following = false;
        _pending = false;
      case 'setDir':
        final d = a?['dir'] as int? ?? 1;
        if (d != _cur.dir) _cur.points.clear();
        _cur.dir = d;
        _cur.directionConfirmed = true;
        _pending = false;
      case 'startFollow':
        _following =
            _valid && _cur.points.length >= 5 && _cur.directionConfirmed;
      case 'unalign':
        _following = false;
        _auto = false;
      case 'addLutPoint':
        final m = a?['meters'] as double? ?? _distance;
        if (m != null) {
          _cur.points.removeWhere((p) => (p.meters - m).abs() < 0.02);
          _cur.points.add(FfLutPoint(meters: m, steps: _pos));
          _cur.points.sort((a, b) => a.meters.compareTo(b.meters));
        }
      case 'removeLutPoint':
        final i = a?['index'] as int? ?? -1;
        if (i >= 0 && i < _cur.points.length) _cur.points.removeAt(i);
        _following = false;
    }
    _events.add(_build());
  }

  FfState _build() => FfState(
    appVersion: '2.3.0+demo',
    calSupported: true,
    calStage: _stage,
    calSafeSpan: _valid ? 4096 : 0,
    calTravel: _valid ? 4096 : 0,
    calDirectionPending: _pending,
    connected: _connected,
    linkAlive: _connected,
    deviceId: 'FF-DEMO01',
    host: '192.168.4.1',
    localPort: 51234,
    localAddrs: const ['192.168.4.2'],
    rxPackets: 42,
    probeTx: 42,
    pos: _pos,
    target: _pos,
    enabled: _enabled,
    canOk: true,
    positionTrusted: _valid,
    stepsPerRev: 4096,
    microsteps: 1,
    posRevs: _pos / 4096,
    strokeRevs: _valid ? 1 : 0,
    auto: _auto,
    stopLatched: _stopLatched,
    canResume: _valid && _connected && _stopLatched,
    controlMode: _wheel ? 'handwheel' : 'automatic',
    wheelReady: _wheel && _valid && _enabled && _connected && !_stopLatched,
    wheelA: _a,
    wheelB: _b,
    wheelRangeEnabled: _wheelRange,
    wheelSensitivity: _sensitivity,
    wheelPullCurve: _pullCurve,
    wheelReversed: _wheelReversed,
    wheelArrival: _arrival,
    wheelArrivalSequence: _arrivalSequence,
    slider: _pos / 4096,
    speedRevS: _speed,
    faces: _faces,
    lensId: _cur.id.isEmpty ? null : _cur.id,
    lensName: _cur.name,
    lenses: [
      for (final l in _lenses)
        FfLens(
          id: l.id,
          name: l.name,
          params: l.params,
          dir: l.dir,
          directionConfirmed: l.directionConfirmed,
          lutCount: l.points.length,
          lutReady: l.points.length >= 5,
        ),
    ],
    phase: !_valid
        ? SetupPhase.stroke
        : _wheel
        ? SetupPhase.follow
        : _pending
        ? SetupPhase.align
        : _following
        ? SetupPhase.follow
        : SetupPhase.calibrate,
    nearSteps: _valid ? (_cur.dir > 0 ? 0 : 4096) : null,
    dir: _cur.dir,
    strokeSteps: _valid ? 4096 : 0,
    lutPoints: List.unmodifiable(_cur.points),
    lutCurve: _previewCurve(),
    lutReady: _cur.points.length >= 5,
    limitLo: 0,
    limitHi: 4096,
    distanceM: _distance,
    statusAgeMs: 12,
    echoAgeMs: 12,
    fm03: FfFm03(
      online: true,
      stage: 3,
      value: 0,
      maxSpeed: (_speed * 4096).round(),
      tolerance: 4,
      gain: _gain,
      acceleration: _acceleration,
      rawPosition: _pos,
      txFailures: 0,
      rxMissed: 0,
      feedbackAge: 12,
      logLine: 'CAN 在线 stage=3',
    ),
    fm03Log: List.unmodifiable(_log),
    msg: 'web 演示核心（没有真实硬件）',
  );

  void _wheelPosition(int position) {
    final lo = _wheelRange ? (_a! < _b! ? _a! : _b!) : 0;
    final hi = _wheelRange ? (_a! > _b! ? _a! : _b!) : 4096;
    _pos = position.clamp(lo, hi);
    final point = _pos == _a
        ? 'A'
        : _pos == _b
        ? 'B'
        : _pos == 0
        ? '起点'
        : _pos == 4096
        ? '终点'
        : '';
    if (point.isNotEmpty) {
      _arrival = point;
      _arrivalSequence++;
    }
  }

  // 仅为假数据画曲线；真机曲线由 Swift 快照提供。
  List<FfLutPoint> _previewCurve() {
    final p = _cur.points;
    if (p.length < 2) return [];
    return [
      for (var i = 0; i < p.length - 1; i++)
        for (var j = 0; j <= 20; j++) _previewPoint(p[i], p[i + 1], j / 20),
    ];
  }

  FfLutPoint _previewPoint(FfLutPoint a, FfLutPoint b, double t) {
    final m = a.meters + (b.meters - a.meters) * t;
    final inv = (1 / m - 1 / a.meters) / (1 / b.meters - 1 / a.meters);
    return FfLutPoint(
      meters: m,
      steps: (a.steps + inv * (b.steps - a.steps)).round(),
    );
  }
}

class _DemoLens {
  _DemoLens(this.id, this.name, this.params);
  final String id, name, params;
  int dir = 1;
  bool directionConfirmed = false;
  final points = <FfLutPoint>[];
}
