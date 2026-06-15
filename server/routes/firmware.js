// Proxy pro firmware autoindex listing.
//
// Web prohlížeč nemůže fetchnout autoindex firmware serveru přímo — server
// nemá CORS hlavičky (a při HTTPS frontendu by to navíc blokoval mixed-content).
// Backend HTML stáhne server-side a vrátí ho jako { html }. Flutter ho pak
// parsuje stejným parserem jako na native.
//
// Jen GET, jen http/https, za přihlášením (platná session).
// Pozn.: FLASH samotný proxy nepotřebuje — firmware si stahuje jednotka sama.

const express = require('express');
const jwt = require('jsonwebtoken');

const { SESSION_COOKIE } = require('./auth');

function requireAuth(req, res, next) {
  const token = req.cookies?.[SESSION_COOKIE];
  if (!token) return res.status(401).json({ error: 'no_session' });
  try {
    jwt.verify(token, process.env.JWT_SECRET);
    next();
  } catch {
    return res.status(401).json({ error: 'invalid_session' });
  }
}

function makeRouter() {
  const router = express.Router();
  router.use(requireAuth);

  router.get('/firmware-list', async (req, res) => {
    const url = req.query.url;
    if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) {
      return res.status(400).json({ error: 'invalid_url' });
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 10000);
    try {
      const upstream = await fetch(url, {
        headers: { Accept: 'text/html' },
        signal: controller.signal,
      });
      if (!upstream.ok) {
        return res
          .status(502)
          .json({ error: 'upstream_status', status: upstream.status });
      }
      const html = await upstream.text();
      res.json({ html });
    } catch (e) {
      if (e.name === 'AbortError') {
        return res.status(504).json({ error: 'timeout' });
      }
      return res.status(502).json({ error: 'fetch_failed', message: String(e) });
    } finally {
      clearTimeout(timer);
    }
  });

  return router;
}

module.exports = { makeRouter };
