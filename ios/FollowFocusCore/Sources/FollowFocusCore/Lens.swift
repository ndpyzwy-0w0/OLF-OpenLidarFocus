import Foundation

/// App 只持久化镜头信息、物距变远方向及 FM03 归一化坐标的距离表。
/// 机械限位由 FM03 保存；寻限位结果与坐标可信度只存在当前会话。
public struct Lens: Equatable {
  public let id: String
  public var name: String
  public var params: String
  public var lut: LensLut
  /// +1 = 坐标增大时物距变远，-1 = 坐标增大时物距变近。
  public var dir: Int
  public var directionConfirmed: Bool

  public init(id: String, name: String, params: String = "",
    lut: LensLut = LensLut([]), dir: Int = 1, directionConfirmed: Bool = false) {
    self.id = id
    self.name = name
    self.params = params
    self.lut = lut
    self.dir = dir >= 0 ? 1 : -1
    self.directionConfirmed = directionConfirmed
  }

  public static func newId() -> String { "lens-" + UUID().uuidString }
}

// MARK: - JSON

public extension LensLut {
  var jsonObject: [String: Any] {
    [
      "points": points.map { ["m": $0.meters, "s": $0.steps] },
    ]
  }

  init(jsonObject o: [String: Any]) {
    let raw = (o["points"] as? [[String: Any]] ?? []).compactMap { p -> LutPoint? in
      guard let m = number(p["m"]), let s = number(p["s"]) else { return nil }
      return LutPoint(meters: m.doubleValue, steps: s.intValue)
    }
    self.init(raw)
  }
}

public extension Lens {
  var jsonObject: [String: Any] {
    ["id": id, "name": name, "params": params, "dir": dir,
     "directionConfirmed": directionConfirmed,
     "coordinateSystem": "fm03-normalized-v1", "lut": lut.jsonObject]
  }

  init?(jsonObject o: [String: Any]) {
    guard let id = o["id"] as? String else { return nil }
    // 旧版表可能被“最近点对齐”平移过，不能当作 FM03 原始坐标继续跟焦。
    let normalized = o["coordinateSystem"] as? String == "fm03-normalized-v1"
    self.init(id: id, name: o["name"] as? String ?? "",
      params: o["params"] as? String ?? "",
      lut: normalized ? LensLut(jsonObject: o["lut"] as? [String: Any] ?? [:]) : LensLut([]),
      dir: number(o["dir"])?.intValue ?? 1,
      directionConfirmed: normalized && o["directionConfirmed"] as? Bool == true)
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
