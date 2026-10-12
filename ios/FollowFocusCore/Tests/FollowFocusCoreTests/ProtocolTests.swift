import XCTest

@testable import FollowFocusCore

/// 从 Dart 的 `test/ff_protocol_test.dart` 逐条搬过来（发现/链路的网络测试
/// 留在链路那一层，不在这里）。
final class ProtocolTests: XCTestCase {
  func testCalStatusExactWireLayoutAndRejectsMalformed() {
    var raw = [UInt8](repeating: 0, count: 32)
    raw[0] = kFfMagic
    raw[1] = kFfCalStatus
    raw[2] = 5
    raw[3] = 37
    raw[4] = 0
    raw[5] = 9
    raw[6] = 60
    raw[7] = 1
    writeInt32LE(&raw, 8, 8000)
    writeInt32LE(&raw, 12, 8512)
    writeInt32LE(&raw, 16, 0)
    writeInt32LE(&raw, 20, 8000)
    writeUInt16LE(&raw, 24, 123)
    writeUInt16LE(&raw, 26, 16)
    raw[28] = 0x78; raw[29] = 0x56; raw[30] = 0x34; raw[31] = 0x12
    let c = CalStatus.decode(raw)
    XCTAssertEqual(c?.state, 5)
    XCTAssertEqual(c?.sequence, 37)
    XCTAssertEqual(c?.runId, 9)
    XCTAssertEqual(c?.pos, 8000)
    XCTAssertEqual(c?.travel, 8512)
    XCTAssertEqual(c?.safeMax, 8000)
    XCTAssertEqual(c?.sg, 123)
    XCTAssertEqual(c?.microsteps, 16)
    XCTAssertEqual(c?.elapsedMs, 0x12345678)
    XCTAssertNil(CalStatus.decode(Array(raw.dropLast())))
    XCTAssertNil(CalStatus.decode(raw + [0]))
    raw[7] = 2
    XCTAssertNil(CalStatus.decode(raw))
  }

  /// 固件的错误码没有“最大已知值”之外的上界，尤其 `CAL_DIAG = 11` 曾经被
  /// 解码器整包拒收，把明确拒绝变成了 App 侧的保活超时（见 §14）。
  func testCalStatusKeepsEveryFirmwareErrorCode() {
    var raw = [UInt8](repeating: 0, count: 32)
    raw[0] = kFfMagic
    raw[1] = kFfCalStatus
    raw[2] = 7
    for code in [UInt8(0), 7, 10, 11, 200] {
      raw[4] = code
      XCTAssertEqual(CalStatus.decode(raw)?.error, code, "error=\(code) 不该被丢掉")
    }
  }
  func testPacketRoundtripMatches12ByteLayout() {
    let raw = FfPacket(cmd: kFfSetPos, sequence: 42, a: 1234, b: -5).encode()
    XCTAssertEqual(raw.count, 12)
    XCTAssertEqual(raw[0], kFfMagic)
    let p = FfPacket.decode(raw)
    XCTAssertNotNil(p)
    XCTAssertEqual(p?.cmd, kFfSetPos)
    XCTAssertEqual(p?.sequence, 42)
    XCTAssertEqual(p?.a, 1234)
    XCTAssertEqual(p?.b, -5)
  }

  func testPacketDecodeRejectsShortOrWrongMagic() {
    XCTAssertNil(FfPacket.decode([UInt8](repeating: 0, count: 11)))
    var wrong = [UInt8](repeating: 0, count: 12)
    wrong[0] = 0xAA
    XCTAssertNil(FfPacket.decode(wrong))
  }

  func testStatusFlags() {
    let raw = FfPacket(
      cmd: kFfStatus, flags: kFlagEnabled | kFlagMoving, a: -99, b: 100
    ).encode()
    guard let p = FfPacket.decode(raw) else { return XCTFail("decode failed") }
    let s = MotorStatus(packet: p)
    XCTAssertTrue(s.enabled)
    XCTAssertTrue(s.moving)
    XCTAssertFalse(s.canOk)
    XCTAssertFalse(s.standby)
    XCTAssertEqual(s.pos, -99)
    XCTAssertEqual(s.target, 100)
  }

  func testStatusPreservesRequestSequence() {
    let raw = FfPacket(cmd: kFfStatus, sequence: 7, a: 1, b: 2).encode()
    guard let p = FfPacket.decode(raw) else { return XCTFail("decode failed") }
    XCTAssertEqual(MotorStatus(packet: p).sequence, 7)
  }

  func testStatusDecodesCommandResultFromUpperFlags() {
    let raw = FfPacket(
      cmd: kFfStatus,
      flags: kFlagEnabled | (UInt8(kResultLimited) << kFlagResultShift)
    ).encode()
    guard let p = FfPacket.decode(raw) else { return XCTFail("decode failed") }
    XCTAssertEqual(MotorStatus(packet: p).result, kResultLimited)
  }

  func testStandbyFlagIsIndependentOfEnabled() {
    let raw = FfPacket(
      cmd: kFfStatus,
      flags: kFlagEnabled | kFlagCanOk | kFlagStandby,
      a: 5,
      b: 5
    ).encode()
    guard let p = FfPacket.decode(raw) else { return XCTFail("decode failed") }
    let s = MotorStatus(packet: p)
    XCTAssertTrue(s.enabled, "用户仍处于使能意图")
    XCTAssertTrue(s.standby, "但驱动已被待机断电释放")
    XCTAssertFalse(s.moving)
  }

  func testFm03DumpWireLayoutAndMalformedInput() {
    var raw = [UInt8](repeating: 0, count: 26)
    raw[0]=kFfMagic; raw[1]=kFfFm03Dump; raw[2]=1; raw[3]=3
    writeUInt16LE(&raw,4,UInt16(bitPattern: -16)); writeUInt16LE(&raw,6,64)
    writeUInt16LE(&raw,8,4); writeUInt16LE(&raw,10,4)
    writeInt32LE(&raw,12,2187); writeInt32LE(&raw,16,2)
    writeInt32LE(&raw,20,1); writeUInt16LE(&raw,24,100)
    let t = Fm03Dump.decode(raw)
    XCTAssertEqual(t?.value,-16); XCTAssertEqual(t?.rawPosition,2187)
    XCTAssertEqual(t?.maxSpeed,64); XCTAssertEqual(t?.txFailures,2)
    XCTAssertNil(Fm03Dump.decode(Array(raw.dropLast())))
    XCTAssertNil(t?.acceleration, "Legacy firmware cannot tune acceleration")
    raw += [32, 0]
    XCTAssertEqual(Fm03Dump.decode(raw)?.acceleration, 32)
    XCTAssertEqual(Fm03Dump.decode(raw)?.rawPosition, 2187)
    XCTAssertNil(Fm03Dump.decode(Array(raw.dropLast())))
    raw[26] = 0; XCTAssertNil(Fm03Dump.decode(raw))
    raw[26] = 65; XCTAssertNil(Fm03Dump.decode(raw))
    raw[26] = 32
    raw[1]=0x82; XCTAssertNil(Fm03Dump.decode(raw))
  }

  func testStatusV2DecodesTrustedPosition() {
    var raw = [UInt8](repeating: 0, count: 16)
    raw[0] = kFfMagic
    raw[1] = kFfStatusV2
    raw[2] = kFlagEnabled | (UInt8(kResultCompleted) << kFlagResultShift)
    raw[3] = 9
    writeInt32LE(&raw, 4, 12)
    writeInt32LE(&raw, 8, 12)
    raw[12] = 1
    raw[13] = 3

    guard let s = MotorStatusV2.decode(raw) else { return XCTFail("decode failed") }
    XCTAssertEqual(s.sequence, 9)
    XCTAssertTrue(s.positionTrusted)
    XCTAssertEqual(s.result, kResultCompleted)
    XCTAssertEqual(s.pos, 12)
    XCTAssertEqual(s.fault, 3)
  }

  func testDiscoveryReply32ByteLayout() {
    var raw = [UInt8](repeating: 0, count: 32)
    raw[0] = kFfMagic
    raw[1] = kFfDiscoverReply
    raw[2] = 1  // kind = 跟焦器
    raw[3] = 1  // protocol
    writeUInt16LE(&raw, 4, 4210)
    raw[6] = 1  // fw 1.0.0
    raw[7] = 0
    raw[8] = 0
    for (i, b) in [UInt8(0x92), 0xDA, 0x72, 0x75, 0xA5, 0x78].enumerated() {
      raw[9 + i] = b
    }
    let id = "FF-75A578"
    for (i, c) in id.utf8.enumerated() {
      raw[15 + i] = c
    }

    guard let info = FfDiscovery.decode(raw, host: kFfSoftApHost) else {
      return XCTFail("decode failed")
    }
    XCTAssertEqual(info.deviceId, id)
    XCTAssertEqual(info.mac, "92:DA:72:75:A5:78")
    XCTAssertEqual(info.udpPort, 4210)
    XCTAssertEqual(info.firmware, "1.0.0")
    XCTAssertTrue(info.isFollowFocus)
    XCTAssertEqual(info.host, kFfSoftApHost)
  }

  func testDiscoveryDecodeRejectsShortOrUnrelatedPackets() {
    XCTAssertNil(
      FfDiscovery.decode([UInt8](repeating: 0, count: 31), host: kFfSoftApHost))
    var wrong = [UInt8](repeating: 0, count: 32)
    wrong[0] = kFfMagic
    wrong[1] = kFfStatus
    XCTAssertNil(FfDiscovery.decode(wrong, host: kFfSoftApHost))
  }
}
