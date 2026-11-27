import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, randomInt } from 'node:crypto';
import { closeSync, constants, fchmodSync, mkdirSync, openSync } from 'node:fs';
import { dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

export const PAIRING_SECONDS = 600;
export const STATE_SECONDS = 600;
const BROWSER_SECONDS = 600;
const CODE_ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

export const randomToken = () => randomBytes(32).toString('base64url');
export const digest = value => createHash('sha256').update(value).digest('hex');

export class Store {
  constructor(filename, key) {
    // SQLite, its journal, and backups should stay on a private persistent volume.
    mkdirSync(dirname(filename), { recursive: true, mode: 0o700 });
    const file = openSync(filename, constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW, 0o600);
    try { fchmodSync(file, 0o600); } finally { closeSync(file); }
    this.db = new DatabaseSync(filename);
    this.key = key;
    this.db.exec(`
      PRAGMA foreign_keys = ON;
      PRAGMA journal_mode = WAL;
      PRAGMA busy_timeout = 5000;
      PRAGMA secure_delete = ON;
      CREATE TABLE IF NOT EXISTS connections (
        key TEXT PRIMARY KEY,
        credentials BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS pairings (
        id TEXT PRIMARY KEY,
        poll_key TEXT NOT NULL,
        code_key TEXT NOT NULL UNIQUE,
        expires INTEGER NOT NULL,
        active_state TEXT,
        connection_key TEXT UNIQUE REFERENCES connections(key) ON DELETE CASCADE,
        delivery BLOB,
        claimed INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS pairing_expiry ON pairings(expires);
      CREATE TABLE IF NOT EXISTS states (
        key TEXT PRIMARY KEY,
        pairing_id TEXT NOT NULL REFERENCES pairings(id) ON DELETE CASCADE,
        browser_key TEXT NOT NULL,
        verifier BLOB NOT NULL,
        expires INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS browsers (
        key TEXT PRIMARY KEY,
        pairing_id TEXT NOT NULL REFERENCES pairings(id) ON DELETE CASCADE,
        credentials BLOB NOT NULL,
        expires INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS files (
        connection_key TEXT NOT NULL REFERENCES connections(key) ON DELETE CASCADE,
        file_id TEXT NOT NULL,
        name TEXT NOT NULL,
        size INTEGER NOT NULL,
        mime_type TEXT NOT NULL,
        parent_id TEXT,
        resource_key BLOB,
        PRIMARY KEY (connection_key, file_id)
      );
    `);
  }

  close() {
    this.db.close();
  }

  transaction(work) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const result = work();
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  seal(purpose, value) {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    cipher.setAAD(Buffer.from(purpose));
    const data = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), data]);
  }

  open(purpose, value) {
    const decipher = createDecipheriv('aes-256-gcm', this.key, value.subarray(0, 12));
    decipher.setAAD(Buffer.from(purpose));
    decipher.setAuthTag(value.subarray(12, 28));
    return JSON.parse(Buffer.concat([decipher.update(value.subarray(28)), decipher.final()]));
  }

  codeFingerprint(code) {
    return createHmac('sha256', this.key).update('pairing-code\0').update(code).digest('hex');
  }

  sweep(now) {
    return this.transaction(() => {
      // Approved links whose TV never polled are abandoned when the pairing expires.
      const abandoned = this.db.prepare(
        'SELECT connection_key FROM pairings WHERE expires <= ? AND connection_key IS NOT NULL AND claimed = 0',
      ).all(now).map(row => row.connection_key);
      for (const key of abandoned) this.db.prepare('DELETE FROM connections WHERE key = ?').run(key);
      this.db.prepare('DELETE FROM pairings WHERE expires <= ?').run(now);
      this.db.prepare('DELETE FROM states WHERE expires <= ?').run(now);
      this.db.prepare('DELETE FROM browsers WHERE expires <= ?').run(now);
      return abandoned;
    });
  }

  pair(now) {
    const id = randomBytes(18).toString('base64url');
    const secret = randomToken();
    for (let attempt = 0; attempt < 5; attempt++) {
      const code = Array.from({ length: 8 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('');
      const result = this.db.prepare(
        'INSERT INTO pairings (id, poll_key, code_key, expires) VALUES (?, ?, ?, ?) ON CONFLICT(code_key) DO NOTHING',
      ).run(id, digest(secret), this.codeFingerprint(code), now + PAIRING_SECONDS);
      if (result.changes) return { id, secret, code };
    }
    throw new Error('Pairing code generation exhausted');
  }

  poll(id, secret, now) {
    return this.transaction(() => {
      const row = this.db.prepare(
        'SELECT * FROM pairings WHERE id = ? AND poll_key = ?',
      ).get(id, digest(secret));
      if (!row) return { status: 404 };
      if (row.expires <= now) return { status: 410 };
      if (!row.connection_key) return { status: 200, body: { status: 'pending' } };
      const token = this.open('delivery:' + id, row.delivery);
      if (!row.claimed) this.db.prepare('UPDATE pairings SET claimed = 1 WHERE id = ?').run(id);
      const files = this.catalog(row.connection_key);
      return { status: 200, body: { status: 'approved', connection: { token, files } } };
    });
  }

  cancel(id, secret, now) {
    return this.transaction(() => {
      const row = this.db.prepare('SELECT * FROM pairings WHERE id = ? AND poll_key = ?').get(id, digest(secret));
      if (!row) return { status: 404 };
      if (row.expires <= now) return { status: 410 };
      if (row.connection_key) this.deleteConnection(row.connection_key);
      else this.db.prepare('DELETE FROM pairings WHERE id = ?').run(id);
      return { status: 204, revoked: row.connection_key };
    });
  }

  startOAuth(code, now) {
    return this.transaction(() => {
      const pair = this.db.prepare(
        'SELECT id, expires FROM pairings WHERE code_key = ? AND expires > ? AND connection_key IS NULL',
      ).get(this.codeFingerprint(code), now);
      if (!pair) return;
      const state = randomToken();
      const stateKey = digest(state);
      const browser = randomToken();
      const verifier = randomToken();
      this.db.prepare('DELETE FROM states WHERE pairing_id = ?').run(pair.id);
      this.db.prepare('DELETE FROM browsers WHERE pairing_id = ?').run(pair.id);
      this.db.prepare('UPDATE pairings SET active_state = ? WHERE id = ?').run(stateKey, pair.id);
      this.db.prepare('INSERT INTO states VALUES (?, ?, ?, ?, ?)').run(
        stateKey, pair.id, digest(browser), this.seal('state:' + stateKey, verifier),
        Math.min(pair.expires, now + STATE_SECONDS),
      );
      return { state, browser, verifier };
    });
  }

  consumeOAuth(state, browser, now) {
    return this.transaction(() => {
      const key = digest(state);
      const row = this.db.prepare(`
        SELECT s.* FROM states AS s JOIN pairings AS p ON p.id = s.pairing_id
        WHERE s.key = ? AND s.browser_key = ? AND s.expires > ? AND p.expires > ?
          AND p.connection_key IS NULL AND p.active_state = s.key
      `).get(key, digest(browser), now, now);
      if (!row) return;
      this.db.prepare('DELETE FROM states WHERE key = ?').run(key);
      return { pairingId: row.pairing_id, stateKey: key, verifier: this.open('state:' + key, row.verifier) };
    });
  }

  stage({ pairingId, stateKey }, credentials, now) {
    return this.transaction(() => {
      const pair = this.db.prepare(
        'SELECT expires FROM pairings WHERE id = ? AND expires > ? AND connection_key IS NULL AND active_state = ?',
      ).get(pairingId, now, stateKey);
      if (!pair) return;
      const token = randomToken();
      const key = digest(token);
      this.db.prepare('DELETE FROM browsers WHERE pairing_id = ?').run(pairingId);
      this.db.prepare('UPDATE pairings SET active_state = NULL WHERE id = ?').run(pairingId);
      this.db.prepare('INSERT INTO browsers VALUES (?, ?, ?, ?)').run(
        key, pairingId, this.seal('browser:' + key, credentials),
        Math.min(pair.expires, now + BROWSER_SECONDS, credentials.accessExpiresAt),
      );
      return token;
    });
  }

  browser(token, now) {
    const key = digest(token);
    const row = this.db.prepare(`
      SELECT b.* FROM browsers AS b JOIN pairings AS p ON p.id = b.pairing_id
      WHERE b.key = ? AND b.expires > ? AND p.expires > ? AND p.connection_key IS NULL
    `).get(key, now, now);
    if (row) return { key, pairingId: row.pairing_id, credentials: this.open('browser:' + key, row.credentials) };
  }

  approve(browserToken, files, now) {
    return this.transaction(() => {
      const browser = this.browser(browserToken, now);
      if (!browser) return false;
      const token = randomToken();
      const key = digest(token);
      this.db.prepare('INSERT INTO connections VALUES (?, ?)').run(
        key, this.seal('credentials:' + key, browser.credentials),
      );
      const insert = this.db.prepare('INSERT INTO files VALUES (?, ?, ?, ?, ?, ?, ?)');
      for (const file of files) {
        const resource = file.resourceKey ? this.seal('resource:' + key + ':' + file.id, file.resourceKey) : null;
        insert.run(key, file.id, file.name, file.size, file.mimeType, file.parentId ?? null, resource);
      }
      this.db.prepare('UPDATE pairings SET connection_key = ?, delivery = ? WHERE id = ?').run(
        key, this.seal('delivery:' + browser.pairingId, token), browser.pairingId,
      );
      this.db.prepare('DELETE FROM browsers WHERE pairing_id = ?').run(browser.pairingId);
      this.db.prepare('DELETE FROM states WHERE pairing_id = ?').run(browser.pairingId);
      return true;
    });
  }

  catalog(key) {
    return this.db.prepare(`
      SELECT file_id AS id, name, size, mime_type AS mimeType, parent_id AS parentId
      FROM files WHERE connection_key = ? ORDER BY file_id
    `).all(key).map(({ parentId, ...file }) => parentId ? { ...file, parentId } : file);
  }

  file(key, fileId) {
    const file = this.db.prepare(`
      SELECT file_id AS id, size, mime_type AS mimeType, resource_key AS resourceKey
      FROM files WHERE connection_key = ? AND file_id = ?
    `).get(key, fileId);
    if (file?.resourceKey) file.resourceKey = this.open('resource:' + key + ':' + fileId, file.resourceKey);
    return file;
  }

  credentials(key) {
    const row = this.db.prepare('SELECT credentials FROM connections WHERE key = ?').get(key);
    if (row) return this.open('credentials:' + key, row.credentials);
  }

  updateCredentials(key, credentials) {
    return this.db.prepare('UPDATE connections SET credentials = ? WHERE key = ?').run(
      this.seal('credentials:' + key, credentials), key,
    ).changes === 1;
  }

  deleteConnection(key) {
    return this.db.prepare('DELETE FROM connections WHERE key = ?').run(key).changes === 1;
  }
}
