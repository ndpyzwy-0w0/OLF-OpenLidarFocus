import Foundation

// 保留既有会话/LUT 的换算接口；一“圈”内部值现在表示 4096 坐标的归一化行程，
// 不是电机转数。FM03 坐标不能从旧步进脉冲或微步数换算。
public let kFullStepsPerRev = 4096
public let kDefaultLimitRevs = 1
public let kMaxStepHz = 256
public let kAutoDeadbandSteps: Int32 = 8
public struct MotorCal {
  public let fullStepsPerRev: Int
  public init(fullStepsPerRev: Int = kFullStepsPerRev) { self.fullStepsPerRev=fullStepsPerRev }
  public func stepsPerRev(_ scale: Int) -> Int { fullStepsPerRev }
  public func defaultLimitSpan(_ scale: Int) -> Int { 4096 }
  public func maxRevsPerSec(_ scale: Int) -> Double { 256.0/4096 }
  public func revsToSteps(_ fraction: Double, _ scale: Int) -> Int {
    guard fraction.isFinite else { return 0 }
    return Int((min(max(fraction,-1),1)*Double(fullStepsPerRev)).rounded())
  }
  public func stepsToRevs(_ coordinate: Int, _ scale: Int) -> Double { Double(coordinate)/Double(fullStepsPerRev) }
}
