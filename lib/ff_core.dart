import 'dart:async';

import 'package:flutter/services.dart';

/// `ff.core` 通道的 Dart 客户端。
///
/// **只做两件事**：把命令发下去、把状态快照解出来。
/// 不含任何控制逻辑 —— 软限位、自动跟焦死区、相位机、镜头对齐全在 Swift 侧的
/// `FollowFocusSession` 里（见 HANDOFF §13）。
///
/// 所以这里只允许出现“字段搬运”，不要在这里加 `_limitsFor`、`_autoSteps`
/// 这类函数：一旦出现，就是第二份实现，两边迟早不一致。

// MARK: - 协议常量（跨语言契约）
//
// 这些是线协议里的取值，不是逻辑。改它们要同时改固件和 Swift 侧。

/// TMC2209 可写参数 key。
const int kTmcRms = 1;
const int kTmcMicrosteps = 2;
const int kTmcStealth = 3;
const int kTmcToff = 4;
const int kTmcIhold = 5;
const int kTmcIrun = 6;
const int kTmcStandby = 7;

/// 命令结果（STATUS.flags 高 3 位）。
const int kResultIdle = 0;
const int kResultAccepted = 1;
const int kResultCompleted = 2;
const int kResultLimited = 3;
const int kResultRejected = 4;
const int kResultStopped = 5;

/// 跟焦前的三步。
enum SetupPhase { stroke, align, follow }

SetupPhase _phaseFrom(String? s) {
  switch (s) {
    case 'align':
      return SetupPhase.align;
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

/// 距离标定点。`steps` 是**当前细分下**的步数（核心已换算好）。
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
  final bool calibrated;
  final int strokeSteps;

  /// 行程圈数。圈数与细分无关，列表页直接显示它。
  final double strokeRevs;
  final int lutCount;
  final int? autoTravel;
  final int? autoSafeSpan;
  final int? autoRmsMa;
  final int? autoThreshold;
  final int? autoMaxSteps;
  final String? autoFirmware;

  const FfLens({
    required this.id,
    required this.name,
    required this.params,
    required this.dir,
    required this.calibrated,
    required this.strokeSteps,
    required this.strokeRevs,
    required this.lutCount,
    this.autoTravel,
    this.autoSafeSpan,
    this.autoRmsMa,
    this.autoThreshold,
    this.autoMaxSteps,
    this.autoFirmware,
  });

  factory FfLens.fromMap(Map<dynamic, dynamic> m) => FfLens(
    id: (m['id'] as String?) ?? '',
    name: (m['name'] as String?) ?? '',
    params: (m['params'] as String?) ?? '',
    dir: (m['dir'] as num?)?.toInt() ?? 1,
    calibrated: (m['calibrated'] as bool?) ?? false,
    strokeSteps: (m['stroke_steps'] as num?)?.toInt() ?? 0,
    strokeRevs: (m['stroke_revs'] as num?)?.toDouble() ?? 0,
    lutCount: (m['lut_count'] as num?)?.toInt() ?? 0,
    autoTravel: (m['auto_travel'] as num?)?.toInt(),
    autoSafeSpan: (m['auto_safe_span'] as num?)?.toInt(),
    autoRmsMa: (m['auto_rms_ma'] as num?)?.toInt(),
    autoThreshold: (m['auto_threshold'] as num?)?.toInt(),
    autoMaxSteps: (m['auto_max_steps'] as num?)?.toInt(),
    autoFirmware: m['auto_firmware'] as String?,
  );
}

class FfTmc {
  final bool uartOk;
  final bool stealth;
  final int rmsMa;
  final int microsteps;
  final int toff;
  final int ihold;
  final int irun;
  final int version;
  final int csActual;
  final int sg;
  final int tstep;
  final bool ot;
  final bool otpw;
  final bool ola;
  final bool olb;
  final bool shorted;
  final bool standstill;

  /// 已经排好版的一行日志，由核心生成（`TmcDump.logLine()`），
  /// UI 不再自己拼这些诊断文字。
  final String logLine;

  const FfTmc({
    required this.uartOk,
    required this.stealth,
    required this.rmsMa,
    required this.microsteps,
    required this.toff,
    required this.ihold,
    required this.irun,
    required this.version,
    required this.csActual,
    required this.sg,
    required this.tstep,
    required this.ot,
    required this.otpw,
    required this.ola,
    required this.olb,
    required this.shorted,
    required this.standstill,
    required this.logLine,
  });

  factory FfTmc.fromMap(Map<dynamic, dynamic> m) => FfTmc(
    uartOk: (m['uart_ok'] as bool?) ?? false,
    stealth: (m['stealth'] as bool?) ?? true,
    rmsMa: (m['rms_ma'] as num?)?.toInt() ?? 0,
    microsteps: (m['microsteps'] as num?)?.toInt() ?? 16,
    toff: (m['toff'] as num?)?.toInt() ?? 0,
    ihold: (m['ihold'] as num?)?.toInt() ?? 0,
    irun: (m['irun'] as num?)?.toInt() ?? 0,
    version: (m['version'] as num?)?.toInt() ?? 0,
    csActual: (m['cs_actual'] as num?)?.toInt() ?? 0,
    sg: (m['sg'] as num?)?.toInt() ?? 0,
    tstep: (m['tstep'] as num?)?.toInt() ?? 0,
    ot: (m['ot'] as bool?) ?? false,
    otpw: (m['otpw'] as bool?) ?? false,
    ola: (m['ola'] as bool?) ?? false,
    olb: (m['olb'] as bool?) ?? false,
    shorted: (m['shorted'] as bool?) ?? false,
    standstill: (m['standstill'] as bool?) ?? false,
    logLine: (m['log_line'] as String?) ?? '',
  );
}

/// 一条聚合状态快照。UI 只渲染最新一条，不做累积。
class FfState {
  final bool calSupported;
  final String calStage;
  final int calError;
  final int calSafeSpan;
  final int calTravel;
  final bool calDirectionPending;
  // 链路
  final bool connected;
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
  final bool uartOk;
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
  final int limitLo;
  final int limitHi;
  final int? strokeA;

  // 距离
  final double? distanceM;

  // 诊断
  final int lastSentSequence;
  final int lastEchoedSequence;
  final int? statusAgeMs;
  final int? echoAgeMs;
  final String? socketError;
  final FfTmc? tmc;
  final List<String> tmcLog;
  final String msg;

  const FfState({
    this.calSupported = false,
    this.calStage = 'idle',
    this.calError = 0,
    this.calSafeSpan = 0,
    this.calTravel = 0,
    this.calDirectionPending = false,
    this.connected = false,
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
    this.uartOk = false,
    this.standby = false,
    this.limitHit = false,
    this.result = kResultIdle,
    this.positionTrusted = false,
    this.microsteps = 16,
    this.stepsPerRev = 6400,
    this.maxRevsPerSec = 6.25,
    this.posRevs = 0,
    this.strokeRevs = 0,
    this.auto = false,
    this.stopLatched = false,
    this.slider = 0.5,
    this.speedRevS = 1.2,
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
    this.limitLo = 0,
    this.limitHi = 0,
    this.strokeA,
    this.distanceM,
    this.lastSentSequence = 0,
    this.lastEchoedSequence = 0,
    this.statusAgeMs,
    this.echoAgeMs,
    this.socketError,
    this.tmc,
    this.tmcLog = const [],
    this.msg = '',
  });

  factory FfState.fromMap(Map<dynamic, dynamic> m) {
    final tmc = m['tmc'];
    return FfState(
      calSupported: (m['cal_supported'] as bool?) ?? false,
      calStage: (m['cal_stage'] as String?) ?? 'idle',
      calError: (m['cal_error'] as num?)?.toInt() ?? 0,
      calSafeSpan: (m['cal_safe_span'] as num?)?.toInt() ?? 0,
      calTravel: (m['cal_travel'] as num?)?.toInt() ?? 0,
      calDirectionPending: (m['cal_direction_pending'] as bool?) ?? false,
      connected: (m['connected'] as bool?) ?? false,
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
      uartOk: (m['uart_ok'] as bool?) ?? false,
      standby: (m['standby'] as bool?) ?? false,
      limitHit: (m['limit_hit'] as bool?) ?? false,
      result: (m['result'] as num?)?.toInt() ?? kResultIdle,
      positionTrusted: (m['position_trusted'] as bool?) ?? false,
      microsteps: (m['microsteps'] as num?)?.toInt() ?? 16,
      stepsPerRev: (m['steps_per_rev'] as num?)?.toInt() ?? 6400,
      maxRevsPerSec: (m['max_revs_per_sec'] as num?)?.toDouble() ?? 6.25,
      posRevs: (m['pos_revs'] as num?)?.toDouble() ?? 0,
      strokeRevs: (m['stroke_revs'] as num?)?.toDouble() ?? 0,
      auto: (m['auto'] as bool?) ?? false,
      stopLatched: (m['stop_latched'] as bool?) ?? false,
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
      limitLo: (m['limit_lo'] as num?)?.toInt() ?? 0,
      limitHi: (m['limit_hi'] as num?)?.toInt() ?? 0,
      strokeA: (m['stroke_a'] as num?)?.toInt(),
      distanceM: (m['distance_m'] as num?)?.toDouble(),
      lastSentSequence: (m['last_sent_sequence'] as num?)?.toInt() ?? 0,
      lastEchoedSequence: (m['last_echoed_sequence'] as num?)?.toInt() ?? 0,
      statusAgeMs: (m['status_age_ms'] as num?)?.toInt(),
      echoAgeMs: (m['echo_age_ms'] as num?)?.toInt(),
      socketError: m['socket_error'] as String?,
      tmc: tmc is Map ? FfTmc.fromMap(tmc) : null,
      tmcLog: _strings(m['tmc_log']),
      msg: (m['msg'] as String?) ?? '',
    );
  }

  /// 距离标定表够不够两点。自动跟焦需要它。
  bool get lutReady => lutPoints.length >= 2;

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
    (v as List?)?.whereType<Map>().map((e) => e.cast<dynamic, dynamic>()).toList() ??
    const [];

List<String> _strings(Object? v) =>
    (v as List?)?.map((e) => '$e').toList() ?? const [];

// MARK: - 客户端

class FfCore {
  static const _methods = MethodChannel('ff.core');
  static const _events = EventChannel('ff.core/events');

  /// 约 20Hz 的状态快照流。UI 只渲染最新一条。
  Stream<FfState> states() => _events
      .receiveBroadcastStream()
      .map((e) => FfState.fromMap(e as Map<dynamic, dynamic>));

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
  Future<void> homePressed() => invoke('homePressed');
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
  Future<void> setMicrosteps(int value) =>
      invoke('setMicrosteps', {'value': value});
  Future<void> setTmc(int key, int value) =>
      invoke('setTmc', {'key': key, 'value': value});
  Future<void> queryTmc() => invoke('queryTmc');
  Future<void> setStandbyFeature(bool on) =>
      invoke('setStandbyFeature', {'on': on});

  // 镜头
  Future<void> selectLens(String id) => invoke('selectLens', {'id': id});
  Future<void> createLens({required String name, required String params}) =>
      invoke('createLens', {'name': name, 'params': params});
  Future<void> deleteLens(String id) => invoke('deleteLens', {'id': id});

  // ① 行程标定
  Future<void> recordStrokeA() => invoke('recordStrokeA');
  Future<void> finishStroke() => invoke('finishStroke');
  Future<void> recalibrateStroke() => invoke('recalibrateStroke');
  Future<void> startAutoCalibration({required int threshold, required double maxRevs}) =>
      invoke('startAutoCalibration', {'threshold': threshold, 'maxRevs': maxRevs});
  Future<void> cancelAutoCalibration() => invoke('cancelAutoCalibration');
  Future<void> leaveLens() => invoke('leaveLens');

  // ② 单侧对齐
  Future<void> confirmNear() => invoke('confirmNear');
  Future<void> setDir(int dir) => invoke('setDir', {'dir': dir});
  Future<void> startFollow() => invoke('startFollow');
  Future<void> unalign() => invoke('unalign');

  // ③ 距离标定
  Future<void> addLutPoint() => invoke('addLutPoint');
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
