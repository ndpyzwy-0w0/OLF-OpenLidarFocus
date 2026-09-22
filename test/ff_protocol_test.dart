import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/ff_protocol.dart';

void main() {
  test('packet roundtrip matches 12-byte firmware layout', () {
    final raw = const FfPacket(
      cmd: kFfSetPos,
      sequence: 42,
      a: 1234,
      b: -5,
    ).encode();
    expect(raw.length, 12);
    expect(raw[0], kFfMagic);
    final p = FfPacket.decode(raw)!;
    expect(p.cmd, kFfSetPos);
    expect(p.sequence, 42);
    expect(p.a, 1234);
    expect(p.b, -5);
  });

  test('status flags', () {
    final p = FfPacket.decode(
      const FfPacket(
        cmd: kFfStatus,
        flags: kFlagEnabled | kFlagMoving,
        a: -99,
        b: 100,
      ).encode(),
    )!;
    final s = MotorStatus.fromPacket(p);
    expect(s.enabled, isTrue);
    expect(s.moving, isTrue);
    expect(s.uartOk, isFalse);
    expect(s.standby, isFalse);
    expect(s.pos, -99);
    expect(s.target, 100);
  });

  test('status preserves request sequence', () {
    final p = FfPacket.decode(
      const FfPacket(cmd: kFfStatus, sequence: 7, a: 1, b: 2).encode(),
    )!;
    final s = MotorStatus.fromPacket(p);
    expect(s.sequence, 7);
  });

  test('status decodes command result from upper flags', () {
    final p = FfPacket.decode(
      const FfPacket(
        cmd: kFfStatus,
        flags: kFlagEnabled | (kResultLimited << kFlagResultShift),
      ).encode(),
    )!;
    expect(MotorStatus.fromPacket(p).result, kResultLimited);
  });

  test('standby flag is reported independently of enabled', () {
    final p = FfPacket.decode(
      const FfPacket(
        cmd: kFfStatus,
        flags: kFlagEnabled | kFlagUartOk | kFlagStandby,
        a: 5,
        b: 5,
      ).encode(),
    )!;
    final s = MotorStatus.fromPacket(p);
    expect(s.enabled, isTrue, reason: '用户仍处于使能意图');
    expect(s.standby, isTrue, reason: '但驱动已被待机断电释放');
    expect(s.moving, isFalse);
  });

  test('tmc dump 22-byte layout', () {
    final raw = Uint8List(22);
    final d = ByteData.sublistView(raw);
    d.setUint8(0, kFfMagic);
    d.setUint8(1, kFfTmcDump);
    d.setUint8(2, 1);
    d.setUint8(3, 1);
    d.setUint16(4, 800, Endian.little);
    d.setUint16(6, 16, Endian.little);
    d.setUint8(8, 5);
    d.setUint8(9, 8);
    d.setUint8(10, 16);
    d.setUint8(11, 0x21);
    d.setUint8(12, 12);
    d.setUint8(13, 64);
    d.setUint32(14, 0xabc, Endian.little);
    d.setUint16(18, 7, Endian.little);
    d.setUint16(20, 100, Endian.little);
    final t = TmcDump.decode(raw)!;
    expect(t.uartOk, isTrue);
    expect(t.stealth, isTrue);
    expect(t.rmsMa, 800);
    expect(t.microsteps, 16);
    expect(t.toff, 5);
    expect(t.standstill, isTrue);
    expect(t.sg, 7);
    expect(t.logLine(), contains('800'));
  });

  test('status v2 decodes trusted position', () {
    final raw = Uint8List(16);
    final d = ByteData.sublistView(raw);
    d.setUint8(0, kFfMagic);
    d.setUint8(1, kFfStatusV2);
    d.setUint8(2, kFlagEnabled | (kResultCompleted << kFlagResultShift));
    d.setUint8(3, 9);
    d.setInt32(4, 12, Endian.little);
    d.setInt32(8, 12, Endian.little);
    d.setUint8(12, 1);
    final s = MotorStatusV2.decode(raw)!;
    expect(s.sequence, 9);
    expect(s.positionTrusted, isTrue);
    expect(s.result, kResultCompleted);
  });
}
