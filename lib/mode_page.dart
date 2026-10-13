import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'device_page.dart';
import 'ff_core.dart';
import 'handwheel_page.dart';
import 'lens_page.dart';

class ModePage extends StatefulWidget {
  final FfCore core;
  const ModePage({super.key, required this.core});

  @override
  State<ModePage> createState() => _ModePageState();
}

class _ModePageState extends State<ModePage> {
  late final _states = widget.core.states();

  Future<void> _open(bool wheel) async {
    await widget.core.setControlMode(wheel ? 'handwheel' : 'automatic');
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => wheel
            ? HandwheelPage(core: widget.core)
            : LensPage(core: widget.core),
      ),
    );
  }

  Future<void> _manageDevice() async {
    final device = await Navigator.of(context).push(
      MaterialPageRoute<FfDevice>(
        builder: (_) => DevicePage(core: widget.core),
      ),
    );
    if (device != null) {
      await widget.core.selectDevice(device);
      await widget.core.connect();
    }
  }

  void _showGuide() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('连接与标定指南'),
        content: const SingleChildScrollView(
          child: Text(
            '1. 在系统无线局域网设置中连接 FF-XXXXXX 热点（密码 change-me），然后在主页“管理”中选择设备。\n\n'
            '2. 自动跟焦：选择或新建镜头，完成 FM03 自动寻限位、选择物距变近方向，再手动对焦记录至少五个物距标定点。完成后开启自动跟焦。\n\n'
            '3. 手动跟焦：连接设备并完成自动寻限位后，使用屏幕手轮或滑块控制焦点，可设置 A/B 点进行拉焦。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '跟焦器',
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '设备管理',
                      onPressed: _manageDevice,
                      icon: const Icon(Icons.settings_outlined, size: 28),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                StreamBuilder<FfState>(
                  stream: _states,
                  builder: (context, snapshot) {
                    final state = snapshot.data ?? const FfState();
                    final alive = state.connected && state.linkAlive;
                    final title = alive
                        ? 'FM03 已连接'
                        : state.connected
                        ? 'FM03 连接异常'
                        : 'FM03 未连接';
                    final detail = alive
                        ? '设备连接正常'
                        : state.connected
                        ? '未收到设备回包，请检查连接'
                        : '连接设备后开始跟焦';
                    return _panel(
                      onTap: _manageDevice,
                      child: Row(
                        children: [
                          Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: alive
                                  ? colors.primary
                                  : state.connected
                                  ? Colors.orange
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  detail,
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '管理',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 40),
                const Text(
                  '选择跟焦方式',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  '自动追焦，或用手轮精细控制。',
                  style: TextStyle(
                    fontSize: 17,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                _mode(
                  false,
                  Icon(
                    Icons.center_focus_strong,
                    size: 56,
                    color: colors.primary,
                  ),
                  '自动跟焦',
                  '用 iPhone LiDAR 实时测距，\n自动调整镜头焦点。',
                ),
                const SizedBox(height: 16),
                _mode(
                  true,
                  CustomPaint(
                    size: const Size(56, 56),
                    painter: _WheelIconPainter(colors.primary),
                  ),
                  '手动跟焦',
                  '滑动屏幕手轮精细调焦，\n支持 A/B 点与触感反馈。',
                ),
                const SizedBox(height: 20),
                _panel(
                  onTap: _showGuide,
                  child: Row(
                    children: [
                      Icon(Icons.help_outline, color: colors.onSurfaceVariant),
                      const SizedBox(width: 14),
                      const Expanded(child: Text('首次使用？查看连接与标定指南')),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel({required VoidCallback onTap, required Widget child}) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(22), child: child),
      ),
    );
  }

  Widget _mode(bool wheel, Widget icon, String title, String body) {
    final colors = Theme.of(context).colorScheme;
    return _panel(
      onTap: () => _open(wheel),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          icon,
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 30,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: TextStyle(
              fontSize: 17,
              height: 1.5,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _WheelIconPainter extends CustomPainter {
  final Color color;
  const _WheelIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, paint);
    for (var i = 0; i < 24; i++) {
      final angle = i * math.pi / 12 - math.pi / 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      paint.strokeWidth = i == 0 ? 3 : 1.2;
      canvas.drawLine(
        center + direction * (radius - (i == 0 ? 12 : 5)),
        center + direction * (radius - 3),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WheelIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
