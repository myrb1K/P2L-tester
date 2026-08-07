// Tenká asynchronní vrstva nad databází — jedna logika, dva drivery.
//
// Proč vůbec existuje: server původně jel na better-sqlite3, který je
// SYNCHRONNÍ (`stmt.get()` vrátí řádek přímo). MariaDB klient synchronní být
// nemůže, takže celá datová vrstva i routes jsou async. Adapter tenhle rozdíl
// izoluje: `db/units.js` a `db/users.js` píšou jeden SQL a jeden algoritmus,
// tady se řeší jen dialekt a mechanika spojení.
//
// Volba driveru: env `DB_DRIVER` = `sqlite` (default) | `mariadb`.
//   - sqlite  — soubory v data/, žádná instalace; portable Windows dist
//   - mariadb — firemní server (databáze `P2Lunits`), viz .env.example
//
// API handle:
//   dialect                       'sqlite' | 'mariadb'
//   get(sql, params)   -> row | undefined
//   all(sql, params)   -> row[]
//   run(sql, params)   -> { changes, lastInsertId }
//   exec(sqlScript)    -> void            (víc statementů, DDL — bez parametrů)
//   columns(table)     -> Set<string>     (introspekce pro mini-migrace)
//   transaction(fn)    -> await fn(tx)    (tx má stejné API; commit/rollback)
//   close()
//   sql                             dialektové fragmenty (viz DIALECTS)
//
// Parametry se píšou pojmenovaně (`:name` + objekt) — rozumí jim better-sqlite3
// i mysql2 (`namedPlaceholders`). Pozicové `?` + pole fungují také.
//
// DŮLEŽITÉ — transakce: dotazy uvnitř `transaction(fn)` MUSÍ jít přes `tx`,
// který dostane callback, ne přes vnější handle. U MariaDB proto, že transakce
// drží jedno spojení z poolu; u SQLite proto, že vnější handle je serializovaný
// mutexem (viz níže) a rekurzivní vstup by zablokoval sám sebe.

'use strict';

const fs = require('fs');
const path = require('path');

// ── Dialektové rozdíly ─────────────────────────────────────────────────────
// Jen to, co se nedá napsat společně. Časové značky společné jsou: ukládáme je
// jako ISO 8601 string generovaný v JS (nowIso), takže žádné `datetime('now')`
// vs `UTC_TIMESTAMP()` v SQL neřešíme.

const DIALECTS = {
  sqlite: {
    name: 'sqlite',
    castInt: (expr) => `CAST(${expr} AS INTEGER)`,
    // SQLite je case-sensitive by default, MariaDB má ci collation ve schématu.
    collateNoCase: ' COLLATE NOCASE',
    onConflictDoNothing: (pk) => `ON CONFLICT(${pk}) DO NOTHING`,
    onConflictUpdate: (pk, cols) =>
      `ON CONFLICT(${pk}) DO UPDATE SET ${cols.map((c) => `${c} = excluded.${c}`).join(', ')}`,
  },
  mariadb: {
    name: 'mariadb',
    castInt: (expr) => `CAST(${expr} AS UNSIGNED)`,
    collateNoCase: '',
    // MariaDB nezná DO NOTHING; přiřazení PK sobě samému je no-op update.
    onConflictDoNothing: (pk) => `ON DUPLICATE KEY UPDATE ${pk} = ${pk}`,
    onConflictUpdate: (pk, cols) =>
      `ON DUPLICATE KEY UPDATE ${cols.map((c) => `${c} = VALUES(${c})`).join(', ')}`,
  },
};

/// Časová značka pro DB — jeden formát pro oba drivery (ISO 8601 UTC).
function nowIso() {
  return new Date().toISOString();
}

/// Který driver se má použít. `override` má přednost před env (testy).
function resolveDriver(override) {
  const raw = (override || process.env.DB_DRIVER || 'sqlite').trim().toLowerCase();
  if (raw !== 'sqlite' && raw !== 'mariadb') {
    throw new Error(`Neznámý DB_DRIVER '${raw}' (povolené: sqlite, mariadb)`);
  }
  return raw;
}

/// Rozdělí SQL skript na jednotlivé statementy. MariaDB `execute()` bere jen
/// jeden příkaz a `multipleStatements` zapínat nechceme (rozšiřuje dopad
/// případné injection). Schémata jsou naše, syntax jednoduchá: odstraníme
/// `--` komentáře a rozdělíme na `;`.
// POZOR na `\r`: v JS `.` nematchuje řádkové terminátory a `$` bez `m` sedí až
// na konec stringu, takže na CRLF řádku (`-- text\r`) by `/--.*$/` neodpovídalo
// vůbec a komentář by v SQL zůstal. Windows checkout má CRLF, takže se to týká
// každého schématu — proto se řádky dělí `\r?\n`, ne `\n`. (Než se to opravilo,
// stačil jeden komentář se středníkem a schéma se rozsekalo na půli věty.)
function splitStatements(script) {
  return script
    .split(/\r?\n/)
    .map((line) => line.replace(/--.*$/, ''))
    .join('\n')
    .split(';')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/// Načte schéma pro daný dialekt: `units-schema.sql` (sqlite) vs
/// `units-schema.mariadb.sql`. Sqlite si drží původní název, aby zůstal
/// kompatibilní s existujícími DB soubory.
function schemaPathFor(baseName, dialect) {
  const dir = __dirname;
  return dialect === 'mariadb'
    ? path.join(dir, `${baseName}.mariadb.sql`)
    : path.join(dir, `${baseName}.sql`);
}

// ── SQLite ─────────────────────────────────────────────────────────────────
//
// better-sqlite3 je synchronní, takže jednotlivé dotazy se „prolnout" nemohou.
// Prolnout se ale může transakce: mezi BEGIN a COMMIT je v našem async kódu
// `await`, během kterého by Node obsloužil jiný request a jeho zápis by spadl
// do cizí transakce (a při rollbacku zmizel). Proto všechny operace na handle
// procházejí frontou (mutex) — u synchronního driveru je to zanedbatelná režie.

function makeQueue() {
  let tail = Promise.resolve();
  return function enqueue(fn) {
    const run = tail.then(fn, fn);
    // Chyba nesmí zaseknout frontu — spolkneme ji jen pro účel řetězení.
    tail = run.then(
      () => undefined,
      () => undefined
    );
    return run;
  };
}

function openSqlite({ file, schemas }) {
  const Database = require('better-sqlite3');

  if (file !== ':memory:') {
    const dir = path.dirname(file);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  }

  const db = new Database(file);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  for (const schemaFile of schemas) {
    db.exec(fs.readFileSync(schemaFile, 'utf8'));
  }

  const stmtCache = new Map();
  function prepare(sql) {
    let stmt = stmtCache.get(sql);
    if (!stmt) {
      stmt = db.prepare(sql);
      stmtCache.set(sql, stmt);
    }
    return stmt;
  }

  // better-sqlite3 odmítne parametry, které v SQL nejsou — prázdný objekt na
  // dotazu bez placeholderů tedy nesmíme předat.
  function bindArgs(params) {
    if (params == null) return [];
    if (Array.isArray(params)) return params.length ? [params] : [];
    return Object.keys(params).length ? [params] : [];
  }

  const raw = {
    dialect: 'sqlite',
    sql: DIALECTS.sqlite,
    async get(sql, params) {
      return prepare(sql).get(...bindArgs(params));
    },
    async all(sql, params) {
      return prepare(sql).all(...bindArgs(params));
    },
    async run(sql, params) {
      const info = prepare(sql).run(...bindArgs(params));
      return { changes: info.changes, lastInsertId: Number(info.lastInsertRowid) };
    },
    async exec(script) {
      db.exec(script);
    },
    async columns(table) {
      return new Set(db.pragma(`table_info(${table})`).map((c) => c.name));
    },
    // Vnořená transakce = pokračuj ve stávající (savepointy neřešíme).
    async transaction(fn) {
      return fn(raw);
    },
  };

  const enqueue = makeQueue();

  return {
    dialect: 'sqlite',
    sql: DIALECTS.sqlite,
    get: (sql, params) => enqueue(() => raw.get(sql, params)),
    all: (sql, params) => enqueue(() => raw.all(sql, params)),
    run: (sql, params) => enqueue(() => raw.run(sql, params)),
    exec: (script) => enqueue(() => raw.exec(script)),
    columns: (table) => enqueue(() => raw.columns(table)),
    transaction: (fn) =>
      enqueue(async () => {
        db.exec('BEGIN');
        try {
          const result = await fn(raw);
          db.exec('COMMIT');
          return result;
        } catch (err) {
          try {
            db.exec('ROLLBACK');
          } catch {
            // transakce už mohla být ukončena — původní chyba je důležitější
          }
          throw err;
        }
      }),
    async close() {
      stmtCache.clear();
      db.close();
    },
  };
}

// ── MariaDB ────────────────────────────────────────────────────────────────

function mariadbConfigFromEnv(overrides = {}) {
  const num = (v, d) => {
    const n = parseInt(v, 10);
    return Number.isFinite(n) ? n : d;
  };
  return {
    host: process.env.DB_HOST || '127.0.0.1',
    port: num(process.env.DB_PORT, 3306),
    user: process.env.DB_USER || 'root',
    password: process.env.DB_PASSWORD || '',
    database: process.env.DB_NAME || 'P2Lunits',
    connectionLimit: num(process.env.DB_CONNECTION_LIMIT, 10),
    ...overrides,
  };
}

async function openMariadb({ schemas, config }) {
  const mysql = require('mysql2/promise');

  const pool = mysql.createPool({
    ...mariadbConfigFromEnv(config),
    // `:name` placeholdery (viz hlavička) — stejná syntax jako better-sqlite3.
    namedPlaceholders: true,
    charset: 'utf8mb4',
    // Časy držíme jako ISO string ve VARCHARu, takže konverze DATE→JS Date
    // (a s ní časové zóny) nás nikde netrápí. dateStrings je pojistka.
    dateStrings: true,
    waitForConnections: true,
    multipleStatements: false,
  });

  // Ověří spojení hned při startu — server má spadnout s jasnou chybou,
  // ne až u prvního requestu.
  const probe = await pool.getConnection();
  probe.release();

  for (const schemaFile of schemas) {
    for (const stmt of splitStatements(fs.readFileSync(schemaFile, 'utf8'))) {
      await pool.query(stmt);
    }
  }

  // `executor` je pool (autocommit, spojení per dotaz) nebo konkrétní
  // connection (uvnitř transakce).
  function handleFor(executor, isTx) {
    const h = {
      dialect: 'mariadb',
      sql: DIALECTS.mariadb,
      async get(sql, params) {
        const [rows] = await executor.execute(sql, params ?? []);
        return rows[0];
      },
      async all(sql, params) {
        const [rows] = await executor.execute(sql, params ?? []);
        return rows;
      },
      async run(sql, params) {
        const [result] = await executor.execute(sql, params ?? []);
        return { changes: result.affectedRows, lastInsertId: result.insertId };
      },
      async exec(script) {
        for (const stmt of splitStatements(script)) await executor.query(stmt);
      },
      async columns(table) {
        const [rows] = await executor.execute(
          `SELECT COLUMN_NAME AS name FROM information_schema.COLUMNS
           WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = :table`,
          { table }
        );
        return new Set(rows.map((r) => r.name));
      },
      async transaction(fn) {
        if (isTx) return fn(h); // vnořená → pokračuj ve stávající
        const conn = await pool.getConnection();
        try {
          await conn.beginTransaction();
          try {
            const result = await fn(handleFor(conn, true));
            await conn.commit();
            return result;
          } catch (err) {
            await conn.rollback();
            throw err;
          }
        } finally {
          conn.release();
        }
      },
      async close() {
        await pool.end();
      },
    };
    return h;
  }

  return handleFor(pool, false);
}

// ── Veřejné API ────────────────────────────────────────────────────────────

/// Otevře databázi podle konfigurace.
///
/// - `schemas` — seznam základních názvů schémat (`'schema'`, `'units-schema'`);
///   dialekt si dohledá správný soubor.
/// - `sqliteFile` — cesta k SQLite souboru (`:memory:` v testech). U MariaDB
///   se ignoruje.
/// - `driver` / `config` — override pro testy; jinak se bere z env.
async function openAdapter({ schemas, sqliteFile, driver, config } = {}) {
  const dialect = resolveDriver(driver);
  const schemaFiles = (schemas || []).map((base) => schemaPathFor(base, dialect));
  if (dialect === 'mariadb') {
    return openMariadb({ schemas: schemaFiles, config });
  }
  return openSqlite({ file: sqliteFile, schemas: schemaFiles });
}

module.exports = {
  openAdapter,
  resolveDriver,
  mariadbConfigFromEnv,
  splitStatements,
  schemaPathFor,
  nowIso,
  DIALECTS,
};
