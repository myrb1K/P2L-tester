import 'file_export_types.dart';

/// Fallback — platforma bez `dart:io` i `dart:html`.
Future<SaveResult> saveTextFile({
  required String fileName,
  required String content,
  String dialogTitle = 'Uložit soubor',
}) async {
  throw UnsupportedError('Ukládání souborů není na této platformě podporováno.');
}
