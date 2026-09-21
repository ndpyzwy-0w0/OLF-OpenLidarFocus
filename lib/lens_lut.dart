import 'dart:convert';
import 'dart:io';
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

  LensLut(List<LutPoint> raw)
      : points = List<LutPoint>.from(raw)
          ..sort((a, b) => a.meters.compareTo(b.meters));

  bool get ready => points.length >= 2;

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

  LensLut adding(LutPoint p) {
    final next = [for (final x in points) x];
    next.removeWhere((x) => (x.meters - p.meters).abs() < 0.02);
    next.add(p);
    return LensLut(next);
  }

  LensLut removingAt(int i) {
    final next = [for (final x in points) x];
    next.removeAt(i);
    return LensLut(next);
  }

  Map<String, Object> toJson() => {
        'points': [for (final p in points) p.toJson()],
      };

  factory LensLut.fromJson(Map<String, dynamic> j) {
    final list = (j['points'] as List<dynamic>? ?? [])
        .map((e) => LutPoint.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return LensLut(list);
  }

  static File _file() {
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    final dir = Directory('$base${Platform.pathSeparator}iphone_follow_focus');
    dir.createSync(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}lens_lut.json');
  }

  static Future<LensLut> load() async {
    final f = _file();
    if (!f.existsSync()) return LensLut(const []);
    final raw = f.readAsStringSync();
    if (raw.isEmpty) return LensLut(const []);
    return LensLut.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save() async {
    _file().writeAsStringSync(jsonEncode(toJson()));
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
