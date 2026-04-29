import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device_template.dart';
import '../models/module.dart';
import '../providers/app_state.dart';
import '../widgets/add_module_dialog.dart';
import '../widgets/module_tile.dart';
import 'unit_detail_screen.dart';

class TemplateEditorScreen extends StatefulWidget {
  final DeviceTemplate? initial;
  /// Předvyplněné moduly pro novou šablonu (např. odvozené z konkrétní jednotky).
  /// Použije se jen když [initial] není zadané.
  final List<PumaModule>? seedModules;
  /// Předvyplněný název pro novou šablonu (uživatel může přepsat).
  /// Použije se jen když [initial] není zadané.
  final String? seedName;

  const TemplateEditorScreen({
    super.key,
    this.initial,
    this.seedModules,
    this.seedName,
  });

  @override
  State<TemplateEditorScreen> createState() => _TemplateEditorScreenState();
}

class _TemplateEditorScreenState extends State<TemplateEditorScreen> {
  late TextEditingController _nameCtrl;
  late List<PumaModule> _modules;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    final seedName = widget.initial?.name ?? widget.seedName ?? '';
    _nameCtrl = TextEditingController(text: seedName);
    _modules = List.of(
      widget.initial?.modules ?? widget.seedModules ?? const [],
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _addModule() async {
    final existing = _modules.map((m) => m.baseAddress).toSet();
    final suggested = existing.isEmpty
        ? null
        : (existing.reduce((a, b) => a > b ? a : b) + 1);
    final result = await showDialog<AddModuleResult>(
      context: context,
      builder: (_) => AddModuleDialog(
        existingAddresses: existing,
        hasPumAWithRoom: hasPumAWithButtonRoom(_modules),
        suggestedAddress: suggested,
      ),
    );
    if (result != null) {
      if (_modules.length >= kMaxChipsPerUnit) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Limit 100 čipů dosažen.'),
        ));
        return;
      }
      setState(() => _modules.add(result.module));
    }
  }

  void _removeAt(int index) {
    setState(() => _modules.removeAt(index));
  }

  Future<void> _editAt(int index) async {
    final existing = _modules.map((m) => m.baseAddress).toSet();
    final result = await showDialog<AddModuleResult>(
      context: context,
      builder: (_) => AddModuleDialog(
        existingAddresses: existing,
        hasPumAWithRoom: hasPumAWithButtonRoom(_modules),
        initial: _modules[index],
      ),
    );
    if (result != null) {
      setState(() => _modules[index] = result.module);
    }
  }

  Future<void> _save(AppState state) async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Zadej název šablony.');
      return;
    }
    if (_modules.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Šablona musí obsahovat alespoň jeden modul.'),
      ));
      return;
    }
    // Pokud přejmenoval na jiné jméno než originál a to jméno už existuje → confirm
    final existing = state.templates.any((t) => t.name == name);
    final isRename = widget.initial != null && widget.initial!.name != name;
    if (existing && (widget.initial == null || isRename)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Přepsat šablonu?'),
          content: Text('Šablona "$name" už existuje. Přepsat?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Přepsat'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    final template = DeviceTemplate(
      name: name,
      modules: _modules,
      created: widget.initial?.created ?? DateTime.now(),
    );
    await state.saveTemplate(template);
    // Pokud přejmenoval, smaž starý záznam
    if (isRename) {
      await state.deleteTemplate(widget.initial!.name);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.initial == null ? 'Nová šablona' : 'Upravit šablonu'),
            actions: [
              IconButton(
                icon: const Icon(Icons.save),
                tooltip: 'Uložit',
                onPressed: () => _save(state),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _nameCtrl,
                  decoration: InputDecoration(
                    labelText: 'Název šablony',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: _nameError,
                  ),
                  onChanged: (_) {
                    if (_nameError != null) setState(() => _nameError = null);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Text(
                      'Moduly: ${_modules.length} / $kMaxChipsPerUnit čipů',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Přidat'),
                      onPressed: _addModule,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _modules.isEmpty
                    ? Center(
                        child: Text(
                          'Zatím žádné moduly.\nPřidej první tlačítkem nahoře.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _modules.length,
                        itemBuilder: (context, i) => ModuleTile(
                          module: _modules[i],
                          compact: true,
                          onEdit: () => _editAt(i),
                          onDelete: () => _removeAt(i),
                        ),
                      ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.save),
            label: const Text('Uložit'),
            onPressed: () => _save(state),
          ),
        );
      },
    );
  }
}
