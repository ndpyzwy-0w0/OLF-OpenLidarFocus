import Foundation

/// 自动寻限位 → 选择物距方向 → 标定距离图表 → 跟焦。
public enum SetupPhase: String {
  case stroke
  case align
  case calibrate
  case follow
}

public enum ControlMode: String { case automatic, handwheel }

public enum WheelPullCurve: String {
  case smooth, linear

  public func progress(_ fraction: Double) -> Double {
    let t = min(max(fraction, 0), 1)
    return self == .linear ? t : t * t * (3 - 2 * t)
  }
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
  /// 兼容旧快照的归一化速度字段；界面使用最大拨轮值。
  public var maxRevsPerSec = 0.0
  /// 当前位置换算成圈，给界面显示用，省得 UI 再自己算一遍。
  public var posRevs = 0.0
  public var strokeRevs = 0.0

  // 会话
  public var auto = false
  public var stopLatched = false
  public var canResume = false
  public var controlMode: ControlMode = .automatic
  public var wheelReady = false
  public var wheelA: Int32?
  public var wheelB: Int32?
  public var wheelRangeEnabled = false
  public var wheelSensitivity = 1.0
  public var wheelReversed = false
  public var wheelPulling = false
  public var wheelPullCurve: WheelPullCurve = .smooth
  public var wheelArrival = ""
  public var wheelArrivalSequence = 0
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
  public var lutCurve: [LutPoint] = []
  public var lutReady = false
  public var limitLo = 0
  public var limitHi = 0

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
  "标定前握手没有回包：检查链路，并确认固件为 FM03 2.x",
  "固件没有回应标定命令：确认固件为 FM03 2.x 且未丢包",
]

/// 会话编排：**所有跟焦逻辑的唯一位置**。
///
/// 职责边界：
/// - `MotorLink` 只管收发，`LensStore` 只管存档，LiDAR 只管采样；
/// - 这里决定“什么时机发什么”：20ms 控制 tick、使能自愈、停机闩锁、
///   自动跟焦死区、相位机（寻限位/方向/物距/跟焦）、坐标范围检查；
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
  private var following = false
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
  private var resumeAuto = false
  private var lastStopSent = Date.distantPast
  private var wheelCoordinate = 0.0
  private var wheelArrivalTarget: (name: String, coordinate: Int32)?
  private var wheelPull: (started: Date, from: Double, to: Int32, duration: Double, curve: WheelPullCurve)?
  private var lastQuery = Date.distantPast
  private var lastProbe = Date.distantPast
  private var lastFm03 = Date.distantPast
  private var lastStatusAt: Date?
  private var positionQueries = Set<UInt8>()
  private var filter = DistFilter()
  private var distance: Double?
  private var distanceAt = Date.distantPast
  private var socketErrorText: String?
  private var revision = 0
  private var lastEmittedRevision = -1
  private var discovered: [FfDiscovery] = []
  private var device: FfDiscovery?
  private enum CalPhase { case idle, stopping, checking, enabling, reading, starting, running }
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
  private var pendingFm03: [Int32: (value: Int32, started: Date, sent: Date)] = [:]
  private var lastFm03At = Date.distantPast
  private var calHighestState: UInt8 = 0

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
  /// 和设备页里手动"选用"走同一条 [openLinkOnQueue]：读取设备已保存参数
  /// 并下发 ENABLE(1)。**这是有物理后果的**（线圈通电、镜头被握住），和用户手动
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

  /// LiDAR 采样入口。无效或过期测距停止自动输出，禁止记录旧距离。
  public func ingest(distanceMeters: Double?) {
    queue.async {
      guard let meters = distanceMeters, meters.isFinite, (0.05...1000).contains(meters) else {
        self.distance = nil
        self.filter.reset()
        self.markDirty()
        return
      }
      self.distanceAt = Date()
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
      self.invalidatePosition("已切换设备，请重新寻限位")
      self.device = d
      self.state.calSupported = d.fwMajor >= 2 && d.protocolVersion == 2
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
            self.state.calSupported = found[0].fwMajor >= 2 && found[0].protocolVersion == 2
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
      self.invalidatePosition("已断开，请重新寻限位")
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
      invalidatePosition("连接后请重新寻限位")
      try link.open()
      positionQueries.removeAll()
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
      if on && self.stopLatched && self.calPositionValid {
        self.setMsg("已停止锁定，请点击复位后继续")
        return
      }
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
      if self.calPhase != .idle { self.cancelCalibrationOnQueue("停止观察；电机内部寻限位仍会继续，立即中止需断开电机电源"); return }
      if !self.stopLatched { self.resumeAuto = self.state.auto }
      self.stopLatched = true
      self.wantEnabled = false
      self.link.stop()
      self.link.enable(false)
      self.lastStopSent = Date()
      self.pendingJog = 0
      self.takeManual("停机")
      self.stopLatched = true
      self.lastSent = nil
      self.sliderDirty = false
      self.wheelPull = nil
      self.state.wheelPulling = false
      self.wheelArrivalTarget = nil
      self.setMsg("已停止锁定；复位后才能继续控制")
    }
  }

  /// Explicitly unlock STOP. Resume AF only if it was active before STOP and the distance is fresh.
  public func resumeControl() {
    queue.async {
      guard self.calPhase == .idle, self.stopLatched, self.calPositionValid,
        !self.state.moving, self.requireFreshPosition() else { return }
      if self.resumeAuto {
        guard self.phase == .follow, self.lens?.lut.matchesDirection(self.state.dir) == true,
          self.lens?.lut.ready == true, self.distance != nil,
          Date().timeIntervalSince(self.distanceAt) < 0.5 else {
          self.setMsg("等待新鲜 LiDAR 测距与有效标定后再复位")
          return
        }
      }
      self.state.auto = self.resumeAuto
      self.resumeAuto = false
      self.stopLatched = false
      self.wantEnabled = true
      self.pendingJog = 0
      self.sliderDirty = false
      self.lastSent = nil
      self.lastAutoSend = .distantPast
      self.wheelCoordinate = Double(self.state.pos)
      self.state.slider = Double(self.state.pos) / 4096
      self.lastEnableAttempt = Date()
      self.link.enable(true)
      self.setMsg(self.state.auto ? "已复位，继续自动跟焦" : "已复位，可继续手动控制")
    }
  }

  public func jog(_ delta: Int32) {
    queue.async { self.jogOnQueue(delta) }
  }

  public func setSlider(_ v: Double) {
    queue.async {
      guard self.calPhase == .idle, !self.stopLatched, self.calPositionValid, self.requireFreshPosition() else { return }
      self.takeManual("手动焦点")
      guard v.isFinite else { return }
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
      guard !on || (!self.stopLatched && self.state.controlMode == .automatic) else { return }
      guard !on || (self.phase == .follow && self.calPositionValid && self.requireFreshPosition() && self.lens?.lut.matchesDirection(self.state.dir) == true) else { return }
      if on && (self.distance == nil || Date().timeIntervalSince(self.distanceAt) >= 0.5) {
        self.setMsg("等待新鲜 LiDAR 测距后再开启自动跟焦")
        return
      }
      self.state.auto = on
      self.lastSent = nil
      if on { self.stopLatched = false }
      self.lastAutoSend = .distantPast
      self.filter.reset()
      self.markDirty()
    }
  }

  /// 兼容通道的归一化速度接口；FM03 拨轮值范围为 1～256。
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
        ((key == kFm03Tolerance || key == kFm03Gain || key == kFm03Acceleration) && (1...64).contains(value))
      guard valid else { self.setMsg("FM03 参数超出范围"); return }
      guard self.link.isOpen else {
        self.setMsg("请连接设备后调整参数"); return
      }
      if key == kFm03Acceleration, self.state.fm03?.acceleration == nil {
        self.setMsg("启动加速调节需要固件2.1.0或更新版本"); return
      }
      let now = Date()
      self.pendingFm03[key] = (value, now, now)
      self.link.setFm03(key, value)
      self.setMsg("正在应用\(Self.fm03Name(key))：\(value)")
    }
  }
  private static func fm03Name(_ key: Int32) -> String {
    switch key {
    case kFm03MaxSpeed: return "电机速度"
    case kFm03Tolerance: return "到位容差"
    case kFm03Gain: return "接近目标减速"
    default: return "启动加速"
    }
  }

  public func queryFm03() { queue.async { self.link.queryFm03() } }

  // MARK: - 手机手轮（无需物距表或 LiDAR）

  public func setControlMode(_ mode: ControlMode) {
    queue.async {
      guard self.state.controlMode != mode else { return }
      self.cancelCalibrationOnQueue("已切换控制模式")
      if self.link.isOpen { self.link.stop(); self.link.enable(false); self.link.setLimits(0, 4096) }
      self.invalidatePosition("已切换模式，请先自动寻限位")
      self.state.controlMode = mode
      self.markDirty()
    }
  }

  public func turnWheel(_ turns: Double) {
    queue.async {
      guard self.wheelCanControl(), turns.isFinite, abs(turns) <= 0.5 else { return }
      self.wheelPull = nil
      self.state.wheelPulling = false
      let delta = turns * 4096 * self.state.wheelSensitivity * (self.state.wheelReversed ? -1 : 1)
      self.setWheelTarget(self.wheelCoordinate + delta)
    }
  }

  public func setWheelPoint(_ point: String) {
    queue.async {
      guard self.state.controlMode == .handwheel, self.calPositionValid,
        self.requireFreshPosition(), !self.state.moving, self.wheelPull == nil,
        point == "A" || point == "B" else {
        self.setMsg("请先寻限位，并等待电机停稳后设置 A/B 点")
        return
      }
      let other = point == "A" ? self.state.wheelB : self.state.wheelA
      let tolerance = self.state.fm03?.tolerance ?? 4
      if let other, abs(Int(other - self.state.pos)) <= tolerance * 2 {
        self.setMsg("A/B 点距离太近，请转动手轮后重新设置")
        return
      }
      if point == "A" { self.state.wheelA = self.state.pos }
      else { self.state.wheelB = self.state.pos }
      self.syncWheelLimits()
      self.setMsg("已记录 \(point) 点：\(self.state.pos)")
    }
  }

  public func clearWheelPoints() {
    queue.async {
      guard self.state.controlMode == .handwheel, !self.state.moving, self.wheelPull == nil else { return }
      self.state.wheelA = nil; self.state.wheelB = nil
      self.state.wheelRangeEnabled = false
      self.wheelArrivalTarget = nil
      self.wheelPull = nil; self.state.wheelPulling = false
      self.sliderDirty = false; self.lastSent = nil
      self.syncWheelLimits()
      self.setMsg("已清除 A/B 点，恢复完整行程")
    }
  }

  public func setWheelRange(_ on: Bool) {
    queue.async {
      guard self.state.controlMode == .handwheel, !self.state.moving else { return }
      if on {
        guard let a=self.state.wheelA, let b=self.state.wheelB,
          (min(a,b)...max(a,b)).contains(self.state.pos) else {
          self.setMsg("先设置 A/B 点，并将电机转到两点之间")
          return
        }
      }
      self.state.wheelRangeEnabled = on
      self.syncWheelLimits()
      self.setMsg(on ? "手轮已限制在 A/B 范围内" : "手轮已恢复完整行程")
    }
  }

  public func setWheelSensitivity(_ value: Double) {
    queue.async {
      guard value.isFinite, (0.1...2).contains(value) else { return }
      self.state.wheelSensitivity = value
      self.markDirty()
    }
  }

  public func setWheelReversed(_ on: Bool) {
    queue.async { self.state.wheelReversed = on; self.markDirty() }
  }

  public func setWheelPullCurve(_ curve: WheelPullCurve) {
    queue.async { self.state.wheelPullCurve = curve; self.markDirty() }
  }

  /// Duration schedules targets; actual arrival is always confirmed by motor feedback.
  public func pullWheelTo(_ point: String, duration: Double) {
    queue.async {
      guard self.wheelCanControl(), duration.isFinite, (0...10).contains(duration),
        let target = point == "A" ? self.state.wheelA : point == "B" ? self.state.wheelB : nil else { return }
      if duration == 0 {
        self.wheelPull = nil; self.state.wheelPulling = false
        self.setWheelTarget(Double(target))
      } else {
        self.wheelPull = (Date(), Double(self.state.pos), target, duration, self.state.wheelPullCurve)
        self.state.wheelPulling = true
        self.lastAutoSend = .distantPast
      }
      self.setMsg("正在拉焦至 \(point) 点")
    }
  }

  private func wheelCanControl() -> Bool {
    state.controlMode == .handwheel && calPhase == .idle && !stopLatched &&
      calPositionValid && state.enabled && link.isOpen && requireFreshPosition()
  }

  private func setWheelTarget(_ coordinate: Double) {
    let range = limitsFor(microsteps)
    wheelCoordinate = min(max(coordinate, Double(range.lo)), Double(range.hi))
    state.slider = wheelCoordinate / 4096
    sliderDirty = true
    let target = Int32(wheelCoordinate.rounded())
    let name: String? = target == state.wheelA ? "A" : target == state.wheelB ? "B" :
      target == 0 ? "起点" : target == 4096 ? "终点" : nil
    if let name {
      if wheelArrivalTarget?.coordinate != target { wheelArrivalTarget = (name,target) }
    } else { wheelArrivalTarget = nil }
    markDirty()
  }

  private func syncWheelLimits() {
    if state.controlMode == .handwheel && link.isOpen {
      let range=limitsFor(microsteps)
      link.setLimits(Int32(range.lo), Int32(range.hi))
    }
    markDirty()
  }

  // MARK: - 镜头

  public func selectLens(id: String) {
    queue.async {
      self.cancelCalibrationOnQueue("已切换镜头")
      if self.link.isOpen { self.link.stop(); self.link.enable(false) }
      self.invalidatePosition("已切换镜头")
      self.lens = self.store.lenses.first { $0.id == id }
      // 每换镜头都要重新寻限位，距离表的原始坐标保持不变。
      self.following = false
      self.state.nearSteps = nil
      self.state.dir = self.lens?.dir ?? 1
      self.state.auto = false
      self.lastSent = nil
      self.setMsg(self.lens.map { "镜头 \($0.name)" } ?? "未选镜头")
    }
  }

  public func createLens(name: String, params: String) {
    queue.async {
      self.cancelCalibrationOnQueue("已切换镜头")
      if self.link.isOpen { self.link.stop(); self.link.enable(false) }
      self.invalidatePosition("已切换镜头")
      let l = Lens(id: Lens.newId(), name: name, params: params)
      self.store.upsert(l)
      self.persist()
      self.lens = l
      self.following = false
      self.state.nearSteps = nil
      self.state.dir = l.dir
      self.state.auto = false
      self.lastSent = nil
      self.setMsg("新镜头 \(l.name)：先自动寻限位")
    }
  }

  public func deleteLens(id: String) {
    queue.async {
      if self.lens?.id == id { self.cancelCalibrationOnQueue("已删除镜头") }
      if self.lens?.id == id {
        if self.link.isOpen { self.link.stop(); self.link.enable(false) }
        self.invalidatePosition("已删除镜头")
      }
      self.store.remove(id: id)
      self.persist()
      if self.lens?.id == id {
        self.lens = nil
        self.following = false
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

  /// 长按确认后只重置 App 的方向和距离表，不修改 FM03 内部限位或原点。
  public func resetLensCalibration() {
    queue.async {
      guard self.calPhase == .idle, var lens = self.lens else { return }
      self.link.stop()
      self.takeManual("重新标定")
      lens.lut = LensLut([])
      lens.directionConfirmed = false
      self.updateLensOnQueue(lens)
      self.following = false
      self.state.calDirectionPending = self.calPositionValid
      self.lastSent = nil
      self.sliderDirty = false
      // Clearing a distance table must not unlock an explicit STOP.
      self.setMsg(self.calPositionValid ? "已清空距离表，请选择物距变近方向并重新标定" : "已清空距离表，请先自动寻限位")
    }
  }

  /// FM03 自主双端寻限位；保留参数固定为 0。
  public func startAutoCalibration() {
    queue.async {
      guard self.calPhase == .idle, self.state.calSupported, self.link.isOpen,
        self.state.controlMode == .handwheel || self.lens != nil else {
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
      self.calPendingLensId = self.lens?.id
      self.state.wheelA = nil; self.state.wheelB = nil; self.state.wheelRangeEnabled = false
      self.wheelArrivalTarget = nil; self.wheelPull = nil; self.state.wheelPulling = false
      self.resumeAuto = false
      self.state.auto = false
      self.pendingJog = 0
      self.sliderDirty = false
      self.lastSent = nil
      self.stopLatched = true
      self.wantEnabled = false
      self.following = false
      self.state.nearSteps = nil
      self.calPositionValid = false
      self.state.calDirectionPending = false
      self.state.calError = 0
      self.state.calStage = "preparing"
      self.calPhase = .stopping
      self.calSeq = self.link.stop()
      self.calSentAt = Date()
      self.setMsg("正在停止电机并检查状态")
    }
  }

  public func cancelAutoCalibration() {
    queue.async {
      let reason = "停止观察；FM03 内部标定仍会继续，请等待完成或断开电机电源"
      if self.calPhase == .idle {
        self.link.stop()
        self.link.enable(false)
        self.state.calStage = "cancelled"
        self.invalidatePosition(reason)
      } else {
        self.cancelCalibrationOnQueue(reason)
      }
    }
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
    pendingFm03.removeAll()
    following = false
    state.nearSteps = nil
    state.auto = false
    state.positionTrusted = false
    calPositionValid = false
    state.calDirectionPending = false
    state.calSafeSpan = 0
    state.calTravel = 0
    if calPhase == .idle && state.calStage != "failed" && state.calStage != "cancelled" { state.calStage = "idle" }
    lastSent = nil
    pendingJog = 0
    sliderDirty = false
    stopLatched = true
    wantEnabled = false
    resumeAuto = false
    wheelPull = nil; state.wheelPulling = false; wheelArrivalTarget = nil
    state.wheelA = nil; state.wheelB = nil; state.wheelRangeEnabled = false
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
    default: return
    }
    lastStatusAt = now
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
      calPositionValid = true
      lastStatusAt = Date()
      state.positionTrusted = true
      state.pos = c.pos
      state.target = c.pos
      state.calSafeSpan = Int(c.safeMax)
      state.calTravel = Int(c.travel)
      state.calDirectionPending = lens?.directionConfirmed != true
      state.nearSteps = state.dir > 0 ? 0 : 4096
      state.slider = Double(c.pos) / 4096
      wheelCoordinate = Double(c.pos)
      if state.controlMode == .handwheel { state.calDirectionPending = false }
      stopLatched = false
      wantEnabled = true
      calQueries.removeAll()
      calPhase = .idle
      positionQueries.removeAll()
      positionQueries.insert(link.query())
      setMsg(state.controlMode == .handwheel ? "寻限位完成，可转动手轮并设置 A/B 点" : state.calDirectionPending ? "寻限位完成，请选择物距变近的旋转方向" : "寻限位完成，距离表已保留；可继续标定或开始跟焦")
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
      "标定观察回包超时，内部校准可能仍在继续", "采样中断超时，请重试",
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

  // MARK: - 物距方向（②）

  /// dir 沿用协议含义：坐标变大时物距变远为 +1。
  public func setDir(_ d: Int) {
    queue.async {
      guard self.calPhase == .idle, !self.stopLatched, self.calPositionValid, self.requireFreshPosition(), !self.state.moving else { return }
      let normalized = d >= 0 ? 1 : -1
      self.link.stop()
      self.takeManual("选择方向")
      self.sliderDirty = false
      if var lens = self.lens {
        if lens.dir != normalized {
          lens.lut = LensLut([])
          self.following = false
        }
        lens.dir = normalized
        lens.directionConfirmed = true
        self.updateLensOnQueue(lens)
      }
      self.state.dir = normalized
      self.state.nearSteps = normalized > 0 ? 0 : 4096
      self.state.calDirectionPending = false
      self.lastSent = nil
      self.setMsg("方向已确认，请手动对焦并记录至少五个物距点")
    }
  }

  public func startFollow() {
    queue.async { if self.calPhase == .idle { self.startFollowOnQueue() } }
  }

  /// 退出跟焦，继续补充距离标定；保持 FM03 原始坐标和限位。
  public func unalign() {
    queue.async {
      self.link.stop()
      self.unalignOnQueue("继续标定距离")
    }
  }

  // MARK: - 距离标定（③）

  public func addLutPoint(meters: Double? = nil) {
    queue.async {
      guard self.calPhase == .idle, self.calPositionValid, self.requireFreshPosition(),
        self.lens?.directionConfirmed == true, !self.state.moving, !self.state.auto else {
        self.setMsg("请先寻限位并选择方向，手动对焦停稳后再记录")
        return
      }
      guard let lens = self.lens else { return }
      guard let d = meters ?? (Date().timeIntervalSince(self.distanceAt) < 0.5 ? self.distance : nil),
        d.isFinite, (0.05...1000).contains(d) else {
        self.setMsg("请输入有效物距（0.05～1000 m），或等待新鲜 LiDAR 测距")
        return
      }
      let nextLut = lens.lut.adding(LutPoint(meters: d, steps: Int(self.state.pos)))
      guard nextLut.points.count < 2 || nextLut.matchesDirection(lens.dir) else {
        self.setMsg("该点与所选方向或已有标定点不一致，请核对物距和实焦位置")
        return
      }
      var next = lens
      next.lut = nextLut
      self.updateLensOnQueue(next)
      self.setMsg("已记录 \(next.lut.points.count) / 至少五点；请覆盖近、中、远距离")
    }
  }

  public func removeLutPoint(at index: Int) {
    queue.async {
      guard self.calPhase == .idle else { return }
      guard let lens = self.lens else { return }
      var next = lens
      self.link.stop()
      self.takeManual("删除标定点")
      self.following = false
      self.lastSent = nil
      self.sliderDirty = false
      next.lut = lens.lut.removingAt(index)
      self.updateLensOnQueue(next)
    }
  }

  // MARK: - 内部：tick

  private var microsteps: Int { state.microsteps }
  private var stepsPerRev: Int { cal.stepsPerRev(microsteps) }

  private var phase: SetupPhase {
    if state.controlMode == .handwheel { return calPositionValid ? .follow : .stroke }
    guard lens != nil, calPositionValid else { return .stroke }
    if state.calDirectionPending || lens?.directionConfirmed != true { return .align }
    return following ? .follow : .calibrate
  }

  private func tick() {
    let now = Date()
    if stopLatched && calPositionValid && (state.enabled || state.moving) && now.timeIntervalSince(lastStopSent) >= 0.2 {
      link.stop(); link.enable(false); lastStopSent = now
    }
    if link.isOpen {
      // 200ms 轮询状态：位置反馈用。**注意它喂不了固件看门狗** ——
      // 固件只把 SET_POS/JOG 当控制包（`motorNoteControlPacket`），
      // QUERY 不计入 `lastControlPacketMs`。保活见下面 `lastControlSent`。
      if now.timeIntervalSince(lastQuery) > 0.2 {
        lastQuery = now
        let seq = link.query()
        if positionQueries.count >= 32 { positionQueries.removeAll() }
        positionQueries.insert(seq)
      }
      if now.timeIntervalSince(lastProbe) > 1.0 {
        lastProbe = now
        link.probe()
      }
      if now.timeIntervalSince(lastFm03) > 1.0 {
        lastFm03 = now
        link.queryFm03()
      }
    }
    if calPhase != .idle {
      pendingFm03.removeAll()
      tickCalibration(now)
      emit()
      return
    }
    for (key, pending) in pendingFm03 {
      if !link.isOpen {
        pendingFm03.removeValue(forKey: key)
      } else if now.timeIntervalSince(pending.started) >= 2 {
        pendingFm03.removeValue(forKey: key)
        setMsg("\(Self.fm03Name(key))未获设备确认；停稳后重试，运动中调参需固件2.1.1")
      } else if now.timeIntervalSince(pending.sent) >= 0.25 {
        link.setFm03(key, pending.value)
        pendingFm03[key]?.sent = now
      }
    }
    if distance != nil && now.timeIntervalSince(distanceAt) >= 0.5 { distance = nil; filter.reset() }
    if state.auto && distance == nil {
      link.stop(); takeManual("测距已失效"); lastSent = nil; sliderDirty = false
    }
    if calPositionValid && (lastStatusAt == nil || now.timeIntervalSince(lastStatusAt!) > kLinkAliveWindow) {
      link.stop()
      link.enable(false)
      invalidatePosition("状态回包超时，已释放电机；请重新定位")
    }
    if link.isOpen {
      // 板子重启后固件 enabled 会归零，App 这边补一次使能，让状态自愈。
      if wantEnabled, !state.enabled, now.timeIntervalSince(lastEnableAttempt) > 1.0 {
        lastEnableAttempt = now
        link.enable(true)
      }
      if state.enabled, !stopLatched, calPositionValid, state.positionTrusted,
        let at = lastStatusAt, now.timeIntervalSince(at) < 0.5 {
        if state.controlMode == .handwheel, let pull=wheelPull {
          let t=min(now.timeIntervalSince(pull.started)/pull.duration,1)
          // Curve is captured at the start to avoid mid-pull target jumps.
          let eased=pull.curve.progress(t)
          setWheelTarget(pull.from + (Double(pull.to)-pull.from)*eased)
          if t >= 1 { wheelPull=nil; state.wheelPulling=false }
        }
        var want: Int32?
        if state.auto {
          if let d = distance { want = autoSteps(d) }
        } else if sliderDirty {
          want = sliderSteps()
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
          sliderDirty = false
        }
        // 看门狗保活：固件只把 SET_POS/JOG 当控制包，静默 >1s 就刹停
        // （`kControlTimeoutMs`，且只在 `ARMED && MOVING` 时生效）。
        // 所以“目标没变”不等于“不用发”：一次 >1s 的行程会在中途被刹掉，
        // 表现就是“点了走一半就停” —— 这是 §7 记过的“控制有时候不灵”的根因。
        // 重发同一个 SET_POS 是幂等的，顺带解除待机，所以按 ≤400ms 重发当前目标。
        else if let last = lastSent, (state.moving || state.target != last),
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
      if now.timeIntervalSince(calSentAt) > 3.0 {
        failCalibration(error: kAppCalErrorBase + 0)
      } else if now.timeIntervalSince(calLastQuery) >= 0.2 {
        // STOP/QUERY/ENABLE/首读都是幂等操作；丢一次 UDP 不能直接终止寻限位。
        calLastQuery = now
        switch calPhase {
        case .stopping: calSeq = link.stop()
        case .checking: calSeq = link.query()
        case .enabling: calSeq = link.enable(true)
        case .reading: calSeq = link.calQuery(runId: 0)
        default: break
        }
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
      // 观察回包断链不会取消电机内部校准；退出后明确报告这一限制。
      if now.timeIntervalSince(calLastReply) > 3.0 { failCalibration(error: 7) }
    case .idle: break
    }
  }

  /// 五点单调距离表映射到 FM03 0～4096 坐标，范围外保持已标定端点。
  private func autoSteps(_ meters: Double) -> Int32? {
    let lutNow = lens?.lut ?? LensLut([])
    guard let v = lutNow.stepsFor(meters) else { return nil }
    let r = limitsFor(microsteps)
    return Int32(min(max(v, r.lo), r.hi))
  }

  private func sliderSteps() -> Int32 {
    if state.controlMode == .handwheel { return Int32(wheelCoordinate.rounded()) }
    let r = limitsFor(microsteps)
    if r.hi == r.lo { return Int32(r.lo) }
    return Int32((Double(r.lo) + state.slider * Double(r.hi - r.lo)).rounded())
  }

  /// FM03 内部维护机械限位；App 仅使用协议的归一化坐标范围。
  private func limitsFor(_ ms: Int) -> (lo: Int, hi: Int) {
    if state.controlMode == .handwheel, state.wheelRangeEnabled, let a=state.wheelA, let b=state.wheelB {
      return (Int(min(a,b)), Int(max(a,b)))
    }
    return (0,4096)
  }

  /// 把物理单位换算成固件要的坐标/秒、坐标/秒²。
  private func applySpeed() {
    guard link.isOpen, calPhase == .idle else { return }
    let spd = Int32((state.speedRevS * Double(stepsPerRev)).rounded())
    link.setSpeed(min(max(spd, 1), 256), 0)
  }

  // MARK: - 内部：命令

  private func jogOnQueue(_ delta: Int32) {
    guard link.isOpen, delta != 0, calPhase == .idle, !stopLatched, calPositionValid, requireFreshPosition() else { return }
    let r = limitsFor(microsteps)
    let want = Int(state.pos) + Int(delta)
    guard want >= r.lo, want <= r.hi else {
      setMsg(
        "超出软限位 \(r.lo)..\(r.hi) 坐标（当前 \(state.pos)，请求 \(want)）。"
          + "请先完成 FM03 自动寻限位。")
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
    guard calPositionValid, requireFreshPosition(), !state.moving, let lens,
      lens.directionConfirmed, lens.lut.ready, lens.lut.matchesDirection(state.dir) else {
      setMsg("请先自动寻限位、确认方向并记录至少五个有效物距点")
      return
    }
    following = true
    state.slider = Double(state.pos) / 4096
    sliderDirty = false
    lastSent = nil
    state.auto = false
    setMsg("标定表已就绪，可开启自动跟焦")
    markDirty()
  }

  private func unalignOnQueue(_ msg: String) {
    following = false
    state.nearSteps = nil
    state.auto = false
    sliderDirty = false
    pendingJog = 0
    lastSent = nil
    setMsg(msg)
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
    if calPhase == .idle, !stopLatched, wantEnabled, s.enabled, pendingJog != 0 {
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
    guard calPhase == .idle, positionQueries.remove(s.sequence) != nil else { return }
    if !s.positionTrusted && (calPositionValid || following) {
      invalidatePosition("设备坐标已失效，请重新寻限位")
    }
    state.positionTrusted = s.positionTrusted
    state.pos = s.pos
    state.target = s.target
    if s.fault == 3, !s.moving, !sliderDirty, s.target == lastSent {
      // A completed failure is terminal; do not feed the old goal again.
      takeManual("拉焦无有效进展")
      lastSent = nil; sliderDirty = false
      wheelPull = nil; state.wheelPulling = false; wheelArrivalTarget = nil
      wheelCoordinate = Double(s.pos); state.slider = Double(s.pos) / 4096
      setMsg("拉焦未完成：坐标未有效接近目标，已停止旧目标；可调整容差或速度后重新操作")
    }
    if state.controlMode == .handwheel, !stopLatched, s.positionTrusted, s.canOk, !s.moving,
      let arrival=wheelArrivalTarget, s.target==arrival.coordinate,
      abs(Int(s.pos-arrival.coordinate)) <= (state.fm03?.tolerance ?? 4) {
      state.wheelArrival=arrival.name
      state.wheelArrivalSequence += 1
      wheelArrivalTarget=nil
      setMsg("已到达 \(arrival.name) 点")
    }
    markDirty()
  }

  private func applyFm03(_ t: Fm03Dump) {
    lastFm03At = Date()
    state.fm03 = t
    state.speedRevS = Double(t.maxSpeed) / 4096
    let values: [Int32: Int] = [kFm03MaxSpeed: t.maxSpeed, kFm03Tolerance: t.tolerance,
      kFm03Gain: t.gain, kFm03Acceleration: t.acceleration ?? -1]
    for (key, pending) in pendingFm03 where values[key] == Int(pending.value) {
      pendingFm03.removeValue(forKey: key)
      setMsg("已确认\(Self.fm03Name(key))：\(pending.value)")
    }
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
    s.strokeSteps = calPositionValid ? state.calSafeSpan : 0
    s.lutPoints = lens?.lut.points ?? []
    s.lutCurve = lens?.lut.curve ?? []
    s.lutReady = lens?.lut.ready == true && lens?.lut.matchesDirection(state.dir) == true
    s.stepsPerRev = stepsPerRev
    s.maxRevsPerSec = cal.maxRevsPerSec(microsteps)
    s.posRevs = cal.stepsToRevs(Int(s.pos), microsteps)
    s.strokeRevs = cal.stepsToRevs(s.strokeSteps, microsteps)
    let r = limitsFor(microsteps)
    s.limitLo = r.lo
    s.limitHi = r.hi
    s.stopLatched = stopLatched
    let fresh = calPositionValid && state.positionTrusted && state.canOk &&
      link.isOpen && lastStatusAt.map { Date().timeIntervalSince($0)<0.5 } == true
    s.wheelReady = state.controlMode == .handwheel && fresh && state.enabled && !stopLatched
    s.canResume = stopLatched && fresh && !state.moving && (!resumeAuto ||
      (phase == .follow && lens?.lut.ready == true && distance != nil && Date().timeIntervalSince(distanceAt)<0.5))
    s.distanceM = distance
    s.socketError = socketErrorText
    s.statusAgeMs = lastStatusAt.map { Int(Date().timeIntervalSince($0) * 1000) }
    s.echoAgeMs = link.lastEchoAt.map { Int(Date().timeIntervalSince($0) * 1000) }
    s.linkAlive =
      link.isOpen && lastStatusAt.map { Date().timeIntervalSince($0) < kLinkAliveWindow } ?? false
    return s
  }

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
