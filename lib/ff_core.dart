import 'dart:async';

import 'package:flutter/services.dart';

/// `ff.core` 通道的 Dart 客户端。
///
/// **只做两件事**：把命令发下去、把状态快照解出来。
/// 不含任何控制逻辑 —— 自动跟焦死区、相位机、镜头标定全在 Swift 侧的
/// `FollowFocusSession` 里（见 HANDOFF §13）。
///
/// 所以这里只允许出现“字段搬运”，不要在这里加 `_limitsFor`、`_autoSteps`
/// 这类函数：一旦出现，就是第二份实现，两边迟早不一致。

// MARK: - 协议常量（跨语言契约）
//
// 这些是线协议里的取值，不是逻辑。改它们要同时改固件和 Swift 侧。

const int kFm03MaxSpeed = 1;
const int kFm03Tolerance = 2;
const int kFm03Gain = 3;

/// 命令结果（STATUS.flags 高 3 位）。
const int kResultIdle = 0;
const int kResultAccepted = 1;
const int kResultCompleted = 2;
const int kResultLimited = 3;
const int kResultRejected = 4;
const int kResultStopped = 5;

/// 寻限位、方向、物距标定、跟焦。
enum SetupPhase { stroke, align, calibrate, follow }

SetupPhase _phaseFrom(String? s) {
  switch (s) {
    case 'align':
      return SetupPhase.align;
    case 'calibrate':
      return SetupPhase.calibrate;
    case 'follow':
      return SetupPhase.follow;
    default:
      return SetupPhase.stroke;
  }
}

// MARK: - 快照模型

class FfDevice {
  final String deviceId;
  final String mac;
  final int udpPort;
  final String firmware;
  final String host;

  const FfDevice({
    required this.deviceId,
    required this.mac,
    required this.udpPort,
    required this.firmware,
    required this.host,
  });

  factory FfDevice.fromMap(Map<dynamic, dynamic> m) => FfDevice(
    deviceId: (m['device_id'] as String?) ?? '',
    mac: (m['mac'] as String?) ?? '',
    udpPort: (m['udp_port'] as num?)?.toInt() ?? 4210,
    firmware: (m['firmware'] as String?) ?? '',
    host: (m['host'] as String?) ?? '',
  );
}

/// 距离标定点。`steps` 是FM03 坐标（内部限位校准后的归一化坐标）。
class FfLutPoint {
  final double meters;
  final int steps;

  const FfLutPoint({required this.meters, required this.steps});

  factory FfLutPoint.fromMap(Map<dynamic, dynamic> m) => FfLutPoint(
    meters: (m['meters'] as num?)?.toDouble() ?? 0,
    steps: (m['steps'] as num?)?.toInt() ?? 0,
  );
}

class FfLens {
  final String id;
  final String name;
  final String params;

  /// 焦距变远方向：+1 表示步数增大，-1 表示减小。
  final int dir;
  final bool directionConfirmed;
  final bool lutReady;
  final int lutCount;

  const FfLens({
    required this.id,
    required this.name,
    required this.params,
    required this.dir,
    this.directionConfirmed = false,
    this.lutReady = false,
    required this.lutCount,
  });

  factory FfLens.fromMap(Map<dynamic, dynamic> m) => FfLens(
    id: (m['id'] as String?) ?? '',
    name: (m['name'] as String?) ?? '',
    params: (m['params'] as String?) ?? '',
    dir: (m['dir'] as num?)?.toInt() ?? 1,
    directionConfirmed: m['direction_confirmed'] == true,
    lutReady: m['lut_ready'] == true,
    lutCount: (m['lut_count'] as num?)?.toInt() ?? 0,
  );
}

class FfFm03 {
  final bool online;
  final int stage, value, maxSpeed, tolerance, gain, rawPosition;
  final int txFailures, rxMissed, feedbackAge;
  final String logLine;
  const FfFm03({
    required this.online,
    required this.stage,
    required this.value,
    required this.maxSpeed,
    required this.tolerance,
    required this.gain,
    required this.rawPosition,
    required this.txFailures,
    required this.rxMissed,
    required this.feedbackAge,
    required this.logLine,
  });
  factory FfFm03.fromMap(Map<dynamic, dynamic> m) => FfFm03(
    online: m['online'] == true,
    stage: (m['stage'] as num?)?.toInt() ?? 255,
    value: (m['value'] as num?)?.toInt() ?? 0,
    maxSpeed: (m['max_speed'] as num?)?.toInt() ?? 64,
    tolerance: (m['tolerance'] as num?)?.toInt() ?? 4,
    gain: (m['gain'] as num?)?.toInt() ?? 4,
    rawPosition: (m['raw_position'] as num?)?.toInt() ?? 0,
    txFailures: (m['tx_failures'] as num?)?.toInt() ?? 0,
    rxMissed: (m['rx_missed'] as num?)?.toInt() ?? 0,
    feedbackAge: (m['feedback_age'] as num?)?.toInt() ?? 65535,
    logLine: (m['log_line'] as String?) ?? '',
  );
}

/// 一条聚合状态快照。UI 只渲染最新一条，不做累积。
class FfState {
  /// App 版本，格式 `<pubspec version>`（例如 `1.1.0+2`）。
  ///
  /// 由 iOS 壳从 `Bundle.main`（= Flutter 构建时写进 Info.plist 的 pubspec 版本）
  /// 注入快照；功能层是纯 Swift Package，读不到 App 的 Bundle。
  final String appVersion;
  final bool calSupported;
  final String calStage;
  final int calError;
  final int calSafeSpan;
  final int calTravel;
  final bool calDirectionPending;
  // 链路
  final bool connected;

  /// 链路**真的通**：socket 开着且最近收到过状态回包。
  ///
  /// `connected` 只表示 socket bind 成功；手机掉出板子热点、App 刚回前台还没发包时
  /// 它照样是 true，而 `enabled/standby/canOk` 是"收到过就不再失效"的字段。
  /// 判断"现在通不通"只能用这个，见 [FollowFocusState.linkAlive]。
  final bool linkAlive;
  final String? deviceId;
  final String? host;
  final int port;
  final int? localPort;
  final List<String> localAddrs;
  final List<FfDevice> devices;
  final int rxPackets;
  final int probeTx;

  // 电机
  final int pos;
  final int target;
  final bool enabled;
  final bool moving;
  final bool canOk;
  final bool standby;
  final bool limitHit;
  final int result;
  final bool positionTrusted;

  // 单位换算（核心算好，UI 不再自己乘 400）
  final int microsteps;
  final int stepsPerRev;
  final double maxRevsPerSec;
  final double posRevs;
  final double strokeRevs;

  // 会话
  final bool auto;
  final bool stopLatched;
  final bool canResume;
  final String controlMode;
  final bool wheelReady, wheelRangeEnabled, wheelReversed, wheelPulling;
  final int? wheelA, wheelB;
  final double wheelSensitivity;
  final String wheelArrival;
  final int wheelArrivalSequence;
  final double slider;
  final double speedRevS;
  final double accelRevS2;
  final bool standbyFeature;
  final bool faces;

  // 镜头与流程
  final String? lensId;
  final String lensName;
  final List<FfLens> lenses;
  final SetupPhase phase;
  final int? nearSteps;
  final int dir;
  final int strokeSteps;
  final List<FfLutPoint> lutPoints;
  final List<FfLutPoint> lutCurve;
  final bool lutReady;
  final int limitLo;
  final int limitHi;

  // 距离
  final double? distanceM;

  // 诊断
  final int lastSentSequence;
  final int lastEchoedSequence;
  final int? statusAgeMs;
  final int? echoAgeMs;
  final String? socketError;
  final FfFm03? fm03;
  final List<String> fm03Log;
  final String msg;

  const FfState({
    this.appVersion = '',
    this.calSupported = false,
    this.calStage = 'idle',
    this.calError = 0,
    this.calSafeSpan = 0,
    this.calTravel = 0,
    this.calDirectionPending = false,
    this.connected = false,
    this.linkAlive = false,
    this.deviceId,
    this.host,
    this.port = 4210,
    this.localPort,
    this.localAddrs = const [],
    this.devices = const [],
    this.rxPackets = 0,
    this.probeTx = 0,
    this.pos = 0,
    this.target = 0,
    this.enabled = false,
    this.moving = false,
    this.canOk = false,
    this.standby = false,
    this.limitHit = false,
    this.result = kResultIdle,
    this.positionTrusted = false,
    this.microsteps = 1,
    this.stepsPerRev = 4096,
    this.maxRevsPerSec = 6.25,
    this.posRevs = 0,
    this.strokeRevs = 0,
    this.auto = false,
    this.stopLatched = false,
    this.canResume = false,
    this.controlMode = 'automatic',
    this.wheelReady = false,
    this.wheelRangeEnabled = false,
    this.wheelReversed = false,
    this.wheelPulling = false,
    this.wheelA,
    this.wheelB,
    this.wheelSensitivity = 1,
    this.wheelArrival = '',
    this.wheelArrivalSequence = 0,
    this.slider = 0.5,
    this.speedRevS = 64 / 4096,
    this.accelRevS2 = 30,
    this.standbyFeature = true,
    this.faces = false,
    this.lensId,
    this.lensName = '',
    this.lenses = const [],
    this.phase = SetupPhase.stroke,
    this.nearSteps,
    this.dir = 1,
    this.strokeSteps = 0,
    this.lutPoints = const [],
    this.lutCurve = const [],
    this.lutReady = false,
    this.limitLo = 0,
    this.limitHi = 0,
    this.distanceM,
    this.lastSentSequence = 0,
    this.lastEchoedSequence = 0,
    this.statusAgeMs,
    this.echoAgeMs,
    this.socketError,
    this.fm03,
    this.fm03Log = const [],
    this.msg = '',
  });

  factory FfState.fromMap(Map<dynamic, dynamic> m) {
    final fm03 = m['fm03'];
    return FfState(
      appVersion: (m['app_version'] as String?) ?? '',
      calSupported: (m['cal_supported'] as bool?) ?? false,
      calStage: (m['cal_stage'] as String?) ?? 'idle',
      calError: (m['cal_error'] as num?)?.toInt() ?? 0,
      calSafeSpan: (m['cal_safe_span'] as num?)?.toInt() ?? 0,
      calTravel: (m['cal_travel'] as num?)?.toInt() ?? 0,
      calDirectionPending: (m['cal_direction_pending'] as bool?) ?? false,
      connected: (m['connected'] as bool?) ?? false,
      linkAlive: (m['link_alive'] as bool?) ?? false,
      deviceId: m['device_id'] as String?,
      host: m['host'] as String?,
      port: (m['port'] as num?)?.toInt() ?? 4210,
      localPort: (m['local_port'] as num?)?.toInt(),
      localAddrs: _strings(m['local_addrs']),
      devices: _maps(m['devices']).map(FfDevice.fromMap).toList(),
      rxPackets: (m['rx_packets'] as num?)?.toInt() ?? 0,
      probeTx: (m['probe_tx'] as num?)?.toInt() ?? 0,
      pos: (m['pos'] as num?)?.toInt() ?? 0,
      target: (m['target'] as num?)?.toInt() ?? 0,
      enabled: (m['enabled'] as bool?) ?? false,
      moving: (m['moving'] as bool?) ?? false,
      canOk: (m['can_ok'] as bool?) ?? false,
      standby: (m['standby'] as bool?) ?? false,
      limitHit: (m['limit_hit'] as bool?) ?? false,
      result: (m['result'] as num?)?.toInt() ?? kResultIdle,
      positionTrusted: (m['position_trusted'] as bool?) ?? false,
      microsteps: (m['microsteps'] as num?)?.toInt() ?? 16,
      stepsPerRev: (m['steps_per_rev'] as num?)?.toInt() ?? 4096,
      maxRevsPerSec: (m['max_revs_per_sec'] as num?)?.toDouble() ?? 6.25,
      posRevs: (m['pos_revs'] as num?)?.toDouble() ?? 0,
      strokeRevs: (m['stroke_revs'] as num?)?.toDouble() ?? 0,
      auto: (m['auto'] as bool?) ?? false,
      stopLatched: (m['stop_latched'] as bool?) ?? false,
      canResume: m['can_resume'] == true,
      controlMode: (m['control_mode'] as String?) ?? 'automatic',
      wheelReady: m['wheel_ready'] == true,
      wheelRangeEnabled: m['wheel_range_enabled'] == true,
      wheelReversed: m['wheel_reversed'] == true,
      wheelPulling: m['wheel_pulling'] == true,
      wheelA: (m['wheel_a'] as num?)?.toInt(),
      wheelB: (m['wheel_b'] as num?)?.toInt(),
      wheelSensitivity: (m['wheel_sensitivity'] as num?)?.toDouble() ?? 1,
      wheelArrival: (m['wheel_arrival'] as String?) ?? '',
      wheelArrivalSequence: (m['wheel_arrival_sequence'] as num?)?.toInt() ?? 0,
      slider: (m['slider'] as num?)?.toDouble() ?? 0.5,
      speedRevS: (m['speed_rev_s'] as num?)?.toDouble() ?? 1.2,
      accelRevS2: (m['accel_rev_s2'] as num?)?.toDouble() ?? 30,
      standbyFeature: (m['standby_feature'] as bool?) ?? true,
      faces: (m['faces'] as bool?) ?? false,
      lensId: m['lens_id'] as String?,
      lensName: (m['lens_name'] as String?) ?? '',
      lenses: _maps(m['lenses']).map(FfLens.fromMap).toList(),
      phase: _phaseFrom(m['phase'] as String?),
      nearSteps: (m['near_steps'] as num?)?.toInt(),
      dir: (m['dir'] as num?)?.toInt() ?? 1,
      strokeSteps: (m['stroke_steps'] as num?)?.toInt() ?? 0,
      lutPoints: _maps(m['lut_points']).map(FfLutPoint.fromMap).toList(),
      lutCurve: _maps(m['lut_curve']).map(FfLutPoint.fromMap).toList(),
      lutReady: m['lut_ready'] == true,
      limitLo: (m['limit_lo'] as num?)?.toInt() ?? 0,
      limitHi: (m['limit_hi'] as num?)?.toInt() ?? 0,
      distanceM: (m['distance_m'] as num?)?.toDouble(),
      lastSentSequence: (m['last_sent_sequence'] as num?)?.toInt() ?? 0,
      lastEchoedSequence: (m['last_echoed_sequence'] as num?)?.toInt() ?? 0,
      statusAgeMs: (m['status_age_ms'] as num?)?.toInt(),
      echoAgeMs: (m['echo_age_ms'] as num?)?.toInt(),
      socketError: m['socket_error'] as String?,
      fm03: fm03 is Map ? FfFm03.fromMap(fm03) : null,
      fm03Log: _strings(m['fm03_log']),
      msg: (m['msg'] as String?) ?? '',
    );
  }

  /// 最近命令结果的中文说明。
  String get resultLabel {
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
}

List<Map<dynamic, dynamic>> _maps(Object? v) =>
    (v as List?)
        ?.whereType<Map>()
        .map((e) => e.cast<dynamic, dynamic>())
        .toList() ??
    const [];

List<String> _strings(Object? v) =>
    (v as List?)?.map((e) => '$e').toList() ?? const [];

// MARK: - 客户端

class FfCore {
  static const _methods = MethodChannel('ff.core');
  static const _events = EventChannel('ff.core/events');

  /// 约 20Hz 的状态快照流。UI 只渲染最新一条。
  Stream<FfState> states() => _events.receiveBroadcastStream().map(
    (e) => FfState.fromMap(e as Map<dynamic, dynamic>),
  );

  /// 取一次当前快照，用于首帧绘制。
  Future<FfState> snapshot() async {
    final m = await _methods.invokeMethod<Map<dynamic, dynamic>>('snapshot');
    return m == null ? const FfState() : FfState.fromMap(m);
  }

  // 生命周期
  Future<void> start() => invoke('start');
  Future<void> stop() => invoke('stop');

  // 设备
  Future<List<FfDevice>> discover() async {
    final list = await _methods.invokeMethod<List<dynamic>>('discover');
    return _maps(list).map(FfDevice.fromMap).toList();
  }

  Future<void> selectDevice(FfDevice d) => invoke('selectDevice', {
    'device_id': d.deviceId,
    'host': d.host,
    'port': d.udpPort,
    'firmware': d.firmware,
  });

  Future<void> connect() => invoke('connect');
  Future<void> disconnect() => invoke('disconnect');

  // 手动控制
  Future<void> enable(bool on) => invoke('enable', {'on': on});
  Future<void> stopPressed() => invoke('stopPressed');
  Future<void> resumeControl() => invoke('resumeControl');
  Future<void> setControlMode(String mode) =>
      invoke('setControlMode', {'mode': mode});
  Future<void> turnWheel(double turns) => invoke('turnWheel', {'turns': turns});
  Future<void> setWheelPoint(String point) =>
      invoke('setWheelPoint', {'point': point});
  Future<void> clearWheelPoints() => invoke('clearWheelPoints');
  Future<void> setWheelRange(bool on) => invoke('setWheelRange', {'on': on});
  Future<void> setWheelSensitivity(double value) =>
      invoke('setWheelSensitivity', {'value': value});
  Future<void> setWheelReversed(bool on) =>
      invoke('setWheelReversed', {'on': on});
  Future<void> pullWheelTo(String point, {double duration = 0}) =>
      invoke('pullWheelTo', {'point': point, 'duration': duration});
  Future<void> jog(int delta) => invoke('jog', {'delta': delta});
  Future<void> setSlider(double value) => invoke('setSlider', {'value': value});
  Future<void> setAuto(bool on) => invoke('setAuto', {'on': on});
  Future<void> setSpeed({
    required double revsPerSec,
    required double accelRevsPerSec2,
  }) => invoke('setSpeed', {
    'revsPerSec': revsPerSec,
    'accelRevsPerSec2': accelRevsPerSec2,
  });

  // 驱动参数
  Future<void> setFm03(int key, int value) =>
      invoke('setFm03', {'key': key, 'value': value});
  Future<void> queryFm03() => invoke('queryFm03');

  // 镜头
  Future<void> selectLens(String id) => invoke('selectLens', {'id': id});
  Future<void> createLens({required String name, required String params}) =>
      invoke('createLens', {'name': name, 'params': params});
  Future<void> deleteLens(String id) => invoke('deleteLens', {'id': id});

  // ① FM03 内部寻限位
  Future<void> resetLensCalibration() => invoke('resetLensCalibration');
  Future<void> startAutoCalibration() => invoke('startAutoCalibration');
  Future<void> cancelAutoCalibration() => invoke('cancelAutoCalibration');
  Future<void> leaveLens() => invoke('leaveLens');

  // ② 物距方向
  Future<void> setDir(int dir) => invoke('setDir', {'dir': dir});
  Future<void> startFollow() => invoke('startFollow');
  Future<void> unalign() => invoke('unalign');

  // ③ 距离标定
  Future<void> addLutPoint({double? meters}) =>
      invoke('addLutPoint', {'meters': ?meters});
  Future<void> removeLutPoint(int index) =>
      invoke('removeLutPoint', {'index': index});

  // LiDAR
  Future<void> setTrackFaces(bool on) => invoke('setTrackFaces', {'on': on});

  /// 喂一个距离。真机上 LiDAR 直连核心，不需要 UI 调这个；
  /// 模拟器/测试里没有 LiDAR 时用它驱动自动跟焦。
  Future<void> ingestDistance(double? meters) =>
      invoke('ingestDistance', {'meters': meters});

  /// 唯一的命令出口。**测试接缝**：伪造核心时覆盖这一个方法就能记录所有命令，
  /// 不必逐个覆盖 20 多个方法（也不必去 mock 平台通道）。
  Future<void> invoke(String method, [Map<String, Object?>? args]) async {
    await _methods.invokeMethod<void>(method, args);
  }
}
