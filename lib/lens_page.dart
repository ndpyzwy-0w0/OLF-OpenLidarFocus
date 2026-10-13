import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
      builder: (ctx) => AlertDialog(
        title: const Text('新建镜头'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => FocusManager.instance.primaryFocus?.unfocus(),
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(labelText: '名称（如 50mm F1.4）'),
            ),
            TextField(
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => FocusManager.instance.primaryFocus?.unfocus(),
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              controller: params,
              decoration: const InputDecoration(labelText: '参数备注（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (name.text.trim().isEmpty) return; // 名称是必填，空名不入库
              Navigator.pop(ctx, true);
            },
            child: const Text('创建'),
          ),
        ],
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
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${lens.name}？'),
        content: const Text('会删除镜头信息、方向选择和距离标定表。'),
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
    await widget.core.deleteLens(lens.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('选择镜头')),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            '新建镜头 → FM03 自动寻限位 → 选择物距变近方向 → 手动对焦标定至少 5 点 → 跟焦。'
            '每个镜头保存方向和物距—旋转位置图表；机械限位由电机保留。重新连接或换镜头后先寻限位。',
          ),
          const Divider(height: 24),
          if (_lenses.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('还没有镜头，点下面新建一个。')),
            ),
          for (final l in _lenses) _row(l),
          const SizedBox(height: 12),
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
      '距离标定 ${l.lutCount} 点${l.lutReady ? " · 可跟焦" : " · 至少需 5 点"}',
      l.directionConfirmed ? '物距变近：${l.dir < 0 ? "+" : "−"} 方向' : '待选择物距方向',
    ];
    return Card(
      child: ListTile(
        leading: Icon(
          l.lutReady ? LucideIcons.circleCheck : LucideIcons.circleAlert,
          color: l.lutReady ? Colors.greenAccent : Colors.orangeAccent,
        ),
        title: Text(l.name.isEmpty ? '(未命名)' : l.name),
        subtitle: Text(parts.join(' · ')),
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
