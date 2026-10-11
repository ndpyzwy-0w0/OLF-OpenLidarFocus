import 'package:flutter/material.dart';

import 'ff_core.dart';

/// 只绘制 Swift 功能层提供的插值曲线；不在 Flutter 拟合第二份 LUT。
class LensChart extends StatelessWidget {
  final List<FfLutPoint> points;
  final List<FfLutPoint> curve;

  const LensChart({super.key, required this.points, required this.curve});

  @override
  Widget build(BuildContext context) => Semantics(
    label: '物距与旋转位置图表，横轴物距米，纵轴 FM03 坐标 0 到 4096，${points.length} 个标定点',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('物距—旋转位置图表', style: TextStyle(fontWeight: FontWeight.bold)),
        SizedBox(
          height: 210,
          width: double.infinity,
          child: CustomPaint(
            painter: _ChartPainter(
              points,
              curve,
              Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        const Text('横轴：物距（m） · 纵轴：FM03 旋转位置坐标', style: TextStyle(fontSize: 11)),
      ],
    ),
  );
}

class _ChartPainter extends CustomPainter {
  final List<FfLutPoint> points, curve;
  final Color color;
  _ChartPainter(this.points, this.curve, this.color);

  void _label(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white70, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(42, 12, size.width - 54, size.height - 42);
    final grid = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = plot.bottom - plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _label(canvas, '${1024 * i}', Offset(0, y - 6));
    }
    canvas.drawLine(plot.topLeft, plot.bottomLeft, grid);
    if (points.isEmpty) {
      _label(canvas, '记录实焦点后生成图表', plot.center - const Offset(55, 6));
      return;
    }
    final sorted = [...points]..sort((a, b) => a.meters.compareTo(b.meters));
    final min = sorted.first.meters;
    final max = sorted.last.meters;
    final span = max == min ? 1.0 : max - min;
    Offset xy(FfLutPoint p) => Offset(
      plot.left + (p.meters - min) / span * plot.width,
      plot.bottom - p.steps / 4096 * plot.height,
    );
    for (var i = 0; i <= 4; i++) {
      final x = plot.left + plot.width * i / 4;
      _label(
        canvas,
        (min + span * i / 4).toStringAsFixed(2),
        Offset(x - 12, plot.bottom + 8),
      );
    }
    if (curve.isNotEmpty) {
      final path = Path()..moveTo(xy(curve.first).dx, xy(curve.first).dy);
      for (final p in curve.skip(1)) {
        path.lineTo(xy(p).dx, xy(p).dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    for (final p in sorted) {
      canvas.drawCircle(xy(p), 4, Paint()..color = Colors.orangeAccent);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.points != points || old.curve != curve || old.color != color;
}
