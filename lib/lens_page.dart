import 'package:flutter/material.dart';

import 'lens.dart';
import 'motor_cal.dart';

/// 启动后的首页：选镜头。镜头列表由 [LensStore] 持久化，选一个进入跟焦页。
///
/// 已标定行程的镜头进入后会先走单侧对齐；新镜头先进标定行程。
class LensPage extends StatefulWidget {
  final LensStore store;

  /// 打开某个镜头（进入跟焦页）。由 `main.dart` 注入，避免这里反向依赖它。
  final Future<void> Function(BuildContext context, Lens lens) open;

  const LensPage({super.key, required this.store, required this.open});

  @override
  State<LensPage> createState() => _LensPageState();
}

class _LensPageState extends State<LensPage> {
  static const _cal = MotorCal();

  Future<void> _open(Lens lens) async {
    await widget.open(context, lens);
    if (mounted) setState(() {});
  }

  Future<void> _create() async {
    // 对话框局部 controller：弹出后随对话框一起被回收，不必显式 dispose。
    final name = TextEditingController();
    final params = TextEditingController();
    final created = await showDialog<Lens>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建镜头'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: '名称（如 50mm F1.4）'),
            ),
            TextField(
              controller: params,
              decoration: const InputDecoration(labelText: '参数备注（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final n = name.text.trim();
              if (n.isEmpty) return; // 名称是必填，空名不入库
              Navigator.pop(
                ctx,
                Lens(id: Lens.newId(), name: n, params: params.text.trim()),
              );
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (created == null) return;
    widget.store.upsert(created);
    await widget.store.save();
    if (!mounted) return;
    // 新镜头必然要标定行程，直接进去，省一次点击。
    await _open(created);
  }

  Future<void> _delete(Lens lens) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${lens.name}？'),
        content: const Text('会同时删掉它的行程标定和距离标定表。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    widget.store.remove(lens.id);
    await widget.store.save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final lenses = widget.store.lenses;
    return Scaffold(
      appBar: AppBar(title: const Text('选择镜头')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            '每个镜头单独保存行程标定、变远方向和距离标定表。'
            '新镜头第一次进入要先手动标定行程；标定过的每次进入都要先做单侧对齐。',
          ),
          const Divider(height: 24),
          if (lenses.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('还没有镜头，点下面新建一个。')),
            ),
          for (final l in lenses) _row(l),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.add),
            label: const Text('新建镜头'),
          ),
        ],
      ),
    );
  }

  Widget _row(Lens l) {
    final parts = <String>[
      if (l.params.isNotEmpty) l.params,
      if (l.calibrated)
        '行程 ${_cal.stepsToRevs(l.strokeAt(l.strokeMicrosteps), l.strokeMicrosteps).toStringAsFixed(2)} 圈'
      else
        '未标定行程',
      if (l.lut.ready) '距离标定 ${l.lut.points.length} 点',
      '焦距变远：${l.dir > 0 ? "+" : "-"} 方向',
    ];
    return Card(
      child: ListTile(
        leading: Icon(
          l.calibrated ? Icons.check_circle : Icons.error_outline,
          color: l.calibrated ? Colors.greenAccent : Colors.orangeAccent,
        ),
        title: Text(l.name.isEmpty ? '(未命名)' : l.name),
        subtitle: Text(parts.join(' · ')),
        trailing: IconButton(
          tooltip: '删除',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _delete(l),
        ),
        onTap: () => _open(l),
      ),
    );
  }
}
