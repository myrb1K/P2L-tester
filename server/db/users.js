// Sdílené DB operace pro uživatele. Používají je jak admin endpointy
// (routes/admin.js), tak CLI skripty (scripts/*.js).

const bcrypt = require('bcrypt');
const { BCRYPT_ROUNDS } = require('./init');

/// Vyhozeno z guardů (last admin, self-delete, duplikát).
class UserOpError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function listUsers(db) {
  return db
    .prepare(
      'SELECT username, is_admin AS isAdmin, created_at AS createdAt FROM users ORDER BY is_admin DESC, username COLLATE NOCASE'
    )
    .all()
    .map((row) => ({
      username: row.username,
      isAdmin: !!row.isAdmin,
      createdAt: row.createdAt,
    }));
}

function getUser(db, username) {
  return db
    .prepare(
      'SELECT id, username, is_admin AS isAdmin FROM users WHERE username = ?'
    )
    .get(username);
}

function adminCount(db) {
  return db.prepare('SELECT COUNT(*) AS n FROM users WHERE is_admin = 1').get().n;
}

function createUser(db, { username, password, isAdmin }) {
  const u = (username || '').trim();
  if (!u) throw new UserOpError('invalid_username', 'Jméno nesmí být prázdné.');
  if (!password || password.length < 1) {
    throw new UserOpError('invalid_password', 'Heslo nesmí být prázdné.');
  }
  if (getUser(db, u)) {
    throw new UserOpError('duplicate', `Uživatel '${u}' už existuje.`);
  }
  const hash = bcrypt.hashSync(password, BCRYPT_ROUNDS);
  db.prepare(
    'INSERT INTO users (username, password_hash, is_admin) VALUES (?, ?, ?)'
  ).run(u, hash, isAdmin ? 1 : 0);
  return getUser(db, u);
}

function deleteUser(db, username, { actingUser = null } = {}) {
  const user = getUser(db, username);
  if (!user) {
    throw new UserOpError('not_found', `Uživatel '${username}' neexistuje.`);
  }
  if (actingUser && actingUser === user.username) {
    throw new UserOpError('self_delete', 'Nelze smazat svůj vlastní účet.');
  }
  if (user.isAdmin && adminCount(db) <= 1) {
    throw new UserOpError(
      'last_admin',
      `Nelze smazat posledního admina ('${user.username}'). Vytvoř jiného admina nejdřív.`
    );
  }
  db.prepare('DELETE FROM users WHERE id = ?').run(user.id);
}

function resetPassword(db, username, newPassword) {
  const user = getUser(db, username);
  if (!user) {
    throw new UserOpError('not_found', `Uživatel '${username}' neexistuje.`);
  }
  if (!newPassword || newPassword.length < 1) {
    throw new UserOpError('invalid_password', 'Heslo nesmí být prázdné.');
  }
  const hash = bcrypt.hashSync(newPassword, BCRYPT_ROUNDS);
  db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(hash, user.id);
}

module.exports = {
  UserOpError,
  listUsers,
  getUser,
  adminCount,
  createUser,
  deleteUser,
  resetPassword,
};
