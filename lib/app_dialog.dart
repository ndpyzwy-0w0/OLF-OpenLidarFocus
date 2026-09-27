import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The shared dialog layout follows MiriaGo's action and input dialogs.
class AppActionDialog extends StatelessWidget {
  const AppActionDialog({
    super.key,
    required this.title,
    required this.content,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onCancel,
    this.destructive = false,
  });

  final String title;
  final Widget content;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final bool destructive;

  static const dangerColor = Color(0xFFF44348);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final muted = dark ? const Color(0xFF2C2C2E) : const Color(0xFFEEF1F4);
    final maxHeight =
        (MediaQuery.sizeOf(context).height -
                MediaQuery.viewInsetsOf(context).bottom -
                48)
            .clamp(0.0, double.infinity);
    final cancel = FilledButton(
      onPressed: onCancel,
      style: FilledButton.styleFrom(
        backgroundColor: muted,
        foregroundColor: scheme.onSurface,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: const Text('取消'),
    );
    final confirm = FilledButton(
      onPressed: onConfirm,
      style: FilledButton.styleFrom(
        backgroundColor: destructive ? dangerColor : scheme.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(confirmLabel, textAlign: TextAlign.center, maxLines: 2),
    );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420, maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                DefaultTextStyle.merge(
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 14,
                    height: 1.55,
                  ),
                  child: content,
                ),
                if (destructive) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: dangerColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          LucideIcons.triangleAlert,
                          color: dangerColor,
                          size: 17,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '此操作无法撤销',
                            style: TextStyle(
                              color: dangerColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth <
                        240 * MediaQuery.textScalerOf(context).scale(1)) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [cancel, const SizedBox(height: 10), confirm],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: cancel),
                        const SizedBox(width: 10),
                        Expanded(child: confirm),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

InputDecoration appDialogInputDecoration(
  BuildContext context, {
  String? labelText,
  String? hintText,
}) {
  final scheme = Theme.of(context).colorScheme;
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide(color: scheme.outline),
  );
  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    filled: true,
    fillColor: Theme.of(context).scaffoldBackgroundColor,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
    border: border,
    enabledBorder: border,
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: scheme.primary, width: 1.25),
    ),
  );
}
