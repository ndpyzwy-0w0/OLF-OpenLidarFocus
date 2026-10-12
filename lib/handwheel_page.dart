import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'device_page.dart';
import 'ff_core.dart';

class HandwheelPage extends StatefulWidget {
  final FfCore core;
  const HandwheelPage({super.key, required this.core});

  @override
  State<HandwheelPage> createState() => _HandwheelPageState();
}

class _HandwheelPageState extends State<HandwheelPage>
    with WidgetsBindingObserver {
  FfState _s = const FfState();
  StreamSubscription<FfState>? _sub;
  bool _haptics = true;
  int? _arrivalSequence;
  double _duration = 2;
  double? _speedDrag;
  bool get _calRunning =>
      !['idle', 'completed', 'cancelled', 'failed'].contains(_s.calStage);
  bool get _paused => _s.stopLatched && _s.strokeSteps > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = widget.core.states().listen((s) {
      if (!mounted) return;
      if (_arrivalSequence != null &&
          s.wheelArrivalSequence != _arrivalSequence &&
          _haptics) {
        unawaited(HapticFeedback.heavyImpact());
      }
      _arrivalSequence = s.wheelArrivalSequence;
      setState(() => _s = s);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(widget.core.stopPressed());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    unawaited(widget.core.leaveLens());
    super.dispose();
  }

  Future<void> _calibrate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('FM03 自动寻限位'),
        content: const Text(
          '电机会自动寻找镜头两端限位，请确认齿轮安装牢固。重新寻限位会清除本次 A/B 点。\n\n内部寻限位无法通过软件中止；“停止观察”只结束观察，立即中止需断开电机电源。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始寻限位'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.core.startAutoCalibration();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF101516),
    appBar: AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('手机跟焦手轮'),
          if (_s.appVersion.isNotEmpty)
            Text(
              'v${_s.appVersion}',
              style: const TextStyle(fontSize: 11, color: Colors.white60),
            ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: '连接设备',
          icon: const Icon(Icons.wifi),
          onPressed: () async {
            final device = await Navigator.of(context).push(
              MaterialPageRoute<FfDevice>(
                builder: (_) =>
                    DevicePage(core: widget.core, linkOpen: _s.connected),
              ),
            );
            if (device != null) {
              await widget.core.selectDevice(device);
              await widget.core.connect();
            }
          },
        ),
      ],
    ),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth > 600 && box.maxWidth > box.maxHeight) {
              return Row(
                children: [
                  Expanded(
                    child: Center(
                      child: SizedBox.square(
                        dimension: math.min(box.maxHeight, 400),
                        child: _dial(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(child: SingleChildScrollView(child: _controls())),
                ],
              );
            }
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: ListView(
                  children: [
                    _status(),
                    const SizedBox(height: 8),
                    Center(
                      child: SizedBox.square(
                        dimension: math.min(box.maxWidth, 350),
                        child: _dial(),
                      ),
                    ),
                    _controls(showStatus: false),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );

  Widget _status() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          Chip(
            avatar: Icon(
              Icons.circle,
              size: 10,
              color: _s.linkAlive && _s.canOk
                  ? Colors.greenAccent
                  : Colors.orangeAccent,
            ),
            label: Text(
              _s.linkAlive ? (_s.canOk ? 'CAN 在线' : '等待 CAN 反馈') : '未连接设备',
            ),
          ),
          Chip(
            label: Text(
              _paused
                  ? '已停止锁定'
                  : _calRunning
                  ? '正在寻限位'
                  : _s.wheelReady
                  ? (_s.moving ? '正在拉焦' : '手轮就绪')
                  : '先完成寻限位',
            ),
          ),
          if (_s.wheelRangeEnabled) const Chip(label: Text('A/B 限位')),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        _s.positionTrusted ? '实际 ${_s.pos}  →  目标 ${_s.target}' : '实际位置 --',
        style: const TextStyle(color: Colors.white70),
      ),
    ],
  );

  Widget _dial() => WheelDial(
    enabled: _s.wheelReady,
    haptics: _haptics,
    actual: _s.positionTrusted ? _s.pos / 4096 : null,
    target: _s.slider,
    a: _s.wheelA == null ? null : _s.wheelA! / 4096,
    b: _s.wheelB == null ? null : _s.wheelB! / 4096,
    label: _paused
        ? '已停止'
        : _s.positionTrusted
        ? '${(_s.pos / 4096 * 100).toStringAsFixed(1)}%'
        : '--',
    onTurn: widget.core.turnWheel,
  );

  Widget _controls({bool showStatus = true}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (showStatus) ...[_status(), const SizedBox(height: 12)],
      Row(
        children: [
          Expanded(child: _point('A', _s.wheelA)),
          const SizedBox(width: 12),
          Expanded(child: _point('B', _s.wheelB)),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('限制在 A/B 点之间'),
        subtitle: const Text('两点可任意先后；开启后手轮不会越过端点'),
        value: _s.wheelRangeEnabled,
        onChanged:
            _s.wheelReady &&
                !_s.moving &&
                _s.wheelA != null &&
                _s.wheelB != null
            ? widget.core.setWheelRange
            : null,
      ),
      Row(
        children: [
          const Text('过渡时长'),
          const SizedBox(width: 12),
          DropdownButton<double>(
            value: _duration,
            items: [
              for (final n in [.5, 1.0, 2.0, 4.0, 8.0])
                DropdownMenuItem(
                  value: n,
                  child: Text('${n.toStringAsFixed(n < 1 ? 1 : 0)} 秒'),
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _duration = v);
            },
          ),
          const Spacer(),
          TextButton(
            onPressed:
                !_s.moving &&
                    !_s.wheelPulling &&
                    (_s.wheelA != null || _s.wheelB != null)
                ? widget.core.clearWheelPoints
                : null,
            child: const Text('清除 A/B'),
          ),
        ],
      ),
      Row(
        children: [
          for (final point in ['A', 'B'])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: OutlinedButton.icon(
                  onPressed:
                      _s.wheelReady &&
                          (point == 'A' ? _s.wheelA : _s.wheelB) != null
                      ? () =>
                            widget.core.pullWheelTo(point, duration: _duration)
                      : null,
                  icon: const Icon(Icons.swap_horiz),
                  label: Text('拉到 $point'),
                ),
              ),
            ),
        ],
      ),
      if (_s.wheelPulling)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: LinearProgressIndicator(),
        ),
      const SizedBox(height: 16),
      FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: _paused
              ? const Color(0xFF16745E)
              : const Color(0xFFAB4249),
          padding: const EdgeInsets.all(16),
        ),
        onPressed: _s.connected && (!_paused || _s.canResume)
            ? (_paused ? widget.core.resumeControl : widget.core.stopPressed)
            : null,
        icon: Icon(_paused ? Icons.restart_alt : Icons.stop_circle_outlined),
        label: Text(
          _paused
              ? '复位并继续手轮'
              : _calRunning
              ? '停止观察'
              : '停止并锁定',
        ),
      ),
      const SizedBox(height: 8),
      Text(_s.msg, style: const TextStyle(fontSize: 12, color: Colors.white70)),
      if (!_s.wheelReady && !_paused && !_calRunning) ...[
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: _s.connected && _s.calSupported ? _calibrate : null,
          icon: const Icon(Icons.sync),
          label: const Text('FM03 自动寻限位'),
        ),
        if (!_s.connected)
          OutlinedButton.icon(
            onPressed: widget.core.connect,
            icon: const Icon(Icons.wifi),
            label: const Text('连接电机'),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '手轮模式无需物距表。寻限位完成后即可控制。',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ),
      ],
      const SizedBox(height: 16),
      Card(
        child: ExpansionTile(
          title: const Text('手轮设置'),
          leading: const Icon(Icons.tune),
          childrenPadding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Expanded(child: Text('旋转灵敏度')),
                DropdownButton<double>(
                  value: [.25, .5, 1.0, 2.0].contains(_s.wheelSensitivity)
                      ? _s.wheelSensitivity
                      : null,
                  hint: Text('${_s.wheelSensitivity}×'),
                  items: [
                    for (final n in [.25, .5, 1.0, 2.0])
                      DropdownMenuItem(value: n, child: Text('$n×')),
                  ],
                  onChanged: (v) {
                    if (v != null) widget.core.setWheelSensitivity(v);
                  },
                ),
              ],
            ),
            const Text(
              '1×：手轮转一圈对应完整行程；0.25× 用于精细对焦。',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('反转手轮方向'),
              value: _s.wheelReversed,
              onChanged: widget.core.setWheelReversed,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('触感反馈'),
              subtitle: const Text('旋转刻度轻触感，实际到达端点时强触感'),
              value: _haptics,
              onChanged: (v) => setState(() => _haptics = v),
            ),
            Text('最大拨轮速度 ${(_speedDrag ?? _s.speedRevS * 4096).round()}'),
            Slider(
              min: 1,
              max: 256,
              divisions: 255,
              value: (_speedDrag ?? _s.speedRevS * 4096).clamp(1, 256),
              onChanged: _s.moving || _calRunning
                  ? null
                  : (v) => setState(() => _speedDrag = v),
              onChangeEnd: _s.moving || _calRunning
                  ? null
                  : (v) {
                      widget.core.setFm03(kFm03MaxSpeed, v.round());
                      setState(() => _speedDrag = null);
                    },
            ),
            const Text(
              '过渡时长控制目标变化节奏；实际到位时间受电机速度限制。A/B 点在重连、离开模式或重新寻限位后清除。',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _s.connected && _s.calSupported && !_calRunning
                  ? _calibrate
                  : null,
              icon: const Icon(Icons.sync),
              label: const Text('重新寻限位'),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _point(String name, int? coordinate) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Text(
            '$name 点',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            coordinate == null
                ? '未设置'
                : '$coordinate · ${(coordinate / 4096 * 100).toStringAsFixed(1)}%',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
          TextButton(
            onPressed: _s.wheelReady && !_s.moving && !_s.wheelPulling
                ? () => widget.core.setWheelPoint(name)
                : null,
            child: Text(coordinate == null ? '设置 $name 点' : '重设 $name 点'),
          ),
          OutlinedButton(
            onPressed: _s.wheelReady && coordinate != null
                ? () => widget.core.pullWheelTo(name)
                : null,
            child: Text('到 $name 点'),
          ),
        ],
      ),
    ),
  );
}

/// Touch geometry and haptics only; coordinate mapping and limits live in Swift.
class WheelDial extends StatefulWidget {
  final bool enabled, haptics;
  final double? actual, a, b;
  final double target;
  final String label;
  final ValueChanged<double> onTurn;
  const WheelDial({
    super.key,
    required this.enabled,
    required this.haptics,
    required this.actual,
    required this.target,
    this.a,
    this.b,
    required this.label,
    required this.onTurn,
  });

  @override
  State<WheelDial> createState() => _WheelDialState();
}

class _WheelDialState extends State<WheelDial> {
  double? _angle;
  double _detent = 0;
  DateTime _lastHaptic = DateTime.fromMillisecondsSinceEpoch(0);
  double? _touchAngle(Offset p, Size size) {
    final delta = p - Offset(size.width / 2, size.height / 2);
    if (delta.distance < size.shortestSide * .18) return null;
    return math.atan2(delta.dy, delta.dx);
  }

  @override
  void didUpdateWidget(covariant WheelDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _angle = null;
      _detent = 0;
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return Semantics(
        label: '跟焦手轮',
        value: widget.label,
        increasedValue: widget.enabled ? '正向微调' : null,
        decreasedValue: widget.enabled ? '反向微调' : null,
        enabled: widget.enabled,
        onIncrease: widget.enabled ? () => widget.onTurn(1 / 120) : null,
        onDecrease: widget.enabled ? () => widget.onTurn(-1 / 120) : null,
        child: GestureDetector(
          key: const ValueKey('focus-wheel'),
          behavior: HitTestBehavior.opaque,
          onPanStart: widget.enabled
              ? (d) {
                  _angle = _touchAngle(d.localPosition, size);
                  _detent = 0;
                }
              : null,
          onPanUpdate: widget.enabled
              ? (d) {
                  final next = _touchAngle(d.localPosition, size);
                  if (next == null) {
                    _angle = null;
                    return;
                  }
                  if (_angle != null) {
                    final delta = math.atan2(
                      math.sin(next - _angle!),
                      math.cos(next - _angle!),
                    );
                    widget.onTurn(delta / (2 * math.pi));
                    _detent += delta.abs();
                    final now = DateTime.now();
                    if (widget.haptics &&
                        _detent >= math.pi / 30 &&
                        now.difference(_lastHaptic).inMilliseconds >= 80) {
                      unawaited(HapticFeedback.selectionClick());
                      _lastHaptic = now;
                      _detent = 0;
                    }
                  }
                  _angle = next;
                }
              : null,
          onPanEnd: (_) => _angle = null,
          onPanCancel: () => _angle = null,
          child: CustomPaint(
            painter: _WheelPainter(
              widget.actual,
              widget.target,
              widget.a,
              widget.b,
              widget.enabled,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'FOCUS',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 4,
                      color: Colors.white54,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.label,
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.enabled ? '沿轮缘转动手指' : '等待解锁与电机就绪',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _WheelPainter extends CustomPainter {
  final double? actual, a, b;
  final double target;
  final bool enabled;
  _WheelPainter(this.actual, this.target, this.a, this.b, this.enabled);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide * .43;
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFF263332), Color(0xFF161E20)],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF384847),
    );
    for (var i = 0; i < 60; i++) {
      final theta = i * math.pi / 30 - math.pi / 2;
      final unit = Offset(math.cos(theta), math.sin(theta));
      canvas.drawLine(
        center + unit * (r - (i % 5 == 0 ? 18 : 10)),
        center + unit * (r - 4),
        Paint()
          ..strokeWidth = i % 5 == 0 ? 2 : 1
          ..color = enabled ? const Color(0xFF9CAFA9) : Colors.white24,
      );
    }
    final ring = Rect.fromCircle(center: center, radius: r + 6);
    canvas.drawArc(
      ring,
      -math.pi / 2,
      2 * math.pi * target.clamp(0, 1),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = enabled ? const Color(0xFF53D6B7) : Colors.white24,
    );
    void marker(double value, Color color, String? label) {
      final theta = value * 2 * math.pi - math.pi / 2;
      final unit = Offset(math.cos(theta), math.sin(theta));
      canvas.drawCircle(center + unit * (r - 27), 5, Paint()..color = color);
      if (label != null) {
        final text = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(
          canvas,
          center + unit * (r + 18) - Offset(text.width / 2, text.height / 2),
        );
      }
    }

    if (a != null) marker(a!, const Color(0xFFFFBF69), 'A');
    if (b != null) marker(b!, const Color(0xFF79B8FF), 'B');
    if (actual != null) marker(actual!, Colors.white, null);
  }

  @override
  bool shouldRepaint(covariant _WheelPainter old) =>
      actual != old.actual ||
      target != old.target ||
      a != old.a ||
      b != old.b ||
      enabled != old.enabled;
}
