// Login / logout / me endpointy. JWT v httpOnly cookie.
// V M4 ne-používáme refresh tokeny ani blacklist — JWT po 24h sám vyprší,
// rememberMe prodlouží expiraci na 7 dní.

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
      user: { username: user.username, isAdmin: !!user.is_admin },
    });
  });

  router.post('/logout', (req, res) => {
    res.clearCookie(SESSION_COOKIE, { path: '/' });
    res.json({ ok: true });
  });

  router.get('/me', (req, res) => {
    const token = req.cookies?.[SESSION_COOKIE];
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

module.exports = { makeRouter, SESSION_COOKIE };
