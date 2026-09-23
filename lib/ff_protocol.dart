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
const int kFfHome = 0x0a;
const int kFfStatusV2 = 0x83;
const int kFfDiscover = 0x0b;
const int kFfDiscoverReply = 0x84;

/// 板子 SoftAP 的固定地址。这是固件契约（HANDOFF §6），只在**扫描时**当候选目标用；
/// 控制目标一律来自发现回包，不要再用它。
const String kFfSoftApHost = '192.168.4.1';
const int kFfDefaultPort = 4210;

const int kTmcRms = 1;
const int kTmcMicrosteps = 2;
const int kTmcStealth = 3;
const int kTmcToff = 4;
const int kTmcIhold = 5;
const int kTmcIrun = 6;
const int kTmcStandby = 7;

const int kFlagEnabled = 1;
const int kFlagMoving = 2;
const int kFlagUartOk = 4;
const int kFlagStandby = 8;
const int kFlagLimited = 16;
const int kFlagResultShift = 5;
const int kFlagResultMask = 0xe0;

const int kResultIdle = 0;
const int kResultAccepted = 1;
const int kResultCompleted = 2;
const int kResultLimited = 3;
const int kResultRejected = 4;
const int kResultStopped = 5;

class FfPacket {
  final int cmd;
  final int sequence;
  final int flags;
  final int a;
  final int b;

  const FfPacket({
    required this.cmd,
    this.sequence = 0,
    this.flags = 0,
    this.a = 0,
    this.b = 0,
  });

  Uint8List encode() {
    final d = ByteData(12);
    d.setUint8(0, kFfMagic);
    d.setUint8(1, cmd);
    d.setUint8(2, flags);
    d.setUint8(3, sequence & 0xff);
    d.setInt32(4, a, Endian.little);
    d.setInt32(8, b, Endian.little);
    return d.buffer.asUint8List();
  }

  static FfPacket? decode(List<int> bytes) {
    if (bytes.length < 12 || bytes[0] != kFfMagic) return null;
    final d = ByteData.sublistView(Uint8List.fromList(bytes), 0, 12);
    return FfPacket(
      cmd: d.getUint8(1),
      sequence: d.getUint8(3),
      flags: d.getUint8(2),
      a: d.getInt32(4, Endian.little),
      b: d.getInt32(8, Endian.little),
    );
  }
}

class TmcDump {
  final bool uartOk;
  final bool limited;
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
    this.limited = false,
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
  final int sequence;
  final int pos;
  final int target;
  final bool enabled;
  final bool moving;
  final bool uartOk;
  final bool limited;

  /// 处于待机断电：用户仍使能，但驱动已释放（不发热、不震动）。
  final bool standby;
  final int result;
  final bool? positionTrusted;

  const MotorStatus({
    this.sequence = 0,
    required this.pos,
    required this.target,
    required this.enabled,
    required this.moving,
    required this.uartOk,
    this.limited = false,
    this.standby = false,
    this.result = kResultIdle,
    this.positionTrusted,
  });

  factory MotorStatus.fromPacket(FfPacket p) {
    return MotorStatus(
      sequence: p.sequence,
      pos: p.a,
      target: p.b,
      enabled: p.flags & kFlagEnabled != 0,
      moving: p.flags & kFlagMoving != 0,
      uartOk: p.flags & kFlagUartOk != 0,
      limited: p.flags & kFlagLimited != 0,
      standby: p.flags & kFlagStandby != 0,
      result: (p.flags & kFlagResultMask) >> kFlagResultShift,
    );
  }

}

class MotorStatusV2 extends MotorStatus {
  const MotorStatusV2({
    required super.sequence,
    required super.pos,
    required super.target,
    required super.enabled,
    required super.moving,
    required super.uartOk,
    required super.limited,
    required super.standby,
    required super.result,
    required bool trusted,
  }) : super(positionTrusted: trusted);

  static MotorStatusV2? decode(List<int> bytes) {
    if (bytes.length < 16 || bytes[0] != kFfMagic || bytes[1] != kFfStatusV2) {
      return null;
    }
    final d = ByteData.sublistView(Uint8List.fromList(bytes), 0, 16);
    final flags = d.getUint8(2);
    return MotorStatusV2(
      sequence: d.getUint8(3),
      pos: d.getInt32(4, Endian.little),
      target: d.getInt32(8, Endian.little),
      enabled: flags & kFlagEnabled != 0,
      moving: flags & kFlagMoving != 0,
      uartOk: flags & kFlagUartOk != 0,
      limited: flags & kFlagLimited != 0,
      standby: flags & kFlagStandby != 0,
      result: (flags & kFlagResultMask) >> kFlagResultShift,
      trusted: d.getUint8(12) != 0,
    );
  }
}

/// 设备发现回包（`0x84`，固定 32 字节，见 HANDOFF §6）。
///
/// [host] 是回包的**源地址**，也就是板子的 IP。iOS 不允许普通 App 扫描 Wi-Fi，
/// 广播又需要额外的 multicast entitlement（实测 `errno 13`），所以单播发现时
/// 回包源地址是拿到设备地址的**唯一**途径。
class FfDiscovery {
  final String deviceId;
  final String mac;
  final int kind;
  final int protocol;
  final int udpPort;
  final int fwMajor;
  final int fwMinor;
  final int fwPatch;
  final InternetAddress host;

  const FfDiscovery({
    required this.deviceId,
    required this.mac,
    required this.kind,
    required this.protocol,
    required this.udpPort,
    required this.fwMajor,
    required this.fwMinor,
    required this.fwPatch,
    required this.host,
  });

  String get firmware => '$fwMajor.$fwMinor.$fwPatch';

  /// 回包里 `kind = 1` 表示跟焦器。
  bool get isFollowFocus => kind == 1;

  static FfDiscovery? decode(List<int> bytes, InternetAddress host) {
    if (bytes.length < 32 ||
        bytes[0] != kFfMagic ||
        bytes[1] != kFfDiscoverReply) {
      return null;
    }
    final d = ByteData.sublistView(Uint8List.fromList(bytes), 0, 32);
    final mac = [
      for (var i = 9; i < 15; i++)
        d.getUint8(i).toRadixString(16).padLeft(2, '0').toUpperCase(),
    ].join(':');
    // device_id 是 16 字节、NUL 结尾的 ASCII（如 "FF-75A578"）。
    var id = '';
    for (var i = 15; i < 31; i++) {
      final c = d.getUint8(i);
      if (c == 0) break;
      id += String.fromCharCode(c);
    }
    return FfDiscovery(
      deviceId: id,
      mac: mac,
      kind: d.getUint8(2),
      protocol: d.getUint8(3),
      udpPort: d.getUint16(4, Endian.little),
      fwMajor: d.getUint8(6),
      fwMinor: d.getUint8(7),
      fwPatch: d.getUint8(8),
      host: host,
    );
  }
}

/// 发现网络上的板子，按 `device_id` 去重。
///
/// 默认只**单播** SoftAP 地址：iOS 上广播（含子网广播 `192.168.4.255`）会被
/// 系统按缺 multicast entitlement 拒绝，报 `errno 13`（见 HANDOFF §8.1）。
/// 桌面端可以传广播地址，发不出去的错误会被忽略。
///
/// 与固件侧 [firmware/tools/discover.py](firmware/tools/discover.py) 行为一致：
/// 同一个 socket 上重复发几次，再等一段超时收集回包。UDP 发送错误是**异步**
/// 抛出的，所以既要 catch 同步异常，也要吞掉 `onError`。
Future<List<FfDiscovery>> discoverBoards({
  List<InternetAddress>? targets,
  int port = kFfDefaultPort,
  Duration timeout = const Duration(milliseconds: 600),
  int tries = 3,
}) async {
  final list = targets ?? [InternetAddress(kFfSoftApHost)];
  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final found = <String, FfDiscovery>{};
  try {
    // 桌面端发广播需要它；iOS 上开了也不会让广播合法。
    sock.broadcastEnabled = true;
    sock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = sock.receive();
      if (dg == null) return;
      final info = FfDiscovery.decode(dg.data, dg.address);
      if (info != null) found[info.deviceId] = info;
    }, onError: (Object _) {});
    final packet = const FfPacket(cmd: kFfDiscover).encode();
    for (var i = 0; i < tries; i++) {
      for (final t in list) {
        try {
          sock.send(packet, t, port);
        } on Object {
          // 单个目标发不出去（例如 iOS 上的广播）不影响其它目标。
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    await Future<void>.delayed(timeout);
  } finally {
    sock.close();
  }
  return found.values.toList();
}

class MotorLink {
  /// 控制目标，由发现结果填充（[useDevice]）。为 null 表示还没选设备。
  ///
  /// 不再写死 `192.168.4.1:4210`：板子的 UDP 端口来自发现回包（HANDOFF §6）。
  InternetAddress? host;
  int port = kFfDefaultPort;
  RawDatagramSocket? _sock;
  int _nextSequence = 0;
  int get lastSequence => _nextSequence;
  void Function(MotorStatus)? onStatus;
  void Function(MotorStatusV2)? onStatusV2;
  void Function(TmcDump)? onTmc;
  void Function(int)? onSent;

  /// 收到的数据包总数（含固件回显）。
  ///
  /// UDP 发送失败是以 **异步 stream 错误** 形式抛出的，`open()` 的 await 捕获不到，
  /// 所以"发得出去、收不回来"只能靠这个计数器和 [lastEchoAt] 判断。
  int rxPackets = 0;

  /// 本机 UDP 端口。用于确认包是从哪张网卡/哪个端口出去的。
  int? localPort;

  /// 实际绑定的本机地址，用于确认出口网卡选对了。
  String? localAddr;

  /// 探测包发送次数，用于和接收数对比判断收发方向。
  int probeTx = 0;

  /// 最近一次收到固件原样回显的非协议包（链路探测，见 HANDOFF §6）。
  DateTime? lastEchoAt;

  /// 套接字层的异步错误。
  void Function(Object error)? onSocketError;

  bool get isOpen => _sock != null;

  Future<void> open() async {
    await close();
    _nextSequence = 0;
    rxPackets = 0;
    probeTx = 0;
    lastEchoAt = null;
    // 用通配地址绑定，让内核按目标自己挑出口。
    // 不要绑定到具体网卡的地址：地址会随 Wi-Fi 切换失效，Apple 也明确不建议
    // 去猜本机 IP（「Don't Try to Get the Device's IP Address」）。
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    localPort = sock.port;
    localAddr = sock.address.address;
    sock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = sock.receive();
      if (dg == null) return;
      rxPackets++;
      if (dg.data.length < 12 || dg.data[0] != kFfMagic) {
        // 固件把非协议包原样回显，正好当链路探测用（HANDOFF §6）。
        lastEchoAt = DateTime.now();
        return;
      }
      if (dg.data[1] == kFfTmcDump) {
        final t = TmcDump.decode(dg.data);
        if (t != null) onTmc?.call(t);
        return;
      }
      if (dg.data[1] == kFfStatusV2) {
        final s = MotorStatusV2.decode(dg.data);
        if (s != null) onStatusV2?.call(s);
        return;
      }
      if (dg.data[1] != kFfStatus) return;
      final p = FfPacket.decode(dg.data);
      if (p != null) onStatus?.call(MotorStatus.fromPacket(p));
    }, onError: (Object e) => onSocketError?.call(e));
    _sock = sock;
  }

  Future<void> close() async {
    _sock?.close();
    _sock = null;
  }

  /// 把控制目标切到发现到的板子：地址取回包源地址，端口取固件上报的 `udp_port`。
  void useDevice(FfDiscovery d) {
    host = d.host;
    port = d.udpPort;
  }

  void _send(FfPacket p) {
    final target = host;
    if (target == null) return; // 还没选设备，静默丢弃
    final sequence = (_nextSequence + 1) & 0xff;
    _nextSequence = sequence == 0 ? 1 : sequence;
    _sock?.send(
      FfPacket(
        cmd: p.cmd,
        sequence: _nextSequence,
        flags: p.flags,
        a: p.a,
        b: p.b,
      ).encode(),
      target,
      port,
    );
    onSent?.call(_nextSequence);
  }

  /// 发一个非协议短报文；固件会原样回显，用来判断链路是否双向通（HANDOFF §6）。
  ///
  /// 长度必须 < 12 且首字节不是 0x46，否则会被固件当成普通协议包。
  void probe() {
    final target = host;
    if (target == null) return;
    probeTx++;
    _sock?.send(const [0xab, 0xcd], target, port);
  }

  void setPos(int steps) => _send(FfPacket(cmd: kFfSetPos, a: steps));
  void home() => _send(const FfPacket(cmd: kFfHome));
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
