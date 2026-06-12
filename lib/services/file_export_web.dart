// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'file_export_types.dart';

/// Webová implementace — prohlížeč nemá nativní „Uložit jako" dialog, takže
/// soubor stáhneme přes dočasný blob + skrytý <a download>. Soubor spadne do
/// složky Stažené (SaveResult.path == null). `dialogTitle` se na webu nevyužije.
///
/// Řetězec předaný do Blob se zakóduje jako UTF-8.
Future<SaveResult> saveTextFile({
  required String fileName,
  required String content,
  String dialogTitle = 'Uložit soubor',
}) async {
  final blob = html.Blob(<Object>[content], 'application/json');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  return const SaveResult.saved();
}
