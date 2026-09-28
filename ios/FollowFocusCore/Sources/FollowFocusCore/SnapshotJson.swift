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
      "uart_ok": uartOk,
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
      "limit_lo": limitLo,
      "limit_hi": limitHi,

      // 诊断
      "last_sent_sequence": Int(lastSentSequence),
      "last_echoed_sequence": Int(lastEchoedSequence),
      "tmc_log": tmcLog,
      "msg": msg,
      "cal_supported": calSupported,
      "cal_stage": calStage,
      "cal_error": calError,
      "cal_safe_span": calSafeSpan,
      "cal_travel": calTravel,
      "cal_direction_pending": calDirectionPending,
    ]

    if let v = lensId { m["lens_id"] = v }
    if let v = deviceId { m["device_id"] = v }
    if let v = host { m["host"] = v }
    if let v = localPort { m["local_port"] = Int(v) }
    if let v = nearSteps { m["near_steps"] = v }
    if let v = strokeA { m["stroke_a"] = v }
    if let v = distanceM { m["distance_m"] = v }
    if let v = statusAgeMs { m["status_age_ms"] = v }
    if let v = echoAgeMs { m["echo_age_ms"] = v }
    if let v = socketError { m["socket_error"] = v }
    if let v = tmc { m["tmc"] = v.channelObject }
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
  /// 列表页要显示“行程 x 圈”，而行程是按**镜头自己的细分**记的，
  /// 所以连圈数一起给出去，省得 UI 自己换算。
  public func channelObject(cal: MotorCal) -> [String: Any] {
    let steps = strokeAt(strokeMicrosteps)
    var m: [String: Any] = [
      "id": id,
      "name": name,
      "params": params,
      "dir": dir,
      "calibrated": calibrated,
      "stroke_steps": steps,
      "stroke_revs": cal.stepsToRevs(steps, strokeMicrosteps),
      "lut_count": lut.points.count,
    ]
    if let autoTravel { m["auto_travel"] = autoTravel }
    if let autoSafeSpan { m["auto_safe_span"] = autoSafeSpan }
    if let autoRmsMa { m["auto_rms_ma"] = autoRmsMa }
    if let autoThreshold { m["auto_threshold"] = autoThreshold }
    if let autoMaxSteps { m["auto_max_steps"] = autoMaxSteps }
    if let autoFirmware { m["auto_firmware"] = autoFirmware }
    return m
  }
}

extension LutPoint {
  public var channelObject: [String: Any] { ["meters": meters, "steps": steps] }
}

extension TmcDump {
  public var channelObject: [String: Any] {
    [
      "uart_ok": uartOk,
      "stealth": stealth,
      "rms_ma": rmsMa,
      "microsteps": microsteps,
      "toff": toff,
      "ihold": ihold,
      "irun": irun,
      "version": version,
      "cs_actual": csActual,
      "sg": sg,
      "tstep": tstep,
      "drv_status": Int(drvStatus),
      "ot": ot,
      "otpw": otpw,
      "ola": ola,
      "olb": olb,
      "shorted": shorted,
      "standstill": standstill,
      // 日志那一行由核心排版好，UI 不再自己拼诊断文字。
      "log_line": logLine(),
    ]
  }
}
