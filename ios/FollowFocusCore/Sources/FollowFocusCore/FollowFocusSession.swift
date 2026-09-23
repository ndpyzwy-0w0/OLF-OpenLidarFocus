import Foundation

/// 跟焦前的三步：新镜头标定行程 → 单侧对齐 → 跟焦。
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
  public var uartOk = false
  public var standby = false
  public var limitHit = false
  public var result = kResultIdle
  public var positionTrusted = false

  // 单位换算
  public var microsteps = 16
  public var stepsPerRev = 6400

  // 会话
  public var auto = false
  public var stopLatched = false
  public var slider = 0.5
  public var speedRevS = 1.2
  public var accelRevS2 = 30.0
  public var standbyFeature = true
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
  public var tmc: TmcDump?
  public var tmcLog: [String] = []
  public var msg = ""
}

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
  private var sliderDirty = false
  private var stopLatched = false
  private var lastQuery = Date.distantPast
  private var lastProbe = Date.distantPast
  private var lastTmc = Date.distantPast
  private var lastStatusAt: Date?
  private var filter = DistFilter()
  private var distance: Double?
  private var socketErrorText: String?
  private var revision = 0
  private var lastEmittedRevision = -1
  private var discovered: [FfDiscovery] = []

  public init(store: LensStore, cal: MotorCal = MotorCal()) {
    self.store = store
    self.cal = cal
    self.link = MotorLink()
    link.onStatus = { [weak self] s in self?.queue.async { self?.applyStatus(s) } }
    link.onStatusV2 = { [weak self] s in self?.queue.async { self?.applyStatusV2(s) } }
    link.onTmc = { [weak self] t in self?.queue.async { self?.applyTmc(t) } }
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
      guard self.timer == nil else { return }
      let t = DispatchSource.makeTimerSource(queue: self.queue)
      t.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(5))
      t.setEventHandler { [weak self] in self?.tick() }
      self.timer = t
      t.resume()
      self.emit()
    }
  }

  public func stop() {
    queue.async {
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
      self.link.useDevice(d)
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
    do {
      try link.open()
      appliedStepsPerRev = 0
      applySpeed()
      applyLimits()
      link.setTmc(kTmcStandby, state.standbyFeature ? 1 : 0)
      // 板子重启后固件 enabled 会归零，这里补一次使能，让状态自愈。
      wantEnabled = true
      lastEnableAttempt = Date()
      link.enable(true)
      link.query()
      link.queryTmc()
      state.localAddrs = Self.localIPv4Addrs()
      setMsg("已连接 \(host):\(link.port)")
    } catch {
      setMsg("连接失败 \(error)")
    }
  }

  // MARK: - 手动控制

  public func enable(_ on: Bool) {
    queue.async {
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
      self.link.home()
      self.unalignOnQueue("已软件置零，请重新对齐最近点")
    }
  }

  public func jog(_ delta: Int32) {
    queue.async { self.jogOnQueue(delta) }
  }

  public func setSlider(_ v: Double) {
    queue.async {
      self.state.slider = min(max(v, 0), 1)
      self.sliderDirty = true
      self.stopLatched = false
      self.lastSent = nil
      self.markDirty()
    }
  }

  public func setAuto(_ on: Bool) {
    queue.async {
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
      self.state.speedRevS = max(revsPerSec, 0)
      self.state.accelRevS2 = max(accelRevsPerSec2, 0)
      self.applySpeed()
      self.markDirty()
    }
  }

  public func setMicrosteps(_ ms: Int32) {
    queue.async {
      self.link.setTmc(kTmcMicrosteps, ms)
      self.markDirty()
    }
  }

  public func setTmc(_ key: Int32, _ value: Int32) {
    queue.async {
      self.link.setTmc(key, value)
      self.markDirty()
    }
  }

  public func queryTmc() {
    queue.async { self.link.queryTmc() }
  }

  public func setStandbyFeature(_ on: Bool) {
    queue.async {
      self.state.standbyFeature = on
      self.link.setTmc(kTmcStandby, on ? 1 : 0)
      self.markDirty()
    }
  }

  // MARK: - 镜头

  public func selectLens(id: String) {
    queue.async {
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

  // MARK: - 行程标定（①）

  /// 行程标定：先记一端，再记另一端，两点距离就是行程长度。
  public func recordStrokeA() {
    queue.async {
      self.strokeA = Int(self.state.pos)
      self.setMsg("已记录端点 A = \(self.state.pos) 步，请转到行程另一端再记录")
    }
  }

  public func finishStroke() {
    queue.async {
      guard let lens = self.lens, let a = self.strokeA else { return }
      let stroke = abs(Int(self.state.pos) - a)
      guard stroke >= 1 else {
        self.setMsg("A 和 B 几乎在同一位置，请转到行程另一端再记录")
        return
      }
      var next = lens
      next.strokeSteps = stroke
      next.strokeMicrosteps = self.microsteps
      self.updateLensOnQueue(next)
      self.strokeA = nil
      self.setMsg(
        "行程已标定：\(stroke) 步"
          + "（\(self.fmt(self.cal.stepsToRevs(stroke, self.microsteps))) 圈），接下来对齐最近点")
    }
  }

  /// 行程标定的防误触：清空重标要 UI 先确认，避免碰到就把行程弄丢。
  public func recalibrateStroke() {
    queue.async {
      guard let lens = self.lens else { return }
      var next = lens
      next.strokeSteps = nil
      self.updateLensOnQueue(next)
      self.strokeA = nil
      self.unalignOnQueue("行程已清空，请重新标定")
    }
  }

  // MARK: - 单侧对齐（②）

  /// 确认焦距最近点。方向默认用距离标定表推断，没有表就用上次选过的方向。
  public func confirmNear() {
    queue.async {
      self.state.nearSteps = Int(self.state.pos)
      self.state.dir = inferDir(self.lens?.lut ?? LensLut([])) ?? (self.lens?.dir ?? 1)
      self.setMsg("最近点 = \(self.state.pos) 步，选好变远方向后开始")
    }
  }

  /// 只改方向（对齐之后也能改）。
  ///
  /// 必须同时更新 `state.dir` 和镜头里的 `dir`：前者决定本次会话的软限位，
  /// 后者是持久化的物理属性，只写一个会让界面选的方向不生效。
  public func setDir(_ d: Int) {
    queue.async {
      let normalized = d >= 0 ? 1 : -1
      self.state.dir = normalized
      if var lens = self.lens {
        lens.dir = normalized
        self.updateLensOnQueue(lens)
      }
      self.lastSent = nil
      self.applyLimits()
      self.markDirty()
    }
  }

  /// 选定方向后真正进入跟焦：把距离标定表锚到本次会话的坐标系，再下发软限位。
  public func startFollow() {
    queue.async { self.startFollowOnQueue() }
  }

  /// 作废本次对齐，并把固件软限位恢复成默认值。
  ///
  /// 必须真正下发默认限位：否则固件还留着上一轮对齐的窄区间，
  /// 对齐阶段的“自由微调”会在旧边界被夹住，表现是微调不动。
  public func unalign() {
    queue.async { self.unalignOnQueue("重新对齐最近点") }
  }

  // MARK: - 距离标定（③）

  public func addLutPoint() {
    queue.async {
      guard let lens = self.lens, let d = self.distance else { return }
      var next = lens
      next.lut = lens.lut.adding(
        LutPoint(meters: d, steps: Int(self.state.pos)), microsteps: self.microsteps)
      self.updateLensOnQueue(next)
    }
  }

  public func removeLutPoint(at index: Int) {
    queue.async {
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
    if !aligned || state.nearSteps == nil { return .align }
    return .follow
  }

  private func tick() {
    let now = Date()
    if link.isOpen {
      // 200ms 轮询状态：既是位置反馈，也是看门狗要的保活。
      if now.timeIntervalSince(lastQuery) > 0.2 {
        lastQuery = now
        link.query()
      }
      if now.timeIntervalSince(lastProbe) > 1.0 {
        lastProbe = now
        link.probe()
      }
      if now.timeIntervalSince(lastTmc) > 1.0 {
        lastTmc = now
        link.queryTmc()
      }
      // 细分变化会改变“步”的尺度：重算速度，并把软限位按新细分重新下发。
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
            // 死区和最小间隔：距离微抖会让目标每 tick 变几步，每段都是三角形微动，
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
          link.setPos(target)
        }
      }
    }
    emit()
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
  /// 未对齐（标定/对齐阶段）用和固件默认一致的 ±20 圈，好让跟焦器自由微调。
  private func limitsFor(_ ms: Int) -> (lo: Int, hi: Int) {
    if aligned, let near = state.nearSteps {
      return alignedRange(near, state.dir, lens?.strokeAt(ms) ?? 0)
    }
    let span = cal.defaultLimitSpan(ms)
    return (lo: -span, hi: span)
  }

  private func applyLimits() {
    guard link.isOpen else { return }
    let r = limitsFor(microsteps)
    link.setLimits(Int32(r.lo), Int32(r.hi))
  }

  /// 把物理单位换算成固件要的步/秒、步/秒²。
  private func applySpeed() {
    guard link.isOpen else { return }
    let spd = Int32((state.speedRevS * Double(stepsPerRev)).rounded())
    let acc = Int32((state.accelRevS2 * Double(stepsPerRev)).rounded())
    link.setSpeed(min(max(spd, 100), 40000), min(max(acc, 100), 1_000_000))
  }

  // MARK: - 内部：命令

  private func jogOnQueue(_ delta: Int32) {
    guard link.isOpen, delta != 0 else { return }
    let r = limitsFor(microsteps)
    let want = Int(state.pos) + Int(delta)
    guard want >= r.lo, want <= r.hi else {
      setMsg(
        "超出软限位 \(r.lo)..\(r.hi) 步（当前 \(state.pos)，请求 \(want)）。"
          + "换细分会改变步数尺度；可先重新对齐。")
      return
    }
    guard state.enabled else {
      // 板子重启后固件是关的：先补使能，并保留这次 JOG，待状态确认后执行。
      pendingJog += delta
      wantEnabled = true
      lastEnableAttempt = Date()
      link.enable(true)
      setMsg("正在使能，已暂存 \(pendingJog > 0 ? "+" : "")\(pendingJog) 步")
      return
    }
    takeManual("走步")
    stopLatched = false
    lastSent = nil
    link.jog(delta)
    sliderDirty = false
  }

  /// 用户手动介入（走步/拖滑条/停机）时退出自动跟焦。
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
    guard let lens = self.lens, let near = state.nearSteps else { return }
    let lutNow = lens.lut.scaledTo(microsteps)
    let delta = lutRebaseDelta(near, lutNow)
    var next = lens
    next.dir = state.dir
    if delta != 0 { next.lut = lutNow.shifted(delta) }
    self.lens = store.upsert(next)
    persist()
    aligned = true
    applyLimits()
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
    applyLimits()
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
    lastStatusAt = Date()
    state.lastEchoedSequence = s.sequence
    state.result = s.result
    state.pos = s.pos
    state.target = s.target
    state.enabled = s.enabled
    state.moving = s.moving
    state.uartOk = s.uartOk
    state.standby = s.standby
    state.limitHit = s.limited
    if s.enabled, pendingJog != 0 {
      let delta = pendingJog
      pendingJog = 0
      takeManual("走步")
      stopLatched = false
      lastSent = nil
      sliderDirty = false
      link.jog(delta)
    }
    if s.limited { setMsg("已到软限位：\(s.pos) 步") }
    markDirty()
    emit()
  }

  private func applyStatusV2(_ s: MotorStatusV2) {
    state.positionTrusted = s.positionTrusted
    state.pos = s.pos
    state.target = s.target
    markDirty()
  }

  private func applyTmc(_ t: TmcDump) {
    state.tmc = t
    state.microsteps = t.microsteps
    let ts = Self.clockLabel()
    state.tmcLog.insert("\(ts)  \(t.logLine())", at: 0)
    if state.tmcLog.count > 40 { state.tmcLog.removeLast(state.tmcLog.count - 40) }
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

  private func buildSnapshot() -> FollowFocusState {
    var s = state
    s.connected = link.isOpen
    s.host = link.host
    s.port = link.port
    s.localPort = link.localPort
    s.rxPackets = link.rxPackets
    s.probeTx = link.probeTx
    s.devices = discovered
    s.lensId = lens?.id
    s.lensName = lens?.name ?? ""
    s.lenses = store.lenses
    s.phase = phase
    s.strokeSteps = lens?.strokeAt(microsteps) ?? 0
    s.lutPoints = (lens?.lut ?? LensLut([])).scaledTo(microsteps).points
    s.stepsPerRev = stepsPerRev
    let r = limitsFor(microsteps)
    s.limitLo = r.lo
    s.limitHi = r.hi
    s.stopLatched = stopLatched
    s.strokeA = strokeA
    s.distanceM = distance
    s.socketError = socketErrorText
    s.statusAgeMs = lastStatusAt.map { Int(Date().timeIntervalSince($0) * 1000) }
    s.echoAgeMs = link.lastEchoAt.map { Int(Date().timeIntervalSince($0) * 1000) }
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
