import Foundation

/// 控制链路：往已选定的板子发命令，收状态回包。
///
/// 这里是**唯一**发 UDP 控制包的地方；会话层（`FollowFocusSession`）只管
/// “什么时机发什么”，不碰 socket。
///
/// 注意 UDP 从不验证对端：`isOpen` 只代表本地 bind 成功，连通性要靠
/// [probeTx] / [lastEchoAt] 的回显判断（固件把非协议包原样回显）。
public final class MotorLink {
  /// 控制目标，由发现结果填充（[useDevice]）。为 nil 表示还没选设备。
  ///
  /// 不写死 `192.168.4.1`：板子的地址来自回包源地址，端口来自回包里的 `udp_port`。
  public private(set) var host: String?
  public private(set) var port: UInt16 = kFfDefaultPort

  /// 收到的数据包总数（含固件回显），用于和发送数对比判断收发方向。
  public private(set) var rxPackets = 0

  /// 最近一次收到固件原样回显的非协议包（链路探测）。
  public private(set) var lastEchoAt: Date?

  /// 探测包发送次数。
  public private(set) var probeTx = 0

  public var onStatus: ((MotorStatus) -> Void)?
  public var onStatusV2: ((MotorStatusV2) -> Void)?
  public var onFm03: ((Fm03Dump) -> Void)?
  public var onCalStatus: ((CalStatus) -> Void)?
  public var onSent: ((UInt8) -> Void)?
  public var onSocketError: ((Error) -> Void)?

  private var sock: UdpSocket?
  private var nextSequence: UInt8 = 0

  public init() {}

  public var isOpen: Bool { sock != nil }
  public var localPort: UInt16? { sock?.localPort }
  public var lastSequence: UInt8 { nextSequence }

  public func useDevice(_ d: FfDiscovery) {
    host = d.host
    port = UInt16(clamping: d.udpPort)
  }

  public func open() throws {
    close()
    nextSequence = 0
    rxPackets = 0
    probeTx = 0
    lastEchoAt = nil
    let s = UdpSocket()
    s.onPacket = { [weak self] bytes, _ in self?.handle(bytes) }
    s.onError = { [weak self] e in self?.onSocketError?(e) }
    try s.open()
    s.startReceiving()
    sock = s
  }

  public func close() {
    sock?.close()
    sock = nil
  }

  /// 固件会把非协议短报文原样回显，用来判断链路是否双向通。
  ///
  /// 长度必须 < 12 且首字节不是 0x46，否则会被固件当成普通协议包。
  public func probe() {
    guard let target = host, let sock else { return }
    probeTx += 1
    do {
      try sock.send([0xAB, 0xCD], to: target, port: port)
    } catch {
      onSocketError?(error)
    }
  }

  // MARK: - 命令

  public func setPos(_ steps: Int32) { send(FfPacket(cmd: kFfSetPos, a: steps)) }
  public func home() { send(FfPacket(cmd: kFfHome)) }
  public func jog(_ delta: Int32) { send(FfPacket(cmd: kFfJog, a: delta)) }
  @discardableResult public func stop() -> UInt8 { send(FfPacket(cmd: kFfStop)) }
  @discardableResult public func enable(_ on: Bool) -> UInt8 { send(FfPacket(cmd: kFfEnable, a: on ? 1 : 0)) }
  public func setLimits(_ min: Int32, _ max: Int32) {
    send(FfPacket(cmd: kFfSetLimits, a: min, b: max))
  }
  public func setSpeed(_ hz: Int32, _ accel: Int32) {
    send(FfPacket(cmd: kFfSetSpeed, a: hz, b: accel))
  }
  @discardableResult public func query() -> UInt8 { send(FfPacket(cmd: kFfQuery)) }
  public func queryFm03() { send(FfPacket(cmd: kFfFm03Query)) }
  public func setFm03(_ key: Int32, _ value: Int32) {
    send(FfPacket(cmd: kFfFm03Set, a: key, b: value))
  }
  public func calStart(runId: UInt8, threshold: Int32, maxSteps: Int32) {
    send(FfPacket(cmd: kFfCalStart, sequence: runId, a: threshold, b: maxSteps),
      sequence: runId)
  }
  @discardableResult public func calQuery(runId: UInt8) -> UInt8 {
    send(FfPacket(cmd: kFfCalQuery, a: Int32(runId)))
  }
  @discardableResult public func calCancel() -> UInt8 {
    send(FfPacket(cmd: kFfCalCancel))
  }

  // MARK: - 内部

  @discardableResult private func send(_ p: FfPacket, sequence: UInt8? = nil) -> UInt8 {
    guard let target = host, let sock else { return 0 }
    let seq = sequence ?? ffNextSequence(after: nextSequence)
    nextSequence = seq
    do {
      try sock.send(
        FfPacket(cmd: p.cmd, sequence: seq, flags: p.flags, a: p.a, b: p.b).encode(),
        to: target,
        port: port
      )
      onSent?(seq)
    } catch {
      onSocketError?(error)
    }
    return seq
  }

  private func handle(_ bytes: [UInt8]) {
    rxPackets += 1
    guard bytes.count >= 12, bytes[0] == kFfMagic else {
      lastEchoAt = Date()
      return
    }
    switch bytes[1] {
    case kFfCalStatus:
      if let c = CalStatus.decode(bytes) { onCalStatus?(c) }
    case kFfFm03Dump:
      if let t = Fm03Dump.decode(bytes) { onFm03?(t) }
    case kFfStatusV2:
      if let s = MotorStatusV2.decode(bytes) { onStatusV2?(s) }
    case kFfStatus:
      if let p = FfPacket.decode(bytes) { onStatus?(MotorStatus(packet: p)) }
    default:
      break
    }
  }
}
