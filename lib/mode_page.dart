import 'package:flutter/material.dart';

import 'device_page.dart';
import 'ff_core.dart';
import 'handwheel_page.dart';
import 'lens_page.dart';

class ModePage extends StatelessWidget {
  final FfCore core;
  const ModePage({super.key, required this.core});

  Future<void> _open(BuildContext context, bool wheel) async {
    await core.setControlMode(wheel ? 'handwheel' : 'automatic');
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            wheel ? HandwheelPage(core: core) : LensPage(core: core),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('跟焦器'),
      actions: [
        IconButton(
          tooltip: '连接设备',
          icon: const Icon(Icons.wifi),
          onPressed: () async {
            final device = await Navigator.of(context).push(
              MaterialPageRoute<FfDevice>(
                builder: (_) => DevicePage(core: core),
              ),
            );
            if (device != null) {
              await core.selectDevice(device);
              await core.connect();
            }
          },
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              '选择你的跟焦方式',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            const Text(
              '同一台 FM03，两种控制方式。先连接固件热点，再选择模式。',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 28),
            _mode(
              context,
              false,
              Icons.center_focus_strong,
              '自动跟焦',
              '用 iPhone LiDAR 测距，按镜头标定表自动跟随焦点。',
              '选择镜头 · 寻限位 · 物距标定',
            ),
            const SizedBox(height: 16),
            _mode(
              context,
              true,
              Icons.rotate_right,
              '手机跟焦手轮',
              '用手指转动屏幕手轮，精细拉焦，设置 A/B 点并获得触感提醒。',
              '无需 LiDAR · 无需五点物距表',
            ),
          ],
        ),
      ),
    ),
  );

  Widget _mode(
    BuildContext context,
    bool wheel,
    IconData icon,
    String title,
    String body,
    String detail,
  ) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => _open(context, wheel),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 32, color: const Color(0xFF53D6B7)),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(Icons.arrow_forward),
              ],
            ),
            const SizedBox(height: 16),
            Text(body),
            const SizedBox(height: 12),
            Text(
              detail,
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
      ),
    ),
  );
}
