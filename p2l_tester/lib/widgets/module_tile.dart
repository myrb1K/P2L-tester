import 'package:flutter/material.dart';

import '../models/module.dart';

class ModuleTile extends StatelessWidget {
  final PumaModule module;
  final VoidCallback? onReplace;
  final VoidCallback? onDelete;
  final bool compact;

  const ModuleTile({
    super.key,
    required this.module,
    this.onReplace,
    this.onDelete,
    this.compact = false,
  });

  IconData get _icon {
    switch (module.type) {
      case ModuleType.pumA:
        return Icons.display_settings;
      case ModuleType.pumB:
        return Icons.radio_button_checked;
      case ModuleType.pumC:
        return Icons.swap_vert;
      case ModuleType.dist:
        return Icons.straighten;
    }
  }

  String _subtitle() {
    final entries = module.toDevices().length;
    final base = '$entries entries';
    if (module.type == ModuleType.dist && module.distConfig != null) {
      final c = module.distConfig!;
      final range = switch (c.measureType) {
        1 => 'Short',
        2 => 'Middle',
        3 => 'Long',
        _ => '?',
      };
      return '$base · ${c.measurePeriod}ms · $range · ±${c.maxDeviation}mm';
    }
    return base;
  }

  Color get _color {
    switch (module.type) {
      case ModuleType.pumA:
        return Colors.blue;
      case ModuleType.pumB:
        return Colors.orange;
      case ModuleType.pumC:
        return Colors.purple;
      case ModuleType.dist:
        return Colors.teal;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: compact ? 2 : 4),
      child: ListTile(
        dense: compact,
        leading: CircleAvatar(
          backgroundColor: _color.withAlpha(40),
          child: Icon(_icon, color: _color, size: 20),
        ),
        title: Text(
          module.displayLabel,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          _subtitle(),
          style: const TextStyle(fontSize: 11),
        ),
        trailing: (onReplace != null || onDelete != null)
            ? PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20),
                onSelected: (v) {
                  if (v == 'replace') onReplace?.call();
                  if (v == 'delete') onDelete?.call();
                },
                itemBuilder: (_) => [
                  if (onReplace != null)
                    const PopupMenuItem(
                      value: 'replace',
                      child: Row(children: [
                        Icon(Icons.swap_horiz, size: 18),
                        SizedBox(width: 8),
                        Text('Vyměnit'),
                      ]),
                    ),
                  if (onDelete != null)
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(children: [
                        Icon(Icons.delete_outline, size: 18, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Smazat', style: TextStyle(color: Colors.red)),
                      ]),
                    ),
                ],
              )
            : null,
      ),
    );
  }
}
