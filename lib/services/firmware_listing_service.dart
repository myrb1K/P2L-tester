import 'dart:async';

import 'package:http/http.dart' as http;

/// Jeden firmware soubor v listingu.
class FirmwareFile {
  /// Holé jméno souboru, např. `P2L_26033101NT.bin`.
  final String name;

  /// Suffix-flag (NT/OT/CT/…). Parsovaný z názvu, prázdný pokud neodpovídá vzoru.
  final String typeTag;

  /// 8-ciferné číslo `YYMMDDVV` pro řazení (sestupně = nejnovější nahoře).
  /// 0 pokud název neodpovídá vzoru.
  final int sortKey;

  /// `2026-03-31` pro zobrazení. Prázdné pokud parser selže.
  final String dateLabel;

  /// `01`, `02` … revize toho dne, prázdné pokud parser selže.
  final String revisionLabel;

  /// Lidsky čitelná velikost ze serveru, např. `1.3M` nebo `484K`. Volitelné.
  final String? sizeLabel;

  const FirmwareFile({
    required this.name,
    required this.typeTag,
    required this.sortKey,
    required this.dateLabel,
    required this.revisionLabel,
    this.sizeLabel,
  });
}

class FirmwareListingException implements Exception {
  final String message;
  const FirmwareListingException(this.message);
  @override
  String toString() => message;
}

class FirmwareListingService {
  /// Načte HTML listing z [baseUrl] a vrátí seřazený seznam P2L firmware souborů.
  ///
  /// Sort: sestupně podle `YYMMDDVV` (nejnovější nahoře). Pokud regex neuspěje,
  /// soubor se zařadí na konec se `sortKey = 0`.
  ///
  /// Hází [FirmwareListingException] s českou zprávou pro UI.
  static Future<List<FirmwareFile>> fetch(String baseUrl) async {
    final url = _normalizeBaseUrl(baseUrl);
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FirmwareListingException(
          'Neplatná URL — musí začínat http:// nebo https://');
    }

    final http.Response response;
    try {
      response = await http
          .get(uri, headers: {'Accept': 'text/html'})
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw const FirmwareListingException('Server neodpověděl (timeout 10 s).');
    } catch (e) {
      throw FirmwareListingException('Chyba spojení: $e');
    }

    if (response.statusCode != 200) {
      throw FirmwareListingException(
          'Server vrátil HTTP ${response.statusCode}.');
    }

    return parseHtml(response.body);
  }

  /// Parsuje HTML autoindex (Apache / nginx). Hledá `href="*.bin"` linky
  /// a doplní `YYMMDDVV` + typ z názvu souboru.
  ///
  /// Vystaveno jako veřejné kvůli testům.
  static List<FirmwareFile> parseHtml(String html) {
    // Zachytí "P2L_<8dig><type>.bin" v href. Předpoklad: konvence pojmenování
    // P2L firmware — pokud se v budoucnu změní, parser uvolnit.
    final hrefRe = RegExp(
      r'href="([^"]*P2L_(\d{8})([A-Za-z]+)\.bin)"',
      caseSensitive: false,
    );

    // Velikost souboru — Apache autoindex má za </a> kus textu se "1.3M" nebo "484K".
    // Najdu řádek obsahující href a vytáhnu velikost z téhož řádku.
    final lines = html.split('\n');
    final sizeRe = RegExp(r'>\s*(\d+(?:\.\d+)?[KMG]?)\s*<', caseSensitive: false);

    final seen = <String>{};
    final files = <FirmwareFile>[];

    for (final line in lines) {
      for (final m in hrefRe.allMatches(line)) {
        final href = m.group(1)!;
        final fileName = href.split('/').last;
        if (seen.contains(fileName)) continue;
        seen.add(fileName);

        final digits = m.group(2)!;
        final type = m.group(3)!.toUpperCase();
        final sortKey = int.tryParse(digits) ?? 0;
        final dateLabel = _formatDate(digits);
        final revisionLabel = digits.length >= 8 ? digits.substring(6, 8) : '';

        String? sizeLabel;
        final lineAfterHref = line.substring(m.end);
        final sm = sizeRe.firstMatch(lineAfterHref);
        if (sm != null) {
          final raw = sm.group(1)!;
          if (RegExp(r'\d').hasMatch(raw)) sizeLabel = raw;
        }

        files.add(FirmwareFile(
          name: fileName,
          typeTag: type,
          sortKey: sortKey,
          dateLabel: dateLabel,
          revisionLabel: revisionLabel,
          sizeLabel: sizeLabel,
        ));
      }
    }

    files.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    return files;
  }

  /// `YYMMDD` → `20YY-MM-DD`. Vrátí prázdný string pokud parser selže.
  static String _formatDate(String digits) {
    if (digits.length < 6) return '';
    final yy = digits.substring(0, 2);
    final mm = digits.substring(2, 4);
    final dd = digits.substring(4, 6);
    return '20$yy-$mm-$dd';
  }

  /// Odstraní trailing `/` (kromě root `/`), aby `{base}/{file}` nedělal `//`.
  static String _normalizeBaseUrl(String raw) {
    var u = raw.trim();
    while (u.endsWith('/') && u.length > 1 && !u.endsWith('://')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// Spojí base URL a název souboru.
  static String joinPath(String baseUrl, String fileName) {
    return '${_normalizeBaseUrl(baseUrl)}/$fileName';
  }
}
