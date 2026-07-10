// Globální bearer token pro nativní auth HTTP klient
// (auth_http_client_io.dart přidává `Authorization: Bearer <token>`).
//
// Na webu se nepoužívá — session tam drží httpOnly cookie v prohlížeči.
// Zapisuje ho výhradně AuthSession (login / restore / logout). Samostatný
// soubor kvůli importním cyklům: čte ho auth_http_client_io (pod AuthApi),
// plní ho auth_session (nad AuthApi).

String? currentAuthToken;
