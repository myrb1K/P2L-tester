// Entry point pro vytvoření HTTP klienta pro auth API.
// Na webu používáme BrowserClient s withCredentials=true (aby browser
// posílal session cookie i v cross-origin requestech proti dev backendu
// na jiném portu). Na nativu vrátíme klasický http.Client().
//
// V produkci je všechno same-origin (Nginx servíruje frontend i /api/*
// z jedné domény) a withCredentials je no-op.

export 'auth_http_client_io.dart'
    if (dart.library.html) 'auth_http_client_web.dart';
