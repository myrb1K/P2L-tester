#!/usr/bin/env node
// Použití: node scripts/del-user.js <username>
//
// Last-admin guard je sdílený s admin endpointy v db/users.js.

const { openDb } = require('../db');
const { deleteUser, UserOpError } = require('../db/users');
const { die, parseArgs } = require('./_lib');

const { positional } = parseArgs(process.argv.slice(2));
const [username] = positional;

if (!username) die('Použití: node scripts/del-user.js <username>');

try {
  deleteUser(openDb(), username);
  console.log(`✓ Uživatel '${username}' smazán.`);
} catch (e) {
  if (e instanceof UserOpError) die(e.message);
  throw e;
}
