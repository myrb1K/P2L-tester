import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device_template.dart';
import '../models/module.dart';
import '../providers/app_state.dart';

/// Bottom sheet pro aplikaci šablony na jednotky.
/// [preselectedUnitIds] — jednotky, které budou v sheetu od začátku zaškrtnuté.
class ApplyTemplateSheet extends StatefulWidget {
  final Set<String>? preselectedUnitIds;
  const ApplyTemplateSheet({super.key, this.preselectedUnitIds});

  @override
  State<ApplyTemplateSheet> createState() => _ApplyTemplateSheetState();
}

class _ApplyTemplateSheetState extends State<ApplyTemplateSheet> {
  DeviceTemplate? _selectedTemplate;
  final Set<String> _selectedUnits = {};

  @override
  void initState() {
    super.initState();
    if (widget.preselectedUnitIds != null) {
      _selectedUnits.addAll(widget.preselectedUnitIds!);
    }
  }

  void _apply(AppState state) async {
    if (_selectedTemplate == null || _selectedUnits.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Pozor: RECREATE'),
        content: Text(
          'Aplikace šablony "${_selectedTemplate!.name}" smaže všechna existující zařízení na ${_selectedUnits.length} jednotk(ách) a přepíše je obsahem šablony. Pokračovat?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Aplikovat'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await state.applyTemplateToUnits(
        _selectedTemplate!,
        _selectedUnits.toList(),
      );
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final templates = state.templates;
        final units = state.unitList;

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.75,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              builder: (context, scrollCtrl) => Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Text(
                          'Aplikovat šablonu',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  if (templates.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Žádné uložené šablony. Vytvoř šablonu v sekci Šablony.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: DropdownButtonFormField<DeviceTemplate>(
                        initialValue: _selectedTemplate,
                        decoration: const InputDecoration(
                          labelText: 'Šablona',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: templates
                            .map((t) => DropdownMenuItem(
                                  value: t,
                                  child: Text('${t.name} (${t.chipCount} entit)'),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() => _selectedTemplate = v),
                      ),
                    ),
                  if (_selectedTemplate != null) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _TemplateModulesSummary(template: _selectedTemplate!),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Cílové jednotky',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  Expanded(
                    child: units.isEmpty
                        ? const Center(child: Text('Žádné jednotky'))
                        : ListView.separated(
                            controller: scrollCtrl,
                            itemCount: units.length,
                            separatorBuilder: (_, _) => const Divider(
                              height: 1,
                              thickness: 1,
                            ),
                            itemBuilder: (context, i) {
                              final u = units[i];
                              final checked = _selectedUnits.contains(u.id);
                              final moduleCount =
                                  state.modulesForUnit(u.id)?.length;
                              return CheckboxListTile(
                                value: checked,
                                onChanged: (v) => setState(() {
                                  if (v == true) {
                                    _selectedUnits.add(u.id);
                                  } else {
                                    _selectedUnits.remove(u.id);
                                  }
                                }),
                                title: Row(
                                  children: [
                                    Text(
                                      u.displayName,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: u.isOnline ? null : Colors.grey,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Badge(
                                      isLabelVisible: moduleCount != null,
                                      backgroundColor: Colors.blueGrey,
                                      textColor: Colors.white,
                                      offset: const Offset(-2, 2),
                                      label: Text('$moduleCount'),
                                      child: const Icon(
                                        Icons.device_hub,
                                        size: 24,
                                        color: Colors.blueGrey,
                                      ),
                                    ),
                                  ],
                                ),
                                secondary: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: u.isOnline ? Colors.green : Colors.grey,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton.icon(
                      icon: const Icon(Icons.rocket_launch),
                      label: Text(
                          'Aplikovat na ${_selectedUnits.length} jednotek'),
                      onPressed: (_selectedTemplate != null &&
                              _selectedUnits.isNotEmpty)
                          ? () => _apply(state)
                          : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Rozpis modulů v šabloně podle typu (PUM-A 12× · SENZOR 3× …).
/// Barvy a popisky odpovídají `_ModulesGroupedList` v UnitDetailScreen.
class _TemplateModulesSummary extends StatelessWidget {
  final DeviceTemplate template;
  const _TemplateModulesSummary({required this.template});

  static const _order = [
    ModuleType.pumA,
    ModuleType.pumB,
    ModuleType.pumC,
    ModuleType.dist,
  ];

  static String _label(ModuleType t) => switch (t) {
        ModuleType.pumA => 'PUM-A',
        ModuleType.pumB => 'PUM-B',
        ModuleType.pumC => 'PUM-C',
        ModuleType.dist => 'SENZOR',
      };

  static Color _color(ModuleType t) => switch (t) {
        ModuleType.pumA => Colors.blue,
        ModuleType.pumB => Colors.orange,
        ModuleType.pumC => Colors.purple,
        ModuleType.dist => Colors.teal,
      };

  @override
  Widget build(BuildContext context) {
    final counts = <ModuleType, int>{};
    for (final m in template.modules) {
      counts[m.type] = (counts[m.type] ?? 0) + 1;
    }
    if (counts.isEmpty) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Šablona je prázdná.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final type in _order)
          if ((counts[type] ?? 0) > 0)
            _SummaryChip(
              label: '${_label(type)} ${counts[type]}×',
              color: _color(type),
            ),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final Color color;
  const _SummaryChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        border: Border.all(color: color.withAlpha(110)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
