import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class LidarSample {
  final double? distanceM;
  final double u;
  final double v;
  final double? faceU;
  final double? faceV;
  final double? faceW;
  final double? faceH;

  const LidarSample({
    required this.distanceM,
    required this.u,
    required this.v,
    this.faceU,
    this.faceV,
    this.faceW,
    this.faceH,
  });

  factory LidarSample.fromMap(Map<dynamic, dynamic> m) {
    return LidarSample(
      distanceM: (m['distance_m'] as num?)?.toDouble(),
      u: (m['u'] as num?)?.toDouble() ?? 0.5,
      v: (m['v'] as num?)?.toDouble() ?? 0.5,
      faceU: (m['face_u'] as num?)?.toDouble(),
      faceV: (m['face_v'] as num?)?.toDouble(),
      faceW: (m['face_w'] as num?)?.toDouble(),
      faceH: (m['face_h'] as num?)?.toDouble(),
    );
  }
}

class LidarChannel {
  static const _methods = MethodChannel('ff.lidar');
  static const _events = EventChannel('ff.lidar/events');

  StreamSubscription<dynamic>? _sub;

  static bool get isSupported => Platform.isIOS;

  Future<bool> available() async {
    if (!isSupported) return false;
    try {
      return await _methods.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> start({required bool trackFaces}) async {
    if (!isSupported) return;
    await _methods.invokeMethod<void>('start', {'trackFaces': trackFaces});
  }

  Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _methods.invokeMethod<void>('stop');
    } on MissingPluginException {
      return;
    }
  }

  Future<void> setTarget(double u, double v) async {
    if (!isSupported) return;
    await _methods.invokeMethod<void>('setTarget', {'u': u, 'v': v});
  }

  Future<void> setTrackFaces(bool on) async {
    if (!isSupported) return;
    await _methods.invokeMethod<void>('setTrackFaces', {'on': on});
  }

  Stream<LidarSample> samples() {
    return _events.receiveBroadcastStream().map((e) {
      return LidarSample.fromMap(e as Map<dynamic, dynamic>);
    });
  }

  Future<void> listen(void Function(LidarSample) onSample) async {
    await _sub?.cancel();
    if (!isSupported) return;
    _sub = samples().listen(onSample);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await stop();
  }
}
