import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iphone_follow_focus/ff_protocol.dart';

void main() {
  test('packet roundtrip matches 12-byte firmware layout', () {
    final raw = const FfPacket(cmd: kFfSetPos, a: 1234, b: -5).encode();
    expect(raw.length, 12);
    expect(raw[0], kFfMagic);
    final p = FfPacket.decode(raw)!;
    expect(p.cmd, kFfSetPos);
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
    expect(s.pos, -99);
    expect(s.target, 100);
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
}
