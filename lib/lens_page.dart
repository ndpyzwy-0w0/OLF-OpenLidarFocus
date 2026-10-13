import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'ff_core.dart';
import 'main.dart';

/// 镜头库：首次使用指南、镜头状态与跟焦入口。
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
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        scrolledUnderElevation: 0,
        title: const Text(
          '镜头库',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              children: [
                _guide(),
                const SizedBox(height: 20),
                if (_lenses.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('还没有镜头，点下面新建一个。')),
                  ),
                for (final l in _lenses) ...[
                  _row(l),
                  const SizedBox(height: 16),
                ],
                OutlinedButton.icon(
                  onPressed: _create,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    backgroundColor: Theme.of(context).colorScheme.primary
                        .withValues(alpha: .06),
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.primary
                          .withValues(alpha: .5),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: const Icon(LucideIcons.plus),
                  label: const Text(
                    '添加镜头',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _guide() {
    final colors = Theme.of(context).colorScheme;
    const steps = ['FM03 自动寻限位', '选择物距变近方向', '确认对焦方向', '完成至少 5 个标定点'];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '首次使用请完成：',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 10),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        color: colors.onPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      steps[i],
                      style: TextStyle(
                        fontSize: 16,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 28),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.info, size: 18, color: colors.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '更换镜头后需重新寻限位与标定',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(FfLens l) {
    final colors = Theme.of(context).colorScheme;
    final ready = l.directionConfirmed && l.lutReady;
    final statusColor = ready ? colors.primary : colors.onSurfaceVariant;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(l),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      l.name.isEmpty ? '(未命名)' : l.name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '镜头操作',
                    icon: Icon(
                      LucideIcons.ellipsisVertical,
                      color: colors.onSurfaceVariant,
                    ),
                    onSelected: (_) => _delete(l),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.trash2,
                              size: 18,
                              color: colors.error,
                            ),
                            const SizedBox(width: 10),
                            const Text('删除镜头'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (l.params.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  l.params,
                  style: TextStyle(
                    fontSize: 16,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      ready ? LucideIcons.circleCheck : LucideIcons.circleAlert,
                      size: 18,
                      color: statusColor,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        ready ? '已可跟焦' : '待完成标定',
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '距离标定 ${l.lutCount} 点 · ${l.directionConfirmed ? "物距变近：${l.dir < 0 ? "+" : "−"} 方向" : "待选择物距方向"}',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => _open(l),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(LucideIcons.crosshair, size: 20),
                          SizedBox(width: 10),
                          Flexible(
                            child: Text('进入跟焦', style: TextStyle(fontSize: 17)),
                          ),
                        ],
                      ),
                    ),
                    const Icon(LucideIcons.chevronRight, size: 20),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
