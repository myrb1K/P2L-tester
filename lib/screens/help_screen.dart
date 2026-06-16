import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Obrazovka „Nápověda" — načte návod z assetu [docs/navod.md] a vyrenderuje
/// ho jednoduchým markdown rendererem ([_MarkdownView]). Stejný soubor je
/// čitelný i na GitHubu (jeden zdroj, dvě cesty přístupu).
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const _assetPath = 'docs/navod.md';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nápověda')),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(_assetPath),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Nápovědu se nepodařilo načíst.\n${snapshot.error ?? ''}'),
              ),
            );
          }
          return Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              child: _MarkdownView(source: snapshot.data!),
            ),
          );
        },
      ),
    );
  }
}

/// Minimalistický markdown renderer pro podmnožinu použitou v [docs/navod.md]:
/// nadpisy `#`/`##`/`###`, odstavce, odrážky `- `, číslované `1.`, citace `> `,
/// vodorovná čára `---`, GFM tabulky a inline `**tučné**` / `` `kód` ``.
class _MarkdownView extends StatelessWidget {
  final String source;

  const _MarkdownView({required this.source});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    final blocks = <Widget>[];

    int i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trimRight();

      // Prázdný řádek
      if (trimmed.trim().isEmpty) {
        i++;
        continue;
      }

      // Vodorovná čára
      if (trimmed.trim() == '---' || trimmed.trim() == '***') {
        blocks.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Divider(height: 1),
        ));
        i++;
        continue;
      }

      // Nadpisy
      if (trimmed.startsWith('### ')) {
        blocks.add(_heading(context, trimmed.substring(4), theme.textTheme.titleMedium));
        i++;
        continue;
      }
      if (trimmed.startsWith('## ')) {
        blocks.add(_heading(context, trimmed.substring(3), theme.textTheme.titleLarge));
        i++;
        continue;
      }
      if (trimmed.startsWith('# ')) {
        blocks.add(_heading(context, trimmed.substring(2), theme.textTheme.headlineSmall));
        i++;
        continue;
      }

      // Tabulka: řádek s '|' následovaný oddělovačem '|---|'
      if (trimmed.contains('|') &&
          i + 1 < lines.length &&
          _isTableSeparator(lines[i + 1])) {
        final tableLines = <String>[lines[i], lines[i + 1]];
        int j = i + 2;
        while (j < lines.length && lines[j].contains('|') && lines[j].trim().isNotEmpty) {
          tableLines.add(lines[j]);
          j++;
        }
        blocks.add(_table(context, tableLines));
        i = j;
        continue;
      }

      // Citace
      if (trimmed.startsWith('> ')) {
        final quote = <String>[];
        while (i < lines.length && lines[i].trimRight().startsWith('> ')) {
          quote.add(lines[i].trimRight().substring(2));
          i++;
        }
        blocks.add(_blockquote(context, quote.join(' ')));
        continue;
      }

      // Odrážky
      if (_isBullet(trimmed)) {
        final items = <String>[];
        while (i < lines.length && _isBullet(lines[i].trimRight())) {
          items.add(lines[i].trimRight().trimLeft().substring(2));
          i++;
        }
        blocks.add(_list(context, items, ordered: false));
        continue;
      }

      // Číslovaný seznam
      if (_orderedMarker(trimmed) != null) {
        final items = <String>[];
        while (i < lines.length) {
          final m = _orderedMarker(lines[i].trimRight());
          if (m == null) break;
          items.add(lines[i].trimRight().substring(m));
          i++;
        }
        blocks.add(_list(context, items, ordered: true));
        continue;
      }

      // Odstavec (sloučí navazující neprázdné řádky)
      final para = <String>[line.trim()];
      i++;
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          !_isBlockStart(lines[i])) {
        para.add(lines[i].trim());
        i++;
      }
      blocks.add(_paragraph(context, para.join(' ')));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    );
  }

  bool _isBullet(String s) {
    final t = s.trimLeft();
    return t.startsWith('- ') || t.startsWith('* ');
  }

  /// Vrací délku číslovaného prefixu (`"1. "` → 3), jinak null.
  int? _orderedMarker(String s) {
    final m = RegExp(r'^(\d+)\.\s').firstMatch(s);
    return m?.end;
  }

  bool _isTableSeparator(String s) {
    final t = s.trim();
    if (!t.contains('|') || !t.contains('-')) return false;
    return RegExp(r'^\|?[\s:|-]+\|?$').hasMatch(t) && t.contains('-');
  }

  /// Začíná řádek nový blok (nadpis/čára/odrážka/citace/tabulka)?
  bool _isBlockStart(String line) {
    final t = line.trimRight();
    final tl = t.trimLeft();
    return t.startsWith('#') ||
        t.trim() == '---' ||
        t.trim() == '***' ||
        tl.startsWith('- ') ||
        tl.startsWith('* ') ||
        t.startsWith('> ') ||
        _orderedMarker(t) != null ||
        (t.contains('|') && _isTableSeparator(t));
  }

  Widget _heading(BuildContext context, String text, TextStyle? style) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: RichText(
        text: TextSpan(
          children: _inlineSpans(context, text, style ?? const TextStyle()),
        ),
      ),
    );
  }

  Widget _paragraph(BuildContext context, String text) {
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: RichText(
        text: TextSpan(children: _inlineSpans(context, text, base.copyWith(height: 1.4))),
      ),
    );
  }

  Widget _blockquote(BuildContext context, String text) {
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: color.withAlpha(18),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: RichText(
        text: TextSpan(
          children: _inlineSpans(context, text, base.copyWith(height: 1.4)),
        ),
      ),
    );
  }

  Widget _list(BuildContext context, List<String> items, {required bool ordered}) {
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var idx = 0; idx < items.length; idx++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, left: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(
                      ordered ? '${idx + 1}.' : '•',
                      style: base.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        children: _inlineSpans(context, items[idx], base.copyWith(height: 1.35)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _table(BuildContext context, List<String> lines) {
    final base = Theme.of(context).textTheme.bodySmall ?? const TextStyle();
    final divider = Theme.of(context).dividerColor;
    final headerBg = Theme.of(context).colorScheme.onSurface.withAlpha(12);

    List<String> cells(String row) {
      var r = row.trim();
      if (r.startsWith('|')) r = r.substring(1);
      if (r.endsWith('|')) r = r.substring(0, r.length - 1);
      return r.split('|').map((c) => c.trim()).toList();
    }

    final header = cells(lines[0]);
    final body = [for (var k = 2; k < lines.length; k++) cells(lines[k])];

    TableRow buildRow(List<String> row, {required bool isHeader}) {
      return TableRow(
        decoration: isHeader ? BoxDecoration(color: headerBg) : null,
        children: [
          for (var c = 0; c < header.length; c++)
            Padding(
              padding: const EdgeInsets.all(6),
              child: RichText(
                text: TextSpan(
                  children: _inlineSpans(
                    context,
                    c < row.length ? row[c] : '',
                    isHeader ? base.copyWith(fontWeight: FontWeight.bold) : base,
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Table(
        border: TableBorder.all(color: divider),
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: [
          buildRow(header, isHeader: true),
          for (final row in body) buildRow(row, isHeader: false),
        ],
      ),
    );
  }

  /// Inline parser pro `**tučné**` a `` `kód` ``.
  List<InlineSpan> _inlineSpans(BuildContext context, String text, TextStyle base) {
    final codeBg = Theme.of(context).colorScheme.onSurface.withAlpha(20);
    final spans = <InlineSpan>[];
    var i = 0;
    while (i < text.length) {
      final bold = text.indexOf('**', i);
      final code = text.indexOf('`', i);

      int next = -1;
      var kind = '';
      if (bold != -1 && (code == -1 || bold <= code)) {
        next = bold;
        kind = 'bold';
      } else if (code != -1) {
        next = code;
        kind = 'code';
      }

      if (next == -1) {
        spans.add(TextSpan(text: text.substring(i), style: base));
        break;
      }
      if (next > i) {
        spans.add(TextSpan(text: text.substring(i, next), style: base));
      }

      if (kind == 'bold') {
        final end = text.indexOf('**', next + 2);
        if (end == -1) {
          spans.add(TextSpan(text: text.substring(next), style: base));
          break;
        }
        spans.add(TextSpan(
          text: text.substring(next + 2, end),
          style: base.copyWith(fontWeight: FontWeight.bold),
        ));
        i = end + 2;
      } else {
        final end = text.indexOf('`', next + 1);
        if (end == -1) {
          spans.add(TextSpan(text: text.substring(next), style: base));
          break;
        }
        spans.add(TextSpan(
          text: text.substring(next + 1, end),
          style: base.copyWith(fontFamily: 'monospace', backgroundColor: codeBg),
        ));
        i = end + 1;
      }
    }
    return spans;
  }
}
