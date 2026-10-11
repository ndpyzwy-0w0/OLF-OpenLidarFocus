import XCTest

@testable import FollowFocusCore

/// 跨线程读一个变量的小盒子，避免测试里出现真实的数据竞争。
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
}

/// 假板子：在 loopback 上起一个 UDP socket，按收到的命令回包。
///
/// 覆盖真正的收发路径（bind、sendto、recvfrom、去重、超时），不需要硬件。
private final class FakeBoard {
  let sock = UdpSocket()
  /// 收到的命令：字节 + 来源 IP + 来源端口（回包要用）。
  var onCommand: (([UInt8], String, UInt16) -> Void)?

  private let running = Locked(true)

  init() throws { try sock.open() }

  deinit { sock.close() }

  var port: UInt16 { sock.localPort }

  func reply(_ bytes: [UInt8], to host: String, port: UInt16) {
    try? sock.send(bytes, to: host, port: port)
  }

  /// 后台泵收包，直到 [seconds] 秒后。
  func startPumping(for seconds: TimeInterval = 3) {
    let stop = Date().addingTimeInterval(seconds)
    DispatchQueue(label: "fake-board").async { [weak self] in
      while let self, self.running.current, Date() < stop {
        while let received = self.sock.tryReceive() {
          self.onCommand?(received.bytes, received.from, received.fromPort)
        }
        self.sock.waitReadable(timeout: 0.005)
      }
    }
  }

  func stop() { running.set(false) }
}

final class LinkTests: XCTestCase {
  private func waitUntil(
    _ timeout: TimeInterval = 2, _ condition: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      usleep(10_000)
    }
    return condition()
  }

  private func discovery(id: String, port: UInt16, host: String = "127.0.0.1")
    -> FfDiscovery
  {
    FfDiscovery(
      deviceId: id,
      mac: "",
      kind: 1,
      protocolVersion: 1,
      udpPort: Int(port),
      fwMajor: 1,
      fwMinor: 0,
      fwPatch: 0,
      host: host
    )
  }

  func testSequenceSkipsZero() {
    XCTAssertEqual(ffNextSequence(after: 0), 1)
    XCTAssertEqual(ffNextSequence(after: 1), 2)
    XCTAssertEqual(ffNextSequence(after: 254), 255)
    // 0 表示“没有请求”，必须跳过。
    XCTAssertEqual(ffNextSequence(after: 255), 1)
  }

  func testDiscoveryFindsABoardThatAnswersTheDiscoverPacket() throws {
    let board = try FakeBoard()
    defer { board.stop() }

    // 假板子：收到 0x0B 就回 32 字节发现回包。
    board.onCommand = { bytes, host, port in
      guard bytes.count >= 12, bytes[1] == kFfDiscover else { return }
      var reply = [UInt8](repeating: 0, count: 32)
      reply[0] = kFfMagic
      reply[1] = kFfDiscoverReply
      reply[2] = 1
      writeUInt16LE(&reply, 4, board.port)
      let id = "FF-TEST01"
      for (i, c) in id.utf8.enumerated() { reply[15 + i] = c }
      board.reply(reply, to: host, port: port)
    }
    board.startPumping()

    let found = try discoverBoards(
      targets: ["127.0.0.1"],
      port: board.port,
      timeout: 0.4,
      tries: 2
    )
    XCTAssertEqual(found.count, 1, "重复发包应收敛成一台")
    XCTAssertEqual(found.first?.deviceId, "FF-TEST01")
    XCTAssertEqual(found.first?.host, "127.0.0.1")
    XCTAssertEqual(found.first?.udpPort, Int(board.port))
  }

  func testDiscoveryReturnsEmptyWhenNobodyAnswers() throws {
    // 找一个没人监听的端口：先绑一个再关掉。
    let probe = try FakeBoard()
    let freePort = probe.port
    probe.stop()
    probe.sock.close()

    let found = try discoverBoards(
      targets: ["127.0.0.1"], port: freePort, timeout: 0.1, tries: 1)
    XCTAssertTrue(found.isEmpty)
  }

  func testUseDeviceTakesAddressAndPortFromTheDiscoveryReply() {
    var raw = [UInt8](repeating: 0, count: 32)
    raw[0] = kFfMagic
    raw[1] = kFfDiscoverReply
    writeUInt16LE(&raw, 4, 4321)
    guard let info = FfDiscovery.decode(raw, host: "192.168.5.9") else {
      return XCTFail("decode failed")
    }
    let link = MotorLink()
    XCTAssertNil(link.host, "连接目标不再有写死的默认值")
    link.useDevice(info)
    XCTAssertEqual(link.host, "192.168.5.9")
    XCTAssertEqual(link.port, 4321, "端口取固件上报值，不假设 4210")
  }

  func testLinkWithoutADeviceSendsNothing() {
    let link = MotorLink()
    // 没选设备时命令应当被静默丢弃，而不是崩或抛错。
    link.query()
    link.setPos(100)
    link.probe()
    XCTAssertFalse(link.isOpen)
    XCTAssertEqual(link.rxPackets, 0)
    XCTAssertEqual(link.probeTx, 0)
  }

  func testOpenBindsALocalPortAndQueryReachesTheBoard() throws {
    let board = try FakeBoard()
    defer { board.stop() }

    let seen = Locked<UInt8?>(nil)
    board.onCommand = { bytes, _, _ in
      guard bytes.count >= 12, bytes[1] == kFfQuery else { return }
      seen.set(bytes[3])
    }
    board.startPumping()

    let link = MotorLink()
    try link.open()
    defer { link.close() }
    XCTAssertTrue(link.isOpen)
    XCTAssertNotNil(link.localPort)

    link.useDevice(discovery(id: "FF-TEST01", port: board.port))
    link.query()
    XCTAssertTrue(waitUntil { seen.current != nil }, "板子应当收到 QUERY")
    XCTAssertEqual(seen.current, 1, "第一个请求的序号是 1，不是 0")
  }

  func testLinkDecodesStatusReplyForTheRequestSequence() throws {
    let board = try FakeBoard()
    defer { board.stop() }

    board.onCommand = { bytes, host, port in
      guard bytes.count >= 12, bytes[1] == kFfQuery else { return }
      // 回一条 STATUS，带上请求里的序号。
      let status = FfPacket(
        cmd: kFfStatus,
        sequence: bytes[3],
        flags: kFlagEnabled | kFlagCanOk
          | (UInt8(kResultCompleted) << kFlagResultShift),
        a: 1234,
        b: 1234
      )
      board.reply(status.encode(), to: host, port: port)
    }
    board.startPumping()

    let link = MotorLink()
    try link.open()
    defer { link.close() }
    let status = Locked<MotorStatus?>(nil)
    link.onStatus = { status.set($0) }
    link.useDevice(discovery(id: "FF-TEST01", port: board.port))

    link.query()
    XCTAssertTrue(waitUntil { status.current != nil }, "应当收到 STATUS")
    XCTAssertEqual(status.current?.pos, 1234)
    XCTAssertEqual(status.current?.target, 1234)
    XCTAssertEqual(status.current?.result, kResultCompleted)
    XCTAssertEqual(status.current?.sequence, 1, "回包里的序号应当被保留")
    XCTAssertGreaterThan(link.rxPackets, 0)
  }

  func testStatusV2IsReportedOnItsOwnCallback() throws {
    let board = try FakeBoard()
    defer { board.stop() }

    board.onCommand = { bytes, host, port in
      guard bytes.count >= 12, bytes[1] == kFfQuery else { return }
      var v2 = [UInt8](repeating: 0, count: 16)
      v2[0] = kFfMagic
      v2[1] = kFfStatusV2
      v2[2] = kFlagEnabled
      v2[3] = bytes[3]
      writeInt32LE(&v2, 4, 77)
      writeInt32LE(&v2, 8, 77)
      v2[12] = 1
      board.reply(v2, to: host, port: port)
    }
    board.startPumping()

    let link = MotorLink()
    try link.open()
    defer { link.close() }
    let v2 = Locked<MotorStatusV2?>(nil)
    let legacy = Locked<MotorStatus?>(nil)
    link.onStatusV2 = { v2.set($0) }
    link.onStatus = { legacy.set($0) }
    link.useDevice(discovery(id: "FF-TEST01", port: board.port))

    link.query()
    XCTAssertTrue(waitUntil { v2.current != nil }, "应当收到 STATUS_V2")
    XCTAssertEqual(v2.current?.pos, 77)
    XCTAssertTrue(v2.current?.positionTrusted ?? false)
    XCTAssertNil(legacy.current, "V2 回包不走 legacy 回调")
  }

  func testNonProtocolEchoMarksTheLinkAlive() throws {
    let board = try FakeBoard()
    defer { board.stop() }

    // 固件把非协议短报文原样回显。
    board.onCommand = { bytes, host, port in
      guard bytes.count < 12 else { return }
      board.reply(bytes, to: host, port: port)
    }
    board.startPumping()

    let link = MotorLink()
    try link.open()
    defer { link.close() }
    link.useDevice(discovery(id: "FF-TEST01", port: board.port))
    XCTAssertNil(link.lastEchoAt)

    link.probe()
    XCTAssertEqual(link.probeTx, 1)
    XCTAssertTrue(waitUntil { link.lastEchoAt != nil }, "回显应当把链路标记为通")
  }

  func testBadAddressIsReportedInsteadOfCrashing() throws {
    let link = MotorLink()
    try link.open()
    defer { link.close() }
    link.useDevice(discovery(id: "x", port: 4210, host: "not-an-ip"))
    let error = Locked<Error?>(nil)
    link.onSocketError = { error.set($0) }
    link.query()
    XCTAssertNotNil(error.current, "非法地址要报出来，而不是静默丢弃")
  }

  func testFm03DumpIsReported() throws {
    let board = try FakeBoard()
    defer { board.stop() }

    board.onCommand = { bytes, host, port in
      guard bytes.count >= 12, bytes[1] == kFfFm03Query else { return }
      var raw = [UInt8](repeating: 0, count: 26)
      raw[0] = kFfMagic
      raw[1] = kFfFm03Dump
      raw[2] = 1
      raw[3] = 3
      writeUInt16LE(&raw, 4, 900)
      writeUInt16LE(&raw, 6, 64)
      board.reply(raw, to: host, port: port)
    }
    board.startPumping()

    let link = MotorLink()
    try link.open()
    defer { link.close() }
    let dump = Locked<Fm03Dump?>(nil)
    link.onFm03 = { dump.set($0) }
    link.useDevice(discovery(id: "FF-TEST01", port: board.port))

    link.queryFm03()
    XCTAssertTrue(waitUntil { dump.current != nil }, "应当收到 TMC_DUMP")
    XCTAssertEqual(dump.current?.online, true)
    XCTAssertEqual(dump.current?.maxSpeed, 64)
  }
}
