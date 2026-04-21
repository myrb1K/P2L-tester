import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device_template.dart';
import '../providers/app_state.dart';
import '../widgets/apply_template_sheet.dart';
import 'template_editor_screen.dart';

class TemplatesScreen extends StatelessWidget {
  const TemplatesScreen({super.key});

  Future<void> _edit(BuildContext context, {DeviceTemplate? template}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TemplateEditorScreen(initial: template),
      ),
    );
  }

  Future<void> _delete(BuildContext context, AppState state, DeviceTemplate t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Smazat šablonu'),
        content: Text('Smazat "${t.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Smazat'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await state.deleteTemplate(t.name);
    }
  }

  void _apply(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ApplyTemplateSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final templates = state.templates;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Šablony'),
            actions: [
              if (templates.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.rocket_launch),
                  tooltip: 'Aplikovat šablonu',
                  onPressed: () => _apply(context),
                ),
            ],
          ),
          body: templates.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_special,
                          size: 56, color: Colors.grey[400]),
                      const SizedBox(height: 12),
                      Text(
                        'Zatím žádné šablony.\nVytvoř první tlačítkem +.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: templates.length,
                  itemBuilder: (context, i) {
                    final t = templates[i];
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.dashboard_customize),
                        ),
                        title: Text(t.name,
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(
                            '${t.chipCount} modulů · vytvořeno ${_fmtDate(t.created)}'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'edit') _edit(context, template: t);
                            if (v == 'delete') _delete(context, state, t);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Upravit')),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Smazat', style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                        onTap: () => _edit(context, template: t),
                      ),
                    );
                  },
                ),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add),
            label: const Text('Nová šablona'),
            onPressed: () => _edit(context),
          ),
        );
      },
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.day}.${d.month}.${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
