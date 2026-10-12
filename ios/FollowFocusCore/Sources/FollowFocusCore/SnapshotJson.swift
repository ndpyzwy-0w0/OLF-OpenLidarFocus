import Foundation

/// 快照 → 通道 map 的序列化。
///
/// 放在功能层里而不是插件里，只为了一个理由：**能用 `swift test` 钉住键名**。
/// Dart 侧 `lib/ff_core.dart` 就是按这些键解析的，改错一个键界面只会静默显示空值，
/// 不会报错 —— 这种 bug 只有测试能挡住。
///
/// 规则：
/// - 可选值**省略键**（不用 NSNull），Dart 侧按可空读取；
/// - 键名 snake_case，和 `ff.lidar` 通道保持一致；
/// - 相对量一律给“当前细分下”的值，圈数/上限这类派生值也一并给出来，
///   免得 UI 自己换算（算错就是显示错）。

extension FollowFocusState {
  public func channelObject(cal: MotorCal) -> [String: Any] {
    var m: [String: Any] = [
      // 链路
      "connected": connected,
      "link_alive": linkAlive,
      "port": Int(port),
      "local_addrs": localAddrs,
      "devices": devices.map(\.channelObject),
      "rx_packets": rxPackets,
      "probe_tx": probeTx,

      // 电机
      "pos": Int(pos),
      "target": Int(target),
      "enabled": enabled,
      "moving": moving,
      "can_ok": canOk,
      "standby": standby,
      "limit_hit": limitHit,
      "result": result,
      "position_trusted": positionTrusted,

      // 单位换算
      "microsteps": microsteps,
      "steps_per_rev": stepsPerRev,
      "max_revs_per_sec": maxRevsPerSec,
      "pos_revs": posRevs,
      "stroke_revs": strokeRevs,

      // 会话
      "auto": auto,
      "stop_latched": stopLatched,
      "can_resume": canResume,
      "control_mode": controlMode.rawValue,
      "wheel_ready": wheelReady,
      "wheel_range_enabled": wheelRangeEnabled,
      "wheel_sensitivity": wheelSensitivity,
      "wheel_reversed": wheelReversed,
      "wheel_pulling": wheelPulling,
      "wheel_pull_curve": wheelPullCurve.rawValue,
      "wheel_arrival": wheelArrival,
      "wheel_arrival_sequence": wheelArrivalSequence,
      "slider": slider,
      "speed_rev_s": speedRevS,
      "accel_rev_s2": accelRevS2,
      "standby_feature": standbyFeature,
      "faces": faces,

      // 镜头与流程
      "lens_name": lensName,
      "lenses": lenses.map { $0.channelObject(cal: cal) },
      "phase": phase.rawValue,
      "dir": dir,
      "stroke_steps": strokeSteps,
      "lut_points": lutPoints.map(\.channelObject),
      "lut_curve": lutCurve.map(\.channelObject),
      "lut_ready": lutReady,
      "limit_lo": limitLo,
      "limit_hi": limitHi,

      // 诊断
      "last_sent_sequence": Int(lastSentSequence),
      "last_echoed_sequence": Int(lastEchoedSequence),
      "fm03_log": fm03Log,
      "msg": msg,
      "cal_supported": calSupported,
      "cal_stage": calStage,
      "cal_error": calError,
      "cal_safe_span": calSafeSpan,
      "cal_travel": calTravel,
      "cal_direction_pending": calDirectionPending,
    ]

    if let v = lensId { m["lens_id"] = v }
    if let v = wheelA { m["wheel_a"] = Int(v) }
    if let v = wheelB { m["wheel_b"] = Int(v) }
    if let v = deviceId { m["device_id"] = v }
    if let v = host { m["host"] = v }
    if let v = localPort { m["local_port"] = Int(v) }
    if let v = nearSteps { m["near_steps"] = v }
    if let v = distanceM { m["distance_m"] = v }
    if let v = statusAgeMs { m["status_age_ms"] = v }
    if let v = echoAgeMs { m["echo_age_ms"] = v }
    if let v = socketError { m["socket_error"] = v }
    if let v = fm03 { m["fm03"] = v.channelObject }
    return m
  }
}

extension FfDiscovery {
  public var channelObject: [String: Any] {
    [
      "device_id": deviceId,
      "mac": mac,
      "kind": kind,
      "protocol": protocolVersion,
      "udp_port": udpPort,
      "firmware": firmware,
      "host": host,
    ]
  }
}

extension Lens {
  public func channelObject(cal: MotorCal) -> [String: Any] {
    ["id": id, "name": name, "params": params, "dir": dir,
     "direction_confirmed": directionConfirmed,
     "lut_count": lut.points.count, "lut_ready": lut.ready && lut.matchesDirection(dir)]
  }
}

extension LutPoint {
  public var channelObject: [String: Any] { ["meters": meters, "steps": steps] }
}

extension Fm03Dump {
  public var channelObject: [String: Any] {
    ["online": online, "stage": stage, "value": value, "max_speed": maxSpeed,
     "tolerance": tolerance, "gain": gain, "raw_position": Int(rawPosition),
     "tx_failures": Int(txFailures), "rx_missed": Int(rxMissed),
     "feedback_age": feedbackAge, "log_line": logLine(),
     "acceleration": acceleration.map { $0 as Any } ?? NSNull()]
  }
}
