import 'dart:math' as math;

class LutPoint {
  final double meters;
  final int steps;

  const LutPoint({required this.meters, required this.steps});

  Map<String, Object> toJson() => {'m': meters, 's': steps};

  factory LutPoint.fromJson(Map<String, dynamic> j) => LutPoint(
        meters: (j['m'] as num).toDouble(),
        steps: (j['s'] as num).toInt(),
      );
}

/// Maps subject distance to motor steps in 1/distance space.
class LensLut {
  final List<LutPoint> points;

  /// 标定点的步数是在这个细分下记录的。换细分后用 [scaledTo] 换算。
  /// 步数与细分成正比，所以同一物理位置在不同细分下步数不同——
  /// 不记录细分，改细分后整套标定就会静默错位。
  final int microsteps;

  LensLut(List<LutPoint> raw, {this.microsteps = 16})
      : points = List<LutPoint>.from(raw)
          ..sort((a, b) => a.meters.compareTo(b.meters));

  bool get ready => points.length >= 2;

  /// 把标定步数换算到另一个细分。细分相同时返回自身。
  LensLut scaledTo(int ms) {
    if (ms == microsteps || microsteps <= 0 || ms <= 0) return this;
    final k = ms / microsteps;
    return LensLut(
      [
        for (final p in points)
          LutPoint(meters: p.meters, steps: (p.steps * k).round()),
      ],
      microsteps: ms,
    );
  }

  /// 整体平移标定点。对齐后要把整张表挪到本次会话的坐标系里，
  /// 因为存的是“标定当次会话”的绝对步数，而开环步数跨会话不可信。
  LensLut shifted(int delta) => delta == 0
      ? this
      : LensLut(
          [
            for (final p in points)
              LutPoint(meters: p.meters, steps: p.steps + delta),
          ],
          microsteps: microsteps,
        );

  int? get minSteps =>
      points.isEmpty ? null : points.map((p) => p.steps).reduce(math.min);

  int? get maxSteps =>
      points.isEmpty ? null : points.map((p) => p.steps).reduce(math.max);

  int? stepsFor(double meters) {
    if (!ready) return null;
    final m = meters < 0.05 ? 0.05 : meters;
    if (m <= points.first.meters) return points.first.steps;
    if (m >= points.last.meters) return points.last.steps;
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      if (m <= b.meters) return _interpInv(a, b, m);
    }
    return points.last.steps;
  }

  /// 记录一个标定点。先把已有标定点换算到 [microsteps]，再加新点，
  /// 保证整套标定始终统一在同一个细分下。
  LensLut adding(LutPoint p, {int? microsteps}) {
    final ms = microsteps ?? this.microsteps;
    final base = scaledTo(ms);
    final next = [for (final x in base.points) x];
    next.removeWhere((x) => (x.meters - p.meters).abs() < 0.02);
    next.add(p);
    return LensLut(next, microsteps: ms);
  }

  LensLut removingAt(int i) {
    final next = [for (final x in points) x];
    next.removeAt(i);
    return LensLut(next, microsteps: microsteps);
  }

  Map<String, Object> toJson() => {
        'microsteps': microsteps,
        'points': [for (final p in points) p.toJson()],
      };

  factory LensLut.fromJson(Map<String, dynamic> j) {
    final list = (j['points'] as List<dynamic>? ?? [])
        .map((e) => LutPoint.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return LensLut(list,
        microsteps: (j['microsteps'] as num?)?.toInt() ?? 16);
  }
}

/// Stronger smoothing when still, faster when the subject moves.
class DistFilter {
  double? y;

  double update(double x) {
    final prev = y;
    if (prev == null) {
      y = x;
      return x;
    }
    final a = (x - prev).abs() > 0.12 ? 0.55 : 0.18;
    final next = a * x + (1 - a) * prev;
    y = next;
    return next;
  }

  void reset() => y = null;
}

int _interpInv(LutPoint a, LutPoint b, double m) {
  final ia = 1.0 / a.meters;
  final ib = 1.0 / b.meters;
  final im = 1.0 / m;
  final den = ib - ia;
  final t = den.abs() < 1e-9 ? 0.0 : (im - ia) / den;
  return (a.steps + t * (b.steps - a.steps)).round();
}
