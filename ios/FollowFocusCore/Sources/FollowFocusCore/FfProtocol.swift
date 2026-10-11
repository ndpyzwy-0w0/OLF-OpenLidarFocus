import Foundation

// MARK: - Wire 常量
//
// 命名刻意保持 Dart/固件侧的 `kXxx` 风格，方便和 PROTOCOL.md、
// `firmware/include/protocol.h` 逐条对照。
// 协议只认 PROTOCOL.md：改字段/位定义时先改文档。

/// 所有协议包的第一个字节。
public let kFfMagic: UInt8 = 0x46

public let kFfSetPos: UInt8 = 0x01
public let kFfJog: UInt8 = 0x02
public let kFfStop: UInt8 = 0x03
public let kFfEnable: UInt8 = 0x04
public let kFfSetLimits: UInt8 = 0x05
public let kFfQuery: UInt8 = 0x06
public let kFfSetSpeed: UInt8 = 0x07
public let kFfFm03Query: UInt8 = 0x10
public let kFfFm03Set: UInt8 = 0x11
public let kFfHome: UInt8 = 0x0A
public let kFfDiscover: UInt8 = 0x0B
public let kFfCalStart: UInt8 = 0x0C
public let kFfCalQuery: UInt8 = 0x0D
public let kFfCalCancel: UInt8 = 0x0E
public let kFfStatus: UInt8 = 0x81
public let kFfFm03Dump: UInt8 = 0x86
public let kFfStatusV2: UInt8 = 0x83
public let kFfDiscoverReply: UInt8 = 0x84
public let kFfCalStatus: UInt8 = 0x85

public struct CalStatus: Equatable {
  public let state: UInt8
  public let sequence: UInt8
  public let error: UInt8
  public let runId: UInt8
  public let threshold: UInt8
  public let valid: Bool
  public let pos: Int32
  public let travel: Int32
  public let safeMin: Int32
  public let safeMax: Int32
  public let sg: UInt16
  public let microsteps: UInt16
  public let elapsedMs: UInt32

  /// **不要给 `error` 设上界。** 固件的错误码表会加长：`CAL_DIAG = 11` 就被曾经的
  /// `b[4] <= 10` 整包丢掉，于是“DIAG 未接通”这条明确拒绝变成一次静默超时，
  /// 界面只能报“标定保活超时，请检查连接”，把用户指向完全错误的方向。
  /// 未知码由 `FollowFocusSession` 的文案表兜底成“未知错误 N”。
  /// `state` 仍要卡上界：它在会话里直接当数组下标用。
  public static func decode(_ b: [UInt8]) -> CalStatus? {
    guard b.count == 32, b[0] == kFfMagic, b[1] == kFfCalStatus,
      b[2] <= 7, b[7] <= 1 else { return nil }
    return CalStatus(state: b[2], sequence: b[3], error: b[4], runId: b[5],
      threshold: b[6], valid: b[7] == 1, pos: readInt32LE(b, 8),
      travel: readInt32LE(b, 12), safeMin: readInt32LE(b, 16),
      safeMax: readInt32LE(b, 20), sg: readUInt16LE(b, 24),
      microsteps: readUInt16LE(b, 26), elapsedMs: readUInt32LE(b, 28))
  }
}

/// 板子 SoftAP 的固定地址。只在**发现**时当候选目标；控制目标一律来自回包源地址。
public let kFfSoftApHost = "192.168.4.1"
public let kFfDefaultPort: UInt16 = 4210

// FM03 控制器参数，非角速度/编码器分辨率。
public let kFm03MaxSpeed: Int32 = 1
public let kFm03Tolerance: Int32 = 2
public let kFm03Gain: Int32 = 3

// STATUS.flags 位定义。
public let kFlagEnabled: UInt8 = 1
public let kFlagMoving: UInt8 = 2
public let kFlagCanOk: UInt8 = 4
public let kFlagStandby: UInt8 = 8
public let kFlagLimited: UInt8 = 16
public let kFlagResultShift: UInt8 = 5
public let kFlagResultMask: UInt8 = 0xE0

// 命令结果（flags 高 3 位）。
public let kResultIdle = 0
public let kResultAccepted = 1
public let kResultCompleted = 2
public let kResultLimited = 3
public let kResultRejected = 4
public let kResultStopped = 5

/// 下一个请求序号：1..255 循环，**跳过 0**。
///
/// 0 表示“没有请求”，固件用 `sequence == 0` 判断“这条状态不对应任何请求”，
/// 所以请求序号永远不能是 0。
public func ffNextSequence(after current: UInt8) -> UInt8 {
  let next = (current &+ 1) & 0xFF
  return next == 0 ? 1 : next
}

// MARK: - 小端读写
//
// 手写字节运算而不是 `withUnsafeBytes` + `load`：后者要求内存对齐，
// 而 UDP 回包缓冲区不保证对齐。这里也顺手避免了主机字节序问题。

func readUInt16LE(_ b: [UInt8], _ off: Int) -> UInt16 {
  UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
}

func readUInt32LE(_ b: [UInt8], _ off: Int) -> UInt32 {
  UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16)
    | (UInt32(b[off + 3]) << 24)
}

func readInt32LE(_ b: [UInt8], _ off: Int) -> Int32 {
  Int32(bitPattern: readUInt32LE(b, off))
}

func writeUInt16LE(_ b: inout [UInt8], _ off: Int, _ v: UInt16) {
  b[off] = UInt8(v & 0xFF)
  b[off + 1] = UInt8((v >> 8) & 0xFF)
}

func writeInt32LE(_ b: inout [UInt8], _ off: Int, _ v: Int32) {
  let u = UInt32(bitPattern: v)
  b[off] = UInt8(u & 0xFF)
  b[off + 1] = UInt8((u >> 8) & 0xFF)
  b[off + 2] = UInt8((u >> 16) & 0xFF)
  b[off + 3] = UInt8((u >> 24) & 0xFF)
}

// MARK: - 12 字节请求/状态包

public struct FfPacket: Equatable {
  public var cmd: UInt8
  public var sequence: UInt8
  public var flags: UInt8
  public var a: Int32
  public var b: Int32

  public init(
    cmd: UInt8, sequence: UInt8 = 0, flags: UInt8 = 0, a: Int32 = 0, b: Int32 = 0
  ) {
    self.cmd = cmd
    self.sequence = sequence
    self.flags = flags
    self.a = a
    self.b = b
  }

  public func encode() -> [UInt8] {
    var d = [UInt8](repeating: 0, count: 12)
    d[0] = kFfMagic
    d[1] = cmd
    d[2] = flags
    d[3] = sequence
    writeInt32LE(&d, 4, a)
    writeInt32LE(&d, 8, b)
    return d
  }

  public static func decode(_ bytes: [UInt8]) -> FfPacket? {
    guard bytes.count >= 12, bytes[0] == kFfMagic else { return nil }
    return FfPacket(
      cmd: bytes[1],
      sequence: bytes[3],
      flags: bytes[2],
      a: readInt32LE(bytes, 4),
      b: readInt32LE(bytes, 8)
    )
  }

  public static func decode(_ data: Data) -> FfPacket? {
    decode([UInt8](data))
  }
}

// MARK: - STATUS（0x81）

public struct MotorStatus: Equatable {
  public var sequence: UInt8
  public var pos: Int32
  public var target: Int32
  public var enabled: Bool
  public var moving: Bool
  public var canOk: Bool
  public var limited: Bool
  /// 处于待机断电：用户仍使能，但驱动已释放（不发热、不震动）。
  public var standby: Bool
  public var result: Int
  /// STATUS_V2 才有；legacy STATUS 为 nil。
  public var positionTrusted: Bool?

  public init(
    sequence: UInt8 = 0,
    pos: Int32,
    target: Int32,
    enabled: Bool,
    moving: Bool,
    canOk: Bool,
    limited: Bool = false,
    standby: Bool = false,
    result: Int = kResultIdle,
    positionTrusted: Bool? = nil
  ) {
    self.sequence = sequence
    self.pos = pos
    self.target = target
    self.enabled = enabled
    self.moving = moving
    self.canOk = canOk
    self.limited = limited
    self.standby = standby
    self.result = result
    self.positionTrusted = positionTrusted
  }

  public init(packet p: FfPacket) {
    self.init(
      sequence: p.sequence,
      pos: p.a,
      target: p.b,
      enabled: p.flags & kFlagEnabled != 0,
      moving: p.flags & kFlagMoving != 0,
      canOk: p.flags & kFlagCanOk != 0,
      limited: p.flags & kFlagLimited != 0,
      standby: p.flags & kFlagStandby != 0,
      result: Int((p.flags & kFlagResultMask) >> kFlagResultShift)
    )
  }
}

// MARK: - STATUS_V2（0x83，16 字节）

public struct MotorStatusV2: Equatable {
  public var status: MotorStatus

  public var sequence: UInt8 { status.sequence }
  public var pos: Int32 { status.pos }
  public var target: Int32 { status.target }
  public var enabled: Bool { status.enabled }
  public var moving: Bool { status.moving }
  public var canOk: Bool { status.canOk }
  public var limited: Bool { status.limited }
  public var standby: Bool { status.standby }
  public var result: Int { status.result }
  public var positionTrusted: Bool { status.positionTrusted ?? false }

  public init(status: MotorStatus) {
    self.status = status
  }

  public static func decode(_ bytes: [UInt8]) -> MotorStatusV2? {
    guard bytes.count >= 16, bytes[0] == kFfMagic, bytes[1] == kFfStatusV2
    else { return nil }
    let flags = bytes[2]
    return MotorStatusV2(
      status: MotorStatus(
        sequence: bytes[3],
        pos: readInt32LE(bytes, 4),
        target: readInt32LE(bytes, 8),
        enabled: flags & kFlagEnabled != 0,
        moving: flags & kFlagMoving != 0,
        canOk: flags & kFlagCanOk != 0,
        limited: flags & kFlagLimited != 0,
        standby: flags & kFlagStandby != 0,
        result: Int((flags & kFlagResultMask) >> kFlagResultShift),
        positionTrusted: bytes[12] != 0
      )
    )
  }

  public static func decode(_ data: Data) -> MotorStatusV2? {
    decode([UInt8](data))
  }
}

// MARK: - FM03_DUMP（0x86，26 字节）
public struct Fm03Dump: Equatable {
  public var online: Bool
  public var stage: Int
  public var value: Int
  public var maxSpeed: Int
  public var tolerance: Int
  public var gain: Int
  public var rawPosition: Int32
  public var txFailures: UInt32
  public var rxMissed: UInt32
  public var feedbackAge: Int

  public static func decode(_ b: [UInt8]) -> Fm03Dump? {
    guard b.count == 26, b[0] == kFfMagic, b[1] == kFfFm03Dump,
      b[2] <= 1, b[3] <= 3 || b[3] == 255 else { return nil }
    return Fm03Dump(online: b[2] == 1, stage: Int(b[3]),
      value: Int(Int16(bitPattern: readUInt16LE(b,4))),
      maxSpeed: Int(readUInt16LE(b,6)), tolerance: Int(readUInt16LE(b,8)),
      gain: Int(readUInt16LE(b,10)), rawPosition: readInt32LE(b,12),
      txFailures: readUInt32LE(b,16), rxMissed: readUInt32LE(b,20),
      feedbackAge: Int(readUInt16LE(b,24)))
  }
  public func logLine() -> String {
    "CAN \(online ? "在线" : "离线") stage=\(stage) raw=\(rawPosition) value=\(value) age=\(feedbackAge)ms tx_fail=\(txFailures) rx_missed=\(rxMissed)"
  }
}

// MARK: - 设备发现回包（0x84，32 字节）

/// [host] 是回包的**源地址**，也就是板子的 IP。这是拿到设备地址的唯一途径：
/// iOS 不给普通 App 扫 Wi-Fi 的 API，广播又需要额外 entitlement。
public struct FfDiscovery: Equatable {
  public var deviceId: String
  public var mac: String
  public var kind: Int
  public var protocolVersion: Int
  public var udpPort: Int
  public var fwMajor: Int
  public var fwMinor: Int
  public var fwPatch: Int
  public var host: String

  public init(
    deviceId: String,
    mac: String,
    kind: Int,
    protocolVersion: Int,
    udpPort: Int,
    fwMajor: Int,
    fwMinor: Int,
    fwPatch: Int,
    host: String
  ) {
    self.deviceId = deviceId
    self.mac = mac
    self.kind = kind
    self.protocolVersion = protocolVersion
    self.udpPort = udpPort
    self.fwMajor = fwMajor
    self.fwMinor = fwMinor
    self.fwPatch = fwPatch
    self.host = host
  }

  public var firmware: String { "\(fwMajor).\(fwMinor).\(fwPatch)" }

  /// 回包里 `kind = 1` 表示跟焦器。
  public var isFollowFocus: Bool { kind == 1 }

  public static func decode(_ bytes: [UInt8], host: String) -> FfDiscovery? {
    guard bytes.count >= 32, bytes[0] == kFfMagic, bytes[1] == kFfDiscoverReply
    else { return nil }

    let mac = (9..<15)
      .map { hex2(bytes[$0]) }
      .joined(separator: ":")

    // device_id 是 16 字节、NUL 结尾的 ASCII（如 "FF-75A578"）。
    var id = ""
    for i in 15..<31 {
      let c = bytes[i]
      if c == 0 { break }
      id.append(Character(UnicodeScalar(c)))
    }

    return FfDiscovery(
      deviceId: id,
      mac: mac,
      kind: Int(bytes[2]),
      protocolVersion: Int(bytes[3]),
      udpPort: Int(readUInt16LE(bytes, 4)),
      fwMajor: Int(bytes[6]),
      fwMinor: Int(bytes[7]),
      fwPatch: Int(bytes[8]),
      host: host
    )
  }

  public static func decode(_ data: Data, host: String) -> FfDiscovery? {
    decode([UInt8](data), host: host)
  }
}

/// 一个大写两位十六进制字节，用于拼 MAC。
func hex2(_ b: UInt8) -> String {
  let s = String(b, radix: 16, uppercase: true)
  return s.count == 1 ? "0" + s : s
}
