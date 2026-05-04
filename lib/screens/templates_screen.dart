import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart' show appVersion;
import '../models/device_template.dart';
import '../providers/app_state.dart';
import '../services/template_io.dart';
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

  Future<void> _exportSingle(BuildContext context, DeviceTemplate t) async {
    await _runExport(context, [t], defaultFileName: _fileNameFor(t.name));
  }

  Future<void> _exportFromAppBar(
      BuildContext context, List<DeviceTemplate> templates) async {
    if (templates.isEmpty) return;
    final selected = templates.length == 1
        ? templates
        : await _pickTemplatesToExport(context, templates);
    if (selected == null || selected.isEmpty) return;
    final fileName = selected.length == 1
        ? _fileNameFor(selected.first.name)
        : 'p2l-templates-${_dateStamp()}.json';
    if (!context.mounted) return;
    await _runExport(context, selected, defaultFileName: fileName);
  }

  Future<List<DeviceTemplate>?> _pickTemplatesToExport(
      BuildContext context, List<DeviceTemplate> all) {
    return showDialog<List<DeviceTemplate>>(
      context: context,
      builder: (_) => _ExportPickerDialog(templates: all),
    );
  }

  Future<void> _runExport(
    BuildContext context,
    List<DeviceTemplate> templates, {
    required String defaultFileName,
  }) async {
    final choice = await showDialog<_ExportChoice>(
      context: context,
      builder: (_) => const _ExportChoiceDialog(),
    );
    if (choice == null) return;
    if (!context.mounted) return;

    final json = TemplateBundle.encode(templates, appVersion: appVersion);
    final messenger = ScaffoldMessenger.of(context);

    try {
      if (choice == _ExportChoice.share) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/$defaultFileName');
        await file.writeAsString(json);
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'application/json')],
          subject: defaultFileName,
        );
      } else {
        final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
        if (isMobile) {
          // Android/iOS: saveFile() vyžaduje bytes a vrátí cestu kam SAF uložil.
          final bytes = utf8.encode(json);
          final path = await FilePicker.platform.saveFile(
            dialogTitle: 'Uložit šablony',
            fileName: defaultFileName,
            type: FileType.custom,
            allowedExtensions: const ['json'],
            bytes: Uint8List.fromList(bytes),
          );
          if (path == null) return;
          messenger.showSnackBar(
            SnackBar(content: Text('Uloženo: $path')),
          );
        } else {
          // Desktop (Windows/Linux/macOS): saveFile vrátí cestu, soubor zapíšeme sami.
          final path = await FilePicker.platform.saveFile(
            dialogTitle: 'Uložit šablony',
            fileName: defaultFileName,
            type: FileType.custom,
            allowedExtensions: const ['json'],
          );
          if (path == null) return;
          final outPath = path.toLowerCase().endsWith('.json') ? path : '$path.json';
          await File(outPath).writeAsString(json);
          messenger.showSnackBar(
            SnackBar(content: Text('Uloženo: $outPath')),
          );
        }
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Export selhal: $e')),
      );
    }
  }

  Future<void> _importFromFile(BuildContext context, AppState state) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Načíst šablony',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    String? content;
    try {
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Nelze přečíst soubor: $e')));
      return;
    }
    if (content == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Prázdný soubor.')));
      return;
    }

    final parsed = TemplateBundle.decode(content);
    if (!parsed.isOk) {
      messenger.showSnackBar(SnackBar(content: Text(parsed.error!)));
      return;
    }

    if (!context.mounted) return;
    await _processImport(context, state, parsed.templates!);
  }

  Future<void> _processImport(
      BuildContext context, AppState state, List<DeviceTemplate> incoming) async {
    final messenger = ScaffoldMessenger.of(context);
    var added = 0;
    var overwritten = 0;
    var skipped = 0;
    _ConflictAction? rememberedAction;

    for (final tpl in incoming) {
      if (!state.hasTemplate(tpl.name)) {
        await state.saveTemplate(tpl);
        added++;
        continue;
      }
      _ConflictAction action;
      if (rememberedAction != null) {
        action = rememberedAction;
      } else {
        if (!context.mounted) return;
        final picked = await showDialog<_ConflictResult>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _ConflictDialog(
            existingName: tpl.name,
            suggestedRename: state.suggestUniqueTemplateName(tpl.name),
            remainingCount: incoming.length - (added + overwritten + skipped) - 1,
          ),
        );
        if (picked == null) {
          // Dialog zavřený = zrušit zbytek importu.
          break;
        }
        action = picked.action;
        if (picked.applyToAll) rememberedAction = action;
      }

      switch (action) {
        case _ConflictAction.overwrite:
          await state.saveTemplate(tpl);
          overwritten++;
          break;
        case _ConflictAction.rename:
          final unique = state.suggestUniqueTemplateName(tpl.name);
          await state.saveTemplate(tpl.copyWith(name: unique));
          added++;
          break;
        case _ConflictAction.skip:
          skipped++;
          break;
      }
    }

    final parts = <String>[];
    if (added > 0) parts.add('přidáno $added');
    if (overwritten > 0) parts.add('přepsáno $overwritten');
    if (skipped > 0) parts.add('přeskočeno $skipped');
    messenger.showSnackBar(
      SnackBar(
        content: Text(parts.isEmpty
            ? 'Import zrušen.'
            : 'Import šablon: ${parts.join(', ')}.'),
      ),
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
                  icon: const Icon(Icons.file_download_outlined),
                  tooltip: 'Exportovat šablony',
                  onPressed: () => _exportFromAppBar(context, templates),
                ),
              IconButton(
                icon: const Icon(Icons.file_upload_outlined),
                tooltip: 'Importovat šablony',
                onPressed: () => _importFromFile(context, state),
              ),
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
                        'Zatím žádné šablony.\nVytvoř první tlačítkem + nebo importuj soubor.',
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
                            if (v == 'export') _exportSingle(context, t);
                            if (v == 'delete') _delete(context, state, t);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Upravit')),
                            PopupMenuItem(value: 'export', child: Text('Exportovat')),
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

  String _dateStamp() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _fileNameFor(String templateName) {
    final safe = templateName
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9ÁČĎÉĚÍŇÓŘŠŤÚŮÝŽáčďéěíňóřšťúůýž _.()-]'), '_');
    return '${safe.isEmpty ? 'template' : safe}.json';
  }
}

// ===========================================================================
// Dialogy
// ===========================================================================

enum _ExportChoice { share, save }

class _ExportChoiceDialog extends StatelessWidget {
  const _ExportChoiceDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Export šablon'),
      content: const Text('Jak chceš se souborem naložit?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        TextButton.icon(
          icon: const Icon(Icons.share),
          label: const Text('Sdílet'),
          onPressed: () => Navigator.pop(context, _ExportChoice.share),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.save_outlined),
          label: const Text('Uložit'),
          onPressed: () => Navigator.pop(context, _ExportChoice.save),
        ),
      ],
    );
  }
}

class _ExportPickerDialog extends StatefulWidget {
  final List<DeviceTemplate> templates;
  const _ExportPickerDialog({required this.templates});

  @override
  State<_ExportPickerDialog> createState() => _ExportPickerDialogState();
}

class _ExportPickerDialogState extends State<_ExportPickerDialog> {
  late final Set<String> _selected =
      widget.templates.map((t) => t.name).toSet();

  @override
  Widget build(BuildContext context) {
    final all = widget.templates;
    final allSelected = _selected.length == all.length;
    return AlertDialog(
      title: const Text('Které šablony exportovat?'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CheckboxListTile(
              dense: true,
              title: Text(allSelected ? 'Odznačit vše' : 'Označit vše'),
              value: allSelected,
              onChanged: (_) => setState(() {
                if (allSelected) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(all.map((t) => t.name));
                }
              }),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: all.length,
                itemBuilder: (_, i) {
                  final t = all[i];
                  final checked = _selected.contains(t.name);
                  return CheckboxListTile(
                    dense: true,
                    title: Text(t.name),
                    subtitle: Text('${t.chipCount} modulů'),
                    value: checked,
                    onChanged: (_) => setState(() {
                      if (checked) {
                        _selected.remove(t.name);
                      } else {
                        _selected.add(t.name);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(
                  context, all.where((t) => _selected.contains(t.name)).toList()),
          child: Text('Pokračovat (${_selected.length})'),
        ),
      ],
    );
  }
}

enum _ConflictAction { overwrite, rename, skip }

class _ConflictResult {
  final _ConflictAction action;
  final bool applyToAll;
  const _ConflictResult(this.action, this.applyToAll);
}

class _ConflictDialog extends StatefulWidget {
  final String existingName;
  final String suggestedRename;
  final int remainingCount;

  const _ConflictDialog({
    required this.existingName,
    required this.suggestedRename,
    required this.remainingCount,
  });

  @override
  State<_ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<_ConflictDialog> {
  bool _applyToAll = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Šablona už existuje'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Šablona "${widget.existingName}" v aplikaci už existuje.\n'
            'Co s ní?',
          ),
          const SizedBox(height: 8),
          Text(
            'Při přejmenování se použije: "${widget.suggestedRename}"',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (widget.remainingCount > 0) ...[
            const SizedBox(height: 12),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text('Použít pro zbývajících ${widget.remainingCount}'),
              value: _applyToAll,
              onChanged: (v) => setState(() => _applyToAll = v ?? false),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
              context, _ConflictResult(_ConflictAction.skip, _applyToAll)),
          child: const Text('Přeskočit'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
              context, _ConflictResult(_ConflictAction.rename, _applyToAll)),
          child: const Text('Přejmenovat'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(
              context, _ConflictResult(_ConflictAction.overwrite, _applyToAll)),
          child: const Text('Přepsat'),
        ),
      ],
    );
  }
}
