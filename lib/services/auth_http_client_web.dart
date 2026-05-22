// Web implementace.
// BrowserClient s withCredentials=true zajistí, že browser posílá
// session cookie i v cross-origin requestech (lokální dev: Flutter
// na :8080 → backend na :3001). V produkci je vše same-origin
// a withCredentials nemá co posílat navíc.

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

http.Client createAuthClient() => BrowserClient()..withCredentials = true;
