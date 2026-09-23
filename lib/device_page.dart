import 'package:flutter/material.dart';

import 'ff_protocol.dart';

/// 设备列表页：列出**能应答发现包的板子**，点一行即选为控制目标。
///
/// 这里列的**不是**周围的 Wi-Fi 热点。iOS 不给普通 App 扫描 Wi-Fi 的 API
/// （`NEHotspotHelper` 要 Apple 单独审批且禁用于配件场景），免费账号也没有
/// Hotspot Configuration entitlement 在 App 内连 Wi-Fi（见 HANDOFF §10）。
/// 所以流程是：先在 设置 → 无线局域网 连上板子热点 `FF-XXXXXX`（密码
/// `change-me`），再回到这一页扫描。
///
/// 扫描用**单播**：iOS 上广播会被系统按缺 multicast entitlement 拒绝
/// （`errno 13`，见 HANDOFF §8.1）。板子是 SoftAP，地址固定，单播够用。
class DevicePage extends StatefulWidget {
  /// 当前控制目标，用于高亮。
  final FfDiscovery? selected;

  /// 控制链路是否已打开，用于顶部状态提示。
  final bool linkOpen;

  const DevicePage({super.key, this.selected, this.linkOpen = false});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  List<FfDiscovery> _devices = const [];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final found = await discoverBoards();
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
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _status(),
          if (_scanning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            ),
          const Divider(height: 24),
          if (_devices.isEmpty && !_scanning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('没有板子应答，先连上它的热点再扫描。')),
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
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  widget.linkOpen ? Icons.link : Icons.link_off,
                  size: 18,
                  color: widget.linkOpen ? Colors.greenAccent : null,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.linkOpen
                      ? '控制链路已打开${active == null ? "" : "：${active.deviceId}"}'
                      : '控制链路未打开',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'iOS 不允许 App 扫描或自行连接 Wi-Fi，热点要你手动切：\n'
              '设置 → 无线局域网 → 选 FF-XXXXXX（密码 change-me），'
              '再回来点右上角重新扫描。',
            ),
            if (active != null) ...[
              const SizedBox(height: 8),
              Text(
                '板子的热点名和这里的 device_id 是同一份数据（都取自 AP 接口 MAC），'
                '所以 ${active.deviceId} 对应的热点就叫 ${active.deviceId}。',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(FfDiscovery d) {
    final active = widget.selected?.deviceId == d.deviceId;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        active ? Icons.check_circle : Icons.router_outlined,
        color: active ? Colors.greenAccent : null,
      ),
      title: Text(d.deviceId.isEmpty ? '(回包无 device_id)' : d.deviceId),
      subtitle: Text(
        'fw ${d.firmware} · ${d.mac}\nUDP ${d.host.address}:${d.udpPort}',
      ),
      isThreeLine: true,
      trailing: active ? const Text('使用中') : const Text('选用'),
      onTap: () => Navigator.pop(context, d),
    );
  }
}
