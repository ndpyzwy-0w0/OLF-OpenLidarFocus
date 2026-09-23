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

  /// 关掉时，即使收到 ENABLE 也继续回 enabled=0，用来模拟板子刚重启的固件状态。
  var acksEnable = true

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
    case kFfEnable:
      if acksEnable { _enabled.set(p.a != 0) }
    case kFfJog:
      _pos.set(_pos.current + p.a)
    case kFfSetPos:
      _pos.set(p.a)
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
    reply(status(sequence: p.sequence), to: host, port: port)
  }

  private func status(sequence: UInt8) -> [UInt8] {
    var flags = kFlagUartOk
    if _enabled.current { flags |= kFlagEnabled }
    return FfPacket(
      cmd: kFfStatus,
      sequence: sequence,
      flags: flags | (UInt8(kResultCompleted) << kFlagResultShift),
      a: _pos.current,
      b: _pos.current
    ).encode()
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

  init() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ff-session-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    firmware = try FakeFirmware()
    store = LensStore(directory: dir)
    session = FollowFocusSession(store: store)
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
