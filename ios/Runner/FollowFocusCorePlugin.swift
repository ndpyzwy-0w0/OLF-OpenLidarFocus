import Flutter
import FollowFocusCore
import UIKit

/// `ff.core` 的桥：把 [FollowFocusSession] 暴露给 UI 层。
///
/// 契约（UI 侧见 `lib/ff_core.dart`）：
///
/// - 方法通道 `ff.core`：命令，全部 fire-and-forget，返回 nil 或一次性结果。
/// - 事件通道 `ff.core/events`：约 20Hz 的**聚合状态快照**。
///   UI 只渲染最新一条，不需要理解事件顺序，也不会看到中间态。
///
/// 规则：UI 侧不允许复制任何控制逻辑。需要新行为就往 [FollowFocusSession] 加，
/// 再在这里加一个方法，不要在 Dart 里重算限位/死区/相位。
final class FollowFocusCorePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let session: FollowFocusSession
  private let sinkLock = NSLock()
  private var sink: FlutterEventSink?

  init(store: LensStore) {
    session = FollowFocusSession(store: store)
    super.init()

    session.onState = { [weak self] state in self?.emit(state) }

    // LiDAR 采样直连会话：不再经 Dart 绕一圈。
    // 这里也是 Runner 侧唯一该同时碰「平台采集」和「功能层」的地方。
    let session = self.session
    LidarEngine.shared.onDistance = { meters in session.ingest(distanceMeters: meters) }

    session.start()
    NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  @objc private func didEnterBackground() { session.cancelAutoCalibration() }

  static func register(with registrar: FlutterPluginRegistrar) {
    // 存档在这里加载：插件自己持有功能层，UI 侧不管存档路径。
    let instance = FollowFocusCorePlugin(store: LensStore.load())
    let methods = FlutterMethodChannel(
      name: "ff.core", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: "ff.core/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  // MARK: - 方法表

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let a = args(call)
    switch call.method {
    // 生命周期
    case "start":
      session.start()
      result(nil)
    case "stop":
      session.stop()
      result(nil)
    case "snapshot":
      result(session.snapshot().channelObject(cal: session.cal))

    // 设备
    case "discover":
      session.discover { found in result(found.map(\.channelObject)) }
    case "selectDevice":
      guard let host = string(a, "host"), let port = int(a, "port") else {
        result(FlutterError(code: "bad_args", message: "selectDevice 缺 host/port", details: nil))
        return
      }
      let version = (string(a, "firmware") ?? "").split(separator: ".").compactMap { Int($0) }
      session.selectDevice(
        FfDiscovery(
          deviceId: string(a, "device_id") ?? "",
          mac: "",
          kind: 1,
          protocolVersion: 1,
          udpPort: port,
          fwMajor: version.count > 0 ? version[0] : 0,
          fwMinor: version.count > 1 ? version[1] : 0,
          fwPatch: version.count > 2 ? version[2] : 0,
          host: host
        )
      )
      result(nil)
    case "connect":
      session.connect()
      result(nil)
    case "disconnect":
      session.disconnect()
      result(nil)

    // 手动控制
    case "enable":
      session.enable(bool(a, "on") ?? false)
      result(nil)
    case "stopPressed":
      session.stopPressed()
      result(nil)
    case "homePressed":
      session.homePressed()
      result(nil)
    case "jog":
      session.jog(Int32(int(a, "delta") ?? 0))
      result(nil)
    case "setSlider":
      session.setSlider(double(a, "value") ?? 0)
      result(nil)
    case "setAuto":
      session.setAuto(bool(a, "on") ?? false)
      result(nil)
    case "setSpeed":
      session.setSpeed(
        revsPerSec: double(a, "revsPerSec") ?? 1.2,
        accelRevsPerSec2: double(a, "accelRevsPerSec2") ?? 30
      )
      result(nil)

    // 驱动参数（调试面板）
    case "setMicrosteps":
      session.setMicrosteps(Int32(int(a, "value") ?? 16))
      result(nil)
    case "setTmc":
      session.setTmc(Int32(int(a, "key") ?? 0), Int32(int(a, "value") ?? 0))
      result(nil)
    case "queryTmc":
      session.queryTmc()
      result(nil)
    case "setStandbyFeature":
      session.setStandbyFeature(bool(a, "on") ?? true)
      result(nil)

    // 镜头
    case "selectLens":
      guard let id = string(a, "id") else {
        result(FlutterError(code: "bad_args", message: "selectLens 缺 id", details: nil))
        return
      }
      session.selectLens(id: id)
      result(nil)
    case "createLens":
      session.createLens(name: string(a, "name") ?? "", params: string(a, "params") ?? "")
      result(nil)
    case "deleteLens":
      session.deleteLens(id: string(a, "id") ?? "")
      result(nil)

    // ① 行程标定
    case "recordStrokeA":
      session.recordStrokeA()
      result(nil)
    case "finishStroke":
      session.finishStroke()
      result(nil)
    case "recalibrateStroke":
      session.recalibrateStroke()
      result(nil)
    case "startAutoCalibration":
      session.startAutoCalibration(threshold: int(a, "threshold") ?? 60,
        maxRevs: double(a, "maxRevs") ?? 2)
      result(nil)
    case "cancelAutoCalibration":
      session.cancelAutoCalibration()
      result(nil)
    case "leaveLens":
      session.leaveLens()
      result(nil)

    // ② 单侧对齐
    case "confirmNear":
      session.confirmNear()
      result(nil)
    case "setDir":
      session.setDir(int(a, "dir") ?? 1)
      result(nil)
    case "startFollow":
      session.startFollow()
      result(nil)
    case "unalign":
      session.unalign()
      result(nil)

    // ③ 距离标定
    case "addLutPoint":
      session.addLutPoint()
      result(nil)
    case "removeLutPoint":
      session.removeLutPoint(at: int(a, "index") ?? -1)
      result(nil)

    // LiDAR
    case "setTrackFaces":
      let on = bool(a, "on") ?? false
      session.setTrackFaces(on)
      // 会话只记“界面开着人脸跟踪”；真正驱动相机的是采集层。
      LidarEngine.shared.setTrackFaces(on)
      result(nil)
    case "ingestDistance":
      // 模拟器/测试用：没有 LiDAR 时由 UI 或测试喂距离。
      // 真机上走 LidarEngine 的直连回调，不走这里。
      session.ingest(distanceMeters: double(a, "meters"))

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 事件通道

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sinkLock.lock()
    sink = events
    sinkLock.unlock()
    // 先补一条当前快照，UI 不用等下一个 tick 才有内容。
    events(session.snapshot().channelObject(cal: session.cal))
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sinkLock.lock()
    sink = nil
    sinkLock.unlock()
    return nil
  }

  private func emit(_ state: FollowFocusState) {
    sinkLock.lock()
    let sink = self.sink
    sinkLock.unlock()
    guard let sink else { return }
    let map = state.channelObject(cal: session.cal)
    DispatchQueue.main.async { sink(map) }
  }

  // MARK: - 参数取值

  private func args(_ call: FlutterMethodCall) -> [String: Any] {
    (call.arguments as? [String: Any]) ?? [:]
  }

  private func int(_ a: [String: Any], _ k: String) -> Int? {
    (a[k] as? NSNumber)?.intValue
  }

  private func double(_ a: [String: Any], _ k: String) -> Double? {
    (a[k] as? NSNumber)?.doubleValue
  }

  private func bool(_ a: [String: Any], _ k: String) -> Bool? {
    (a[k] as? NSNumber)?.boolValue
  }

  private func string(_ a: [String: Any], _ k: String) -> String? {
    a[k] as? String
  }
}
