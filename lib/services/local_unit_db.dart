// Lokální databáze jednotek — offline evidence v appce (DB10).
//
// Conditional export jako u mqtt_client_factory: nativ používá sqflite,
// web nic (běží na serveru, offline režim tam nemá smysl — PRD-DB/03 R5).
export 'local_unit_db_stub.dart'
    if (dart.library.io) 'local_unit_db_io.dart';
