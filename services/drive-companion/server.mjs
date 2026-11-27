import { once } from 'node:events';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { Google, GoogleFailure, isFileId } from './google.mjs';
import { digest, PAIRING_SECONDS, STATE_SECONDS, Store } from './store.mjs';

const FLOW = '__Host-drive-flow';
const STAGE = '__Host-drive-stage';
const TOKEN_FORMAT = /^[A-Za-z0-9_-]{43}$/;
const CODE_FORMAT = /^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$/;
const PAIRING_PATH = /^\/v1\/pairings\/([A-Za-z0-9_-]{24})$/;
const FILE_PATH = /^\/v1\/files\/([A-Za-z0-9_-]{1,256})$/;
const MAX_SELECTED_FILES = 100;
const NETWORK_TIMEOUT = 15_000;
const CSP = [
  "default-src 'none'",
  "script-src 'self' https://apis.google.com",
  "style-src 'self'",
  "img-src 'self' data:",
  "connect-src 'self' https://www.googleapis.com https://docs.google.com https://drive.google.com",
  "frame-src https://docs.google.com https://drive.google.com https://accounts.google.com",
  "frame-ancestors 'none'",
  "form-action 'self' https://accounts.google.com",
  "base-uri 'none'",
].join('; ');

class HttpError extends Error {
  constructor(status, code, headers = {}) {
    super(code);
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

const reject = (status, code, headers) => { throw new HttpError(status, code, headers); };

function json(res, status, body, headers = {}) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length, ...headers });
  res.end(data);
}

function redirect(res, location, cookies = []) {
  res.writeHead(303, { Location: location, 'Set-Cookie': cookies });
  res.end();
}

function cookie(name, value = '', maxAge = 0) {
  return name + '=' + value + '; Path=/; Max-Age=' + maxAge + '; HttpOnly; Secure; SameSite=Lax';
}

function cookieToken(req, name) {
  const prefix = name + '=';
  const values = (req.headers.cookie ?? '').split(';').map(part => part.trim())
    .filter(part => part.startsWith(prefix)).map(part => part.slice(prefix.length));
  return values.length === 1 && TOKEN_FORMAT.test(values[0]) ? values[0] : undefined;
}

function bearer(req) {
  return /^Bearer ([A-Za-z0-9_-]{43})$/i.exec(req.headers.authorization ?? '')?.[1];
}

function requireOrigin(req, origin) {
  if (req.headers.origin !== origin) reject(403, 'origin_required');
}

async function body(req, expected, limit) {
  if (req.headers['content-type']?.split(';')[0].trim().toLowerCase() !== expected) {
    reject(415, 'unsupported_content_type');
  }
  if (Number(req.headers['content-length']) > limit) {
    req.resume();
    reject(413, 'request_too_large');
  }
  const parts = [];
  let length = 0;
  for await (const part of req.iterator({ destroyOnReturn: false })) {
    length += part.length;
    if (length > limit) {
      req.resume();
      reject(413, 'request_too_large');
    }
    parts.push(part);
  }
  return Buffer.concat(parts, length).toString('utf8');
}

async function jsonBody(req, limit) {
  const raw = await body(req, 'application/json', limit);
  try {
    return JSON.parse(raw);
  } catch {
    return reject(400, 'invalid_request');
  }
}

function exactParam(search, name) {
  const values = search.getAll(name);
  return values.length === 1 ? values[0] : undefined;
}

function checkSelection(input) {
  const items = input?.files;
  if (!Array.isArray(items) || items.length < 1 || items.length > MAX_SELECTED_FILES) {
    reject(400, 'invalid_selection');
  }
  const seen = new Set();
  return items.map(item => {
    if (!isFileId(item?.id) || seen.has(item.id) ||
        (item.resourceKey !== undefined && !isFileId(item.resourceKey)) ||
        Object.keys(item).some(key => key !== 'id' && key !== 'resourceKey')) {
      reject(400, 'invalid_selection');
    }
    seen.add(item.id);
    return { id: item.id, resourceKey: item.resourceKey };
  });
}

function rateLimit(limit) {
  let minute = -1;
  let used = 0;
  return now => {
    const window = Math.floor(now / 60);
    if (window !== minute) {
      minute = window;
      used = 0;
    }
    if (used >= limit) reject(429, 'rate_limited', { 'Retry-After': 60 - (now % 60) });
    used++;
  };
}

function readRange(header, size) {
  if (header === undefined) return;
  const match = /^bytes=([0-9]{0,16})-([0-9]{0,16})$/.exec(header);
  const rangeInvalid = () => reject(416, 'invalid_range', { 'Content-Range': 'bytes */' + size });
  if (!match || (!match[1] && !match[2])) return rangeInvalid();
  const [first, last] = [match[1] ? Number(match[1]) : undefined, match[2] ? Number(match[2]) : undefined];
  if ((first !== undefined && !Number.isSafeInteger(first)) ||
      (last !== undefined && !Number.isSafeInteger(last))) return rangeInvalid();
  if (first === undefined) {
    if (last === 0) return rangeInvalid();
    return { start: Math.max(0, size - last), end: size - 1 };
  }
  if (first >= size || (last !== undefined && last < first)) return rangeInvalid();
  return { start: first, end: last === undefined ? size - 1 : Math.min(last, size - 1) };
}

function cancellationError() {
  return new HttpError(401, 'authorization_expired');
}

function googleError(error) {
  if (!(error instanceof GoogleFailure)) return error;
  switch (error.code) {
    case 'authorization_expired':
    case 'invalid_grant':
      return cancellationError();
    case 'invalid_filename':
    case 'unsupported_media':
      return new HttpError(422, error.code);
    case 'selection_unavailable':
      return new HttpError(422, 'selection_unavailable');
    case 'temporarily_unavailable':
      return new HttpError(503, 'temporarily_unavailable', { 'Retry-After': 5 });
    default:
      return new HttpError(502, 'provider_response_error');
  }
}

function htmlError(res, status, message) {
  const page = '<!doctype html><html lang="en"><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1"><title>MediaVault</title>' +
    '<link rel="stylesheet" href="/assets/style.css"><main><h1>Connect Google Drive</h1>' +
    '<p>' + message + '</p><a href="/pair">Return to pairing</a></main></html>';
  res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(page);
}

export function createCompanion(config, {
  fetcher = fetch,
  now = () => Math.floor(Date.now() / 1000),
  reportError = () => console.error('Drive companion encountered an internal request error.'),
} = {}) {
  const store = new Store(config.dbPath, config.storageKey);
  const google = new Google(config, fetcher);
  const pairLimit = rateLimit(120);
  const browserLimit = rateLimit(240);
  const activeReads = new Map();
  const refreshes = new Map();
  const assets = new Map([
    ['/pair', 'pair.html'], ['/pair/select', 'select.html'], ['/pair/complete', 'complete.html'],
    ['/assets/picker.js', 'picker.js'], ['/assets/style.css', 'style.css'],
  ]);

  function stopReads(key) {
    for (const controller of activeReads.get(key) ?? []) controller.abort();
  }

  function revoke(key) {
    store.deleteConnection(key);
    stopReads(key);
  }

  function sweep() {
    for (const key of store.sweep(now())) stopReads(key);
  }

  async function currentCredentials(key, rejectedAccessToken) {
    const previous = store.credentials(key, now());
    if (!previous) throw cancellationError();
    if (previous.accessExpiresAt > now() + 30 && previous.accessToken !== rejectedAccessToken) return previous;
    const current = refreshes.get(key);
    if (current) return current;

    const refresh = (async () => {
      try {
        const updated = await google.refresh(previous, now());
        if (!store.updateCredentials(key, updated)) throw cancellationError();
        return updated;
      } catch (error) {
        if (error instanceof GoogleFailure && error.code === 'invalid_grant') revoke(key);
        throw googleError(error);
      }
    })();
    refreshes.set(key, refresh);
    try {
      return await refresh;
    } finally {
      refreshes.delete(key);
    }
  }

  function sendAsset(res, path) {
    const filename = assets.get(path);
    const type = filename.endsWith('.html') ? 'text/html' :
      filename.endsWith('.css') ? 'text/css' : 'text/javascript';
    const contents = readFileSync(new URL('./web/' + filename, import.meta.url));
    res.writeHead(200, { 'Content-Type': type + '; charset=utf-8', 'Content-Length': contents.length });
    res.end(contents);
  }

  function requireConnection(req) {
    const token = bearer(req);
    const key = token && digest(token);
    if (!key || !store.credentials(key, now())) throw cancellationError();
    return key;
  }

  async function streamFile(req, res, fileId) {
    const key = requireConnection(req);
    const file = store.file(key, fileId);
    if (!file) reject(404, 'file_not_found');
    const range = readRange(req.headers.range, file.size);
    const expectedSize = range ? range.end - range.start + 1 : file.size;
    const expectedRange = range ? 'bytes ' + range.start + '-' + range.end + '/' + file.size : undefined;

    const client = new AbortController();
    const reads = activeReads.get(key) ?? new Set();
    reads.add(client);
    activeReads.set(key, reads);
    const close = () => client.abort();
    res.once('close', close);
    let upstream;
    let timer;
    try {
      let credentials = await currentCredentials(key);
      client.signal.throwIfAborted();
      timer = setTimeout(close, NETWORK_TIMEOUT).unref();
      upstream = await google.media(file, credentials.accessToken, range, client.signal);
      if (upstream.status === 401) {
        await upstream.body?.cancel();
        credentials = await currentCredentials(key, credentials.accessToken);
        client.signal.throwIfAborted();
        timer.refresh();
        upstream = await google.media(file, credentials.accessToken, range, client.signal);
      }
      if (upstream.status === 401) throw cancellationError();
      if (upstream.status === 403 || upstream.status === 404) reject(403, 'file_permission_denied');
      if (upstream.status === 429 || upstream.status >= 500) reject(503, 'temporarily_unavailable', { 'Retry-After': 5 });
      const length = upstream.headers.get('Content-Length');
      const encoding = upstream.headers.get('Content-Encoding');
      if (!upstream.body || upstream.status !== (range ? 206 : 200) ||
          (range && upstream.headers.get('Content-Range') !== expectedRange) ||
          (!range && upstream.headers.has('Content-Range')) ||
          (length !== null && length !== String(expectedSize)) ||
          (encoding && encoding !== 'identity')) reject(502, 'provider_response_error');

      client.signal.throwIfAborted();
      if (!store.credentials(key, now())) throw cancellationError();
      const headers = {
        'Accept-Ranges': 'bytes',
        'Content-Type': file.mimeType,
        'Content-Length': expectedSize,
        'Content-Disposition': 'attachment',
      };
      if (range) headers['Content-Range'] = expectedRange;
      res.writeHead(range ? 206 : 200, headers);
      let count = 0;
      for await (const chunk of upstream.body) {
        client.signal.throwIfAborted();
        timer.refresh();
        count += chunk.length;
        if (count > expectedSize) throw new Error('Excess upstream media data');
        if (!res.write(chunk)) await once(res, 'drain', { signal: client.signal });
      }
      if (count !== expectedSize) throw new Error('Incomplete upstream media data');
      res.end();
    } catch (error) {
      if (res.headersSent) res.destroy();
      else if (client.signal.aborted) {
        if (!res.destroyed) {
          if (!store.file(key, fileId)) throw cancellationError();
          reject(503, 'temporarily_unavailable', { 'Retry-After': 5 });
        }
      } else {
        throw googleError(error);
      }
    } finally {
      clearTimeout(timer);
      res.removeListener('close', close);
      reads.delete(client);
      if (!reads.size) activeReads.delete(key);
      if (upstream?.body && !upstream.body.locked) await upstream.body.cancel().catch(() => {});
      close();
    }
  }

  async function handle(req, res) {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Content-Security-Policy', CSP);
    res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Strict-Transport-Security', 'max-age=31536000');
    if (!req.url?.startsWith('/') || req.url.startsWith('//')) reject(400, 'invalid_request');
    const url = new URL(req.url, config.origin);
    if (url.origin !== config.origin) reject(400, 'invalid_request');
    const path = url.pathname;
    const method = req.method;
    const pairing = PAIRING_PATH.exec(path);
    const media = FILE_PATH.exec(path);

    if (method === 'POST' && path === '/v1/pairings') {
      pairLimit(now());
      const payload = await jsonBody(req, 1024);
      if (!payload || typeof payload !== 'object' || Array.isArray(payload) || Object.keys(payload).length) {
        reject(400, 'invalid_request');
      }
      sweep();
      return json(res, 201, { ...store.pair(now()), verificationUrl: config.origin + '/pair', expiresIn: PAIRING_SECONDS });
    }
    if ((method === 'GET' || method === 'DELETE') && pairing) {
      const secret = bearer(req);
      if (!secret) reject(404, 'pairing_not_found');
      const result = method === 'GET' ? store.poll(pairing[1], secret, now()) : store.cancel(pairing[1], secret, now());
      if (result.status === 404) reject(404, 'pairing_not_found');
      if (result.status === 410) reject(410, 'pairing_expired');
      if (result.revoked) stopReads(result.revoked);
      if (result.status === 204) return res.writeHead(204).end();
      return json(res, 200, result.body);
    }
    if ((method === 'GET' || method === 'DELETE') && path === '/v1/connection') {
      const key = requireConnection(req);
      if (method === 'DELETE') {
        revoke(key);
        return res.writeHead(204).end();
      }
      await currentCredentials(key);
      const files = store.claimCatalog(key, now());
      if (!files) throw cancellationError();
      return json(res, 200, { files });
    }
    if (method === 'GET' && media) return streamFile(req, res, media[1]);

    if (method === 'GET' && assets.has(path)) {
      if (path === '/pair/select') {
        const token = cookieToken(req, STAGE);
        if (!token || !store.browser(token, now())) return redirect(res, '/pair');
      }
      return sendAsset(res, path);
    }
    if (method === 'POST' && path === '/pair/start') {
      requireOrigin(req, config.origin);
      browserLimit(now());
      const form = new URLSearchParams(await body(req, 'application/x-www-form-urlencoded', 1024));
      const code = exactParam(form, 'code')?.trim().toUpperCase();
      const state = CODE_FORMAT.test(code ?? '') && store.startOAuth(code, now());
      if (!state) return htmlError(res, 404, 'That code is invalid or expired. Get a new code on your TV.');
      return redirect(res, google.authorization(state.state, state.verifier), [
        cookie(FLOW, state.browser, STATE_SECONDS), cookie(STAGE),
      ]);
    }
    if (method === 'GET' && path === '/oauth/callback') {
      const state = exactParam(url.searchParams, 'state');
      const browser = cookieToken(req, FLOW);
      const consumed = TOKEN_FORMAT.test(state ?? '') && browser && store.consumeOAuth(state, browser, now());
      res.setHeader('Referrer-Policy', 'no-referrer');
      if (!consumed) return htmlError(res, 400, 'That Google authorization expired. Return to pairing and try again.');
      res.setHeader('Set-Cookie', cookie(FLOW));
      const code = exactParam(url.searchParams, 'code');
      if (url.searchParams.has('error') || !/^[!-~]{1,4096}$/.test(code ?? '')) {
        return htmlError(res, 400, 'Google Drive access was not granted. Return to pairing to try again.');
      }
      try {
        const credentials = await google.exchange(code, consumed.verifier, now());
        const stage = store.stage(consumed, credentials, now());
        if (!stage) return htmlError(res, 410, 'Your TV code expired. Start a new pairing on the TV.');
        return redirect(res, '/pair/select', [cookie(FLOW), cookie(STAGE, stage, STATE_SECONDS)]);
      } catch (error) {
        if (!(error instanceof GoogleFailure)) throw error;
        return htmlError(res, 502, 'Google could not finish sign-in. Return to pairing to try again.');
      }
    }
    if ((method === 'GET' && path === '/browser/session') ||
        (method === 'POST' && path === '/browser/selection')) {
      const token = cookieToken(req, STAGE);
      const browser = token && store.browser(token, now());
      if (!browser) throw cancellationError();
      if (method === 'GET') {
        return json(res, 200, {
          accessToken: browser.credentials.accessToken,
          pickerApiKey: config.pickerApiKey,
          googleAppId: config.googleAppId,
        });
      }
      requireOrigin(req, config.origin);
      browserLimit(now());
      const selections = checkSelection(await jsonBody(req, 60_000));
      const files = [];
      // Limit concurrent Google calls while keeping a phone selection responsive.
      for (let index = 0; index < selections.length; index += 8) {
        if (!store.browser(token, now())) throw cancellationError();
        try {
          const batch = selections.slice(index, index + 8);
          files.push(...await Promise.all(batch.map(file => google.metadata(file, browser.credentials.accessToken))));
        } catch (error) {
          throw googleError(error);
        }
      }
      // Apple TV uses a flat, exact-name catalog, so ambiguous display paths cannot be granted.
      if (new Set(files.map(file => file.name)).size !== files.length) reject(422, 'name_collision');
      if (!store.approve(token, files, now())) throw cancellationError();
      res.setHeader('Set-Cookie', cookie(STAGE));
      return json(res, 200, { ok: true });
    }
    reject(404, 'not_found');
  }

  const server = createServer({ requestTimeout: 30_000, headersTimeout: 15_000 }, (req, res) => {
    handle(req, res).catch(error => {
      if (res.destroyed) return;
      if (res.headersSent) return res.destroy();
      if (error instanceof HttpError) return json(res, error.status, { error: error.code }, error.headers);
      reportError();
      json(res, 500, { error: 'internal_error' });
    });
  });
  const maintenance = setInterval(() => {
    try { sweep(); } catch { reportError(); }
  }, 60_000).unref();
  server.once('close', () => {
    clearInterval(maintenance);
    for (const key of activeReads.keys()) stopReads(key);
    store.close();
  });
  return server;
}
