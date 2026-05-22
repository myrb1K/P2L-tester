// Hlavní entry point auth backendu.
// M4 = login + logout + me; M4.5 = admin endpointy pro správu uživatelů.

require('dotenv').config();

const express = require('express');
const cookieParser = require('cookie-parser');
const cors = require('cors');
const rateLimit = require('express-rate-limit');

const { openDb } = require('./db');
const { seedInitialAdmin } = require('./db/init');
const authRoutes = require('./routes/auth');
const adminRoutes = require('./routes/admin');

const PORT = parseInt(process.env.PORT, 10) || 3001;

if (!process.env.JWT_SECRET || process.env.JWT_SECRET.length < 32) {
  console.error('FATAL: JWT_SECRET not set or shorter than 32 chars. Vygeneruj: node -e "console.log(require(\'crypto\').randomBytes(32).toString(\'hex\'))"');
  process.exit(1);
}

const db = openDb();
const seedResult = seedInitialAdmin(db);
if (seedResult.seeded) {
  console.log(`[init] Initial admin '${seedResult.username}' created from env.`);
} else {
  console.log(`[init] Skip initial admin seed: ${seedResult.reason}`);
}

const app = express();
app.set('trust proxy', 1); // pro správné req.ip za Nginxem

app.use(express.json({ limit: '64kb' }));
app.use(cookieParser());

// CORS: v devu povolíme Flutter dev server, v produkci je vše same-origin
// (Nginx servíruje frontend i /api/* z jedné domény) a CORS odpadá.
if (process.env.NODE_ENV !== 'production' && process.env.DEV_CORS_ORIGIN) {
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

app.use('/api', authRoutes.makeRouter(db));
app.use('/api/admin', adminRoutes.makeRouter(db));

app.get('/api/health', (req, res) => {
  res.json({ ok: true, ts: new Date().toISOString() });
});

app.use((err, req, res, next) => {
  console.error('[error]', err);
  res.status(500).json({ error: 'internal' });
});

app.listen(PORT, () => {
  console.log(`[start] P2L Tester auth backend listening on http://localhost:${PORT}`);
});
