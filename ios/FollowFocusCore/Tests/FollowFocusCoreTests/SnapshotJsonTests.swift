import XCTest

@testable import FollowFocusCore

/// 通道契约测试。
///
/// 这些键是 Dart 侧 `lib/ff_core.dart` 的解析依据。跨语言的“字典键”是最容易
/// 悄悄坏掉的东西：拼错了不会崩，只会让界面显示空值。所以这里两侧都钉住：
/// 键必须存在，值必须是 Dart 能 `as num` / `as bool` 读出来的类型。
final class SnapshotJsonTests: XCTestCase {
  private let cal = MotorCal()

  private func state() -> FollowFocusState {
    var s = FollowFocusState()
    s.connected = true
    s.deviceId = "FF-AABBCC"
    s.host = "192.168.4.1"
    s.port = 4210
    s.localPort = 55555
    s.localAddrs = ["en0=192.168.4.2"]
    s.pos = 3200
    s.target = 3200
    s.enabled = true
    s.moving = false
    s.canOk = true
    s.standby = false
    s.limitHit = false
    s.result = kResultCompleted
    s.positionTrusted = true
    s.microsteps = 16
    s.stepsPerRev = 6400
    s.maxRevsPerSec = 6.25
    s.posRevs = 0.5
    s.strokeRevs = 1
    s.auto = true
    s.stopLatched = false
    s.slider = 0.25
    s.speedRevS = 1.2
    s.accelRevS2 = 30
    s.standbyFeature = true
    s.faces = true
    s.lensId = "L1"
    s.lensName = "50mm F1.4"
    s.phase = .follow
    s.nearSteps = 1000
    s.dir = 1
    s.strokeSteps = 6400
    s.lutPoints = [LutPoint(meters: 1, steps: 1000)]
    s.limitLo = 1000
    s.limitHi = 7400
    s.strokeA = 500
    s.distanceM = 1.75
    s.statusAgeMs = 12
    s.echoAgeMs = 40
    s.socketError = "errno 13"
    s.lastSentSequence = 7
    s.lastEchoedSequence = 7
    s.fm03Log = ["12:00:00  rms=800mA"]
    s.msg = "就绪"
    s.fm03 = Fm03Dump(online: true, stage: 3, value: 0, maxSpeed: 64, tolerance: 4, gain: 4, rawPosition: 1000, txFailures: 0, rxMissed: 0, feedbackAge: 12)
    s.lenses = [
      Lens(id: "L1", name: "50mm F1.4", params: "F1.4", strokeSteps: 4096),
      Lens(id: "L2", name: "85mm", params: ""),
    ]
    return s
  }

  func testEveryKeyTheUIReadsIsPresent() {
    let m = state().channelObject(cal: cal)
    let expected: [String] = [
      // 链路
      "connected", "link_alive", "port", "local_addrs", "devices", "rx_packets",
      "probe_tx", "device_id", "host", "local_port",
      // 电机
      "pos", "target", "enabled", "moving", "can_ok", "standby", "limit_hit",
      "result", "position_trusted",
      // 单位换算
      "microsteps", "steps_per_rev", "max_revs_per_sec", "pos_revs", "stroke_revs",
      // 会话
      "auto", "stop_latched", "slider", "speed_rev_s", "accel_rev_s2",
      "standby_feature", "faces",
      // 镜头与流程
      "lens_id", "lens_name", "lenses", "phase", "near_steps", "dir",
      "stroke_steps", "lut_points", "limit_lo", "limit_hi", "stroke_a",
      // 距离与诊断
      "distance_m", "status_age_ms", "echo_age_ms", "socket_error", "fm03",
      "last_sent_sequence", "last_echoed_sequence", "fm03_log", "msg",
    ]
    for key in expected {
      XCTAssertNotNil(m[key], "UI 要读的键 \(key) 丢了")
    }
  }

  func testOptionalKeysAreOmittedRatherThanNull() {
    var s = FollowFocusState()
    s.lensId = nil
    s.distanceM = nil
    s.fm03 = nil
    let m = s.channelObject(cal: cal)
    // 省略键而不是放 NSNull：Dart 侧按可空读，NSNull 会在 `as num?` 上抛异常。
    XCTAssertNil(m["lens_id"])
    XCTAssertNil(m["distance_m"])
    XCTAssertNil(m["fm03"])
    XCTAssertFalse(m.values.contains { $0 is NSNull }, "不要放 NSNull")
  }

  func testValuesAreDartReadableTypes() {
    let m = state().channelObject(cal: cal)
    // Dart 侧用 `as num` / `as bool` / `as String` / `is Map` / `as List` 读。
    XCTAssertTrue(m["pos"] is Int)
    XCTAssertTrue(m["slider"] is Double)
    XCTAssertTrue(m["connected"] is Bool)
    XCTAssertTrue(m["msg"] is String)
    XCTAssertTrue(m["local_addrs"] is [String])
    XCTAssertTrue(m["fm03"] is [String: Any])
    XCTAssertTrue(m["lenses"] is [[String: Any]])

    let lens = (m["lenses"] as! [[String: Any]])[0]
    for key in [
      "id", "name", "params", "dir", "calibrated", "stroke_steps", "stroke_revs", "lut_count",
    ] {
      XCTAssertNotNil(lens[key], "镜头条目缺键 \(key)")
    }
    XCTAssertEqual(lens["calibrated"] as? Bool, true)
    XCTAssertEqual(lens["stroke_revs"] as? Double ?? -1, 1.0, accuracy: 1e-9)

    let point = (m["lut_points"] as! [[String: Any]])[0]
    XCTAssertEqual(point["meters"] as? Double, 1.0)
    XCTAssertEqual(point["steps"] as? Int, 1000)

    let fm03 = m["fm03"] as! [String: Any]
    XCTAssertEqual(fm03["max_speed"] as? Int, 64)
    XCTAssertEqual(fm03["log_line"] as? String, state().fm03?.logLine())
  }

  func testPhaseUsesTheStringsTheUIParses() {
    for (phase, raw) in [
      (SetupPhase.stroke, "stroke"), (SetupPhase.align, "align"), (SetupPhase.follow, "follow"),
    ] {
      var s = FollowFocusState()
      s.phase = phase
      XCTAssertEqual(s.channelObject(cal: cal)["phase"] as? String, raw)
    }
  }

  /// 未标定镜头的行程必须是 0，否则列表页会把它显示成“已标定”。
  func testUncalibratedLensReportsZeroStroke() {
    var s = FollowFocusState()
    s.lenses = [Lens(id: "L", name: "新镜头")]
    let lens = (s.channelObject(cal: cal)["lenses"] as! [[String: Any]])[0]
    XCTAssertEqual(lens["calibrated"] as? Bool, false)
    XCTAssertEqual(lens["stroke_steps"] as? Int, 0)
    XCTAssertEqual(lens["stroke_revs"] as? Double, 0)
  }

  /// 行程按镜头自己的细分记录，所以圈数换算必须用镜头的细分，不能用当前细分。
  func testLensStrokeFractionUsesFm03Coordinates() {
    var s=FollowFocusState()
    s.lenses=[Lens(id: "L",name: "50mm",strokeSteps: 4096,strokeMicrosteps: 1)]
    let lenses=s.channelObject(cal: MotorCal())["lenses"] as! [[String: Any]]
    XCTAssertEqual(lenses[0]["stroke_revs"] as? Double,1)
  }

  func testDiscoveryObjectCarriesWhatTheDevicePageShows() {
    let d = FfDiscovery(
      deviceId: "FF-AABBCC", mac: "AA:BB:CC:DD:EE:FF", kind: 1, protocolVersion: 1,
      udpPort: 4210, fwMajor: 0, fwMinor: 4, fwPatch: 1, host: "192.168.4.1")
    let m = d.channelObject
    XCTAssertEqual(m["device_id"] as? String, "FF-AABBCC")
    XCTAssertEqual(m["udp_port"] as? Int, 4210)
    XCTAssertEqual(m["mac"] as? String, "AA:BB:CC:DD:EE:FF")
    XCTAssertEqual(m["host"] as? String, "192.168.4.1")
    XCTAssertNotNil(m["firmware"], "设备页要显示固件版本")
  }
}
