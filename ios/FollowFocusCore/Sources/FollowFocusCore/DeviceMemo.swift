import Foundation

/// "上次用的是哪台板子"，只为了**冷启动后不用重新扫描**。
///
/// 板子是 SoftAP，地址固定 `192.168.4.1`，但 UDP 端口和 `device_id` 来自发现回包，
/// 所以三个值都要记；固件版本一起记，是为了恢复后能立刻判断 `calSupported`，
/// 不用等下一次 DISCOVER（旧固件仍然只能手动标定）。
///
/// 用 `UserDefaults`：功能层不许依赖 Flutter/UIKit，而 UserDefaults 属于
/// Foundation，编译器的边界检查照旧能过。**不写 host 之外的控制状态** ——
/// 位置、使能、对齐与否都必须重新确认，不能"记住上次连着"就当现在也连着。
///
/// `namespace` 只为测试隔离：每个用例一个独立命名空间，否则用例之间会互相
/// "记住"对方的假板子。
public struct DeviceMemo {
  private let defaults: UserDefaults
  private let key: String

  public init(namespace: String = "ff.core") {
    defaults = .standard
    key = "\(namespace).lastDevice"
  }

  public func save(_ d: FfDiscovery) {
    defaults.set(
      [
        "device_id": d.deviceId,
        "host": d.host,
        "port": Int(d.udpPort),
        "fw_major": Int(d.fwMajor),
        "fw_minor": Int(d.fwMinor),
        "fw_patch": Int(d.fwPatch),
      ], forKey: key)
  }

  public func load() -> FfDiscovery? {
    guard let m = defaults.dictionary(forKey: key),
      let host = m["host"] as? String, !host.isEmpty,
      let port = m["port"] as? Int, (1...65535).contains(port)
    else { return nil }
    return FfDiscovery(
      deviceId: m["device_id"] as? String ?? "",
      mac: "",
      kind: 1,
      protocolVersion: 1,
      udpPort: port,
      fwMajor: m["fw_major"] as? Int ?? 0,
      fwMinor: m["fw_minor"] as? Int ?? 0,
      fwPatch: m["fw_patch"] as? Int ?? 0,
      host: host
    )
  }

  public func clear() { defaults.removeObject(forKey: key) }
}
