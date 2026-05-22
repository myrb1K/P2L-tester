// Admin endpointy (M4.5). Vše chráněné requireAdmin middleware:
// JWT musí být platné A mít claim isAdmin === true, jinak 403.
//
// Bezpečnostní guardy (společné s CLI v db/users.js):
// - createUser: 409 při duplikátu
// - deleteUser: 400 self-delete, 400 last-admin
// - resetPassword: 404 not_found

const express = require('express');
const jwt = require('jsonwebtoken');

const { SESSION_COOKIE } = require('./auth');
const {
  listUsers,
  createUser,
  deleteUser,
  resetPassword,
  UserOpError,
} = require('../db/users');

function requireAdmin(req, res, next) {
  const token = req.cookies?.[SESSION_COOKIE];
  if (!token) return res.status(401).json({ error: 'no_session' });

  try {
    const payload = jwt.verify(token, process.env.JWT_SECRET);
    if (!payload.isAdmin) {
      return res.status(403).json({ error: 'admin_required' });
    }
    req.user = { username: payload.sub, isAdmin: !!payload.isAdmin };
    next();
  } catch {
    return res.status(401).json({ error: 'invalid_session' });
  }
}

function mapErrorToStatus(err) {
  switch (err.code) {
    case 'duplicate':
      return 409;
    case 'not_found':
      return 404;
    case 'self_delete':
    case 'last_admin':
    case 'invalid_username':
    case 'invalid_password':
      return 400;
    default:
      return 500;
  }
}

function makeRouter(db) {
  const router = express.Router();
  router.use(requireAdmin);

  router.get('/users', (req, res) => {
    res.json({ users: listUsers(db) });
  });

  router.post('/users', (req, res) => {
    const { username, password, isAdmin } = req.body || {};
    try {
      const user = createUser(db, { username, password, isAdmin: !!isAdmin });
      res.status(201).json({
        user: {
          username: user.username,
          isAdmin: !!user.isAdmin,
        },
      });
    } catch (e) {
      if (e instanceof UserOpError) {
        return res.status(mapErrorToStatus(e)).json({ error: e.code, message: e.message });
      }
      throw e;
    }
  });

  router.delete('/users/:username', (req, res) => {
    try {
      deleteUser(db, req.params.username, { actingUser: req.user.username });
      res.status(204).end();
    } catch (e) {
      if (e instanceof UserOpError) {
        return res.status(mapErrorToStatus(e)).json({ error: e.code, message: e.message });
      }
      throw e;
    }
  });

  router.post('/users/:username/reset', (req, res) => {
    const { newPassword } = req.body || {};
    try {
      resetPassword(db, req.params.username, newPassword);
      res.json({ ok: true });
    } catch (e) {
      if (e instanceof UserOpError) {
        return res.status(mapErrorToStatus(e)).json({ error: e.code, message: e.message });
      }
      throw e;
    }
  });

  return router;
}

module.exports = { makeRouter, requireAdmin };
