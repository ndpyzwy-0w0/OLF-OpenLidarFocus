/// 电机转动换算：步距角 → 整步/圈 → 脉冲/圈 → 走圈步数。
///
/// 本机电机为 **0.9°/步**，即 `360 / 0.9 = 400` 整步/圈。
/// 细分由 TMC2209 决定（默认 16），所以脉冲/圈 = 400 × 细分。
library;

/// 0.9° 步距角 → 每圈整步数。
const int kFullStepsPerRev = 400;

class MotorCal {
  /// 整步/圈。换电机时改这里（1.8° 电机是 200）。
  final int fullStepsPerRev;

  const MotorCal({this.fullStepsPerRev = kFullStepsPerRev});

  /// 脉冲/圈 = 整步/圈 × 细分。
  int stepsPerRev(int microsteps) {
    final ms = microsteps < 1 ? 1 : microsteps;
    return fullStepsPerRev * ms;
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
