// Hlavní entry point auth backendu.
// M4 = login + logout + me; M4.5 = admin endpointy pro správu uživatelů.
//
// Databáze se otevírá asynchronně (db/adapter.js, driver dle DB_DRIVER), proto
// je bootstrap v `main()`. HTTP listener se spouští AŽ po otevření DB a seedu:
// portable Windows appka pozná naběhnutí serveru přes /api/health, takže dřív
// otevřený port by hlásil „hotovo" nad ještě nepřipravenou databází.

require('dotenv').config();

const express = require('express');
const cookieParser = require('cookie-parser');
const cors = require('cors');
const rateLimit = require('express-rate-limit');

const { openDatabases } = require('./db');
const { resolveDriver, mariadbConfigFromEnv } = require('./db/adapter');
const { seedInitialAdmin } = require('./db/init');
const { dataDir, dataPath, ensureDataDir } = require('./db/paths');
const authRoutes = require('./routes/auth');
const adminRoutes = require('./routes/admin');
const firmwareRoutes = require('./routes/firmware');
const unitsRoutes = require('./routes/units');

const PORT = parseInt(process.env.PORT, 10) || 3001;

if (!process.env.JWT_SECRET || process.env.JWT_SECRET.length < 32) {
  console.error('FATAL: JWT_SECRET not set or shorter than 32 chars. Vygeneruj: node -e "console.log(require(\'crypto\').randomBytes(32).toString(\'hex\'))"');
  process.exit(1);
}

const PID_FILE = () => dataPath('server.pid');

// Kolik reverzních proxy stojí před serverem. Propisuje se do `req.ip`, podle
// kterého se počítá rate limit na /api/login — takže to není kosmetika:
// - moc nízká hodnota sloučí klienty do IP poslední proxy (jeden uživatel
//   s překlepy pak vyčerpá limit všem),
// - moc vysoká nechá klienta podvrhnout si IP hlavičkou X-Forwarded-For.
// Default 1 = jedna proxy s TLS. Po nasazení webové varianty jsou hopy dva
// (vnější proxy → nginx s Flutter buildem → api), proto compose posílá 2.
function trustProxyFromEnv() {
  const raw = (process.env.TRUST_PROXY || '').trim();
  if (raw === '') return 1;
  if (raw === 'false') return false;
  const n = parseInt(raw, 10);
  if (Number.isNaN(n) || n < 0) {
    console.error(`[warn] TRUST_PROXY='${raw}' není nezáporné číslo ani 'false' — používám 1`);
    return 1;
  }
  return n;
}

function buildApp(usersDb, unitsDb) {
  const app = express();
  const trustProxy = trustProxyFromEnv();
  app.set('trust proxy', trustProxy);
  console.log(`[proxy] trust proxy = ${trustProxy}`);

  app.use(express.json({ limit: '64kb' }));
  app.use(cookieParser());

  // CORS. Když frontend a API sdílí domenu (Nginx servíruje web i /api/*),
  // není potřeba nic. Řeší se, jen když je web jinde než server:
  // - `CORS_ORIGIN` — platí i v produkci; víc originů odděl čárkou.
  //   Tohle je cesta pro Flutter web build servírovaný zvlášť.
  // - `DEV_CORS_ORIGIN` — původní dev-only varianta, zachována.
  // Nativní klienti (EXE/APK) CORS neřeší, těch se to netýká.
  const corsOrigins = (process.env.CORS_ORIGIN || '')
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (corsOrigins.length > 0) {
    app.use(cors({ origin: corsOrigins, credentials: true }));
    console.log(`[cors] enabled for ${corsOrigins.join(', ')}`);
  } else if (process.env.NODE_ENV !== 'production' && process.env.DEV_CORS_ORIGIN) {
    app.use(
      cors({
        origin: process.env.DEV_CORS_ORIGIN,
        credentials: true,
      })
    );
    console.log(`[cors] Dev CORS enabled for ${process.env.DEV_CORS_ORIGIN}`);
  }

  // Rate limit: 50 pokusů / IP / 15 min na /api/login. Volnější práh než
  // striktních 5 z PRD §4 — v devu se 5 ukázalo jako neprakticky málo
  // (typo + zapomenuté heslo a zamknuto). 50/15min stále chrání proti
  // rychlému brute force (proti bcrypt-12 je to ~3.5 pokusů/s strop),
  // ale netrestá běžné chyby uživatele.
  const loginLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 50,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'too_many_attempts' },
  });
  app.use('/api/login', loginLimiter);

  // Health check PŘED routery — firmware router (mount na '/api') pouští svůj
  // requireAuth pro všechny /api/* requesty, které skrz něj protečou, takže
  // health registrovaný až za ním vracel 401 (pre-existing bug, fix v DB2).
  // `db` = jen typ driveru (žádné údaje o spojení). Appka podle něj pozná, že
  // adoptovala server běžící nad jinou databází, než má nastavenou — jinak by
  // se zápisy tiše ukládaly jinam, než uživatel čeká.
  app.get('/api/health', (req, res) => {
    res.json({ ok: true, ts: new Date().toISOString(), db: resolveDriver() });
  });

  app.use('/api', authRoutes.makeRouter(usersDb));
  app.use('/api/admin', adminRoutes.makeRouter(usersDb));
  app.use('/api/units', unitsRoutes.makeRouter(unitsDb));
  app.use('/api', firmwareRoutes.makeRouter());

  app.use((err, req, res, next) => {
    console.error('[error]', err);
    res.status(500).json({ error: 'internal' });
  });

  return app;
}

async function main() {
  ensureDataDir();
  console.log(`[data] ${dataDir()}`);

  const driver = resolveDriver();
  if (driver === 'mariadb') {
    const cfg = mariadbConfigFromEnv();
    console.log(`[db] mariadb ${cfg.user}@${cfg.host}:${cfg.port}/${cfg.database}`);
  } else {
    // Cesty jdou přes P2L_DATA_DIR (portable režim je má v %APPDATA%),
    // takže vypisujeme to, co se skutečně otevře.
    const { usersDbPath } = require('./db');
    const { unitsDbPath } = require('./db/units');
    console.log(`[db] sqlite ${usersDbPath()} + ${unitsDbPath()}`);
  }

  let dbs;
  try {
    dbs = await openDatabases();
  } catch (err) {
    // Typicky nedostupná MariaDB / špatné přihlašovací údaje. Bez čitelné
    // hlášky by uživatel viděl jen stack trace mysql2.
    console.error(`FATAL: databázi (${driver}) se nepodařilo otevřít: ${err.message}`);
    if (driver === 'mariadb') {
      console.error('Zkontroluj DB_HOST / DB_PORT / DB_USER / DB_PASSWORD / DB_NAME v .env a že server MariaDB běží.');
    }
    process.exit(1);
  }

  const seedResult = await seedInitialAdmin(dbs.usersDb);
  if (seedResult.seeded) {
    console.log(`[init] Initial admin '${seedResult.username}' created from env.`);
  } else {
    console.log(`[init] Skip initial admin seed: ${seedResult.reason}`);
  }

  const app = buildApp(dbs.usersDb, dbs.unitsDb);
  const server = app.listen(PORT, () => {
    console.log(`[start] P2L Tester auth backend listening on http://localhost:${PORT}`);
    writePidFile();
  });

  installShutdown(server, dbs);
}

// ─── PID file ────────────────────────────────────────────────────────
//
// Portable režim: Windows EXE si server spouští jako podproces a při zavření
// ho ukončí. Když ale appku někdo sestřelí (Task Manager, pád), graceful hook
// se nespustí a Node by tu zůstal jako sirotek. Proto si zapisujeme PID —
// appka ho při dalším startu najde a osiřelý proces uklidí.
//
// Zapisuje server (ne appka), protože jen on zná svůj skutečný PID; při
// spuštění přes wrapper by appka viděla PID wrapperu.

function writePidFile() {
  try {
    require('fs').writeFileSync(PID_FILE(), String(process.pid), 'utf8');
  } catch (err) {
    console.error('[pid] write failed:', err.message);
  }
}

function removePidFile() {
  try {
    require('fs').unlinkSync(PID_FILE());
  } catch {
    // neexistuje / už uklizeno — nic neřešíme
  }
}

function installShutdown(server, dbs) {
  let shuttingDown = false;

  async function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`[stop] ${signal} — ukončuji`);
    removePidFile();
    server.close(async () => {
      // Spojení do DB musí odejít taky, jinak MariaDB pool drží event loop
      // a proces by se sám neukončil.
      try {
        await dbs.close();
      } catch {
        // při ukončování už nemá cenu řešit
      }
      process.exit(0);
    });
    // Pojistka: kdyby se keep-alive spojení nezavřela, nečekáme věčně.
    setTimeout(() => process.exit(0), 2000).unref();
  }

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('exit', removePidFile);
}

main().catch((err) => {
  console.error('FATAL: start serveru selhal:', err);
  process.exit(1);
});
