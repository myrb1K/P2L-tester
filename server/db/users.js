// Sdílené DB operace pro uživatele. Používají je jak admin endpointy
// (routes/admin.js), tak CLI skripty (scripts/*.js).
//
// Asynchronní nad db/adapter.js (SQLite i MariaDB — viz tam). Case-insensitive
// jména uživatelů řeší collation sloupce: COLLATE NOCASE v SQLite,
// utf8mb4_unicode_ci v MariaDB.

const bcrypt = require('bcrypt');
const { BCRYPT_ROUNDS } = require('./init');
const { nowIso } = require('./adapter');

/// Vyhozeno z guardů (last admin, self-delete, duplikát).
class UserOpError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

async function listUsers(db) {
  const rows = await db.all(
    `SELECT username, is_admin AS isAdmin, created_at AS createdAt FROM users
     ORDER BY is_admin DESC, username${db.sql.collateNoCase}`
  );
  return rows.map((row) => ({
    username: row.username,
    isAdmin: !!row.isAdmin,
    createdAt: row.createdAt,
  }));
}

async function getUser(db, username) {
  return db.get(
    'SELECT id, username, is_admin AS isAdmin FROM users WHERE username = :username',
    { username }
  );
}

async function adminCount(db) {
  const row = await db.get('SELECT COUNT(*) AS n FROM users WHERE is_admin = 1');
  return row.n;
}

async function createUser(db, { username, password, isAdmin }) {
  const u = (username || '').trim();
  if (!u) throw new UserOpError('invalid_username', 'Jméno nesmí být prázdné.');
  if (!password || password.length < 1) {
    throw new UserOpError('invalid_password', 'Heslo nesmí být prázdné.');
  }
  if (await getUser(db, u)) {
    throw new UserOpError('duplicate', `Uživatel '${u}' už existuje.`);
  }
  const hash = bcrypt.hashSync(password, BCRYPT_ROUNDS);
  await db.run(
    `INSERT INTO users (username, password_hash, is_admin, created_at)
     VALUES (:username, :password_hash, :is_admin, :created_at)`,
    { username: u, password_hash: hash, is_admin: isAdmin ? 1 : 0, created_at: nowIso() }
  );
  return getUser(db, u);
}

async function deleteUser(db, username, { actingUser = null } = {}) {
  const user = await getUser(db, username);
  if (!user) {
    throw new UserOpError('not_found', `Uživatel '${username}' neexistuje.`);
  }
  if (actingUser && actingUser === user.username) {
    throw new UserOpError('self_delete', 'Nelze smazat svůj vlastní účet.');
  }
  if (user.isAdmin && (await adminCount(db)) <= 1) {
    throw new UserOpError(
      'last_admin',
      `Nelze smazat posledního admina ('${user.username}'). Vytvoř jiného admina nejdřív.`
    );
  }
  await db.run('DELETE FROM users WHERE id = :id', { id: user.id });
}

async function resetPassword(db, username, newPassword) {
  const user = await getUser(db, username);
  if (!user) {
    throw new UserOpError('not_found', `Uživatel '${username}' neexistuje.`);
  }
  if (!newPassword || newPassword.length < 1) {
    throw new UserOpError('invalid_password', 'Heslo nesmí být prázdné.');
  }
  const hash = bcrypt.hashSync(newPassword, BCRYPT_ROUNDS);
  await db.run('UPDATE users SET password_hash = :hash WHERE id = :id', {
    hash,
    id: user.id,
  });
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
