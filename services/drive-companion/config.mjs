import { resolve } from 'node:path';

export function loadConfig(env = process.env) {
  function required(name, pattern) {
    const value = env[name];
    if (typeof value !== 'string' || !pattern.test(value)) {
      throw new Error(`Missing or invalid ${name}`);
    }
    return value;
  }

  const origin = required('DRIVE_COMPANION_ORIGIN', /^https:\/\/[^\s]+$/);
  if (new URL(origin).origin !== origin) {
    throw new Error('DRIVE_COMPANION_ORIGIN must be an HTTPS origin without a path or trailing slash');
  }
  const key = required('DRIVE_COMPANION_STORAGE_KEY', /^[A-Za-z0-9+/]{43}=$/);
  const storageKey = Buffer.from(key, 'base64');
  if (storageKey.length !== 32 || storageKey.toString('base64') !== key) {
    throw new Error('DRIVE_COMPANION_STORAGE_KEY must be a canonical base64 32-byte key');
  }
  const port = Number(env.PORT ?? '8787');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid PORT');

  return {
    origin,
    host: env.HOST ?? '127.0.0.1',
    port,
    dbPath: resolve(required('DRIVE_COMPANION_DB', /^[^\u0000\r\n]+$/)),
    storageKey,
    clientId: required('GOOGLE_CLIENT_ID', /^[\w-]+\.apps\.googleusercontent\.com$/),
    clientSecret: required('GOOGLE_CLIENT_SECRET', /^[\w-]{10,256}$/),
    pickerApiKey: required('GOOGLE_PICKER_API_KEY', /^[\w-]{10,256}$/),
    googleAppId: required('GOOGLE_APP_ID', /^[0-9]{1,30}$/),
  };
}
