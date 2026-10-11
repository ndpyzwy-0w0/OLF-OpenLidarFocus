import Foundation

/// 一个镜头的持久化参数：名称、备注、行程标定、变远方向和距离标定表。
///
/// [strokeSteps] 是机械行程长度（脉冲），在 [strokeMicrosteps] 细分下量的，
/// 换细分后用 [strokeAt] 换算——它是**跨会话有效**的物理量。
///
/// [dir] = 焦距变远的旋转方向：+1 表示步数增大，-1 表示步数减小。对齐后由它
/// 决定允许运动的软限位区间，从而保证不会拧反、也不会超出标定过的行程。
///
/// “焦距最近点”是**每次进入都要重新对齐**的会话量：步进电机开环、掉电丢绝对
/// 位置，所以不在这里持久化。
public struct Lens: Equatable {
  public let id: String
  public var name: String
  public var params: String
  public var lut: LensLut
  public var strokeSteps: Int?
  public var strokeMicrosteps: Int
  public var dir: Int
  public var autoTravel: Int?
  public var autoSafeSpan: Int?
  public var autoFirmware: String?

  public init(
    id: String,
    name: String,
    params: String = "",
    lut: LensLut = LensLut([]),
    strokeSteps: Int? = nil,
    strokeMicrosteps: Int = 1,
    dir: Int = 1,
    autoTravel: Int? = nil,
    autoSafeSpan: Int? = nil,
    autoFirmware: String? = nil
  ) {
    self.id = id
    self.name = name
    self.params = params
    self.lut = lut
    self.strokeSteps = strokeSteps
    self.strokeMicrosteps = strokeMicrosteps
    self.dir = dir >= 0 ? 1 : -1
    self.autoTravel = autoTravel
    self.autoSafeSpan = autoSafeSpan
    self.autoFirmware = autoFirmware
  }

  /// 行程是否已标定。未标定就不能对齐，也不能自动跟焦。
  public var calibrated: Bool { abs(strokeSteps ?? 0) > 0 }

  public static func newId() -> String {
    "lens-" + String(Int(Date().timeIntervalSince1970 * 1_000_000), radix: 36)
  }

  /// 行程脉冲数，换算到指定细分。行程只记长度，不记绝对位置。
  public func strokeAt(_ microsteps: Int) -> Int {
    guard let s = strokeSteps, s != 0 else { return 0 }
    guard strokeMicrosteps > 0, microsteps > 0 else { return abs(s) }
    return Int((Double(abs(s)) * Double(microsteps) / Double(strokeMicrosteps)).rounded())
  }

  /// 清空行程标定（“重新标定行程”用），距离标定表和方向保留。
  public func withoutStroke() -> Lens {
    Lens(
      id: id,
      name: name,
      params: params,
      lut: lut,
      strokeSteps: nil,
      strokeMicrosteps: strokeMicrosteps,
      dir: dir
    )
  }
}

// MARK: - 对齐

/// 对齐后的软限位区间：最近点 [near] 沿变远方向最多走 [stroke] 个脉冲。
///
/// 这就是“不会拧反、也不会超过标定行程”的落点：区间只在最近点到远端这一侧。
public func alignedRange(_ near: Int, _ dir: Int, _ stroke: Int)
  -> (lo: Int, hi: Int)
{
  let far = dir >= 0 ? near + stroke : near - stroke
  return far >= near ? (lo: near, hi: far) : (lo: far, hi: near)
}

/// 从距离标定表推断“焦距变远”的方向：距离越远、步数越大就是 +1。
/// 表里不足两点或两点同值返回 nil（让用户自己选）。
public func inferDir(_ lut: LensLut) -> Int? {
  guard lut.ready, let near = lut.points.first?.steps,
    let far = lut.points.last?.steps
  else { return nil }
  if near == far { return nil }
  return far > near ? 1 : -1
}

/// 对齐后把距离标定表平移到本次会话的坐标系：让表里距离最小（焦距最近）的那个
/// 点落在今天的最近点上。表里存的是标定当次会话的步数，跨会话必须重锚。
public func lutRebaseDelta(_ near: Int, _ lut: LensLut) -> Int {
  guard let first = lut.points.first else { return 0 }
  return near - first.steps
}

// MARK: - JSON

public extension LensLut {
  var jsonObject: [String: Any] {
    [
      "microsteps": microsteps,
      "points": points.map { ["m": $0.meters, "s": $0.steps] },
    ]
  }

  init(jsonObject o: [String: Any]) {
    let raw = (o["points"] as? [[String: Any]] ?? []).compactMap { p -> LutPoint? in
      guard let m = number(p["m"]), let s = number(p["s"]) else { return nil }
      return LutPoint(meters: m.doubleValue, steps: s.intValue)
    }
    self.init(raw, microsteps: number(o["microsteps"])?.intValue ?? 1)
  }
}

public extension Lens {
  var jsonObject: [String: Any] {
    var o: [String: Any] = [
      "id": id,
      "name": name,
      "params": params,
      "dir": dir,
      "strokeMs": strokeMicrosteps,
      "lut": lut.jsonObject,
    ]
    if let strokeSteps { o["stroke"] = strokeSteps }
    if let autoTravel { o["autoTravel"] = autoTravel }
    if let autoSafeSpan { o["autoSafeSpan"] = autoSafeSpan }
    if let autoFirmware { o["autoFirmware"] = autoFirmware }
    return o
  }

  init?(jsonObject o: [String: Any]) {
    guard let id = o["id"] as? String else { return nil }
    self.init(
      id: id,
      name: (o["name"] as? String) ?? "",
      params: (o["params"] as? String) ?? "",
      lut: LensLut(jsonObject: (o["lut"] as? [String: Any]) ?? [:]),
      strokeSteps: number(o["stroke"])?.intValue,
      strokeMicrosteps: number(o["strokeMs"])?.intValue ?? 1,
      dir: (number(o["dir"])?.intValue ?? 1) >= 0 ? 1 : -1,
      autoTravel: number(o["autoTravel"])?.intValue,
      autoSafeSpan: number(o["autoSafeSpan"])?.intValue,
      autoFirmware: o["autoFirmware"] as? String
    )
  }
}

/// JSONSerialization 会把数字桥接成 NSNumber 或 String，这里统一取一下。
private func number(_ v: Any?) -> NSNumber? {
  if let n = v as? NSNumber { return n }
  if let d = v as? Double { return NSNumber(value: d) }
  if let i = v as? Int { return NSNumber(value: i) }
  if let s = v as? String { return Double(s).map { NSNumber(value: $0) } }
  return nil
}

// MARK: - 存储

/// 镜头列表持久化。
///
/// 走 Application Support（iOS 的正确位置），同时兼容旧版写在沙盒根目录的
/// `iphone_follow_focus/` 存档，避免升级后老标定丢失。
public final class LensStore {
  public private(set) var lenses: [Lens]
  private let directory: URL

  public var fileURL: URL { directory.appendingPathComponent("lenses-fm03.json") }

  public init(lenses: [Lens] = [], directory: URL? = nil) {
    self.lenses = lenses
    self.directory = directory ?? Self.defaultDirectory()
  }

  public static func defaultDirectory() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("iphone_follow_focus", isDirectory: true)
  }

  public static func load(directory: URL? = nil) -> LensStore {
    let dir = directory ?? defaultDirectory()
    let store = LensStore(directory: dir)
    if let data = try? Data(contentsOf: store.fileURL), !data.isEmpty,
      let lenses = decode(data)
    {
      store.lenses = lenses
      return store
    }
    return store
  }

  private static func decode(_ data: Data) -> [Lens]? {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
    let raw: Any? = (root as? [String: Any])?["lenses"] ?? root
    guard let list = raw as? [[String: Any]] else { return nil }
    return list.compactMap { Lens(jsonObject: $0) }
  }

  @discardableResult
  public func upsert(_ lens: Lens) -> Lens {
    if let i = lenses.firstIndex(where: { $0.id == lens.id }) {
      lenses[i] = lens
    } else {
      lenses.append(lens)
    }
    return lens
  }

  public func remove(id: String) {
    lenses.removeAll { $0.id == id }
  }

  /// 原子写入：中途崩溃不会留下半截 JSON 把整份镜头表弄坏。
  public func save() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: ["lenses": lenses.map(\.jsonObject)],
      options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: fileURL, options: .atomic)
  }
}
