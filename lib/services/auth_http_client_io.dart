// Native implementace (Windows, Android, iOS, macOS, Linux).
//
// Od DB1 (opt-in login na nativu, PRD-DB) obaluje standardní klient vrstvou,
// která ke každému requestu přidá `Authorization: Bearer <token>`, pokud je
// uživatel přihlášený. Token drží auth_token_store.dart (plní AuthSession).
// Bez tokenu se header neposílá — nepřihlášený stav = žádná auth data
// v requestech, přesně jako dřív.

import 'package:http/http.dart' as http;

import 'auth_token_store.dart';

/// Klient přidávající Bearer token z [currentAuthToken]. Veřejný kvůli
/// testům (v testech obaluje MockClient místo reálného klienta).
class BearerClient extends http.BaseClient {
  final http.Client _inner;
  BearerClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final token = currentAuthToken;
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

http.Client createAuthClient() => BearerClient(http.Client());
