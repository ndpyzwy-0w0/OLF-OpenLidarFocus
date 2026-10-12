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
  private let _microsteps = Locked(1)
  private let _commands = Locked<[[UInt8]]>([])
  private let _target = Locked<Int32>(0)
  private let _calRun = Locked<UInt8>(0)
  private let _calStage = Locked<UInt8>(0)
  private let _limits = Locked<(Int32, Int32)>((0,4096))
  var dropFirstCommands = Set<UInt8>()
  var dropFirstStartReply = false
  var rejectStart = false
  /// 拒绝 CAL_START 时回的错误码。固件的 `CAL_内部取消 = 11` 是最新加的一个。
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
  let holdCalibration = Locked(false)
  var dropHandshakeReplies = Set<UInt8>()
  var dropFirstRead = false

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
    if dropFirstCommands.remove(p.cmd) != nil { return }
    switch p.cmd {
    case kFfCalStart:
      if rejectStart {
        reply(calStatus(sequence: p.sequence, error: rejectStartError), to: host, port: port)
        return
      }
      if _calRun.current != p.sequence {
        _limits.set((0,4096))
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
      if p.a == 0 && dropFirstRead { dropFirstRead = false; return }
      if dropRunQueries && p.a != 0 { return }
      if p.a == Int32(_calRun.current) && p.a != 0 && !holdCalibration.current {
        _calStage.set(min(_calStage.current + 1, 5))
        if _calStage.current == 5 { _pos.set(3789); _target.set(3789) }
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
      if acksEnable {
        _enabled.set(p.a != 0)
        if p.a == 0 { holdMotion.set(false); _target.set(_pos.current) }
      }
    case kFfStop:
      _enabled.set(false); holdMotion.set(false); _target.set(_pos.current)
    case kFfSetLimits:
      _limits.set((p.a,p.b))
    case kFfJog:
      if _enabled.current {
        let target = min(max(_pos.current+p.a,_limits.current.0),_limits.current.1)
        _target.set(target)
        if !holdMotion.current { _pos.set(target) }
      }
    case kFfSetPos:
      if _enabled.current {
        motionFault=0
        let target = min(max(p.a,_limits.current.0),_limits.current.1)
        _target.set(target)
        if !holdMotion.current { _pos.set(target) }
      }
    case kFfHome:
      _pos.set(0)
    case kFfFm03Set:
      if !rejectsFm03 {
        switch p.a {
        case kFm03MaxSpeed: maxSpeed=UInt16(p.b)
        case kFm03Tolerance: fm03Tolerance=UInt16(p.b)
        case kFm03Gain: fm03Gain=UInt16(p.b)
        case kFm03Acceleration: fm03Acceleration=UInt16(p.b)
        default: break
        }
      }
      reply(fm03Dump(), to: host, port: port)
      return
    case kFfFm03Query:
      reply(fm03Dump(), to: host, port: port)
      return
    default:
      break
    }
    if dropStatusReplies || dropHandshakeReplies.remove(p.cmd) != nil { return }
    reply(status(sequence: p.sequence), to: host, port: port)
    if p.cmd==kFfQuery || p.cmd==kFfHome {
      var v=status(sequence:p.sequence);v[1]=kFfStatusV2
      v.append(contentsOf:[invalidateCalResult ? 0 : 1,motionFault,0,0]);reply(v,to:host,port:port)
    }
  }

  private func status(sequence: UInt8) -> [UInt8] {
    var flags = kFlagCanOk
    if _enabled.current { flags |= kFlagEnabled }
    // 固件只在“还差着步数”时报 MOVING，看门狗也只在 MOVING 时才可能刹停。
    let moving = holdMotion.current
    if moving { flags |= kFlagMoving }
    return FfPacket(
      cmd: kFfStatus,
      sequence: sequence,
      flags: flags | (UInt8(motionFault == 3 ? kResultRejected : kResultCompleted) << kFlagResultShift),
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
    writeInt32LE(&b, 12, 4096)
    writeInt32LE(&b, 16, 0)
    writeInt32LE(&b, 20, 4096)
    writeUInt16LE(&b, 24, 100)
    writeUInt16LE(&b, 26, UInt16(_microsteps.current))
    return b
  }

  var supportsAcceleration = false
  var maxSpeed: UInt16 = 64
  var fm03Tolerance: UInt16 = 4, fm03Gain: UInt16 = 4, fm03Acceleration: UInt16 = 8
  var rejectsFm03 = false
  var motionFault: UInt8 = 0

  private func fm03Dump() -> [UInt8] {
    var raw=[UInt8](repeating:0,count:26)
    raw[0]=kFfMagic;raw[1]=kFfFm03Dump;raw[2]=1;raw[3]=3
    writeUInt16LE(&raw,6,maxSpeed);writeUInt16LE(&raw,8,fm03Tolerance);writeUInt16LE(&raw,10,fm03Gain)
    if supportsAcceleration { raw += [0,0];writeUInt16LE(&raw,26,fm03Acceleration) }
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

  init(memoNamespace: String = "ff-test-\(UUID().uuidString)", selectDevice: Bool = true) throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ff-session-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    firmware = try FakeFirmware()
    store = LensStore(directory: dir)
    // 每个用例一个独立命名空间：否则“记住上次板子”的用例会给别的用例留下存档。
    session = FollowFocusSession(store: store, memo: DeviceMemo(namespace: memoNamespace))
    session.onState = { [weak self] s in self?.latest.set(s) }
    if selectDevice { session.selectDevice(
      FfDiscovery(
        deviceId: "FF-TEST01", mac: "", kind: 1, protocolVersion: 2,
        udpPort: Int(firmware.port), fwMajor: 2, fwMinor: 0, fwPatch: 0,
        host: "127.0.0.1"
      )
    )
    }
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
      protocolVersion: 2, udpPort: Int(h.firmware.port), fwMajor: 2,
      fwMinor: 1, fwPatch: 0, host: "127.0.0.1"))
    h.session.createLens(name: "自动测试", params: "")
    h.session.connect()
    XCTAssertTrue(waitUntil { h.latest.current?.calSupported == true &&
      h.latest.current?.fm03?.maxSpeed == 64 })
  }

  func testAutoCalibrationOldFirmwareIsGated() throws {
    let h=try Harness(); defer { h.stop() }
    h.session.selectDevice(FfDiscovery(deviceId:"OLD",mac:"",kind:1,protocolVersion:1,
      udpPort:Int(h.firmware.port),fwMajor:1,fwMinor:1,fwPatch:0,host:"127.0.0.1"))
    h.session.connect();pump(0.2)
    XCTAssertFalse(h.latest.current?.connected ?? true)
    XCTAssertEqual(h.firmware.count(kFfEnable),0)
  }

  func testAutoCalibrationCompletesInBothDirectionsWithoutHomeOrLimits() throws {
    for direction in [1, -1] {
      let h = try Harness(); defer { h.stop() }
      prepareAuto(h)
      let limitsBefore = h.firmware.count(kFfSetLimits)
      h.session.startAutoCalibration()
      XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
      XCTAssertEqual(h.latest.current?.calSafeSpan, 4096)
      XCTAssertEqual(h.firmware.count(kFfHome), 0)
      XCTAssertEqual(h.firmware.count(kFfSetLimits), limitsBefore)
      pump(2.3)
      XCTAssertTrue(h.latest.current?.calDirectionPending == true)
      h.session.setDir(direction)
      XCTAssertTrue(waitUntil { h.latest.current?.calDirectionPending == false })
      seedMap(h, direction: direction)
      h.session.startFollow()
      XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })
      XCTAssertEqual(h.latest.current?.nearSteps, direction > 0 ? 0 : 4096)
      XCTAssertEqual(h.latest.current?.limitLo, 0)
      XCTAssertEqual(h.latest.current?.limitHi, 4096)
      XCTAssertEqual(h.firmware.count(kFfSetLimits), limitsBefore)
      XCTAssertNil(h.store.lenses.first?.jsonObject["autoTravel"])
      XCTAssertTrue(h.store.lenses.first?.lut.ready == true)
    }
  }

  func testDroppedStartReplyUsesRunQueryAndCancelReleases() throws {
    let h = try Harness(); defer { h.stop() }
    h.firmware.dropFirstStartReply = true
    prepareAuto(h)
    h.session.startAutoCalibration()
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
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "failed" })
    XCTAssertEqual(h.latest.current?.calError, 2)
    XCTAssertEqual(h.firmware.last(kFfEnable)?.a, 0)
  }

  /// §14：GPIO11 没接 内部取消 时，固件在运动前就用 `CAL_内部取消 = 11` 拒绝启动。
  /// 解码器曾把 `error > 10` 整包丢掉，这条明确拒绝就变成 App 侧“没收到回包”，
  /// 3 秒后报成“标定保活超时，请检查连接” —— 把用户指向完全错误的方向。
  func testDiagRejectionIsReportedNotAsKeepaliveTimeout() throws {
    let h = try Harness(); defer { h.stop() }
    h.firmware.rejectStart = true
    h.firmware.rejectStartError = 11
    prepareAuto(h)
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "failed" })
    XCTAssertEqual(h.latest.current?.calError, 11)
    XCTAssertTrue(
      h.latest.current?.msg.contains("无法软件取消") == true,
      "应报 内部取消 未接通，实际：\(h.latest.current?.msg ?? "")")
    XCTAssertEqual(h.firmware.last(kFfEnable)?.a, 0)
  }

  /// 还没发出 CAL_START 就没有回包（STOP/QUERY/ENABLE 都收不到）时，说的必须是
  /// “握手没回包”，不能复用保活超时那句。
  func testHandshakeTimeoutIsNotReportedAsKeepalive() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    h.firmware.dropStatusReplies = true
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil(5) { h.latest.current?.calStage == "failed" })
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
    h.session.startAutoCalibration()
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
      FfDiscovery(deviceId: "FF-MEMO", mac: "", kind: 1, protocolVersion: 2,
        udpPort: 4210, fwMajor: 2, fwMinor: 1, fwPatch: 3, host: "192.168.4.1"))
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
      FfDiscovery(deviceId: "FF-MEMO", mac: "", kind: 1, protocolVersion: 2,
        udpPort: Int(a.firmware.port), fwMajor: 2, fwMinor: 1, fwPatch: 0,
        host: "127.0.0.1"))
    a.session.connect()
    XCTAssertTrue(waitUntil { a.latest.current?.linkAlive == true })

    // 第二个会话：不选设备，只带着同一份存档启动。
    let b = try Harness(memoNamespace: ns, selectDevice: false)
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
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "seek_negative" })
    h.session.cancelAutoCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "cancelled" })
    XCTAssertEqual(h.firmware.last(kFfEnable)?.a, 0)
    XCTAssertEqual(h.firmware.count(kFfSetPos), 0)
  }

  func testLongCalibrationKeepsPollingAndCalRepliesKeepLinkAlive() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    h.firmware.holdCalibration.set(true)
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "seek_negative" })
    let queries = h.firmware.count(kFfQuery)
    h.firmware.dropStatusReplies = true
    pump(1.8)
    XCTAssertGreaterThan(h.firmware.count(kFfQuery), queries)
    XCTAssertEqual(h.latest.current?.linkAlive, true)
    XCTAssertEqual(h.latest.current?.calStage, "seek_negative")
    h.firmware.dropStatusReplies = false
    h.firmware.holdCalibration.set(false)
    XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
  }

  func testLostHandshakeRepliesAreRetried() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    h.firmware.dropHandshakeReplies = [kFfStop, kFfQuery, kFfEnable]
    h.firmware.dropFirstRead = true
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil(6) { h.latest.current?.calDirectionPending == true })
    XCTAssertEqual(h.latest.current?.calError, 0)
    XCTAssertEqual(h.firmware.last(kFfEnable)?.a, 1)
  }

  func testBriefReplyLossPreservesCalibrationAndCompletedSetup() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    h.firmware.holdCalibration.set(true)
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "seek_negative" })
    h.firmware.dropRunQueries = true
    pump(1.4)
    XCTAssertEqual(h.latest.current?.calStage, "seek_negative")
    XCTAssertEqual(h.firmware.last(kFfEnable)?.a, 1)
    h.firmware.dropRunQueries = false
    h.firmware.holdCalibration.set(false)
    XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
    h.firmware.dropStatusReplies = true
    pump(0.8)
    XCTAssertEqual(h.latest.current?.phase, .align)
    XCTAssertEqual(h.firmware.last(kFfEnable)?.a, 1)
    h.firmware.dropStatusReplies = false
    XCTAssertTrue(waitUntil { (h.latest.current?.statusAgeMs ?? 9999) < 200 })
    XCTAssertEqual(h.latest.current?.phase, .align)
  }

  func testDelayedUntrustedReplyFromScanCannotEraseCompletedResult() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.calStage == "seek_negative" })
    let oldSequence = try XCTUnwrap(h.firmware.last(kFfQuery)?.sequence)
    XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
    let stale = MotorStatusV2(status: MotorStatus(sequence: oldSequence, pos: 0,
      target: 0, enabled: true, moving: false, canOk: true, limited: false,
      result: kResultStopped, positionTrusted: false))
    h.session.link.onStatusV2?(stale)
    pump(0.1)
    XCTAssertEqual(h.latest.current?.phase, .align)
    XCTAssertEqual(h.latest.current?.positionTrusted, true)
  }

  func testResultLossInvalidatesPositionAndResetDoesNotChangeMotorLimits() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
    h.firmware.invalidateCalResult = true
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .stroke })
    h.firmware.invalidateCalResult = false
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
    h.session.setDir(1)
    seedMap(h)
    let homes = h.firmware.count(kFfHome)
    let limits = h.firmware.count(kFfSetLimits)
    h.session.resetLensCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .align })
    XCTAssertTrue(h.store.lenses.first!.lut.points.isEmpty)
    XCTAssertEqual(h.latest.current?.calSafeSpan, 4096)
    XCTAssertEqual(h.firmware.count(kFfHome), homes)
    XCTAssertEqual(h.firmware.count(kFfSetLimits), limits)
  }

  func testLostStatusAfterFollowReleasesOldCoordinates() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
    h.session.setDir(-1)
    seedMap(h, direction: -1)
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

  func testConnectReadsSavedFm03SpeedWithoutOverwritingDevice() throws {
    let h=try Harness();defer { h.stop() }
    h.firmware.maxSpeed=128
    h.session.connect();XCTAssertTrue(waitUntil { h.firmware.enabled && h.latest.current?.fm03?.maxSpeed==128 })
    XCTAssertEqual(h.firmware.count(kFfSetSpeed),0)
    XCTAssertEqual(h.latest.current?.speedRevS ?? 0,128.0/4096,accuracy:1e-9)
    h.session.disconnect();h.session.connect()
    XCTAssertTrue(waitUntil { h.latest.current?.linkAlive==true })
    XCTAssertEqual(h.firmware.count(kFfSetSpeed),0)
    XCTAssertEqual(h.firmware.count(kFfSetLimits),0)
    XCTAssertEqual(h.firmware.count(kFfFm03Set),0)
    XCTAssertGreaterThan(h.firmware.count(kFfQuery),0)
  }

  /// UI 现在直接显示快照里的圈数/速度上限，不再自己换算。
  /// 这些字段一旦算错，界面就会显示错的圈数和错的细分告警，所以钉住它们。
  func testSnapshotCarriesNormalizedFm03Units() throws {
    let h=try Harness();defer { h.stop() }
    h.session.connect();XCTAssertTrue(waitUntil { h.latest.current?.connected==true })
    XCTAssertEqual(h.latest.current?.stepsPerRev,4096)
    XCTAssertEqual(h.latest.current?.maxRevsPerSec ?? 0,256.0/4096,accuracy:1e-9)
    h.session.setFm03(kFm03Tolerance,8)
    XCTAssertTrue(waitUntil { h.firmware.last(kFfFm03Set)?.b==8 })
    XCTAssertEqual(h.latest.current?.stepsPerRev,4096)
    prepareReady(h)
    h.firmware.pos = 0
    XCTAssertTrue(waitUntil { h.latest.current?.pos == 0 })
    h.session.jog(1024);XCTAssertTrue(waitUntil { h.latest.current?.pos==1024 })
    XCTAssertEqual(h.latest.current?.posRevs ?? 0,0.25,accuracy:1e-9)
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
    prepareReady(h)
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

    prepareReady(h)
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

  func testFm03ParameterValidationRejectsOutOfRange() throws {
    let h=try Harness();defer { h.stop() }
    h.session.connect();XCTAssertTrue(waitUntil { h.firmware.enabled })
    h.session.setFm03(kFm03MaxSpeed,257);h.session.setFm03(kFm03Tolerance,0)
    pump(0.2);XCTAssertEqual(h.firmware.count(kFfFm03Set),0)
    h.session.setFm03(kFm03Gain,16)
    XCTAssertTrue(waitUntil { h.firmware.last(kFfFm03Set)?.a==kFm03Gain })
  }

  // MARK: - 相位机

  func testNewLensWalksLimitsDirectionFivePointsThenFollow() throws {
    let h = try Harness(); defer { h.stop() }
    prepareAuto(h)
    XCTAssertEqual(h.session.snapshot().phase, .stroke)
    h.session.jog(80)
    pump(0.1)
    XCTAssertEqual(h.firmware.count(kFfJog), 0)
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil(4) { h.latest.current?.phase == .align })
    // 方向选择时可试转，不需要 HOME、记录 A/B 或最近点对齐。
    let before = h.firmware.count(kFfJog)
    h.session.jog(-80)
    XCTAssertTrue(waitUntil { h.firmware.count(kFfJog) > before })
    h.session.setDir(1)
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .calibrate })
    h.session.startFollow()
    pump(0.1)
    XCTAssertEqual(h.session.snapshot().phase, .calibrate)
    seedMap(h)
    h.session.startFollow()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })
    XCTAssertEqual(h.firmware.count(kFfHome), 0)
    XCTAssertEqual(h.firmware.count(kFfSetLimits), 0)
    XCTAssertEqual(h.latest.current?.lutCurve.count, 81)
  }

  func testManualCalibrationRejectsWrongDirectionAndMotion() throws {
    let h = try Harness(); defer { h.stop() }
    prepareReady(h)
    let id = h.store.lenses.first!.id
    h.firmware.pos = 500
    XCTAssertTrue(waitUntil { h.latest.current?.pos == 500 && h.latest.current?.moving == false })
    h.session.addLutPoint(meters: 6)
    pump(0.1)
    XCTAssertEqual(h.store.lenses.first { $0.id == id }!.lut.points.count, 5)
    XCTAssertTrue(h.session.snapshot().msg.contains("不一致"))
    h.firmware.holdMotion.set(true)
    XCTAssertTrue(waitUntil { h.latest.current?.moving == true })
    h.session.addLutPoint(meters: 10)
    pump(0.1)
    XCTAssertEqual(h.store.lenses.first!.lut.points.count, 5)
  }

  func testContinuingCalibrationPreservesFivePointsAndAddsNewEndpoints() throws {
    let h = try makeFollowingHarness(); defer { h.stop() }
    let original = h.store.lenses.first!.lut.points
    h.session.ingest(distanceMeters: 2)
    h.session.setAuto(true)
    XCTAssertTrue(waitUntil { h.firmware.last(kFfSetPos)?.a == 2000 })
    h.session.unalign()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .calibrate && h.latest.current?.auto == false })
    XCTAssertEqual(h.store.lenses.first!.lut.points, original)

    for (meters, coordinate) in [(0.3, 50), (6.0, 3900)] {
      h.firmware.pos = Int32(coordinate)
      XCTAssertTrue(waitUntil { h.latest.current?.pos == Int32(coordinate) && h.latest.current?.moving == false })
      let count = h.session.snapshot().lutPoints.count
      h.session.addLutPoint(meters: meters)
      XCTAssertTrue(waitUntil { h.latest.current?.lutPoints.count == count + 1 })
    }
    let lut = h.store.lenses.first!.lut
    XCTAssertEqual(lut.points.count, 7)
    XCTAssertTrue(original.allSatisfy { lut.points.contains($0) })
    XCTAssertTrue(lut.ready)
    XCTAssertEqual(lut.stepsFor(0.15), 50)
    XCTAssertEqual(lut.stepsFor(7), 3900)
    h.session.startFollow()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })
  }

  func testReverseDirectionKeepsNormalizedRangeAndPersistsRawCoordinates() throws {
    let h = try Harness(); defer { h.stop() }
    prepareReady(h, direction: -1)
    XCTAssertEqual(h.latest.current?.limitLo, 0)
    XCTAssertEqual(h.latest.current?.limitHi, 4096)
    XCTAssertTrue(h.store.lenses.first!.lut.matchesDirection(-1))
    h.session.startFollow()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })
    XCTAssertEqual(h.store.lenses.first!.lut.points.first!.steps, 3996)
    h.session.setDir(1)
    XCTAssertTrue(waitUntil { h.latest.current?.lutPoints.isEmpty == true })
    XCTAssertEqual(h.session.snapshot().phase, .calibrate)
  }

  func testReconnectionRequiresFreshLimitSearchButPreservesMap() throws {
    let h = try makeFollowingHarness(); defer { h.stop() }
    let original = h.store.lenses.first!
    h.session.disconnect()
    XCTAssertTrue(waitUntil { h.latest.current?.connected == false })
    h.session.connect()
    XCTAssertTrue(waitUntil { h.latest.current?.connected == true })
    XCTAssertEqual(h.session.snapshot().phase, .stroke)
    let before = h.firmware.count(kFfJog)
    h.session.jog(50)
    pump(0.1)
    XCTAssertEqual(h.firmware.count(kFfJog), before)
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil(4) { h.latest.current?.phase == .calibrate })
    XCTAssertEqual(h.store.lenses.first!, original)
    h.session.startFollow()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })
    XCTAssertEqual(h.store.lenses.first!, original, "不能平移持久化坐标表")
  }

  func testJogOutsideNormalizedRangeIsRefused() throws {
    let h = try Harness(); defer { h.stop() }
    prepareReady(h)
    let before = h.firmware.count(kFfJog)
    h.session.jog(10000)
    pump(0.1)
    XCTAssertEqual(h.firmware.count(kFfJog), before)
    XCTAssertTrue(h.session.snapshot().msg.contains("超出软限位"))
    h.session.jog(-80)
    XCTAssertTrue(waitUntil { h.firmware.count(kFfJog) > before })
  }

  private func prepareReady(_ h: Harness, direction: Int = 1) {
    prepareAuto(h)
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil(4) { h.latest.current?.calDirectionPending == true })
    h.session.setDir(direction)
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .calibrate })
    seedMap(h, direction: direction)
  }

  private func seedMap(_ h: Harness, direction: Int = 1) {
    for (meters, coordinate) in [(0.5, 100), (1.0, 800), (2.0, 2000), (3.0, 2800), (5.0, 3800)] {
      let pos = direction > 0 ? coordinate : 4096 - coordinate
      h.firmware.pos = Int32(pos)
      XCTAssertTrue(waitUntil { h.latest.current?.pos == Int32(pos) && h.latest.current?.moving == false })
      let count = h.session.snapshot().lutPoints.count
      h.session.addLutPoint(meters: meters)
      XCTAssertTrue(waitUntil { h.latest.current?.lutPoints.count == count + 1 })
    }
  }

  // MARK: - 自动跟焦

  /// 造一个已对齐、可自动跟焦的会话。
  private func makeFollowingHarness() throws -> Harness {
    let h = try Harness()
    prepareReady(h)
    h.session.startFollow()
    XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })
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

    XCTAssertEqual(h.firmware.count(kFfSetPos), 0, "开自动之前不该有自动目标")
    h.session.ingest(distanceMeters: 2.0)
    h.session.setAuto(true)
    XCTAssertTrue(waitUntil { h.latest.current?.auto == true })
    XCTAssertTrue(
      waitUntil { h.firmware.count(kFfSetPos) > 0 },
      "没有任何已发目标时，第一个自动目标必须发出去")
    // 2.0m 使用持久化原始坐标 2000，不做最近点重锚。
    XCTAssertEqual(h.firmware.last(kFfSetPos)?.a, 2000)
  }

  func testAutoFocusHoldsInsideTheDeadbandButFollowsBigMoves() throws {
    let h = try makeFollowingHarness()
    defer { h.stop() }
    h.session.ingest(distanceMeters: 2.0)
    h.session.setAuto(true)
    XCTAssertTrue(waitUntil { h.latest.current?.auto == true })
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
    h.session.ingest(distanceMeters: 2.5)
    XCTAssertTrue(
      waitUntil { h.firmware.count(kFfSetPos) > after }, "超出死区的移动要跟上")
  }

  func testStopLatchesAndAutoFocusDoesNotTakeOverAgain() throws {
    let h = try makeFollowingHarness()
    defer { h.stop() }
    h.session.ingest(distanceMeters: 2.0)
    h.session.setAuto(true)
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

  func testStopRejectsEveryMotionInputUntilExplicitReset() throws {
    let h=try makeFollowingHarness(); defer { h.stop() }
    h.session.ingest(distanceMeters:2)
    h.session.setAuto(true)
    XCTAssertTrue(waitUntil { h.firmware.count(kFfSetPos)>0 })
    h.session.stopPressed()
    XCTAssertTrue(waitUntil { h.latest.current?.stopLatched==true && !h.firmware.enabled })
    let sent=h.firmware.count(kFfSetPos), jogs=h.firmware.count(kFfJog)
    h.session.setSlider(0.95); h.session.jog(80); h.session.setAuto(true); h.session.enable(true)
    pump(1.1)
    XCTAssertEqual(h.firmware.count(kFfSetPos),sent)
    XCTAssertEqual(h.firmware.count(kFfJog),jogs)
    XCTAssertFalse(h.firmware.enabled)
    // An expired measurement must not release the latch.
    h.session.resumeControl();pump(0.1)
    XCTAssertTrue(h.latest.current?.stopLatched==true)
    h.session.ingest(distanceMeters:3)
    h.session.resumeControl()
    XCTAssertTrue(waitUntil { h.latest.current?.auto==true && h.firmware.enabled })
    XCTAssertTrue(waitUntil { h.firmware.count(kFfSetPos)>sent })
    XCTAssertEqual(h.firmware.last(kFfSetPos)?.a,2800)
  }

  func testStopRetriesLostStopAndDisableWithoutReenabling() throws {
    let h=try Harness();defer { h.stop() }
    prepareReady(h)
    XCTAssertTrue(waitUntil { h.firmware.enabled })
    h.firmware.holdMotion.set(true)
    h.session.setSlider(0.9)
    XCTAssertTrue(waitUntil { h.latest.current?.moving==true })
    h.firmware.dropFirstCommands=[kFfStop,kFfEnable]
    h.session.stopPressed()
    XCTAssertTrue(waitUntil { h.latest.current?.stopLatched==true && !h.firmware.enabled && h.latest.current?.moving==false })
    let enables=h.firmware.count(kFfEnable)
    pump(1.2)
    XCTAssertEqual(h.firmware.count(kFfEnable),enables)
    XCTAssertFalse(h.firmware.enabled)
    h.session.resumeControl()
    XCTAssertTrue(waitUntil { h.firmware.enabled && h.latest.current?.stopLatched==false })
  }

  private func prepareWheel(_ h: Harness) {
    h.session.setControlMode(.handwheel)
    h.session.connect()
    XCTAssertTrue(waitUntil { h.latest.current?.fm03 != nil })
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil(4) { h.latest.current?.wheelReady==true })
    XCTAssertNil(h.latest.current?.lensId)
    XCTAssertEqual(h.latest.current?.phase,.follow)
  }

  func testWheelCurvesAndRealtimeTargets() throws {
    XCTAssertEqual(WheelPullCurve.smooth.progress(0.25), 0.15625, accuracy: 1e-9)
    XCTAssertEqual(WheelPullCurve.linear.progress(0.25), 0.25, accuracy: 1e-9)
    for curve in [WheelPullCurve.smooth, .linear] {
      XCTAssertEqual(curve.progress(-1), 0)
      XCTAssertEqual(curve.progress(2), 1)
    }
    let h=try Harness();defer { h.stop() }
    prepareWheel(h)
    h.session.setWheelPoint("A")
    XCTAssertTrue(waitUntil { h.latest.current?.wheelA != nil })
    h.session.turnWheel(-0.25)
    XCTAssertTrue(waitUntil { h.latest.current?.pos==2765 })
    h.session.setWheelPullCurve(.linear)
    XCTAssertTrue(waitUntil { h.latest.current?.wheelPullCurve == .linear })
    h.session.pullWheelTo("A",duration:1)
    XCTAssertTrue(waitUntil { h.latest.current?.wheelPulling==true })
    // A running pull retains its selected curve even if the next pull's setting changes.
    h.session.setWheelPullCurve(.smooth)
    pump(0.2)
    let fraction=(h.session.snapshot().slider*4096-2765)/1024
    XCTAssertGreaterThan(fraction, 0.15)
    XCTAssertLessThan(fraction, 0.35)
    h.session.turnWheel(-0.01)
    XCTAssertTrue(waitUntil { h.latest.current?.wheelPulling==false })
    let before=h.firmware.count(kFfSetPos)
    for _ in 0..<8 { h.session.turnWheel(-0.005);pump(0.025) }
    XCTAssertGreaterThan(h.firmware.count(kFfSetPos)-before, 4,
      "手轮目标必须随20ms控制周期发送，不能被60ms限流延后")
  }

  func testWheelAccelerationRequiresSupportedFirmwareAndTunesInMotion() throws {
    let h=try Harness();defer { h.stop() }
    prepareWheel(h)
    h.session.setFm03(kFm03Acceleration,32)
    pump(0.1)
    XCTAssertEqual(h.firmware.count(kFfFm03Set),0)
    h.firmware.supportsAcceleration=true
    h.session.queryFm03()
    XCTAssertTrue(waitUntil { h.latest.current?.fm03?.acceleration==8 })
    h.session.setFm03(kFm03Acceleration,32)
    XCTAssertTrue(waitUntil { h.firmware.last(kFfFm03Set)?.a==kFm03Acceleration })
    XCTAssertEqual(h.firmware.last(kFfFm03Set)?.b,32)
    let before=h.firmware.count(kFfFm03Set)
    h.session.setFm03(kFm03Acceleration,65)
    h.firmware.holdMotion.set(true);h.session.turnWheel(-0.1)
    XCTAssertTrue(waitUntil { h.latest.current?.moving==true })
    h.session.setFm03(kFm03Acceleration,16)
    XCTAssertTrue(waitUntil { h.latest.current?.fm03?.acceleration==16 })
    XCTAssertEqual(h.firmware.count(kFfFm03Set),before+1)
    XCTAssertTrue(h.latest.current?.moving ?? false)
    XCTAssertTrue(h.session.snapshot().msg.contains("已确认"))
  }

  func testFailedWheelGoalIsTerminalAndNextTurnStartsAtActualPosition() throws {
    let h=try Harness();defer { h.stop() }
    prepareWheel(h)
    h.firmware.holdMotion.set(true);h.session.turnWheel(-0.1)
    XCTAssertTrue(waitUntil { h.latest.current?.moving==true })
    h.firmware.motionFault=3;h.firmware.holdMotion.set(false)
    XCTAssertTrue(waitUntil { h.latest.current?.msg.contains("拉焦未完成")==true })
    XCTAssertEqual(h.latest.current?.slider ?? 0,3789.0/4096,accuracy:1e-9)
    let count=h.firmware.count(kFfSetPos)
    pump(0.9)
    XCTAssertEqual(h.firmware.count(kFfSetPos),count,"失败目标不能被保活重启")
    h.session.turnWheel(-0.01)
    XCTAssertTrue(waitUntil { h.latest.current?.pos==3748 })
  }

  func testFm03TuningRetriesLossAndOnlyConfirmsDeviceReadback() throws {
    let h=try Harness();defer { h.stop() }
    prepareWheel(h)
    h.firmware.holdMotion.set(true);h.session.turnWheel(-0.1)
    XCTAssertTrue(waitUntil { h.latest.current?.moving==true })
    h.firmware.dropFirstCommands=[kFfFm03Set]
    h.session.setFm03(kFm03MaxSpeed,128)
    XCTAssertTrue(waitUntil { h.latest.current?.fm03?.maxSpeed==128 })
    XCTAssertGreaterThanOrEqual(h.firmware.count(kFfFm03Set),2)
    XCTAssertTrue(h.session.snapshot().msg.contains("已确认电机速度：128"))
    let count=h.firmware.count(kFfFm03Set)
    pump(0.6)
    XCTAssertEqual(h.firmware.count(kFfFm03Set),count,"确认后停止重试")
    h.firmware.rejectsFm03=true
    h.session.setFm03(kFm03Gain,2)
    XCTAssertTrue(waitUntil(3) { h.latest.current?.msg.contains("未获设备确认")==true })
    XCTAssertEqual(h.latest.current?.fm03?.gain,4,"不能用本地乐观值冒充设备已应用")
    let rejected=h.firmware.count(kFfFm03Set)
    pump(0.6)
    XCTAssertEqual(h.firmware.count(kFfFm03Set),rejected,"超时后停止重试")
  }

  func testWheelCalibratesWithoutLensAndMapsRelativeTurns() throws {
    let h=try Harness();defer { h.stop() }
    prepareWheel(h)
    h.session.turnWheel(-0.25)
    XCTAssertTrue(waitUntil { h.latest.current?.pos==2765 })
    h.session.setWheelSensitivity(0.25)
    h.session.setWheelReversed(true)
    h.session.turnWheel(0.25)
    XCTAssertTrue(waitUntil { h.latest.current?.pos==2509 })
    h.session.ingest(distanceMeters:1);h.session.setAuto(true);pump(0.1)
    XCTAssertFalse(h.latest.current?.auto ?? true)
    let count=h.firmware.count(kFfSetPos)
    h.session.turnWheel(.nan);h.session.turnWheel(100);pump(0.1)
    XCTAssertEqual(h.firmware.count(kFfSetPos),count)
  }

  func testWheelSliderUsesAbsolutePositionAndTakesOverTimedPull() throws {
    let h=try Harness();defer { h.stop() }
    prepareWheel(h)
    h.session.setWheelPoint("A")
    XCTAssertTrue(waitUntil { h.latest.current?.wheelA==3789 })
    h.session.setWheelSensitivity(0.25);h.session.setWheelReversed(true)
    h.session.setSlider(0.5)
    XCTAssertTrue(waitUntil { h.latest.current?.pos==2048 }, "滑块是绝对坐标，不受手轮旋转灵敏度/反转影响")
    h.session.setWheelPoint("B")
    XCTAssertTrue(waitUntil { h.latest.current?.wheelB==2048 })
    h.session.setWheelRange(true)
    XCTAssertTrue(waitUntil { h.latest.current?.wheelRangeEnabled==true })
    h.session.pullWheelTo("A",duration:2)
    XCTAssertTrue(waitUntil { h.latest.current?.wheelPulling==true })
    h.session.setSlider(0)
    XCTAssertTrue(waitUntil { h.latest.current?.wheelPulling==false && h.latest.current?.pos==2048 })
    h.session.setSlider(1)
    XCTAssertTrue(waitUntil { h.latest.current?.pos==3789 })
    h.session.turnWheel(0.1)
    XCTAssertTrue(waitUntil { h.latest.current?.pos==3687 }, "切回手轮从滑块目标继续")
    h.session.stopPressed()
    XCTAssertTrue(waitUntil { h.latest.current?.stopLatched==true && !h.firmware.enabled })
    let count=h.firmware.count(kFfSetPos)
    h.session.setSlider(0.6);h.session.setSlider(.nan);pump(0.2)
    XCTAssertEqual(h.firmware.count(kFfSetPos),count)
    h.session.resumeControl()
    XCTAssertTrue(waitUntil { h.latest.current?.wheelReady==true })
    pump(0.3)
    XCTAssertEqual(h.firmware.count(kFfSetPos),count,"复位不恢复滑块旧目标")
    h.session.setSlider(0.6)
    XCTAssertTrue(waitUntil { h.latest.current?.pos==2458 })
  }

  func testWheelSliderRejectsInputWithoutReadyFeedback() throws {
    let h=try Harness();defer { h.stop() }
    h.session.setControlMode(.handwheel);h.session.connect();pump(0.2)
    h.session.setSlider(0.2);pump(0.1)
    XCTAssertEqual(h.firmware.count(kFfSetPos),0)
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.calStage=="seek_negative" })
    h.session.setSlider(0.6);pump(0.1)
    XCTAssertEqual(h.firmware.count(kFfSetPos),0)
  }

  func testWheelABLimitsAndArrivalRequireActualFeedback() throws {
    let h=try Harness();defer { h.stop() }
    prepareWheel(h)
    h.session.setWheelPoint("A")
    XCTAssertTrue(waitUntil { h.latest.current?.wheelA==3789 })
    h.session.turnWheel(-0.25)
    XCTAssertTrue(waitUntil { h.latest.current?.pos==2765 })
    h.session.setWheelPoint("B")
    XCTAssertTrue(waitUntil { h.latest.current?.wheelB==2765 })
    h.session.setWheelRange(true)
    XCTAssertTrue(waitUntil { h.latest.current?.wheelRangeEnabled==true })
    XCTAssertEqual(h.firmware.last(kFfSetLimits)?.a,2765)
    XCTAssertEqual(h.firmware.last(kFfSetLimits)?.b,3789)
    h.firmware.holdMotion.set(true)
    h.session.pullWheelTo("A",duration:0)
    XCTAssertTrue(waitUntil { h.latest.current?.moving==true && h.firmware.last(kFfSetPos)?.a==3789 })
    let sequence=h.session.snapshot().wheelArrivalSequence
    pump(0.3)
    XCTAssertEqual(h.session.snapshot().wheelArrivalSequence,sequence)
    h.session.setWheelPoint("B");pump(0.1)
    XCTAssertEqual(h.session.snapshot().wheelB,2765,"不能记录运动中位置")
    h.firmware.pos=3789;h.firmware.holdMotion.set(false)
    XCTAssertTrue(waitUntil { h.latest.current?.wheelArrivalSequence==sequence+1 })
    XCTAssertEqual(h.latest.current?.wheelArrival,"A")
    h.session.turnWheel(0.25)
    XCTAssertTrue(waitUntil { h.firmware.last(kFfSetPos)?.a==3789 })
    h.session.turnWheel(-0.5)
    XCTAssertTrue(waitUntil { h.latest.current?.pos==2765 })
    h.session.clearWheelPoints()
    XCTAssertTrue(waitUntil { h.latest.current?.wheelA==nil && h.latest.current?.wheelRangeEnabled==false })
    XCTAssertEqual(h.firmware.last(kFfSetLimits)?.b,4096)
    h.session.disconnect()
    XCTAssertTrue(waitUntil { h.latest.current?.wheelReady==false })
  }

  func testTimedWheelPullStopsAndDoesNotResumeOldTarget() throws {
    let h=try Harness();defer { h.stop() }
    prepareWheel(h)
    h.session.setWheelPoint("A")
    XCTAssertTrue(waitUntil { h.latest.current?.wheelA != nil })
    h.session.turnWheel(-0.25)
    XCTAssertTrue(waitUntil { h.latest.current?.pos==2765 })
    h.session.setWheelPoint("B")
    XCTAssertTrue(waitUntil { h.latest.current?.wheelB != nil })
    h.session.pullWheelTo("A",duration:1)
    XCTAssertTrue(waitUntil { h.latest.current?.wheelPulling==true })
    XCTAssertTrue(waitUntil { h.firmware.last(kFfSetPos)?.a ?? 0 > 2765 })
    h.session.stopPressed()
    XCTAssertTrue(waitUntil { h.latest.current?.stopLatched==true && !h.firmware.enabled })
    let count=h.firmware.count(kFfSetPos)
    h.session.turnWheel(0.1);h.session.pullWheelTo("B",duration:0)
    pump(1.1)
    XCTAssertEqual(h.firmware.count(kFfSetPos),count)
    XCTAssertFalse(h.latest.current?.wheelPulling ?? true)
    h.session.resumeControl()
    XCTAssertTrue(waitUntil { h.latest.current?.wheelReady==true })
    pump(0.5)
    XCTAssertEqual(h.firmware.count(kFfSetPos),count)
    h.session.turnWheel(-0.01)
    XCTAssertTrue(waitUntil { h.firmware.count(kFfSetPos)>count })
    h.session.startAutoCalibration()
    XCTAssertTrue(waitUntil { h.latest.current?.wheelA==nil && h.latest.current?.wheelB==nil })
  }

  func testAutoFocusUsesNearestAndFarthestCalibratedPointsInBothDirections() throws {
    for direction in [1, -1] {
      let h = try Harness()
      defer { h.stop() }
      prepareReady(h, direction: direction)
      h.session.startFollow()
      XCTAssertTrue(waitUntil { h.latest.current?.phase == .follow })
      for (meters, coordinate) in [(0.15, 100), (5.5, 3800)] {
        h.session.setAuto(false)
        h.session.ingest(distanceMeters: nil)
        h.session.ingest(distanceMeters: meters)
        let before = h.firmware.count(kFfSetPos)
        h.session.setAuto(true)
        XCTAssertTrue(waitUntil { h.firmware.count(kFfSetPos) > before })
        let expected = direction > 0 ? coordinate : 4096 - coordinate
        XCTAssertEqual(h.firmware.last(kFfSetPos)?.a, Int32(expected),
          "范围外测距应驱动到对应标定端点，而非机械行程两端")
      }
    }
  }
  func testStaleLidarStopsAutoAndCannotRecordOldDistance() throws {
    let h = try makeFollowingHarness(); defer { h.stop() }
    h.session.ingest(distanceMeters: 2)
    h.session.setAuto(true)
    XCTAssertTrue(waitUntil { h.firmware.count(kFfSetPos) > 0 })
    XCTAssertTrue(waitUntil { h.latest.current?.auto == false && h.latest.current?.distanceM == nil })
    let count = h.store.lenses.first!.lut.points.count
    h.session.addLutPoint()
    pump(0.1)
    XCTAssertEqual(h.store.lenses.first!.lut.points.count, count)
    XCTAssertTrue(h.session.snapshot().msg.contains("有效物距"))
  }

}
