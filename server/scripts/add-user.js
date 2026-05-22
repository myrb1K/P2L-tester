#!/usr/bin/env node
// Použití: node scripts/add-user.js <username> <password> [--admin]

const { openDb } = require('../db');
const { createUser, UserOpError } = require('../db/users');
const { die, parseArgs } = require('./_lib');

const { positional, flags } = parseArgs(process.argv.slice(2));
const [username, password] = positional;

if (!username || !password) {
  die('Použití: node scripts/add-user.js <username> <password> [--admin]');
}

try {
  createUser(openDb(), {
    username,
    password,
    isAdmin: flags.has('admin'),
  });
  console.log(
    `✓ Uživatel '${username}' vytvořen${flags.has('admin') ? ' jako admin' : ''}.`
  );
} catch (e) {
  if (e instanceof UserOpError) die(e.message);
  throw e;
}
