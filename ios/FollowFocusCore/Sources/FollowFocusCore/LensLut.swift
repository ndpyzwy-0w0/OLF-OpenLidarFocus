import Foundation

/// 在 meters 物距处实焦时，FM03 原始归一化坐标为 steps（0～4096）。
public struct LutPoint: Equatable {
  public let meters: Double
  public let steps: Int

  public init(meters: Double, steps: Int) {
    self.meters = meters
    self.steps = steps
  }
}

/// 在 1/距离 空间里把被摄距离映射到电机步数。
public struct LensLut: Equatable {
  public let points: [LutPoint]

  public init(_ raw: [LutPoint]) {
    self.points = raw.filter {
      $0.meters.isFinite && (0.05...1000).contains($0.meters) && (0...4096).contains($0.steps)
    }.sorted { $0.meters < $1.meters }
  }

  public static let minimumPoints = 5

  public var ready: Bool { points.count >= Self.minimumPoints && isMonotonic }

  public var isMonotonic: Bool {
    guard points.count >= 2 else { return false }
    let dir = points.last!.steps > points.first!.steps ? 1 : -1
    return zip(points, points.dropFirst()).allSatisfy {
      $1.meters - $0.meters >= 0.02 && ($1.steps - $0.steps) * dir > 0
    }
  }

  public func matchesDirection(_ dir: Int) -> Bool {
    isMonotonic && (points.last!.steps - points.first!.steps) * dir > 0
  }

  /// 图表与跟焦共用插值；少于五点时显示预览，不能开启自动跟焦。
  public var curve: [LutPoint] {
    guard isMonotonic, let first = points.first, let last = points.last else { return [] }
    return (0...80).compactMap { i in
      let m = first.meters + (last.meters - first.meters) * Double(i) / 80
      return interpolatedSteps(m).map { LutPoint(meters: m, steps: $0) }
    }
  }

  public func stepsFor(_ meters: Double) -> Int? {
    guard ready, meters.isFinite, meters > 0 else { return nil }
    return interpolatedSteps(meters)
  }

  private func interpolatedSteps(_ meters: Double) -> Int? {
    guard let first = points.first, let last = points.last else { return nil }
    let m = max(meters, 0.05)
    if m <= first.meters { return first.steps }
    if m >= last.meters { return last.steps }
    for i in 0..<(points.count - 1) {
      let a = points[i]
      let b = points[i + 1]
      if m <= b.meters { return interpInv(a, b, m) }
    }
    return last.steps
  }

  /// 距离相差不到 2 cm 的点直接替换；全部使用 FM03 0～4096 坐标。
  public func adding(_ p: LutPoint) -> LensLut {
    guard p.meters.isFinite, (0.05...1000).contains(p.meters), (0...4096).contains(p.steps) else { return self }
    return LensLut(points.filter { abs($0.meters - p.meters) >= 0.02 } + [p])
  }

  public func removingAt(_ i: Int) -> LensLut {
    var next = points
    guard next.indices.contains(i) else { return self }
    next.remove(at: i)
    return LensLut(next)
  }
}

/// 1/距离 空间的线性插值。
private func interpInv(_ a: LutPoint, _ b: LutPoint, _ m: Double) -> Int {
  let ia = 1.0 / a.meters
  let ib = 1.0 / b.meters
  let im = 1.0 / m
  let den = ib - ia
  let t = abs(den) < 1e-9 ? 0.0 : (im - ia) / den
  return Int((Double(a.steps) + t * Double(b.steps - a.steps)).rounded())
}

/// 距离滤波：静止时更稳，被摄体移动时跟得快。
public final class DistFilter {
  public private(set) var y: Double?

  public init() {}

  public func update(_ x: Double) -> Double {
    guard let prev = y else {
      y = x
      return x
    }
    let a = abs(x - prev) > 0.12 ? 0.55 : 0.18
    let next = a * x + (1 - a) * prev
    y = next
    return next
  }

  public func reset() { y = nil }
}
