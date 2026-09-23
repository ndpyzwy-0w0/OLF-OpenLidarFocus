import 'dart:io';
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

  test('discovery reply 32-byte layout', () {
    final raw = Uint8List(32);
    final d = ByteData.sublistView(raw);
    d.setUint8(0, kFfMagic);
    d.setUint8(1, kFfDiscoverReply);
    d.setUint8(2, 1); // kind = 跟焦器
    d.setUint8(3, 1); // protocol
    d.setUint16(4, 4210, Endian.little);
    d.setUint8(6, 1); // fw 1.0.0
    d.setUint8(7, 0);
    d.setUint8(8, 0);
    const mac = [0x92, 0xda, 0x72, 0x75, 0xa5, 0x78];
    for (var i = 0; i < mac.length; i++) {
      d.setUint8(9 + i, mac[i]);
    }
    const id = 'FF-75A578';
    for (var i = 0; i < id.length; i++) {
      d.setUint8(15 + i, id.codeUnitAt(i));
    }
    final info = FfDiscovery.decode(raw, InternetAddress(kFfSoftApHost))!;
    expect(info.deviceId, id);
    expect(info.mac, '92:DA:72:75:A5:78');
    expect(info.udpPort, 4210);
    expect(info.firmware, '1.0.0');
    expect(info.isFollowFocus, isTrue);
    expect(info.host.address, kFfSoftApHost);
  });

  test('discovery decode rejects short or unrelated packets', () {
    expect(
      FfDiscovery.decode(Uint8List(31), InternetAddress(kFfSoftApHost)),
      isNull,
    );
    final wrong = Uint8List(32);
    wrong[0] = kFfMagic;
    wrong[1] = kFfStatus;
    expect(FfDiscovery.decode(wrong, InternetAddress(kFfSoftApHost)), isNull);
  });

  test('useDevice takes address and port from the discovery reply', () {
    final raw = Uint8List(32);
    final d = ByteData.sublistView(raw);
    d.setUint8(0, kFfMagic);
    d.setUint8(1, kFfDiscoverReply);
    d.setUint16(4, 4321, Endian.little);
    final info = FfDiscovery.decode(raw, InternetAddress('192.168.5.9'))!;
    final link = MotorLink();
    expect(link.host, isNull, reason: '连接目标不再有写死的默认值');
    link.useDevice(info);
    expect(link.host?.address, '192.168.5.9');
    expect(link.port, 4321, reason: '端口取固件上报值，不假设 4210');
  });

  test('discoverBoards finds a board that answers the discover packet', () async {
    // 假板子：收到 `0x0B` 就回 32 字节发现回包。走 loopback，
    // 覆盖真正的收发路径（绑定、发送、回包、去重、超时）。
    final board = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(board.close);
    board.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = board.receive();
      if (dg == null || dg.data.length < 12 || dg.data[1] != kFfDiscover) return;
      final reply = Uint8List(32);
      final d = ByteData.sublistView(reply);
      d.setUint8(0, kFfMagic);
      d.setUint8(1, kFfDiscoverReply);
      d.setUint8(2, 1);
      d.setUint16(4, 4210, Endian.little);
      const id = 'FF-TEST01';
      for (var i = 0; i < id.length; i++) {
        d.setUint8(15 + i, id.codeUnitAt(i));
      }
      board.send(reply, dg.address, dg.port);
    });

    final found = await discoverBoards(
      targets: [InternetAddress.loopbackIPv4],
      port: board.port,
    );
    expect(found, hasLength(1), reason: '重复发包应收敛成一台');
    expect(found.single.deviceId, 'FF-TEST01');
    expect(found.single.host.address, InternetAddress.loopbackIPv4.address);
  });
}
