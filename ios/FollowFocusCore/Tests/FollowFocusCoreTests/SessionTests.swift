import XCTest

@testable import FollowFocusCore

private final class Locked<T> {
  private var value: T
  private let lock = NSLock()
  init(_ value: T) { self.value = value }
  var current: T {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func set(_ v: T) {
    lock.lock()
    value = v
    lock.unlock()
  }
  func mutate(_ body: (inout T) -> Void) {
    lock.lock()
    body(&value)
    lock.unlock()
  }
}

/// 迷你固件模拟器：在 loopback 上收命令、维护 pos/enabled/细分，并回 STATUS。
///
/// 有了它，会话层的控制循环可以在没有板子的情况下端到端验证：
/// 会话 → MotorLink → UDP → 这里 → 回包 → 会话状态。
private final class FakeFirmware {
  let sock = UdpSocket()
  private let running = Locked(true)
  private let _pos = Locked<Int32>(0)
  private let _enabled = Locked(false)
  private let _microsteps = Locked(16)
  private let _commands = Locked<[[UInt8]]>([])
  private let _target = Locked<Int32>(0)
  private let _calRun = Locked<UInt8>(0)
  private let _calStage = Locked<UInt8>(0)
  var dropFirstStartReply = false
  var rejectStart = false
  /// 拒绝 CAL_START 时回的错误码。固件的 `CAL_DIAG = 11` 是最新加的一个。
  var rejectStartError: UInt8 = 2
  /// CAL_START 一律不回（模拟固件不认这条命令）。
  var dropCalStartReplies = false
  var dropCalQueries = false
  /// 只丢带 run_id 的 CAL_QUERY，保留 `a=0` 的首读，用来验证“握手成功但
  /// 标定期间完全没回包”这条路径。
  var dropRunQueries = false
  var invalidateCalResult = false
  var wrongRunReplies = 0
  var dropStatusReplies = false

  /// 关掉时，即使收到 ENABLE 也继续回 enabled=0，用来模拟板子刚重启的固件状态。
  var acksEnable = true

  /// 模拟“运动还没跑完”：置位后 SET_POS 只记目标、不动位置，状态里报 moving=1。
  /// 用来验证长行程中途的看门狗保活 —— 没有它，`moving` 永远是 0，
  /// 保活分支就是一段测不到的代码。
  var holdMotion = Locked(false)

  init() throws { try sock.open() }
  deinit { sock.close() }

  var port: UInt16 { sock.localPort }
  var pos: Int32 {
    get { _pos.current }
    set { _pos.set(newValue) }
  }
  var enabled: Bool { _enabled.current }
  var microsteps: Int {
    get { _microsteps.current }
    set { _microsteps.set(newValue) }
  }
  var commands: [[UInt8]] { _commands.current }

  func stop() { running.set(false) }

  func start() {
    let stopAt = Date().addingTimeInterval(30)
    DispatchQueue(label: "fake-firmware").async { [weak self] in
      while let self, self.running.current, Date() < stopAt {
        while let r = self.sock.tryReceive() {
          self.handle(r.bytes, host: r.from, port: r.fromPort)
        }
        self.sock.waitReadable(timeout: 0.003)
      }
    }
  }

  func count(_ cmd: UInt8) -> Int {
    commands.filter { $0.count >= 12 && $0[1] == cmd }.count
  }

  func last(_ cmd: UInt8) -> FfPacket? {
    guard let raw = commands.last(where: { $0.count >= 12 && $0[1] == cmd }) else {
      return nil
    }
    return FfPacket.decode(raw)
  }

  private func handle(_ bytes: [UInt8], host: String, port: UInt16) {
    guard let p = FfPacket.decode(bytes) else { return }
    _commands.mutate { $0.append(bytes) }
    switch p.cmd {
    case kFfCalStart:
      if rejectStart {
        reply(calStatus(sequence: p.sequence, error: rejectStartError), to: host, port: port)
        return
      }
      if _calRun.current != p.sequence {
        _calRun.set(p.sequence)
        _calStage.set(1)
      }
      if dropCalStartReplies { return }
      if dropFirstStartReply {
        dropFirstStartReply = false
        return
      }
      reply(calStatus(sequence: p.sequence), to: host, port: port)
      return
    case kFfCalQuery:
      if dropCalQueries { return }
      if dropRunQueries && p.a != 0 { return }
      if p.a == Int32(_calRun.current) && p.a != 0 {
        _calStage.set(min(_calStage.current + 1, 5))
        if _calStage.current == 5 { _pos.set(8000); _target.set(8000) }
      }
      var response = calStatus(sequence: p.sequence)
      if wrongRunReplies > 0 && p.a != 0 {
        wrongRunReplies -= 1
        response[5] = _calRun.current &+ 1
      }
      reply(response, to: host, port: port)
      return
    case kFfCalCancel:
      if _calStage.current < 5 { _calStage.set(6); _enabled.set(false) }
      reply(calStatus(sequence: p.sequence), to: host, port: port)
      return
    case kFfEnable:
      if acksEnable { _enabled.set(p.a != 0) }
    case kFfJog:
      _target.set(_target.current + p.a)
      if !holdMotion.current { _pos.set(_pos.current + p.a) }
    case kFfSetPos:
      _target.set(p.a)
      if !holdMotion.current { _pos.set(p.a) }
    case kFfHome:
      _pos.set(0)
    case kFfTmcSet:
      if p.a == kTmcMicrosteps { _microsteps.set(Int(p.b)) }
    case kFfTmcQuery:
      reply(tmcDump(), to: host, port: port)
      return
    default:
      break
    }
    if dropStatusReplies { return }
    reply(status(sequence: p.sequence), to: host, port: port)
  }

  private func status(sequence: UInt8) -> [UInt8] {
    var flags = kFlagUartOk
    if _enabled.current { flags |= kFlagEnabled }
    // 固件只在“还差着步数”时报 MOVING，看门狗也只在 MOVING 时才可能刹停。
    let moving = holdMotion.current || _target.current != _pos.current
    if moving { flags |= kFlagMoving }
    return FfPacket(
      cmd: kFfStatus,
      sequence: sequence,
      flags: flags | (UInt8(kResultCompleted) << kFlagResultShift),
      a: _pos.current,
      b: _target.current
    ).encode()
  }

  private func calStatus(sequence: UInt8, error: UInt8 = 0) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 32)
    b[0] = kFfMagic; b[1] = kFfCalStatus
    b[2] = _calStage.current; b[3] = sequence
    b[4] = error; b[5] = _calRun.current
    b[6] = 60; b[7] = _calStage.current == 5 && !invalidateCalResult ? 1 : 0
    writeInt32LE(&b, 8, _pos.current)
    writeInt32LE(&b, 12, 8512)
    writeInt32LE(&b, 16, 0)
    writeInt32LE(&b, 20, 8000)
    writeUInt16LE(&b, 24, 100)
    writeUInt16LE(&b, 26, UInt16(_microsteps.current))
    return b
  }

  private func tmcDump() -> [UInt8] {
    var raw = [UInt8](repeating: 0, count: 22)
    raw[0] = kFfMagic
    raw[1] = kFfTmcDump
    raw[2] = 1
    raw[3] = 1
    writeUInt16LE(&raw, 4, 800)
    writeUInt16LE(&raw, 6, UInt16(_microsteps.current))
    raw[8] = 5
    raw[13] = 64
    writeUInt16LE(&raw, 18, 7)
    return raw
  }

  private func reply(_ bytes: [UInt8], to host: String, port: UInt16) {
    try? sock.send(bytes, to: host, port: port)
  }
}

/// 会话 + 假固件 + 临时镜头存档。
private final class Harness {
  let firmware: FakeFirmware
  let store: LensStore
  let session: FollowFocusSession
  let latest = Locked<FollowFocusState?>(nil)

  private let dir: URL

  init(memoNamespace: String = "ff-test-\(UUID().uuidString)") throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ff-session-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    firmware = try FakeFirmware()
    store = LensStore(directory: dir)
    // 每个用例一个独立命名空间：否则“记住上次板子”的用例会给别的用例留下存档。
    session = FollowFocusSession(store: store, memo: DeviceMemo(namespace: memoNamespace))
    session.onState = { [weak self] s in self?.latest.set(s) }
    session.link.useDevice(
      FfDiscovery(
        deviceId: "FF-TEST01", mac: "", kind: 1, protocolVersion: 1,
        udpPort: Int(firmware.port), fwMajor: 1, fwMinor: 0, fwPatch: 0,
        host: "127.0.0.1"
      )
    )
    firmware.start()
    session.start()
  }

  func stop() {
    session.stop()
    firmware.stop()
    try? FileManager.default.removeItem(at: dir)
  }
}

final class SessionTests: XCTestCase {
  private func prepareAuto(_ h: Harness) {
    h.session.selectDevice(FfDiscovery(deviceId: "FF-TEST01", mac: "", kind: 1,
      protocolVersion: 1, udpPort: Int(h.firmware.port), fwMajor: 1,
      fwMinor: 1, fwPatch: 0, host: "127.0.0.1"))
    h.session.createLens(name: "自动测试", params: "")
    h.session.connect()
    XCTAssertTrue(waitUntil { h.latest.current?.calSupported == true &&
      h.latest.current?.tmc?.rmsMa == 800 })
  }

  func testAutoCalibrationOldFirmwareIsGated() throws {
    let h = try Harness(); defer { h.stop() }
    h.session.createLens(name: "旧板子", params: "")
    h.session.connect()
    XCTAssertTrue(waitUntil { h.latest.current?.connected == true })
    h.session.startAutoCalibration(threshold: 60, maxRevs: 2)
    pump(0.2)
    XCTAssertEqual(h.firmware.count(kFfCalStart), 0)
  }

  func testAutoCalibrationCompletesInBothDirectionsWithoutHomeOrLimits() throws {
    for direction in [1, -1] {
      let h = try Harness(); defer { h.stop() }
      prepareAuto(h)
      let limitsBefore = h.firmware.count(kFfSetLimits)
      h.session.startAutoCalibration(threshold: 60, maxRevs: 2)
      XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
      XCTAssertEqual(h.latest.current?.calSafeSpan, 8000)
      XCTAssertEqual(h.firmware.count(kFfHome), 0)
      XCTAssertEqual(h.firmware.count(kFfSetLimits), limitsBefore)
      pump(2.3)
      XCTAssertTrue(h.latest.current?.calDirectionPending == true)
      h.session.setDir(direction)
      XCTAssertTrue(waitUntil { h.latest.current?.calDirectionPending == false })
      h.session.startFollow()
      XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })
      XCTAssertEqual(h.latest.current?.nearSteps, direction > 0 ? 0 : 8000)
      XCTAssertEqual(h.latest.current?.limitLo, 0)
      XCTAssertEqual(h.latest.current?.limitHi, 8000)
      XCTAssertEqual(h.firmware.count(kFfSetLimits), limitsBefore)
      XCTAssertEqual(h.store.lenses.first?.autoTravel, 8512)
      XCTAssertEqual(h.store.lenses.first?.autoRmsMa, 800)
    }
  }

  func testDroppedStartReplyUsesRunQueryAndCancelReleases() throws {
    let h = try Harness(); defer { h.stop() }
    h.firmware.dropFirstStartReply = true
    prepareAuto(h)
    h.session.startAutoCalibration(threshold: 60, maxRevs: 2)
    XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
    XCTAssertGreaterThan(h.firmware.count(kFfCalQuery), 1)
    h.session.cancelAutoCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "cancelled" })
    XCTAssertEqual(h.firmware.last(kFfEnable)?.a, 0)
    XCTAssertEqual(h.latest.current?.phase, .stroke)
  }

  func testRejectedStartUsesRequestSequenceEvenWithOldRun() throws {
    let h = try Harness(); defer { h.stop() }
    h.firmware.rejectStart = true
    prepareAuto(h)
    h.session.startAutoCalibration(threshold: 60, maxRevs: 2)
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "failed" })
    XCTAssertEqual(h.latest.current?.calError, 2)
    XCTAssertEqual(h.firmware.last(kFfEnable)?.a, 0)
  }

  /// §14：GPIO11 没接 DIAG 时，固件在运动前就用 `CAL_DIAG = 11` 拒绝启动。
  /// 解码器曾把 `error > 10` 整包丢掉，这条明确拒绝就变成 App 侧“没收到回包”，
  /// 3 秒后报成“标定保活超时，请检查连接” —— 把用户指向完全错误的方向。
  func testDiagRejectionIsReportedNotAsKeepaliveTimeout() throws {
    let h = try Harness(); defer { h.stop() }
    h.firmware.rejectStart = true
    h.firmware.rejectStartError = 11
    prepareAuto(h)
    h.session.startAutoCalibration(threshold: 60, maxRevs: 2)
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "failed" })
    XCTAssertEqual(h.latest.current?.calError, 11)
    XCTAssertTrue(
      h.latest.current?.msg.contains("DIAG") == true,
      "应报 DIAG 未接通，实际：\(h.latest.current?.msg ?? "")")
    XCTAssertEqual(h.firmware.last(kFfEnable)?.a, 0)
  }

  /// 还没发出 CAL_START 就没有回包（STOP/QUERY/ENABLE 都收不到）时，说的必须是
  /// “握手没回包”，不能复用保活超时那句。
  func testHandshakeTimeoutIsNotReportedAsKeepalive() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    h.firmware.dropStatusReplies = true
    h.session.startAutoCalibration(threshold: 60, maxRevs: 2)
    XCTAssertTrue(waitUntil(3) { h.latest.current?.calStage == "failed" })
    XCTAssertEqual(h.latest.current?.calError, 20)
    XCTAssertTrue(
      h.latest.current?.msg.contains("握手") == true,
      "应报握手超时，实际：\(h.latest.current?.msg ?? "")")
  }

  /// 握手成功、CAL_START 与带 run_id 的 CAL_QUERY 全部石沉大海：报“固件没有回应
  /// 标定命令”，同样不能报成保活超时（那会让人去查 Wi-Fi）。
  func testSilentFirmwareForCalStartIsReportedAsNoReply() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    h.firmware.dropCalStartReplies = true
    h.firmware.dropRunQueries = true
    h.session.startAutoCalibration(threshold: 60, maxRevs: 2)
    XCTAssertTrue(waitUntil(6) { h.latest.current?.calStage == "failed" })
    XCTAssertEqual(h.latest.current?.calError, 21)
    XCTAssertTrue(
      h.latest.current?.msg.contains("没有回应") == true,
      "应报固件没回应，实际：\(h.latest.current?.msg ?? "")")
  }

  /// 链路"看着连着、其实早掉了"必须能从快照看出来：socket 开着但没有状态回包时
  /// `linkAlive` 要变 false。旧版只有 `connected`（= socket bind 成功），
  /// 于是顶栏一直显示 `EN SLP UART`，把人指到错误方向。
  func testLinkAliveGoesStaleWhenStatusRepliesStop() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    XCTAssertTrue(waitUntil { h.latest.current?.linkAlive == true })
    h.firmware.dropStatusReplies = true
    XCTAssertTrue(
      waitUntil(4) { h.latest.current?.linkAlive == false },
      "没了状态回包就该判成失去回包")
    XCTAssertEqual(h.latest.current?.connected, true, "socket 还开着，两层含义不能混")
  }

  /// 存档本身要能原样读回（含端口和固件版本 —— 恢复后靠它判断 calSupported）。
  func testDeviceMemoRoundTripsThroughUserDefaults() {
    let ns = "ff-test-memo-\(UUID().uuidString)"
    defer { DeviceMemo(namespace: ns).clear() }
    let memo = DeviceMemo(namespace: ns)
    XCTAssertNil(memo.load(), "空命名空间不该有存档")
    memo.save(
      FfDiscovery(deviceId: "FF-MEMO", mac: "", kind: 1, protocolVersion: 1,
        udpPort: 4210, fwMajor: 1, fwMinor: 1, fwPatch: 3, host: "192.168.4.1"))
    XCTAssertEqual(memo.load()?.deviceId, "FF-MEMO")
    XCTAssertEqual(memo.load()?.host, "192.168.4.1")
    XCTAssertEqual(memo.load()?.udpPort, 4210)
    XCTAssertEqual(memo.load()?.fwPatch, 3)
    memo.clear()
    XCTAssertNil(memo.load())
  }

  /// 冷启动：上次选过的板子要能自动认回来并连上，不用重新扫描。
  func testSavedDeviceIsRestoredAndReconnected() throws {
    let ns = "ff-test-restore-\(UUID().uuidString)"
    defer { DeviceMemo(namespace: ns).clear() }

    let a = try Harness(memoNamespace: ns)
    defer { a.stop() }
    a.session.selectDevice(
      FfDiscovery(deviceId: "FF-MEMO", mac: "", kind: 1, protocolVersion: 1,
        udpPort: Int(a.firmware.port), fwMajor: 1, fwMinor: 1, fwPatch: 0,
        host: "127.0.0.1"))
    a.session.connect()
    XCTAssertTrue(waitUntil { a.latest.current?.linkAlive == true })

    // 第二个会话：不选设备，只带着同一份存档启动。
    let b = try Harness(memoNamespace: ns)
    defer { b.stop() }
    XCTAssertTrue(
      waitUntil(3) {
        b.latest.current?.deviceId == "FF-MEMO" && b.latest.current?.linkAlive == true
      },
      "应当自动认回 FF-MEMO 并收到状态回包（连的是 A 的假板子）；"
        + "device=\(b.latest.current?.deviceId ?? "nil") "
        + "connected=\(b.latest.current?.connected ?? false) "
        + "age=\(b.latest.current?.statusAgeMs.map(String.init) ?? "nil") "
        + "msg=\(b.latest.current?.msg ?? "")")
  }

  func testWrongRunIsIgnoredAndCancellationStopsRunningScan() throws {
    let h = try Harness(); defer { h.stop() }
    h.firmware.wrongRunReplies = 2
    prepareAuto(h)
    h.session.startAutoCalibration(threshold: 60, maxRevs: 2)
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "seek_negative" })
    h.session.cancelAutoCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "cancelled" })
    XCTAssertEqual(h.firmware.last(kFfEnable)?.a, 0)
    XCTAssertEqual(h.firmware.count(kFfSetPos), 0)
  }

  func testResultLossAndHomeInvalidatePosition() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    h.session.startAutoCalibration(threshold: 60, maxRevs: 2)
    XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
    h.firmware.invalidateCalResult = true
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "failed" })
    XCTAssertEqual(h.latest.current?.phase, .stroke)
    h.firmware.invalidateCalResult = false
    h.session.startAutoCalibration(threshold: 60, maxRevs: 2)
    XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
    h.session.setDir(1)
    XCTAssertTrue(waitUntil { h.latest.current?.calDirectionPending == false })
    h.session.homePressed()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .stroke })
    h.session.recalibrateStroke()
    XCTAssertTrue(waitUntil { h.latest.current?.strokeSteps == 0 })
    XCTAssertNil(h.store.lenses.first?.autoTravel)
  }

  func testLostStatusAfterFollowReleasesOldCoordinates() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    h.session.startAutoCalibration(threshold: 60, maxRevs: 2)
    XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
    h.session.setDir(-1)
    h.session.startFollow()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })
    h.firmware.dropStatusReplies = true
    XCTAssertTrue(waitUntil(3) { h.latest.current?.phase == .stroke })
    XCTAssertEqual(h.firmware.last(kFfEnable)?.a, 0)
  }
  /// 等条件成立。注意必须**泵主队列**：会话的 onState 派发到 main，
  /// 用 usleep 等的话主队列永远不排空，快照永远是 nil。
  private func waitUntil(
    _ timeout: TimeInterval = 3, _ condition: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      pump(0.01)
    }
    return condition()
  }

  /// 让时间流逝 [seconds] 秒，同时把主队列排空。
  private func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }


  // MARK: - 连接

  func testConnectAppliesSpeedLimitsStandbyAndEnable() throws {
    let h = try Harness()
    defer { h.stop() }

    h.session.connect()
    XCTAssertTrue(
      waitUntil { h.firmware.enabled }, "连接后应当使能，这样掉电重启能自愈")

    let speed = h.firmware.last(kFfSetSpeed)
    XCTAssertNotNil(speed, "必须下发速度，否则用固件里的旧值")
    XCTAssertEqual(
      speed?.a, 7680, "1.2 圈/秒 × 6400 步/圈，是物理速度换算出来的")
    XCTAssertEqual(
      h.firmware.last(kFfTmcSet)?.a, kTmcStandby, "连接时按开关设置待机断电")
    XCTAssertEqual(h.firmware.last(kFfSetLimits)?.a, -128000)
    XCTAssertEqual(
      h.firmware.last(kFfSetLimits)?.b, 128000,
      "未对齐时用和固件一致的 ±20 圈，好让标定阶段自由微调")
    XCTAssertGreaterThan(h.firmware.count(kFfQuery), 0, "要有状态轮询")
  }

  /// UI 现在直接显示快照里的圈数/速度上限，不再自己换算。
  /// 这些字段一旦算错，界面就会显示错的圈数和错的细分告警，所以钉住它们。
  func testSnapshotCarriesDerivedDisplayUnits() throws {
    let h = try Harness()
    defer { h.stop() }

    h.session.connect()
    XCTAssertTrue(waitUntil { h.latest.current?.connected == true })

    // 默认 1/16：6400 脉冲/圈，固件 40000 脉冲/秒上限 → 6.25 圈/秒。
    XCTAssertEqual(h.latest.current?.stepsPerRev, 6400)
    XCTAssertEqual(h.latest.current?.maxRevsPerSec ?? 0, 6.25, accuracy: 1e-9)
    XCTAssertEqual(h.latest.current?.posRevs ?? -1, 0, accuracy: 1e-9)

    // 换细分后两个派生值都要跟着变：脉冲/圈 ×16，上限 ÷16。
    h.session.setMicrosteps(256)
    XCTAssertTrue(waitUntil { h.latest.current?.microsteps == 256 })
    XCTAssertEqual(h.latest.current?.stepsPerRev, 102400)
    XCTAssertEqual(h.latest.current?.maxRevsPerSec ?? 0, 0.390625, accuracy: 1e-9)

    // 当前位置换算成圈也要跟着新细分走。
    h.session.jog(1024)
    XCTAssertTrue(waitUntil { h.latest.current?.pos == 1024 })
    XCTAssertEqual(h.latest.current?.posRevs ?? 0, 0.01, accuracy: 1e-9)
  }

  /// 看门狗保活：固件只把 `SET_POS`/`JOG` 当控制包（`motorNoteControlPacket`），
  /// `QUERY` 不算，静默 > 1 s 且还在 MOVING 就刹停。
  ///
  /// 所以“目标没变”不等于“不用发”：一次 > 1 s 的行程会在中途被刹掉，
  /// 表现就是“点了走一半就停”。这里用假固件的 `holdMotion` 把运动停在半路，
  /// 验证上位机会继续按 ≤ 400 ms 重发**同一个**目标。
  func testLongMoveKeepsFeedingTheWatchdog() throws {
    let h = try Harness()
    defer { h.stop() }

    h.session.connect()
    XCTAssertTrue(waitUntil { h.firmware.enabled })

    // 运动停在半路，等于一次走不完的长行程。
    h.firmware.holdMotion.set(true)
    h.session.setSlider(0.9)

    XCTAssertTrue(waitUntil { h.firmware.count(kFfSetPos) > 0 }, "滑条要发出第一个目标")
    let first = h.firmware.count(kFfSetPos)
    let target = h.firmware.last(kFfSetPos)?.a

    XCTAssertTrue(
      waitUntil(2) { h.firmware.count(kFfSetPos) > first },
      "长行程中途必须继续重发，否则固件 1 s 后就把电机刹停")
    XCTAssertEqual(
      h.firmware.last(kFfSetPos)?.a, target,
      "重发的必须是同一个目标：SET_POS 靠幂等保活，不是每次改目标")

    // 需要真的隔一段时间才重发，不能变成每 tick 都发（20ms 一次会白刷链路）。
    let afterBurst = h.firmware.count(kFfSetPos)
    pump(0.1)
    XCTAssertEqual(
      h.firmware.count(kFfSetPos), afterBurst,
      "重发间隔应当是几百毫秒级，不是每个 20ms tick 都发")

    // 运动结束（位置追上目标）后必须停止重发：不能一直往固件刷包。
    h.firmware.pos = target ?? 0
    h.firmware.holdMotion.set(false)
    XCTAssertTrue(waitUntil { h.latest.current?.moving == false }, "假固件应当报运动结束")
    let resting = h.firmware.count(kFfSetPos)
    pump(1.0)
    XCTAssertEqual(
      h.firmware.count(kFfSetPos), resting,
      "停稳之后不该再重发目标")
  }

  /// 停机闩锁必须能压住保活：点了“停”之后不能又被重发拉起来。
  func testKeepaliveDoesNotOverrideStopLatch() throws {
    let h = try Harness()
    defer { h.stop() }

    h.session.connect()
    XCTAssertTrue(waitUntil { h.firmware.enabled })

    h.firmware.holdMotion.set(true)
    h.session.setSlider(0.9)
    XCTAssertTrue(waitUntil { h.firmware.count(kFfSetPos) > 0 })

    h.session.stopPressed()
    pump(0.1)
    let stopped = h.firmware.count(kFfSetPos)
    pump(1.0)
    XCTAssertEqual(
      h.firmware.count(kFfSetPos), stopped,
      "停机之后保活不能把目标重新发出去")
  }

  func testMicrostepChangeRescalesSpeedAndLimits() throws {
    let h = try Harness()
    defer { h.stop() }
    h.session.connect()
    XCTAssertTrue(waitUntil { h.firmware.last(kFfSetLimits) != nil })

    // 板子改成 1/256：同样的物理行程需要 16 倍步数。
    h.firmware.microsteps = 256
    XCTAssertTrue(
      waitUntil {
        h.firmware.last(kFfSetLimits)?.b == 2048000
      }, "细分变了要按新尺度重新下发限位，否则行程被缩到 1/16")

    XCTAssertEqual(
      h.firmware.last(kFfSetSpeed)?.a, 40000, "1/256 下 1.2 圈/秒会超过 40k 步/秒上限，应被夹住")
    XCTAssertEqual(h.latest.current?.microsteps, 256)
    XCTAssertEqual(h.latest.current?.stepsPerRev, 102400)
  }

  // MARK: - 相位机

  func testPhaseWalksStrokeThenAlignThenFollow() throws {
    let h = try Harness()
    defer { h.stop() }
    h.session.connect()

    // 新镜头：还没标行程
    h.session.createLens(name: "50mm", params: "F1.4")
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .stroke })
    XCTAssertEqual(h.latest.current?.strokeSteps, 0)

    // 标行程：A 到 B 两点距离
    h.firmware.pos = 500
    XCTAssertTrue(waitUntil { h.latest.current?.pos == 500 })
    h.session.recordStrokeA()
    h.firmware.pos = 6900
    XCTAssertTrue(waitUntil { h.latest.current?.pos == 6900 })
    h.session.finishStroke()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .align })
    XCTAssertEqual(h.latest.current?.strokeSteps, 6400)

    // 对齐：确认最近点 + 选方向 → 跟焦
    h.firmware.pos = 1000
    XCTAssertTrue(waitUntil { h.latest.current?.pos == 1000 })
    h.session.confirmNear()
    h.session.setDir(1)
    h.session.startFollow()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })
    XCTAssertEqual(h.latest.current?.nearSteps, 1000)
    XCTAssertEqual(h.latest.current?.dir, 1)

    // 对齐后软限位只覆盖“最近点 → 远端”，绝不越过标定行程。
    XCTAssertTrue(
      waitUntil {
        h.firmware.last(kFfSetLimits)?.a == 1000
          && h.firmware.last(kFfSetLimits)?.b == 7400
      },
      "对齐后限位应当是 1000..7400，而不是默认的 ±128000")
  }

  func testReverseDirectionFlipsTheAlignedRange() throws {
    let h = try Harness()
    defer { h.stop() }
    h.store.upsert(Lens(id: "L", name: "50mm", strokeSteps: 6400, strokeMicrosteps: 16))
    h.session.selectLens(id: "L")
    h.session.connect()

    h.firmware.pos = 5000
    XCTAssertTrue(waitUntil { h.latest.current?.pos == 5000 })
    h.session.confirmNear()
    h.session.setDir(-1)
    h.session.startFollow()

    XCTAssertTrue(
      waitUntil {
        h.firmware.last(kFfSetLimits)?.a == -1400
          && h.firmware.last(kFfSetLimits)?.b == 5000
      }, "选反方向时限位应当是 -1400..5000")
  }

  // MARK: - 防误触 / 对齐失效

  func testUnalignRestoresFirmwareDefaultLimits() throws {
    let h = try Harness()
    defer { h.stop() }
    h.store.upsert(Lens(id: "L", name: "50mm", strokeSteps: 6400, strokeMicrosteps: 16))
    h.session.selectLens(id: "L")
    h.session.connect()
    h.firmware.pos = 1000
    XCTAssertTrue(waitUntil { h.latest.current?.pos == 1000 })
    h.session.confirmNear()
    h.session.setDir(1)
    h.session.startFollow()
    XCTAssertTrue(waitUntil { h.firmware.last(kFfSetLimits)?.a == 1000 })

    // 作废对齐必须真的把固件限位改回去：否则固件还留着上一轮对齐的窄区间，
    // 对齐阶段的“自由微调”会在旧边界被夹住，表现是微调不动。
    h.session.unalign()
    XCTAssertTrue(
      waitUntil {
        h.firmware.last(kFfSetLimits)?.a == -128000
          && h.firmware.last(kFfSetLimits)?.b == 128000
      }, "作废对齐要下发默认限位")
    XCTAssertNil(h.latest.current?.nearSteps)
    XCTAssertEqual(h.latest.current?.phase, .align)
  }

  func testHomeInvalidatesAlignment() throws {
    let h = try Harness()
    defer { h.stop() }
    h.store.upsert(Lens(id: "L", name: "50mm", strokeSteps: 6400, strokeMicrosteps: 16))
    h.session.selectLens(id: "L")
    h.session.connect()
    h.firmware.pos = 1000
    XCTAssertTrue(waitUntil { h.latest.current?.pos == 1000 })
    h.session.confirmNear()
    h.session.setDir(1)
    h.session.startFollow()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })

    // 软件置零后当前位置变 0，最近点参考失效。
    h.session.homePressed()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .align })
    XCTAssertNil(h.latest.current?.nearSteps)
    XCTAssertTrue(waitUntil { h.firmware.count(kFfHome) > 0 })
  }

  func testRecalibrateStrokeOnlyClearsTheStroke() throws {
    let h = try Harness()
    defer { h.stop() }
    h.store.upsert(Lens(id: "L", name: "50mm", strokeSteps: 6400, strokeMicrosteps: 16, dir: -1))
    h.session.selectLens(id: "L")
    h.session.connect()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .align })

    h.session.recalibrateStroke()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .stroke })
    XCTAssertEqual(h.latest.current?.strokeSteps, 0)
    // 方向是物理属性，清行程时不该一起丢掉。
    XCTAssertEqual(h.latest.current?.dir, -1)
  }

  // MARK: - JOG

  func testJogBeyondTheAlignedRangeIsRefused() throws {
    let h = try Harness()
    defer { h.stop() }
    h.store.upsert(Lens(id: "L", name: "50mm", strokeSteps: 6400, strokeMicrosteps: 16))
    h.session.selectLens(id: "L")
    h.session.connect()
    XCTAssertTrue(waitUntil { h.firmware.enabled })

    h.firmware.pos = 1000
    XCTAssertTrue(waitUntil { h.latest.current?.pos == 1000 })
    h.session.confirmNear()
    h.session.setDir(1)
    h.session.startFollow()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })

    let before = h.firmware.count(kFfJog)
    h.session.jog(10000)  // 远超 1000..7400
    pump(0.12)
    XCTAssertEqual(h.firmware.count(kFfJog), before, "超出软限位的 JOG 不能发出去")
    XCTAssertTrue(
      h.latest.current?.msg.contains("超出软限位") ?? false,
      "要被拒绝并说明原因，而不是静默不动")

    h.session.jog(100)
    XCTAssertTrue(waitUntil { h.firmware.count(kFfJog) > before }, "范围内的 JOG 要正常执行")
  }

  func testJogBeforeEnableIsHeldUntilTheBoardConfirms() throws {
    let h = try Harness()
    defer { h.stop() }
    // 板子刚重启：收到 ENABLE 也先回 enabled=0。
    h.firmware.acksEnable = false
    h.session.connect()
    XCTAssertTrue(waitUntil { h.firmware.count(kFfEnable) > 0 })
    XCTAssertFalse(h.firmware.enabled)

    h.session.jog(50)
    XCTAssertTrue(
      waitUntil { h.firmware.count(kFfEnable) > 1 }, "未使能时 JOG 要先补使能")
    XCTAssertEqual(h.firmware.count(kFfJog), 0, "还没确认使能就不该走步")

    // 固件开始正常上报使能后，暂存的 JOG 要补上。
    h.firmware.acksEnable = true
    XCTAssertTrue(
      waitUntil { h.firmware.count(kFfJog) > 0 }, "使能确认后要补发暂存的 JOG")
  }

  // MARK: - 自动跟焦

  /// 造一个已对齐、可自动跟焦的会话。
  private func makeFollowingHarness() throws -> Harness {
    let h = try Harness()
    let lut = LensLut(
      [
        LutPoint(meters: 1.0, steps: 0),
        LutPoint(meters: 2.0, steps: 3200),
        LutPoint(meters: 4.0, steps: 4800),
      ], microsteps: 16)
    h.store.upsert(
      Lens(id: "L", name: "50mm", lut: lut, strokeSteps: 6400, strokeMicrosteps: 16))
    try h.store.save()
    h.session.selectLens(id: "L")
    h.session.connect()
    _ = waitUntil { h.firmware.enabled }
    h.firmware.pos = 1000
    _ = waitUntil { h.latest.current?.pos == 1000 }
    h.session.confirmNear()
    h.session.setDir(1)
    h.session.startFollow()
    _ = waitUntil { h.latest.current?.phase == .follow }
    return h
  }

  /// 打开自动跟焦后必须能发出**第一个**目标。
  ///
  /// 这条是新加的，因为原 Dart 版把死区写成了
  /// `abs(want - (lastSent ?? want)) < 死区`：lastSent 为 nil 时恒等于 0，
  /// 于是每一个 tick 都被判成“没跨过死区”直接 return，自动跟焦一个目标都发不出去，
  /// 电机只会被手动滑条推动。这里把正确行为钉住。
  func testAutoFocusSendsTheFirstTargetBeforeAnythingWasSent() throws {
    let h = try makeFollowingHarness()
    defer { h.stop() }

    h.session.setAuto(true)
    XCTAssertTrue(waitUntil { h.latest.current?.auto == true })
    XCTAssertEqual(h.firmware.count(kFfSetPos), 0, "开自动之前不该有自动目标")

    h.session.ingest(distanceMeters: 2.0)
    XCTAssertTrue(
      waitUntil { h.firmware.count(kFfSetPos) > 0 },
      "没有任何已发目标时，第一个自动目标必须发出去")
    // 2.0m 在重锚后的表里是 4200 步，且落在 1000..7400 对2齐区间内。
    XCTAssertEqual(h.firmware.last(kFfSetPos)?.a, 4200)
  }

  func testAutoFocusHoldsInsideTheDeadbandButFollowsBigMoves() throws {
    let h = try makeFollowingHarness()
    defer { h.stop() }
    h.session.setAuto(true)
    XCTAssertTrue(waitUntil { h.latest.current?.auto == true })
    h.session.ingest(distanceMeters: 2.0)
    XCTAssertTrue(waitUntil { h.firmware.count(kFfSetPos) > 0 })
    let after = h.firmware.count(kFfSetPos)

    // 距离不变 → 目标不变 → 死区内不重发，否则电机一直小幅微动停不下来。
    pump(0.2)
    XCTAssertEqual(h.firmware.count(kFfSetPos), after, "同一目标不该反复重发")

    // 1mm 的抖动在 2m 处只有约 1.6 步，远小于死区：也不能重发。
    h.session.ingest(distanceMeters: 2.001)
    pump(0.2)
    XCTAssertEqual(h.firmware.count(kFfSetPos), after, "死区内的抖动不该驱动电机")

    // 0.5m 的真实移动必须跟上。
    pump(0.08)
    h.session.ingest(distanceMeters: 2.5)
    XCTAssertTrue(
      waitUntil { h.firmware.count(kFfSetPos) > after }, "超出死区的移动要跟上")
  }

  func testStopLatchesAndAutoFocusDoesNotTakeOverAgain() throws {
    let h = try makeFollowingHarness()
    defer { h.stop() }
    h.session.setAuto(true)
    h.session.ingest(distanceMeters: 2.0)
    XCTAssertTrue(waitUntil { h.firmware.count(kFfSetPos) > 0 })

    h.session.stopPressed()
    XCTAssertTrue(waitUntil { h.latest.current?.stopLatched == true })
    XCTAssertTrue(waitUntil { h.firmware.count(kFfStop) > 0 })
    let stopped = h.firmware.count(kFfSetPos)

    // 新的距离本来会产生新目标；停机闩锁期间不能重发。
    h.session.ingest(distanceMeters: 3.5)
    pump(0.25)
    XCTAssertEqual(
      h.firmware.count(kFfSetPos), stopped,
      "点停之后自动跟焦不能在下一个 tick 覆盖掉停机")
    XCTAssertEqual(h.latest.current?.auto, false, "手动介入要退出自动跟焦")
  }

  func testAutoFocusClampsTargetIntoTheAlignedRange() throws {
    let h = try makeFollowingHarness()
    defer { h.stop() }
    h.session.setAuto(true)
    XCTAssertTrue(waitUntil { h.latest.current?.auto == true })

    // 5 米超过表尾，查表会被夹到表尾；再夹进 1000..7400 的对齐区间。
    h.session.ingest(distanceMeters: 5.0)
    XCTAssertTrue(waitUntil { h.firmware.count(kFfSetPos) > 0 })
    let sent = h.firmware.last(kFfSetPos)?.a
    XCTAssertNotNil(sent)
    XCTAssertLessThanOrEqual(sent ?? 0, 7400, "自动目标不能越过行程上端")
    XCTAssertGreaterThanOrEqual(sent ?? 0, 1000, "自动目标不能低于最近点")
  }
}
