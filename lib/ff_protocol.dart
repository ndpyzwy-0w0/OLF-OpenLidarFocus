import 'dart:io';
import 'dart:typed_data';

const int kFfMagic = 0x46;
const int kFfSetPos = 0x01;
const int kFfJog = 0x02;
const int kFfStop = 0x03;
const int kFfEnable = 0x04;
const int kFfSetLimits = 0x05;
const int kFfQuery = 0x06;
const int kFfSetSpeed = 0x07;
const int kFfTmcQuery = 0x08;
const int kFfTmcSet = 0x09;
const int kFfStatus = 0x81;
const int kFfTmcDump = 0x82;

const int kTmcRms = 1;
const int kTmcMicrosteps = 2;
const int kTmcStealth = 3;
const int kTmcToff = 4;
const int kTmcIhold = 5;
const int kTmcIrun = 6;

const int kFlagEnabled = 1;
const int kFlagMoving = 2;
const int kFlagUartOk = 4;

class FfPacket {
  final int cmd;
  final int flags;
  final int a;
  final int b;

  const FfPacket({
    required this.cmd,
    this.flags = 0,
    this.a = 0,
    this.b = 0,
  });

  Uint8List encode() {
    final d = ByteData(12);
    d.setUint8(0, kFfMagic);
    d.setUint8(1, cmd);
    d.setUint8(2, flags);
    d.setUint8(3, 0);
    d.setInt32(4, a, Endian.little);
    d.setInt32(8, b, Endian.little);
    return d.buffer.asUint8List();
  }

  static FfPacket? decode(List<int> bytes) {
    if (bytes.length < 12 || bytes[0] != kFfMagic) return null;
    final d = ByteData.sublistView(Uint8List.fromList(bytes), 0, 12);
    return FfPacket(
      cmd: d.getUint8(1),
      flags: d.getUint8(2),
      a: d.getInt32(4, Endian.little),
      b: d.getInt32(8, Endian.little),
    );
  }
}

class TmcDump {
  final bool uartOk;
  final bool stealth;
  final int rmsMa;
  final int microsteps;
  final int toff;
  final int ihold;
  final int irun;
  final int version;
  final int csActual;
  final int flags;
  final int drvStatus;
  final int sg;
  final int tstep;

  const TmcDump({
    required this.uartOk,
    required this.stealth,
    required this.rmsMa,
    required this.microsteps,
    required this.toff,
    required this.ihold,
    required this.irun,
    required this.version,
    required this.csActual,
    required this.flags,
    required this.drvStatus,
    required this.sg,
    required this.tstep,
  });

  bool get ot => flags & 1 != 0;
  bool get otpw => flags & 2 != 0;
  bool get ola => flags & 4 != 0;
  bool get olb => flags & 8 != 0;
  bool get shorted => flags & 48 != 0;
  bool get standstill => flags & 64 != 0;
  bool get stealthNow => flags & 128 != 0;

  static TmcDump? decode(List<int> bytes) {
    if (bytes.length < 22 || bytes[0] != kFfMagic || bytes[1] != kFfTmcDump) {
      return null;
    }
    final d = ByteData.sublistView(Uint8List.fromList(bytes), 0, 22);
    return TmcDump(
      uartOk: d.getUint8(2) != 0,
      stealth: d.getUint8(3) != 0,
      rmsMa: d.getUint16(4, Endian.little),
      microsteps: d.getUint16(6, Endian.little),
      toff: d.getUint8(8),
      ihold: d.getUint8(9),
      irun: d.getUint8(10),
      version: d.getUint8(11),
      csActual: d.getUint8(12),
      flags: d.getUint8(13),
      drvStatus: d.getUint32(14, Endian.little),
      sg: d.getUint16(18, Endian.little),
      tstep: d.getUint16(20, Endian.little),
    );
  }

  String logLine() {
    if (!uartOk) {
      return 'UART 不通。单线：GPIO12 → TMC 模块 RX 脚（不是 TX），VDD=3.3V，VM 先上电';
    }
    final warn = <String>[
      if (ot) 'OT',
      if (otpw) 'OTPW',
      if (ola) 'OLA',
      if (olb) 'OLB',
      if (shorted) 'S2G',
      if (standstill) 'STST',
    ];
    return 'rms=${rmsMa}mA ms=$microsteps stealth=${stealth ? 1 : 0} '
        'toff=$toff ihold=$ihold irun=$irun cs=$csActual sg=$sg tstep=$tstep '
        'ver=0x${version.toRadixString(16)} drv=0x${drvStatus.toRadixString(16)} '
        '${warn.isEmpty ? "ok" : warn.join(",")}';
  }
}

class MotorStatus {
  final int pos;
  final int target;
  final bool enabled;
  final bool moving;
  final bool uartOk;

  const MotorStatus({
    required this.pos,
    required this.target,
    required this.enabled,
    required this.moving,
    required this.uartOk,
  });

  factory MotorStatus.fromPacket(FfPacket p) {
    return MotorStatus(
      pos: p.a,
      target: p.b,
      enabled: p.flags & kFlagEnabled != 0,
      moving: p.flags & kFlagMoving != 0,
      uartOk: p.flags & kFlagUartOk != 0,
    );
  }
}

class MotorLink {
  InternetAddress host = InternetAddress('192.168.4.1');
  int port = 4210;
  RawDatagramSocket? _sock;
  void Function(MotorStatus)? onStatus;
  void Function(TmcDump)? onTmc;

  bool get isOpen => _sock != null;

  Future<void> open() async {
    await close();
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = sock.receive();
      if (dg == null || dg.data.length < 12 || dg.data[0] != kFfMagic) return;
      if (dg.data[1] == kFfTmcDump) {
        final t = TmcDump.decode(dg.data);
        if (t != null) onTmc?.call(t);
        return;
      }
      if (dg.data[1] != kFfStatus) return;
      final p = FfPacket.decode(dg.data);
      if (p != null) onStatus?.call(MotorStatus.fromPacket(p));
    });
    _sock = sock;
  }

  Future<void> close() async {
    _sock?.close();
    _sock = null;
  }

  void _send(FfPacket p) {
    _sock?.send(p.encode(), host, port);
  }

  void setPos(int steps) => _send(FfPacket(cmd: kFfSetPos, a: steps));
  void jog(int delta) => _send(FfPacket(cmd: kFfJog, a: delta));
  void stop() => _send(const FfPacket(cmd: kFfStop));
  void enable(bool on) => _send(FfPacket(cmd: kFfEnable, a: on ? 1 : 0));
  void setLimits(int min, int max) =>
      _send(FfPacket(cmd: kFfSetLimits, a: min, b: max));
  void setSpeed(int hz, int accel) =>
      _send(FfPacket(cmd: kFfSetSpeed, a: hz, b: accel));
  void query() => _send(const FfPacket(cmd: kFfQuery));
  void queryTmc() => _send(const FfPacket(cmd: kFfTmcQuery));
  void setTmc(int key, int val) =>
      _send(FfPacket(cmd: kFfTmcSet, a: key, b: val));
}
