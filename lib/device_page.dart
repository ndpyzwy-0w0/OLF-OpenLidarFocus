import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'ff_core.dart';

/// 设备列表页：列出**能应答发现包的板子**，点一行即选为控制目标。
///
/// 这里列的**不是**周围的 Wi-Fi 热点。iOS 不给普通 App 扫描 Wi-Fi 的 API
/// （`NEHotspotHelper` 要 Apple 单独审批且禁用于配件场景），免费账号也没有
/// Hotspot Configuration entitlement 在 App 内连 Wi-Fi（见 HANDOFF §10）。
/// 所以流程是：先在 设置 → 无线局域网 连上板子热点 `FF-XXXXXX`（密码
/// `change-me`），再回到这一页扫描。
///
/// 扫描由核心完成（Swift 侧单播发现：iOS 上广播会被系统按缺 multicast
/// entitlement 拒绝，`errno 13`，见 HANDOFF §8.1）。板子是 SoftAP，地址固定，单播够用。
class DevicePage extends StatefulWidget {
  final FfCore core;

  /// 当前控制目标，用于高亮。
  final FfDevice? selected;

  /// 控制链路是否已打开，用于顶部状态提示。
  final bool linkOpen;

  const DevicePage({
    super.key,
    required this.core,
    this.selected,
    this.linkOpen = false,
  });

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  List<FfDevice> _devices = const [];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final found = await widget.core.discover();
    if (!mounted) return;
    setState(() {
      _devices = found;
      _scanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备'),
        actions: [
          IconButton(
            tooltip: '重新扫描',
            onPressed: _scanning ? null : _scan,
            icon: const Icon(LucideIcons.refreshCw),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _status(),
          if (_scanning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '发现的设备',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          if (_devices.isEmpty && !_scanning)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: Text('没有板子应答。连接热点后点右上角重新扫描。')),
              ),
            ),
          for (final d in _devices) _row(d),
        ],
      ),
    );
  }

  /// Wi-Fi 手动切换指引 + 当前链路状态。
  Widget _status() {
    final active = widget.selected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  widget.linkOpen ? LucideIcons.link : LucideIcons.link2Off,
                  size: 20,
                  color: widget.linkOpen
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.linkOpen
                        ? '控制链路已打开${active == null ? "" : "：${active.deviceId}"}'
                        : '控制链路未打开',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('连接设备', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('1. 在 iOS 设置 → 无线局域网中连接 FF-XXXXXX 热点。'),
            const Text('2. 输入密码 change-me，返回应用。'),
            const Text('3. 点右上角重新扫描，然后选择设备。'),
            if (active != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '当前设备热点：${active.deviceId}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(FfDevice d) {
    final active = widget.selected?.deviceId == d.deviceId;
    return Card(
      child: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            leading: Icon(
              active ? LucideIcons.circleCheck : LucideIcons.router,
              color: active ? Theme.of(context).colorScheme.primary : null,
            ),
            title: Text(
              d.deviceId.isEmpty ? '(回包无 device_id)' : d.deviceId,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(active ? '当前使用中' : '点击选用'),
            trailing: const Icon(LucideIcons.chevronRight),
            onTap: () => Navigator.pop(context, d),
          ),
          ExpansionTile(
            title: const Text('技术信息', style: TextStyle(fontSize: 13)),
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '固件 ${d.firmware} · MAC ${d.mac}\nUDP ${d.host}:${d.udpPort}',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
