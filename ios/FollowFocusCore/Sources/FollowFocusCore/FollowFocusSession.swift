import Foundation

/// 跟焦前的三坐标：新镜头标定行程 → 单侧对齐 → 跟焦。
public enum SetupPhase: String {
  case stroke
  case align
  case follow
}

/// 给 UI 的一条聚合状态快照。
///
/// UI 只渲染最新快照，不需要理解事件顺序，也不会看到中间态。
/// 字段都是“值”，没有需要 UI 自己累积的东西。
public struct FollowFocusState {
  // 链路
  public var connected = false
  /// 链路**真的通**：socket 开着，并且最近收到过状态回包。
  ///
  /// `connected` 只说明本地 socket bind 成功，电话掉出板子热点、或者 App 刚从
  /// 后台醒来还没发包时它照样是 true；`enabled/standby/canOk` 也是"收到过就
  /// 不再失效"的字段。所以界面要判"现在通不通"必须用这个，不要再自己看
  /// `connected` —— 否则顶栏会显示 `EN SLP UART` 而实际一个包都没通，
  /// 让人去查错的方向。
  public var linkAlive = false
  public var deviceId: String?
  public var host: String?
  public var port: UInt16 = kFfDefaultPort
  public var localPort: UInt16?
  public var localAddrs: [String] = []
  /// 最近一次扫描发现的候选板子。
  public var devices: [FfDiscovery] = []

  // 电机
  public var pos: Int32 = 0
  public var target: Int32 = 0
  public var enabled = false
  public var moving = false
  public var canOk = false
  public var standby = false
  public var limitHit = false
  public var result = kResultIdle
  public var positionTrusted = false

  // 单位换算
  public var microsteps = 1
  public var stepsPerRev = 4096
  /// 当前细分下的速度上限（圈/秒）。UI 用它提示“1/256 只有 0.39 行程/秒”。
  public var maxRevsPerSec = 0.0
  /// 当前位置换算成圈，给界面显示用，省得 UI 再自己算一遍。
  public var posRevs = 0.0
  public var strokeRevs = 0.0

  // 会话
  public var auto = false
  public var stopLatched = false
  public var slider = 0.5
  public var speedRevS = 64.0 / 4096
  public var accelRevS2 = 30.0
  public var standbyFeature = false
  public var faces = false

  // 镜头与流程
  public var lensId: String?
  public var lensName = ""
  public var lenses: [Lens] = []
  public var phase: SetupPhase = .stroke
  public var nearSteps: Int?
  public var dir = 1
  public var strokeSteps = 0
  public var lutPoints: [LutPoint] = []
  public var limitLo = 0
  public var limitHi = 0
  /// 行程标定中已记录的端点 A。
  public var strokeA: Int?

  // 距离
  public var distanceM: Double?

  // 诊断
  public var lastSentSequence: UInt8 = 0
  public var lastEchoedSequence: UInt8 = 0
  public var statusAgeMs: Int?
  public var echoAgeMs: Int?
  public var rxPackets = 0
  public var probeTx = 0
  public var socketError: String?
  public var fm03: Fm03Dump?
  public var fm03Log: [String] = []
  public var msg = ""
  public var calSupported = false
  public var calStage = "idle"
  public var calError = 0
  public var calSafeSpan = 0
  public var calTravel = 0
  public var calDirectionPending = false
}

/// 「链路还活着」的判定窗口：App 每 200 ms 发一次 QUERY，固件每次都回 STATUS，
/// 所以 1.5 s（7 次没回）已经是很宽松的“断了”。
let kLinkAliveWindow: TimeInterval = 1.5

/// App 侧判定出来的标定失败的 `calError` 起始值。
///
/// 固件错误码是紧凑递增的（`PROTOCOL.md` §14 的 0–11），以后还会加；App 自己的
/// “根本没收到回包”必须和固件错误码区分开，所以从 20 起编，中间留空档。
let kAppCalErrorBase = 20

/// 对应 `kAppCalErrorBase + n` 的文案，顺序与下标一致。
let appCalReasons = [
  "标定前握手没有回包：检查链路，并确认固件 ≥1.1.0",
  "固件没有回应标定命令：确认固件 ≥1.1.0 且未丢包",
]

/// 会话编排：**所有跟焦逻辑的唯一位置**。
///
/// 职责边界：
/// - `MotorLink` 只管收发，`LensStore` 只管存档，LiDAR 只管采样；
/// - 这里决定“什么时机发什么”：20ms 控制 tick、使能自愈、停机闩锁、
///   自动跟焦死区、相位机（标定/对齐/跟焦）、软限位下发；
/// - UI 只读 [FollowFocusState] 并调下面这些命令方法，不复制任何逻辑。
///
/// 线程模型：所有内部状态只在 session queue 上改；[onState] 一定在主线程回调。
public final class FollowFocusSession {
  public let cal: MotorCal
  public let store: LensStore
  public let link: MotorLink
  /// 上次用过的板子，冷启动自动恢复（见 [DeviceMemo]）。
  private let memo: DeviceMemo

  /// 状态快照回调（主线程）。约 20Hz；未连接且无变化时不重复推。
  public var onState: ((FollowFocusState) -> Void)?

  private let queue = DispatchQueue(label: "ff.session")
  private var timer: DispatchSourceTimer?

  private var state = FollowFocusState()
  private var lens: Lens?

  // 以下是纯内部量，不给 UI。
  private var aligned = false
  private var strokeA: Int?
  private var appliedStepsPerRev = 0
  private var wantEnabled = false
  private var pendingJog: Int32 = 0
  private var lastEnableAttempt = Date.distantPast
  private var lastAutoSend = Date.distantPast
  private var lastSent: Int32?
  /// 最近一次发出**控制包**（SET_POS/JOG）的时刻，看门狗保活用。
  /// 不能用 `lastQuery`：QUERY 不算控制包，固件不会因此重置超时。
  private var lastControlSent = Date.distantPast
  private var sliderDirty = false
  private var stopLatched = false
  private var lastQuery = Date.distantPast
  private var lastProbe = Date.distantPast
  private var lastFm03 = Date.distantPast
  private var lastStatusAt: Date?
  private var filter = DistFilter()
  private var distance: Double?
  private var socketErrorText: String?
  private var revision = 0
  private var lastEmittedRevision = -1
  private var discovered: [FfDiscovery] = []
  private var device: FfDiscovery?
  private enum CalPhase { case idle, stopping, checking, enabling, reading, starting, running, direction }
  private var calPhase = CalPhase.idle
  private var calSeq: UInt8 = 0
  private var calRun: UInt8 = 0
  private var calThreshold: Int32 = 60
  private var calMaxSteps: Int32 = 0
  private var calSentAt = Date.distantPast
  private var calLastReply = Date.distantPast
  private var calLastQuery = Date.distantPast
  private var calQueries = Set<UInt8>()
  private var calPositionValid = false
  private var calPendingLensId: String?
  private var lastFm03At = Date.distantPast
  private var calHighestState: UInt8 = 0
  private var calRecoveryRequired = false

  public init(store: LensStore, cal: MotorCal = MotorCal(), memo: DeviceMemo = DeviceMemo()) {
    self.store = store
    self.cal = cal
    self.memo = memo
    self.link = MotorLink()
    link.onStatus = { [weak self] s in self?.queue.async { self?.applyStatus(s) } }
    link.onStatusV2 = { [weak self] s in self?.queue.async { self?.applyStatusV2(s) } }
    link.onFm03 = { [weak self] t in self?.queue.async { self?.applyFm03(t) } }
    link.onCalStatus = { [weak self] c in self?.queue.async { self?.applyCalStatus(c) } }
    link.onSent = { [weak self] seq in
      self?.queue.async {
        self?.state.lastSentSequence = seq
        self?.markDirty()
      }
    }
    link.onSocketError = { [weak self] e in
      self?.queue.async {
        self?.socketErrorText = "\(e)"
        self?.markDirty()
      }
    }
  }

  deinit {
    timer?.cancel()
    link.close()
  }

  // MARK: - 生命周期

  public func start() {
    queue.async {
      // 冷启动先认回上次那台板子，省掉"重新扫描 + 选用"两坐标。
      // 放在 timer 守卫之前：重复调用 start() 时也要能补上这次恢复。
      self.restoreDeviceOnQueue()
      guard self.timer == nil else { return }
      let t = DispatchSource.makeTimerSource(queue: self.queue)
      t.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(5))
      t.setEventHandler { [weak self] in self?.tick() }
      self.timer = t
      t.resume()
      self.emit()
    }
  }

  /// 恢复上次的板子并直接连接。没有存过、或者已经选过设备就什么都不做。
  ///
  /// 和设备页里手动"选用"走同一条 [openLinkOnQueue]：同样会下发速度/限位/待机
  /// 偏好和 ENABLE(1)。**这是有物理后果的**（线圈通电、镜头被握住），和用户手动
  /// 点"连接电机"一致；所以只在有存档时做，且只在启动时做一次。
  private func restoreDeviceOnQueue() {
    guard device == nil, let saved = memo.load() else { return }
    device = saved
    state.deviceId = saved.deviceId
    state.calSupported = saved.fwMajor >= 2
    link.useDevice(saved)
    openLinkOnQueue()
    setMsg("已恢复上次的板子 \(saved.deviceId)：\(saved.host):\(saved.udpPort)")
  }

  public func stop() {
    queue.async {
      self.cancelCalibrationOnQueue("已停止")
      self.timer?.cancel()
      self.timer = nil
      self.link.close()
      self.markDirty()
      self.emit()
    }
  }

  // MARK: - 输入

  /// LiDAR 采样入口。nil 表示这一帧没测到：保持上一次的距离，不清零。
  public func ingest(distanceMeters: Double?) {
    queue.async {
      guard let meters = distanceMeters else { return }
      self.distance = self.filter.update(meters)
      self.markDirty()
    }
  }

  /// 只影响 UI 显示的人脸跟踪开关。
  public func setTrackFaces(_ on: Bool) {
    queue.async {
      self.state.faces = on
      self.markDirty()
    }
  }

  // MARK: - 设备

  public func selectDevice(_ d: FfDiscovery) {
    queue.async {
      self.cancelCalibrationOnQueue("已切换设备")
      self.invalidatePosition("已切换设备，请重新对齐")
      self.device = d
      self.state.calSupported = d.fwMajor >= 2
      self.link.useDevice(d)
      self.memo.save(d)
      self.state.deviceId = d.deviceId
      self.setMsg("已选 \(d.deviceId)（\(d.host):\(d.udpPort)）")
    }
  }

  /// 扫描板子。阻塞约 `tries × 120ms + timeout`，所以去后台线程，结果回主线程。
  ///
  /// 扫到几台都回报给 UI，由 UI 决定用哪台（只有一台时 [connect] 会自动选）。
  public func discover(completion: (([FfDiscovery]) -> Void)? = nil) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      var found: [FfDiscovery] = []
      var failure: String?
      do {
        found = try discoverBoards()
      } catch {
        failure = "\(error)"
      }
      self.queue.async {
        self.discovered = found
        if let failure {
          self.socketErrorText = failure
        } else {
          self.setMsg(found.isEmpty ? "没找到板子：先在系统里连上它的热点 FF-XXXXXX" : "发现 \(found.count) 台板子")
        }
        self.emit()
      }
      DispatchQueue.main.async { completion?(found) }
    }
  }

  /// 连接。没选设备就先扫描：只发现一台直接选，否则提示先选用（候选在快照的 devices 里）。
  public func connect() {
    queue.async {
      guard self.calPhase == .idle else {
        self.setMsg("标定期间不能重连，请先取消标定")
        return
      }
      if self.link.host != nil {
        self.openLinkOnQueue()
        return
      }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self else { return }
        var found: [FfDiscovery] = []
        var failure: String?
        do {
          found = try discoverBoards()
        } catch {
          failure = "\(error)"
        }
        self.queue.async {
          self.discovered = found
          if let failure {
            self.socketErrorText = failure
            self.setMsg("扫描失败：\(failure)")
          } else if found.count == 1 {
            self.device = found[0]
            self.state.calSupported = found[0].fwMajor >= 2
            self.link.useDevice(found[0])
            self.state.deviceId = found[0].deviceId
            self.openLinkOnQueue()
          } else {
            self.setMsg(
              found.isEmpty
                ? "没找到板子：先在系统里连上它的热点 FF-XXXXXX"
                : "发现 \(found.count) 台板子，请先选用一台")
          }
          self.emit()
        }
      }
    }
  }

  public func disconnect() {
    queue.async {
      self.cancelCalibrationOnQueue("已断开")
      self.invalidatePosition("已断开，请重新对齐")
      self.link.close()
      self.wantEnabled = false
      self.setMsg("已断开")
    }
  }

  private func openLinkOnQueue() {
    guard let host = link.host else {
      setMsg("还没选设备：先扫描并选用")
      return
    }
    guard let device, device.fwMajor >= 2, device.protocolVersion == 2 else {
      setMsg("请先升级 ESP32 至 FM03 2.0 固件并重新扫描设备")
      return
    }
    do {
      invalidatePosition("连接后请重新对齐")
      try link.open()
      appliedStepsPerRev = 0
      applySpeed()
      applyLimits()
      // 板子重启后固件 enabled 会归零，这里补一次使能，让状态自愈。
      wantEnabled = true
      lastEnableAttempt = Date()
      link.enable(true)
      link.query()
      link.queryFm03()
      state.localAddrs = Self.localIPv4Addrs()
      setMsg("已连接 \(host):\(link.port)")
    } catch {
      setMsg("连接失败 \(error)")
    }
  }

  // MARK: - 手动控制

  public func enable(_ on: Bool) {
    queue.async {
      if self.calPhase != .idle { if !on { self.cancelCalibrationOnQueue("已禁用") }; return }
      if !on { self.invalidatePosition("已禁用，请重新定位") }
      self.wantEnabled = on
      self.stopLatched = false
      self.link.enable(on)
      if !on { self.lastSent = nil }
      self.markDirty()
    }
  }

  /// 停机闩锁：点“停”之后不再自动重发目标，否则自动跟焦会在 20ms 内把它覆盖掉。
  public func stopPressed() {
    queue.async {
      if self.calPhase != .idle { self.cancelCalibrationOnQueue("已停机"); return }
      self.link.stop()
      self.takeManual("停机")
      self.stopLatched = true
      self.lastSent = nil
      self.sliderDirty = false
      self.setMsg("已停机")
    }
  }

  /// 软件置零会把当前位置变成 0，对齐建立的最近点参考随之失效，必须重对齐。
  public func homePressed() {
    queue.async {
      guard self.calPhase == .idle else { return }
      self.invalidatePosition("已软件置零，请重新定位")
      self.calRecoveryRequired = false
      self.link.home()
      self.unalignOnQueue("已软件置零，请重新对齐最近点")
    }
  }

  public func jog(_ delta: Int32) {
    queue.async { self.jogOnQueue(delta) }
  }

  public func setSlider(_ v: Double) {
    queue.async {
      guard self.calPhase == .idle else { return }
      self.state.slider = min(max(v, 0), 1)
      self.sliderDirty = true
      self.stopLatched = false
      self.lastSent = nil
      self.markDirty()
    }
  }

  public func setAuto(_ on: Bool) {
    queue.async {
      guard self.calPhase == .idle else { return }
      guard self.phase == .follow, self.lens?.lut.ready == true else { return }
      self.state.auto = on
      self.lastSent = nil
      self.stopLatched = false
      self.lastAutoSend = .distantPast
      self.filter.reset()
      self.markDirty()
    }
  }

  /// 速度和加速度都用**物理单位**（圈/秒、圈/秒²），换细分不会改变物理速度。
  public func setSpeed(revsPerSec: Double, accelRevsPerSec2: Double) {
    queue.async {
      guard self.calPhase == .idle else { return }
      guard revsPerSec.isFinite else { return }
      self.state.speedRevS = min(max(revsPerSec, 1.0/4096), 256.0/4096)
      self.state.accelRevS2 = max(accelRevsPerSec2, 0)
      self.applySpeed()
      self.markDirty()
    }
  }

  public func setFm03(_ key: Int32, _ value: Int32) {
    queue.async {
      guard self.calPhase == .idle else { return }
      let valid = key == kFm03MaxSpeed ? (1...256).contains(value) :
        ((key == kFm03Tolerance || key == kFm03Gain) && (1...64).contains(value))
      guard valid else { self.setMsg("FM03 参数超出范围"); return }
      self.link.setFm03(key, value)
      self.markDirty()
    }
  }
  public func queryFm03() { queue.async { self.link.queryFm03() } }

  // MARK: - 镜头

  public func selectLens(id: String) {
    queue.async {
      self.cancelCalibrationOnQueue("已切换镜头")
      if self.link.isOpen { self.link.stop(); self.link.enable(false) }
      self.invalidatePosition("已切换镜头")
      self.calRecoveryRequired = false
      self.lens = self.store.lenses.first { $0.id == id }
      // 每换一个镜头都要重新对齐：最近点是会话量，跨镜头没有意义。
      self.aligned = false
      self.state.nearSteps = nil
      self.state.dir = self.lens?.dir ?? 1
      self.state.auto = false
      self.strokeA = nil
      self.lastSent = nil
      self.setMsg(self.lens.map { "镜头 \($0.name)" } ?? "未选镜头")
    }
  }

  public func createLens(name: String, params: String) {
    queue.async {
      self.cancelCalibrationOnQueue("已切换镜头")
      if self.link.isOpen { self.link.stop(); self.link.enable(false) }
      self.invalidatePosition("已切换镜头")
      self.calRecoveryRequired = false
      let l = Lens(id: Lens.newId(), name: name, params: params)
      self.store.upsert(l)
      self.persist()
      self.lens = l
      self.aligned = false
      self.state.nearSteps = nil
      self.state.dir = l.dir
      self.state.auto = false
      self.strokeA = nil
      self.lastSent = nil
      self.setMsg("新镜头 \(l.name)：先标定行程")
    }
  }

  public func deleteLens(id: String) {
    queue.async {
      if self.lens?.id == id { self.cancelCalibrationOnQueue("已删除镜头") }
      if self.lens?.id == id {
        if self.link.isOpen { self.link.stop(); self.link.enable(false) }
        self.invalidatePosition("已删除镜头")
        self.calRecoveryRequired = false
      }
      self.store.remove(id: id)
      self.persist()
      if self.lens?.id == id {
        self.lens = nil
        self.aligned = false
        self.state.nearSteps = nil
        self.state.auto = false
        self.lastSent = nil
      }
      self.setMsg("已删除镜头")
    }
  }

  private func requireFreshPosition() -> Bool {
    guard state.positionTrusted, let at=lastStatusAt,
      Date().timeIntervalSince(at)<0.5, state.canOk else {
      setMsg("请先完成 FM03 内部校准，等待新鲜阶段3坐标")
      return false
    }
    return true
  }

  // MARK: - 行程标定（①）

  /// 行程标定：先记一端，再记另一端，两点距离就是行程长度。
  public func recordStrokeA() {
    queue.async {
      guard self.calPhase == .idle, self.requireFreshPosition() else { return }
      self.strokeA = Int(self.state.pos)
      self.setMsg("已记录端点 A = \(self.state.pos) 坐标，请转到行程另一端再记录")
    }
  }

  public func finishStroke() {
    queue.async {
      guard self.calPhase == .idle, self.requireFreshPosition() else { return }
      guard let lens = self.lens, let a = self.strokeA else { return }
      let stroke = abs(Int(self.state.pos) - a)
      guard stroke >= 1 else {
        self.setMsg("A 和 B 几乎在同一位置，请转到行程另一端再记录")
        return
      }
      var next = lens
      next.strokeSteps = stroke
      next.strokeMicrosteps = self.microsteps
      next.autoTravel = nil
      next.autoSafeSpan = nil
      next.autoFirmware = nil
      self.calRecoveryRequired = false
      self.updateLensOnQueue(next)
      self.strokeA = nil
      self.setMsg(
        "行程已标定：\(stroke) 坐标"
          + "（\(self.fmt(self.cal.stepsToRevs(stroke, self.microsteps))) 行程），接下来对齐最近点")
    }
  }

  /// 行程标定的防误触：清空重标要 UI 先确认，避免碰到就把行程弄丢。
  public func recalibrateStroke() {
    queue.async {
      guard self.calPhase == .idle else { return }
      guard let lens = self.lens else { return }
      if lens.autoTravel != nil {
        self.link.stop()
        self.link.home()
        self.invalidatePosition("已清空自动行程并软件置零，请手动记录两端")
      }
      var next = lens
      next.strokeSteps = nil
      next.autoTravel = nil
      next.autoSafeSpan = nil
      next.autoFirmware = nil
      self.updateLensOnQueue(next)
      self.strokeA = nil
      self.calRecoveryRequired = false
      self.unalignOnQueue("行程已清空，请重新标定")
    }
  }

  /// 机械双端标定。参数在这里验证，UI 只负责收集用户输入。
  public func startAutoCalibration(threshold: Int, maxRevs: Double) {
    queue.async {
      guard self.calPhase == .idle, self.state.calSupported, self.link.isOpen,
        let lens = self.lens else {
        self.setMsg("需连接 FM03 2.0 固件并选择镜头")
        return
      }
      guard let t = self.state.fm03, t.online, t.feedbackAge <= 300,
        Date().timeIntervalSince(self.lastFm03At) < 1.5 else {
        self.link.queryFm03()
        self.setMsg("等待 FM03 的新鲜 CAN 反馈，请稍后重试")
        return
      }
      self.calThreshold = 0
      self.calMaxSteps = 0
      self.calQueries.removeAll()
      self.calHighestState = 0
      self.calLastQuery = .distantPast
      self.calLastReply = .distantPast
      self.calPendingLensId = lens.id
      self.state.auto = false
      self.pendingJog = 0
      self.sliderDirty = false
      self.lastSent = nil
      self.stopLatched = true
      self.wantEnabled = false
      self.aligned = false
      self.state.nearSteps = nil
      self.calPositionValid = false
      self.state.calDirectionPending = false
      self.state.calError = 0
      self.calRecoveryRequired = true
      self.state.calStage = "preparing"
      self.calPhase = .stopping
      self.calSeq = self.link.stop()
      self.calSentAt = Date()
      self.setMsg("正在停止电机并检查状态")
    }
  }

  public func cancelAutoCalibration() {
    queue.async { self.cancelCalibrationOnQueue("停止观察；FM03 内部标定仍会继续，请等待完成或断开电机电源") }
  }

  public func leaveLens() {
    queue.async {
      self.cancelCalibrationOnQueue("已离开镜头")
      if self.link.isOpen { self.link.stop(); self.link.enable(false) }
      self.wantEnabled = false
      self.invalidatePosition("已离开镜头，下次使用请重新定位")
    }
  }

  private func cancelCalibrationOnQueue(_ reason: String) {
    guard calPhase != .idle else { return }
    link.calCancel()
    link.enable(false) // 完成态的 CAL_CANCEL 幂等，显式禁用才会释放坐标。
    calPhase = .idle
    calQueries.removeAll()
    calPositionValid = false
    calPendingLensId = nil
    state.calDirectionPending = false
    state.calStage = "cancelled"
    state.auto = false
    wantEnabled = false
    pendingJog = 0
    invalidatePosition(reason)
  }

  private func invalidatePosition(_ message: String) {
    aligned = false
    state.nearSteps = nil
    state.auto = false
    state.positionTrusted = false
    calPositionValid = false
    state.calSafeSpan = 0
    state.calTravel = 0
    lastSent = nil
    pendingJog = 0
    sliderDirty = false
    stopLatched = true
    wantEnabled = false
    setMsg(message)
  }

  private func applyCalStatus(_ c: CalStatus) {
    let now = Date()
    switch calPhase {
    case .reading:
      guard c.sequence == calSeq else { return }
      calRun = ffNextSequence(after: c.runId)
      calPhase = .starting
      calSeq = calRun
      link.calStart(runId: calRun, threshold: calThreshold, maxSteps: calMaxSteps)
      calSentAt = now
      calLastReply = now
      state.calStage = "starting"
    case .starting:
      guard c.sequence == calRun || calQueries.remove(c.sequence) != nil else { return }
      if c.sequence == calRun && c.error != 0 { failCalibration(error: Int(c.error)); return }
      guard c.runId == calRun else { return }
      if c.state == 6 || c.state == 7 {
        failCalibration(error: Int(c.error)); return
      }
      guard (1...5).contains(c.state) else { return }
      calPhase = .running
      calLastReply = now
      updateCalibration(c)
    case .running:
      guard c.runId == calRun, calQueries.remove(c.sequence) != nil else { return }
      calLastReply = now
      updateCalibration(c)
    case .direction:
      guard c.runId == calRun, calQueries.remove(c.sequence) != nil else { return }
      calLastReply = now
      lastStatusAt = now
      if c.state != 5 || c.error != 0 || !c.valid ||
        c.safeMin != 0 || Int(c.safeMax) != state.calSafeSpan {
        failCalibration(error: c.error == 0 ? 9 : Int(c.error))
      }
    default: return
    }
    markDirty()
  }

  private func updateCalibration(_ c: CalStatus) {
    if c.state < calHighestState && c.state < 6 { return }
    calHighestState = c.state
    state.calStage = ["idle", "seek_negative", "backoff_negative", "seek_positive",
      "backoff_positive", "completed", "cancelled", "failed"][Int(c.state)]
    state.calError = Int(c.error)
    if c.state == 5 {
      guard c.error == 0, c.valid, c.safeMin == 0,
        c.safeMax == 4096, c.travel == 4096,
        c.microsteps == 1, (0...4096).contains(c.pos),
        calPendingLensId == lens?.id else {
        failCalibration(error: c.error == 0 ? 9 : Int(c.error)); return
      }
      var next = lens!
      next.strokeSteps = Int(c.safeMax)
      next.strokeMicrosteps = Int(c.microsteps)
      next.autoTravel = Int(c.travel)
      next.autoSafeSpan = Int(c.safeMax)
      next.autoFirmware = device?.firmware
      next.lut = LensLut([]) // 新原点和行程不能沿用旧距离表。
      updateLensOnQueue(next)
      calPositionValid = true
      calRecoveryRequired = false
      lastStatusAt = Date()
      state.positionTrusted = true
      state.pos = c.pos
      state.target = c.pos
      state.calSafeSpan = Int(c.safeMax)
      state.calTravel = Int(c.travel)
      state.calDirectionPending = true
      calQueries.removeAll()
      calPhase = .direction
      setMsg("行程已识别，请确认正坐标数使对焦距离变远还是变近；距离标定需重做")
    } else if c.state == 6 || c.state == 7 || c.error != 0 {
      failCalibration(error: Int(c.error))
    }
  }

  /// `error` 是固件错误码；`>= kAppCalErrorBase` 的是 App 自己判定出来的
  /// 通信失败（固件根本没能参与），文案在同一张表里，界面不用分两套。
  private func failCalibration(error: Int) {
    state.calError = error
    state.calStage = "failed"
    calPhase = .idle
    calPositionValid = false
    calPendingLensId = nil
    state.calDirectionPending = false
    calQueries.removeAll()
    wantEnabled = false
    link.calCancel()
    link.enable(false)
    let reasons = [
      "未知原因", "参数无效，请调整阈值和最大圈数", "电机未使能、运动中或忙，请停机后重试",
      "CAN 通信异常，请检查收发器和供电", "驱动故障，请检查供电和电机",
      "寻端超过最大距离，请检查挡块或增大最大圈数", "阶段超时，请检查齿轮啮合",
      "标定保活超时，请检查连接", "采样中断超时，请重试",
      "行程过短或空载读数无效，请调整阈值并检查机械行程", "用户取消",
      "FM03 内部标定无法软件取消，请等待完成或切断电机电源",
    ]
    let reason: String
    let appIndex = error - kAppCalErrorBase
    if error >= kAppCalErrorBase, appCalReasons.indices.contains(appIndex) {
      reason = appCalReasons[appIndex]
    } else if reasons.indices.contains(error) {
      reason = reasons[error]
    } else {
      reason = "未知错误 \(error)"
    }
    invalidatePosition("自动标定失败：\(reason)")
  }

  // MARK: - 单侧对齐（②）

  /// 确认焦距最近点。方向默认用距离标定表推断，没有表就用上次选过的方向。
  public func confirmNear() {
    queue.async {
      guard self.calPhase == .idle, self.requireFreshPosition() else { return }
      self.state.nearSteps = Int(self.state.pos)
      self.state.dir = inferDir(self.lens?.lut ?? LensLut([])) ?? (self.lens?.dir ?? 1)
      self.setMsg("最近点 = \(self.state.pos) 坐标，选好变远方向后开始")
    }
  }

  /// 只改方向（对齐之后也能改）。
  ///
  /// 必须同时更新 `state.dir` 和镜头里的 `dir`：前者决定本次会话的软限位，
  /// 后者是持久化的物理属性，只写一个会让界面选的方向不生效。
  public func setDir(_ d: Int) {
    queue.async {
      guard self.calPhase == .idle || self.calPhase == .direction else { return }
      let normalized = d >= 0 ? 1 : -1
      if self.calPhase == .direction {
        self.state.nearSteps = normalized > 0 ? 0 : self.state.calSafeSpan
        self.state.calDirectionPending = false
        self.calPhase = .idle
      } else if self.calPositionValid {
        self.state.nearSteps = normalized > 0 ? 0 : self.state.calSafeSpan
      }
      self.state.dir = normalized
      if var lens = self.lens {
        if lens.dir != normalized && lens.lut.ready {
          lens.lut = LensLut([])
          self.setMsg("方向已改变，距离标定点已清空，请重新标定距离")
        }
        lens.dir = normalized
        self.updateLensOnQueue(lens)
      }
      self.lastSent = nil
      if !self.calPositionValid { self.applyLimits() }
      self.markDirty()
    }
  }

  /// 选定方向后真正进入跟焦：把距离标定表锚到本次会话的坐标系，再下发软限位。
  public func startFollow() {
    queue.async { if self.calPhase == .idle { self.startFollowOnQueue() } }
  }

  /// 作废本次对齐，并把固件软限位恢复成默认值。
  ///
  /// 必须真正下发默认限位：否则固件还留着上一轮对齐的窄区间，
  /// 对齐阶段的“自由微调”会在旧边界被夹住，表现是微调不动。
  public func unalign() {
    queue.async {
      if self.calPhase != .idle { self.cancelCalibrationOnQueue("已退出自动标定") }
      self.unalignOnQueue("重新对齐最近点")
    }
  }

  // MARK: - 距离标定（③）

  public func addLutPoint() {
    queue.async {
      guard self.calPhase == .idle, self.requireFreshPosition() else { return }
      guard let lens = self.lens, let d = self.distance else { return }
      var next = lens
      next.lut = lens.lut.adding(
        LutPoint(meters: d, steps: Int(self.state.pos)), microsteps: self.microsteps)
      self.updateLensOnQueue(next)
    }
  }

  public func removeLutPoint(at index: Int) {
    queue.async {
      guard self.calPhase == .idle else { return }
      guard let lens = self.lens else { return }
      var next = lens
      next.lut = lens.lut.removingAt(index)
      self.updateLensOnQueue(next)
    }
  }

  // MARK: - 内部：tick

  private var microsteps: Int { state.microsteps }
  private var stepsPerRev: Int { cal.stepsPerRev(microsteps) }

  private var phase: SetupPhase {
    guard let lens, lens.calibrated else { return .stroke }
    if calRecoveryRequired { return .stroke }
    if lens.autoTravel != nil && !calPositionValid { return .stroke }
    if !aligned || state.nearSteps == nil { return .align }
    return .follow
  }

  private func tick() {
    let now = Date()
    if calPhase != .idle {
      tickCalibration(now)
      emit()
      return
    }
    if calPositionValid && (lastStatusAt == nil || now.timeIntervalSince(lastStatusAt!) > 2) {
      link.stop()
      link.enable(false)
      invalidatePosition("状态回包超时，已释放电机；请重新定位")
    }
    if link.isOpen {
      // 200ms 轮询状态：位置反馈用。**注意它喂不了固件看门狗** ——
      // 固件只把 SET_POS/JOG 当控制包（`motorNoteControlPacket`），
      // QUERY 不计入 `lastControlPacketMs`。保活见下面 `lastControlSent`。
      if now.timeIntervalSince(lastQuery) > 0.2 {
        lastQuery = now
        link.query()
      }
      if now.timeIntervalSince(lastProbe) > 1.0 {
        lastProbe = now
        link.probe()
      }
      if now.timeIntervalSince(lastFm03) > 1.0 {
        lastFm03 = now
        link.queryFm03()
      }
      // 细分变化会改变“坐标”的尺度：重算速度，并把软限位按新细分重新下发。
      if stepsPerRev != appliedStepsPerRev {
        appliedStepsPerRev = stepsPerRev
        applySpeed()
        applyLimits()
      }
      // 板子重启后固件 enabled 会归零，App 这边补一次使能，让状态自愈。
      if wantEnabled, !state.enabled, now.timeIntervalSince(lastEnableAttempt) > 1.0 {
        lastEnableAttempt = now
        link.enable(true)
      }
      if state.enabled, !stopLatched {
        var want: Int32?
        if state.auto {
          if let d = distance { want = autoSteps(d) }
        } else if sliderDirty {
          want = sliderSteps()
          sliderDirty = false
        }
        if let candidate = want {
          if state.auto {
            // 死区和最小间隔：距离微抖会让目标每 tick 变几坐标，每段都是三角形微动，
            // 表现就是“一直缓慢转动、永远停不下来”。
            //
            // 注意：只在**已经发过目标**时才比死区。忘了这一层就会写成
            // `abs(want - (lastSent ?? want)) < 死区`，在 lastSent 为 nil 时恒等 0，
            // 于是每次都被判定“没跨过死区”而丢弃——自动跟焦永远发不出第一个目标，
            // 电机只会被手动滑条推动。（Dart 版 `lib/main.dart` 就是这个 bug。）
            if let last = lastSent, abs(candidate - last) < kAutoDeadbandSteps {
              want = nil
            } else if now.timeIntervalSince(lastAutoSend) < 0.06 {
              want = nil
            } else {
              lastAutoSend = now
            }
          } else if candidate == lastSent {
            want = nil
          }
        }
        if let target = want {
          lastSent = target
          lastControlSent = now
          link.setPos(target)
        }
        // 看门狗保活：固件只把 SET_POS/JOG 当控制包，静默 >1s 就刹停
        // （`kControlTimeoutMs`，且只在 `ARMED && MOVING` 时生效）。
        // 所以“目标没变”不等于“不用发”：一次 >1s 的行程会在中途被刹掉，
        // 表现就是“点了走一半就停” —— 这是 §7 记过的“控制有时候不灵”的根因。
        // 重发同一个 SET_POS 是幂等的，顺带解除待机，所以按 ≤400ms 重发当前目标。
        else if state.moving, let last = lastSent,
          now.timeIntervalSince(lastControlSent) > 0.4
        {
          lastSent = last
          lastControlSent = now
          link.setPos(last)
        }
      }
    }
    emit()
  }

  private func tickCalibration(_ now: Date) {
    guard link.isOpen else { cancelCalibrationOnQueue("连接已断开"); return }
    switch calPhase {
    // 还没发出 CAL_START 就超时：连 STOP/QUERY/ENABLE 的回包都没到，
    // 这不是“保活”，而是链路或固件版本问题，必须分开报。
    case .stopping, .checking, .enabling, .reading:
      if now.timeIntervalSince(calSentAt) > 1.2 {
        failCalibration(error: kAppCalErrorBase + 0)
      }
    case .starting:
      if now.timeIntervalSince(calLastQuery) >= 0.2 {
        calLastQuery = now
        calQueries.insert(link.calQuery(runId: calRun))
      }
      if now.timeIntervalSince(calSentAt) > 0.4 {
        link.calStart(runId: calRun, threshold: calThreshold, maxSteps: calMaxSteps)
        calSentAt = now
      }
      // 3 s 是“连 CAL_START 的拒绝回包都没收到”。收到拒绝会立刻走
      // `applyCalStatus`，所以这里只可能是丢包或固件不认这条命令。
      if now.timeIntervalSince(calLastReply) > 3.0 {
        failCalibration(error: kAppCalErrorBase + 1)
      }
    case .running:
      if now.timeIntervalSince(calLastQuery) >= 0.2 {
        calLastQuery = now
        let seq = link.calQuery(runId: calRun)
        calQueries.insert(seq)
        if calQueries.count > 32 { calQueries.removeAll(); calQueries.insert(seq) }
      }
      // 已经在跑，查询也一直发：这才是真正的保活断链（固件 1000 ms 停机）。
      if now.timeIntervalSince(calLastReply) > 1.2 { failCalibration(error: 7) }
    case .direction:
      if now.timeIntervalSince(calLastQuery) >= 0.2 {
        calLastQuery = now
        calQueries.insert(link.calQuery(runId: calRun))
      }
      if now.timeIntervalSince(calLastReply) > 1.2 { cancelCalibrationOnQueue("标定结果已失联，请重新定位") }
    case .idle: break
    }
  }

  /// 自动跟焦目标：距离标定表查表，再夹进对齐软限位里，保证不超过行程。
  /// 表不足两点时返回 nil（没有可信目标就不动），而不是随便挑一端。
  private func autoSteps(_ meters: Double) -> Int32? {
    let lutNow = (lens?.lut ?? LensLut([])).scaledTo(microsteps)
    guard let v = lutNow.stepsFor(meters) else { return nil }
    let r = limitsFor(microsteps)
    return Int32(min(max(v, r.lo), r.hi))
  }

  private func sliderSteps() -> Int32 {
    let r = limitsFor(microsteps)
    if r.hi == r.lo { return Int32(r.lo) }
    return Int32((Double(r.lo) + state.slider * Double(r.hi - r.lo)).rounded())
  }

  /// 软限位：对齐后只有“最近点 → 远端”这一侧，绝不超过标定行程；
  /// 未对齐（标定/对齐阶段）用和固件默认一致的 ±20 行程，好让跟焦器自由微调。
  private func limitsFor(_ ms: Int) -> (lo: Int, hi: Int) {
    if calPositionValid { return (lo: 0, hi: state.calSafeSpan) }
    if aligned, let near = state.nearSteps {
      return alignedRange(near, state.dir, lens?.strokeAt(ms) ?? 0)
    }
    let span = cal.defaultLimitSpan(ms)
    return (lo: -span, hi: span)
  }

  private func applyLimits() {
    guard link.isOpen, calPhase == .idle, !calPositionValid,
      lens?.autoTravel == nil || calPositionValid else { return }
    let r = limitsFor(microsteps)
    link.setLimits(Int32(r.lo), Int32(r.hi))
  }

  /// 把物理单位换算成固件要的坐标/秒、坐标/秒²。
  private func applySpeed() {
    guard link.isOpen, calPhase == .idle else { return }
    let spd = Int32((state.speedRevS * Double(stepsPerRev)).rounded())
    link.setSpeed(min(max(spd, 1), 256), 0)
  }

  // MARK: - 内部：命令

  private func jogOnQueue(_ delta: Int32) {
    guard link.isOpen, delta != 0, calPhase == .idle else { return }
    let r = limitsFor(microsteps)
    let want = Int(state.pos) + Int(delta)
    guard want >= r.lo, want <= r.hi else {
      setMsg(
        "超出软限位 \(r.lo)..\(r.hi) 坐标（当前 \(state.pos)，请求 \(want)）。"
          + "请先完成 FM03 内部校准并重新对齐。")
      return
    }
    guard state.enabled else {
      // 板子重启后固件是关的：先补使能，并保留这次 JOG，待状态确认后执行。
      pendingJog += delta
      wantEnabled = true
      lastEnableAttempt = Date()
      link.enable(true)
      setMsg("正在使能，已暂存 \(pendingJog > 0 ? "+" : "")\(pendingJog) 坐标")
      return
    }
    takeManual("走坐标")
    stopLatched = false
    lastSent = nil
    lastControlSent = Date()
    link.jog(delta)
    sliderDirty = false
  }

  /// 用户手动介入（走坐标/拖滑条/停机）时退出自动跟焦。
  /// 不这样做的话自动逻辑会在下一个 tick 把手工动作拉回去，
  /// 看起来就像“操作完还在自己转”。
  private func takeManual(_ why: String) {
    if state.auto {
      state.auto = false
      filter.reset()
      setMsg("已退出自动跟焦（\(why)）")
    }
  }

  private func startFollowOnQueue() {
    guard requireFreshPosition(), let lens = self.lens, let near = state.nearSteps else { return }
    if lens.autoTravel != nil && !calPositionValid {
      setMsg("自动行程坐标已失效，请重新定位")
      return
    }
    let lutNow = lens.lut.scaledTo(microsteps)
    let delta = lutRebaseDelta(near, lutNow)
    var next = lens
    next.dir = state.dir
    if delta != 0 { next.lut = lutNow.shifted(delta) }
    self.lens = store.upsert(next)
    persist()
    aligned = true
    if !calPositionValid { applyLimits() }
    state.slider = 0
    sliderDirty = false
    lastSent = nil
    state.auto = false
    setMsg("对齐完成，可开始跟焦")
    markDirty()
  }

  private func unalignOnQueue(_ msg: String) {
    aligned = false
    state.nearSteps = nil
    state.auto = false
    lastSent = nil
    setMsg(msg)
    if !calPositionValid { applyLimits() }
  }

  private func updateLensOnQueue(_ next: Lens) {
    lens = store.upsert(next)
    persist()
    markDirty()
  }

  private func persist() {
    do {
      try store.save()
    } catch {
      setMsg("镜头存档写入失败：\(error)")
    }
  }

  // MARK: - 内部：回包

  private func applyStatus(_ s: MotorStatus) {
    if calPhase == .stopping, s.sequence == calSeq, !s.moving {
      calPhase = .checking
      calSeq = link.query()
      calSentAt = Date()
    } else if calPhase == .checking, s.sequence == calSeq, !s.moving {
      calPhase = .enabling
      calSeq = link.enable(true)
      calSentAt = Date()
    } else if calPhase == .enabling, s.sequence == calSeq, s.enabled, !s.moving {
      calPhase = .reading
      calSeq = link.calQuery(runId: 0)
      calSentAt = Date()
    }
    lastStatusAt = Date()
    state.lastEchoedSequence = s.sequence
    state.result = s.result
    state.pos = s.pos
    state.target = s.target
    state.enabled = s.enabled
    state.moving = s.moving
    state.canOk = s.canOk
    state.standby = s.standby
    state.limitHit = s.limited
    if calPhase == .idle, s.enabled, pendingJog != 0 {
      let delta = pendingJog
      pendingJog = 0
      takeManual("走坐标")
      stopLatched = false
      lastSent = nil
      sliderDirty = false
      link.jog(delta)
    }
    if s.limited { setMsg("已到软限位：\(s.pos) 坐标") }
    markDirty()
    emit()
  }

  private func applyStatusV2(_ s: MotorStatusV2) {
    if !s.positionTrusted && (calPositionValid || aligned) {
      if calPhase == .direction { cancelCalibrationOnQueue("设备坐标已失效，请重新标定") }
      else { invalidatePosition("设备坐标已失效，请重新定位") }
    }
    state.positionTrusted = s.positionTrusted
    state.pos = s.pos
    state.target = s.target
    markDirty()
  }

  private func applyFm03(_ t: Fm03Dump) {
    lastFm03At = Date()
    state.fm03 = t
    state.speedRevS = Double(t.maxSpeed) / 4096
    let ts = Self.clockLabel()
    state.fm03Log.insert("\(ts)  \(t.logLine())", at: 0)
    if state.fm03Log.count > 40 { state.fm03Log.removeLast(state.fm03Log.count - 40) }
    markDirty()
  }

  // MARK: - 内部：快照

  private func markDirty() { revision += 1 }

  private func setMsg(_ m: String) {
    state.msg = m
    markDirty()
  }

  private func emit() {
    // 未连接时没有位置/时间在变，没改动就不用推，省掉一堆无用消息。
    if !link.isOpen, revision == lastEmittedRevision { return }
    lastEmittedRevision = revision
    let snap = buildSnapshot()
    DispatchQueue.main.async { [weak self] in self?.onState?(snap) }
  }

  /// 当前快照。UI 首次绘制时直接取一次，不用等第一个事件。
  public func snapshot() -> FollowFocusState {
    queue.sync { buildSnapshot() }
  }

  private func buildSnapshot() -> FollowFocusState {
    var s = state
    s.connected = link.isOpen
    s.host = link.host
    s.port = link.port
    s.localPort = link.localPort
    s.rxPackets = link.rxPackets
    s.probeTx = link.probeTx
    s.devices = discovered
    s.calSupported = state.calSupported
    s.lensId = lens?.id
    s.lensName = lens?.name ?? ""
    s.lenses = store.lenses
    s.phase = phase
    s.strokeSteps = lens?.strokeAt(microsteps) ?? 0
    s.lutPoints = (lens?.lut ?? LensLut([])).scaledTo(microsteps).points
    s.stepsPerRev = stepsPerRev
    s.maxRevsPerSec = cal.maxRevsPerSec(microsteps)
    s.posRevs = cal.stepsToRevs(Int(s.pos), microsteps)
    s.strokeRevs = cal.stepsToRevs(s.strokeSteps, microsteps)
    let r = limitsFor(microsteps)
    s.limitLo = r.lo
    s.limitHi = r.hi
    s.stopLatched = stopLatched
    s.strokeA = strokeA
    s.distanceM = distance
    s.socketError = socketErrorText
    s.statusAgeMs = lastStatusAt.map { Int(Date().timeIntervalSince($0) * 1000) }
    s.echoAgeMs = link.lastEchoAt.map { Int(Date().timeIntervalSince($0) * 1000) }
    s.linkAlive =
      link.isOpen && lastStatusAt.map { Date().timeIntervalSince($0) < kLinkAliveWindow } ?? false
    return s
  }

  private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

  private static func clockLabel() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
  }

  /// 本机各网卡地址：确认 App 是否真的看到板子那块网卡
  /// （iOS 本地网络权限问题靠它排查，见 HANDOFF §8.1）。
  static func localIPv4Addrs() -> [String] {
    var result: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(ptr.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
      guard let sa = ptr.pointee.ifa_addr,
        sa.pointee.sa_family == UInt8(AF_INET)
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { continue }
      result.append("\(String(cString: ptr.pointee.ifa_name))=\(String(cString: host))")
    }
    return result
  }
}
