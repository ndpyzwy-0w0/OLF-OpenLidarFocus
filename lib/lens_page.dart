import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'app_dialog.dart';
import 'ff_core.dart';
import 'main.dart';

/// 启动后的首页：选镜头。
///
/// 列表来自 `ff.core` 的快照（镜头存档在 Swift 侧）。新建/删除也走核心，
/// 这里不持有任何镜头数据，避免 UI 和核心各存一份。
class LensPage extends StatefulWidget {
  final FfCore core;

  const LensPage({super.key, required this.core});

  @override
  State<LensPage> createState() => _LensPageState();
}

class _LensPageState extends State<LensPage> {
  List<FfLens> _lenses = const [];

  @override
  void initState() {
    super.initState();
    // 首页用一次性快照即可：镜头变了之后由下面的操作自己刷新。
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await widget.core.snapshot();
    if (mounted) setState(() => _lenses = s.lenses);
  }

  Future<void> _open(FfLens lens) async {
    await widget.core.selectLens(lens.id);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FollowPage(core: widget.core, lensId: lens.id),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _create() async {
    // 对话框局部 controller：弹出后随对话框一起被回收，不必显式 dispose。
    final name = TextEditingController();
    final params = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppActionDialog(
        title: '新建镜头',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: appDialogInputDecoration(
                ctx,
                labelText: '名称（如 50mm F1.4）',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: params,
              decoration: appDialogInputDecoration(ctx, labelText: '参数备注（可选）'),
            ),
          ],
        ),
        confirmLabel: '创建',
        onCancel: () => Navigator.pop(ctx, false),
        onConfirm: () {
          if (name.text.trim().isEmpty) return; // 名称是必填，空名不入库
          Navigator.pop(ctx, true);
        },
      ),
    );
    if (ok != true) return;
    await widget.core.createLens(
      name: name.text.trim(),
      params: params.text.trim(),
    );
    if (!mounted) return;
    await _refresh();
    // 新镜头必然要标定行程，直接进去，省一次点击。
    final s = await widget.core.snapshot();
    final created = s.lenses.isEmpty ? null : s.lenses.last;
    if (created != null && mounted) await _open(created);
  }

  Future<void> _delete(FfLens lens) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppActionDialog(
        title: '删除镜头',
        content: Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: '将删除「'),
              TextSpan(
                text: lens.name,
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const TextSpan(text: '」及其行程标定和距离标定表。'),
            ],
          ),
        ),
        confirmLabel: '删除镜头',
        destructive: true,
        onCancel: () => Navigator.pop(ctx, false),
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (ok != true) return;
    await widget.core.deleteLens(lens.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('选择镜头')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '选择镜头开始跟焦。首次使用需标定行程，之后每次进入需对齐。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          if (_lenses.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('还没有镜头，点下面新建一个。')),
              ),
            ),
          for (final l in _lenses) _row(l),
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(LucideIcons.plus),
            label: const Text('新建镜头'),
          ),
        ],
      ),
    );
  }

  Widget _row(FfLens l) {
    final parts = <String>[
      if (l.params.isNotEmpty) l.params,
      if (l.calibrated) '行程 ${l.strokeRevs.toStringAsFixed(2)} 圈' else '未标定行程',
      if (l.lutCount >= 2) '距离标定 ${l.lutCount} 点',
      '焦距变远：${l.dir > 0 ? "+" : "-"} 方向',
    ];
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(
          l.calibrated ? LucideIcons.circleCheck : LucideIcons.circleAlert,
          color: l.calibrated
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.tertiary,
        ),
        title: Text(
          l.name.isEmpty ? '(未命名)' : l.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(parts.join(' · ')),
        ),
        trailing: IconButton(
          tooltip: '删除',
          icon: const Icon(LucideIcons.trash2),
          onPressed: () => _delete(l),
        ),
        onTap: () => _open(l),
      ),
    );
  }
}
