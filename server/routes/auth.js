// Login / logout / me endpointy. JWT v httpOnly cookie.
// V M4 ne-používáme refresh tokeny ani blacklist — JWT po 24h sám vyprší,
// rememberMe prodlouží expiraci na 7 dní.
//
// DB1 (PRD-DB): nativní klienti (EXE/APK) cookies nedrží — login proto vrací
// token i v response body a všechny chráněné endpointy přijímají
// `Authorization: Bearer <JWT>` jako alternativu k cookie (viz tokenFromReq).
// Web se nemění: cookie má přednost, token v body prohlížeč ignoruje.

const express = require('express');
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');

const SESSION_COOKIE = 'p2l_session';
const TOKEN_TTL_DEFAULT = 60 * 60 * 24;       // 24 h
const TOKEN_TTL_REMEMBER = 60 * 60 * 24 * 7;  // 7 dní

function cookieOptions(maxAgeSec) {
  return {
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
    sameSite: 'lax',
    path: '/',
    maxAge: maxAgeSec * 1000,
  };
}

function signToken(user, ttlSec) {
  return jwt.sign(
    { sub: user.username, isAdmin: !!user.is_admin },
    process.env.JWT_SECRET,
    { expiresIn: ttlSec }
  );
}

// Middleware: vyžaduje platnou session (cookie nebo Bearer) a naplní
// req.user = { username, isAdmin }. Sdílené pro firmware a units routes;
// admin.js má vlastní requireAdmin (navíc kontroluje isAdmin claim).
function requireAuth(req, res, next) {
  const token = tokenFromReq(req);
  if (!token) return res.status(401).json({ error: 'no_session' });
  try {
    const payload = jwt.verify(token, process.env.JWT_SECRET);
    req.user = { username: payload.sub, isAdmin: !!payload.isAdmin };
    next();
  } catch {
    return res.status(401).json({ error: 'invalid_session' });
  }
}

// Vytáhne JWT z requestu: session cookie (web) nebo Authorization: Bearer
// header (nativní klienti). Cookie má přednost — prohlížeč Bearer neposílá,
// takže kolize nehrozí.
function tokenFromReq(req) {
  const cookieToken = req.cookies?.[SESSION_COOKIE];
  if (cookieToken) return cookieToken;
  const header = req.get('authorization') || '';
  if (header.startsWith('Bearer ')) {
    const t = header.slice('Bearer '.length).trim();
    if (t) return t;
  }
  return null;
}

function makeRouter(db) {
  const router = express.Router();

  router.post('/login', (req, res) => {
    const { username, password, rememberMe } = req.body || {};
    if (typeof username !== 'string' || typeof password !== 'string') {
      return res.status(400).json({ error: 'invalid_body' });
    }

    const user = db
      .prepare('SELECT id, username, password_hash, is_admin FROM users WHERE username = ?')
      .get(username.trim());

    // Konstantní čas: i když user neexistuje, projedeme bcrypt.compare proti
    // dummy hashi, aby útočník nepoznal, jestli username existuje.
    const dummyHash = '$2b$12$0000000000000000000000.0000000000000000000000000000000';
    const ok = user
      ? bcrypt.compareSync(password, user.password_hash)
      : (bcrypt.compareSync(password, dummyHash), false);

    if (!user || !ok) {
      return res.status(401).json({ error: 'invalid_credentials' });
    }

    const ttl = rememberMe ? TOKEN_TTL_REMEMBER : TOKEN_TTL_DEFAULT;
    const token = signToken(user, ttl);
    res.cookie(SESSION_COOKIE, token, cookieOptions(ttl));
    res.json({
      ok: true,
      // token v body pro nativní klienty (DB1) — web ho ignoruje, cookie stačí
      token,
      user: { username: user.username, isAdmin: !!user.is_admin },
    });
  });

  router.post('/logout', (req, res) => {
    res.clearCookie(SESSION_COOKIE, { path: '/' });
    res.json({ ok: true });
  });

  router.get('/me', (req, res) => {
    const token = tokenFromReq(req);
    if (!token) return res.status(401).json({ error: 'no_session' });

    try {
      const payload = jwt.verify(token, process.env.JWT_SECRET);
      res.json({
        user: { username: payload.sub, isAdmin: !!payload.isAdmin },
      });
    } catch (err) {
      res.clearCookie(SESSION_COOKIE, { path: '/' });
      res.status(401).json({ error: 'invalid_session' });
    }
  });

  return router;
}

module.exports = { makeRouter, SESSION_COOKIE, tokenFromReq, requireAuth };
