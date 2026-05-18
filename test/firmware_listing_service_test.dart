import 'package:flutter_test/flutter_test.dart';
import 'package:p2l_tester/services/firmware_listing_service.dart';

void main() {
  group('FirmwareListingService.parseHtml — Apache autoindex', () {
    // Reálný snapshot z http://185.149.129.164/download/ (zkráceno).
    const apacheHtml = '''
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html><head><title>Index of /download</title></head><body>
<h1>Index of /download</h1>
<table>
<tr><td><a href="/">Parent Directory</a></td><td>&nbsp;</td><td>-</td></tr>
<tr><td><a href="P2L_24053101OT.bin">P2L_24053101OT.bin</a></td><td>2025-01-14 10:43</td><td align="right">482K</td></tr>
<tr><td><a href="P2L_25092501NT.bin">P2L_25092501NT.bin</a></td><td>2025-09-25 09:49</td><td align="right">1.2M</td></tr>
<tr><td><a href="P2L_26033101NT.bin">P2L_26033101NT.bin</a></td><td>2026-03-31 15:17</td><td align="right">1.3M</td></tr>
<tr><td><a href="P2L_24121101CT.bin">P2L_24121101CT.bin</a></td><td>2024-12-12 13:22</td><td align="right">1.3M</td></tr>
</table></body></html>
''';

    test('najde všechny .bin soubory napříč typy (NT/OT/CT)', () {
      final files = FirmwareListingService.parseHtml(apacheHtml);
      expect(files.length, 4);
      expect(files.map((f) => f.name).toSet(), {
        'P2L_24053101OT.bin',
        'P2L_25092501NT.bin',
        'P2L_26033101NT.bin',
        'P2L_24121101CT.bin',
      });
    });

    test('seřadí sestupně podle YYMMDDVV', () {
      final files = FirmwareListingService.parseHtml(apacheHtml);
      expect(files.first.name, 'P2L_26033101NT.bin');
      expect(files.last.name, 'P2L_24053101OT.bin');
    });

    test('parsuje typeTag, dateLabel, revisionLabel', () {
      final files = FirmwareListingService.parseHtml(apacheHtml);
      final latest = files.first;
      expect(latest.typeTag, 'NT');
      expect(latest.dateLabel, '2026-03-31');
      expect(latest.revisionLabel, '01');
      expect(latest.sortKey, 26033101);
    });

    test('parsuje velikost ze stejné řádky', () {
      final files = FirmwareListingService.parseHtml(apacheHtml);
      final byName = {for (final f in files) f.name: f};
      expect(byName['P2L_26033101NT.bin']!.sizeLabel, '1.3M');
      expect(byName['P2L_24053101OT.bin']!.sizeLabel, '482K');
    });

    test('ignoruje Parent Directory a další non-bin linky', () {
      final files = FirmwareListingService.parseHtml(apacheHtml);
      expect(files.any((f) => f.name.contains('Parent')), false);
    });

    test('duplikáty se neopakují (paranoidní whitelisting)', () {
      const dupHtml = '''
<a href="P2L_26033101NT.bin">x</a>
<a href="P2L_26033101NT.bin">x</a>
''';
      final files = FirmwareListingService.parseHtml(dupHtml);
      expect(files.length, 1);
    });

    test('chytí i jiné budoucí flagy než NT/OT/CT', () {
      const html = '<a href="P2L_26050101XT.bin">x</a>';
      final files = FirmwareListingService.parseHtml(html);
      expect(files.length, 1);
      expect(files.first.typeTag, 'XT');
    });

    test('prázdný HTML vrátí prázdný seznam', () {
      expect(FirmwareListingService.parseHtml('<html></html>'), isEmpty);
    });
  });

  group('FirmwareListingService.joinPath', () {
    test('spojí base bez trailing slash a name', () {
      expect(
        FirmwareListingService.joinPath(
          'http://185.149.129.164/download',
          'P2L_26033101NT.bin',
        ),
        'http://185.149.129.164/download/P2L_26033101NT.bin',
      );
    });

    test('strip trailing slash z base', () {
      expect(
        FirmwareListingService.joinPath(
          'http://example.com/fw/',
          'file.bin',
        ),
        'http://example.com/fw/file.bin',
      );
    });

    test('strip víc trailing slashů z base', () {
      expect(
        FirmwareListingService.joinPath('http://x//', 'a.bin'),
        'http://x/a.bin',
      );
    });
  });
}
