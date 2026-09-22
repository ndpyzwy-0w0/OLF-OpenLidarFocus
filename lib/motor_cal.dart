/// 电机转动换算：步距角 → 整步/圈 → 脉冲/圈 → 走圈步数。
///
/// 本机电机为 **0.9°/步**，即 `360 / 0.9 = 400` 整步/圈。
/// 细分由 TMC2209 决定（默认 16），所以脉冲/圈 = 400 × 细分。
library;

/// 0.9° 步距角 → 每圈整步数。
const int kFullStepsPerRev = 400;

/// 未标定时的默认软限位（电机圈数）。
/// **必须与固件 `motor.cpp` 里的 `kDefaultLimitRevs` 一致**，否则 App 以为能走、
/// 固件却把命令夹掉，表现就是“点了没反应”。
const int kDefaultLimitRevs = 20;

/// 固件 `motorSetSpeed()` 里的上限（步/秒）。
/// 细分越高，同样的步率对应的物理速度越低——1/256 时上限只剩 0.39 圈/秒。
const int kMaxStepHz = 40000;

class MotorCal {
  /// 整步/圈。换电机时改这里（1.8° 电机是 200）。
  final int fullStepsPerRev;

  const MotorCal({this.fullStepsPerRev = kFullStepsPerRev});

  /// 脉冲/圈 = 整步/圈 × 细分。
  int stepsPerRev(int microsteps) {
    final ms = microsteps < 1 ? 1 : microsteps;
    return fullStepsPerRev * ms;
  }

  /// 未标定时的软限位跨度（步），随细分缩放。
  int defaultLimitSpan(int microsteps) => stepsPerRev(microsteps) * kDefaultLimitRevs;

  /// 当前细分下能达到的最大物理速度（圈/秒）。
  /// 固件上限是 kMaxStepHz 步/秒，细分越高这个物理上限越低。
  double maxRevsPerSec(int microsteps) {
    final spr = stepsPerRev(microsteps);
    return spr == 0 ? 0 : kMaxStepHz / spr;
  }

  /// 圈数 → 步数。负数表示反转。
  int revsToSteps(double revs, int microsteps) {
    if (!revs.isFinite) return 0;
    return (revs * stepsPerRev(microsteps)).round();
  }

  /// 步数 → 圈数，用于界面显示。
  double stepsToRevs(int steps, int microsteps) {
    final spr = stepsPerRev(microsteps);
    return spr == 0 ? 0 : steps / spr;
  }
}
