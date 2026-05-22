// Native implementace (Windows, Android, iOS, macOS, Linux).
// Auth se na nativu v M4 nepoužívá (login je jen pro web), ale klient
// musí existovat, aby se kód zkompiloval. Vrací standardní http.Client.

import 'package:http/http.dart' as http;

http.Client createAuthClient() => http.Client();
