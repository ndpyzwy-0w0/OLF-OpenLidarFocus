import Foundation

/// 发现网络上的板子，按 `device_id` 去重。
///
/// 默认只**单播** SoftAP 地址：iOS 上广播（含子网广播 `192.168.4.255`）会被系统按
/// 缺 multicast entitlement 拒绝，报 `errno 13`。桌面/模拟器可以传广播地址，
/// 发不出去的错误会被忽略，不影响其它候选目标。
///
/// 与固件侧 `firmware/tools/discover.py` 行为一致：重复发几次，再等一段超时收集回包。
///
/// 阻塞函数（约 `tries × 120ms + timeout`），**不要在主线程调用**。
/// 抛错和“没找到”是两件事：前者通常是缺本地网络权限或 bind 失败，
/// 后者只是周围没有板子。
public func discoverBoards(
  targets: [String] = [kFfSoftApHost],
  port: UInt16 = kFfDefaultPort,
  timeout: TimeInterval = 0.6,
  tries: Int = 3
) throws -> [FfDiscovery] {
  let sock = UdpSocket()
  try sock.open()
  defer { sock.close() }

  let packet = FfPacket(cmd: kFfDiscover).encode()
  let interval: TimeInterval = 0.120
  let started = Date()
  let deadline = started.addingTimeInterval(
    Double(max(tries - 1, 0)) * interval + timeout)

  var found: [FfDiscovery] = []
  var seen = Set<String>()
  var sent = 0

  while true {
    if sent < tries, Date().timeIntervalSince(started) >= Double(sent) * interval {
      for t in targets {
        // 单个目标发不出去（例如 iOS 上的广播）不影响其它目标。
        try? sock.send(packet, to: t, port: port)
      }
      sent += 1
    }
    while let received = sock.tryReceive() {
      guard let info = FfDiscovery.decode(received.bytes, host: received.from) else {
        continue
      }
      if seen.insert(info.deviceId).inserted {
        found.append(info)
      }
    }
    if Date() >= deadline { break }
    sock.waitReadable(timeout: 0.02)
  }
  return found
}
