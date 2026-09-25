import Foundation

/// 0.9° 步距角 → 每圈整步数。
public let kFullStepsPerRev = 400

/// 未标定时的默认软限位（电机圈数）。
/// **必须与固件 `motor.cpp` 里的 `kDefaultLimitRevs` 一致**，否则 App 以为能走、
/// 固件却把命令夹掉，表现就是“点了没反应”。
public let kDefaultLimitRevs = 20

/// 固件 `motorSetSpeed()` 里的上限（步/秒）。
/// 细分越高，同样的步率对应的物理速度越低——1/256 时上限只剩 0.39 圈/秒。
public let kMaxStepHz = 40000

/// 自动跟焦的死区（步）。距离微抖导致目标反复变化时，小于这个步数就不重发，
/// 否则电机每 20ms 被叫去一个新位置，表现为“一直缓慢转、停不下来”。
public let kAutoDeadbandSteps: Int32 = 8

/// 电机转动换算：步距角 → 整步/圈 → 脉冲/圈 → 走圈步数。
public struct MotorCal {
  /// 整步/圈。换电机时改这里（1.8° 电机是 200）。
  public let fullStepsPerRev: Int

  public init(fullStepsPerRev: Int = kFullStepsPerRev) {
    self.fullStepsPerRev = fullStepsPerRev
  }

  /// 脉冲/圈 = 整步/圈 × 细分。
  public func stepsPerRev(_ microsteps: Int) -> Int {
    fullStepsPerRev * max(microsteps, 1)
  }

  /// 未标定时的软限位跨度（步），随细分缩放。
  public func defaultLimitSpan(_ microsteps: Int) -> Int {
    stepsPerRev(microsteps) * kDefaultLimitRevs
  }

  /// 当前细分下能达到的最大物理速度（圈/秒）。
  public func maxRevsPerSec(_ microsteps: Int) -> Double {
    let spr = stepsPerRev(microsteps)
    return spr == 0 ? 0 : Double(kMaxStepHz) / Double(spr)
  }

  /// 预测一次移动能达到的**峰值步频**。
  ///
  /// 走固定距离 d 时若来不及加到巡航速度，运动是三角形加减速：
  /// `v_peak = √(加速度 × 距离)`。所以同样的速度/加速度设置下，
  /// 短行程的峰值速度更低——这就是“走 80 步比走 800 步慢好多”的原因，不是 bug。
  public func peakStepsPerSec(_ distance: Int, _ accelStepS2: Int) -> Double {
    let d = abs(distance)
    let a = max(accelStepS2, 1)
    if d == 0 { return 0 }
    return (Double(a) * Double(d)).squareRoot()
  }

  /// 预测峰值物理速度（圈/秒），已按巡航速度封顶。
  public func peakRevsPerSec(
    _ distance: Int, _ accelStepS2: Int, _ cruiseStepHz: Int, _ microsteps: Int
  ) -> Double {
    let peak = min(peakStepsPerSec(distance, accelStepS2), Double(cruiseStepHz))
    let spr = stepsPerRev(microsteps)
    return spr == 0 ? 0 : peak / Double(spr)
  }

  /// 圈数 → 步数。负数表示反转。非有限值退化为 0，而不是抛错。
  public func revsToSteps(_ revs: Double, _ microsteps: Int) -> Int {
    guard revs.isFinite else { return 0 }
    return Int((revs * Double(stepsPerRev(microsteps))).rounded())
  }

  /// 步数 → 圈数，用于界面显示。
  public func stepsToRevs(_ steps: Int, _ microsteps: Int) -> Double {
    let spr = stepsPerRev(microsteps)
    return spr == 0 ? 0 : Double(steps) / Double(spr)
  }
}
