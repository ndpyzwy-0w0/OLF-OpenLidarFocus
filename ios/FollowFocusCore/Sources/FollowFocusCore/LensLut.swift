import Foundation

/// 一个距离标定点：在 [meters] 处的实焦位置是 [steps] 步。
///
/// [steps] 是**标定当次会话**的绝对步数（开环计数），跨会话必须靠对齐重锚。
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

  /// 标定点的步数是在这个细分下记录的。换细分后用 [scaledTo] 换算。
  /// 步数与细分成正比，所以不记录细分，改细分后整套标定会静默错位。
  public let microsteps: Int

  public init(_ raw: [LutPoint], microsteps: Int = 16) {
    self.points = raw.sorted { $0.meters < $1.meters }
    self.microsteps = microsteps
  }

  public var ready: Bool { points.count >= 2 }

  public var minSteps: Int? { points.map(\.steps).min() }
  public var maxSteps: Int? { points.map(\.steps).max() }

  /// 把标定步数换算到另一个细分。细分相同时返回自身。
  public func scaledTo(_ ms: Int) -> LensLut {
    if ms == microsteps || microsteps <= 0 || ms <= 0 { return self }
    let k = Double(ms) / Double(microsteps)
    return LensLut(
      points.map { LutPoint(meters: $0.meters, steps: Int((Double($0.steps) * k).rounded())) },
      microsteps: ms
    )
  }

  /// 整体平移标定点。对齐后要把整张表挪到本次会话的坐标系里。
  public func shifted(_ delta: Int) -> LensLut {
    delta == 0
      ? self
      : LensLut(
        points.map { LutPoint(meters: $0.meters, steps: $0.steps + delta) },
        microsteps: microsteps
      )
  }

  public func stepsFor(_ meters: Double) -> Int? {
    guard ready, let first = points.first, let last = points.last else { return nil }
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

  /// 记录一个标定点。先把已有标定点换算到 [microsteps]，再加新点，
  /// 保证整套标定始终统一在同一个细分下。
  public func adding(_ p: LutPoint, microsteps ms: Int? = nil) -> LensLut {
    let target = ms ?? microsteps
    let base = scaledTo(target)
    var next = base.points.filter { abs($0.meters - p.meters) >= 0.02 }
    next.append(p)
    return LensLut(next, microsteps: target)
  }

  public func removingAt(_ i: Int) -> LensLut {
    var next = points
    guard next.indices.contains(i) else { return self }
    next.remove(at: i)
    return LensLut(next, microsteps: microsteps)
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
