import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { loadConfig } from '../config.mjs';
import { DRIVE_SCOPE, validateMetadata } from '../google.mjs';
import { createCompanion } from '../server.mjs';

const origin = 'https://drive.example.test';
const clientId = 'example-test.apps.googleusercontent.com';
const clientSecret = 'fixture-google-client-secret';
const firstAccess = 'fixture-google-access-original';
const firstRefresh = 'fixture-google-refresh-original';
const movie = Buffer.from('0123456789abcdefghijklmnopqrstuvwxyz');
const captions = Buffer.from('WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nHello.');
const photo = Buffer.from('fake fixture image bytes');

const configEnvironment = {
  DRIVE_COMPANION_ORIGIN: origin,
  DRIVE_COMPANION_STORAGE_KEY: Buffer.alloc(32, 7).toString('base64'),
  GOOGLE_CLIENT_ID: clientId,
  GOOGLE_CLIENT_SECRET: clientSecret,
  GOOGLE_PICKER_API_KEY: 'fake-picker-key-testing',
  GOOGLE_APP_ID: '123456789',
};

const authorization = token => ({ Authorization: 'Bearer ' + token });
const metadata = (id, name, mimeType, contents, extra = {}) => ({
  id, name, mimeType, size: String(contents.length),
  parents: ['folderA'], trashed: false, capabilities: { canDownload: true }, ...extra,
});

class GoogleMock {
  constructor() {
    this.calls = [];
    this.files = new Map([
      ['MovieID', [metadata('MovieID', 'Family Film.mp4', 'video/mp4', movie, { resourceKey: 'key_1' }), movie]],
      ['captionID', [metadata('captionID', 'Family Film.en.vtt', 'text/vtt', captions, { resourceKey: '' }), captions]],
      ['photoID', [metadata('photoID', 'Trip.jpg', 'image/jpeg', photo, { parents: [] }), photo]],
      ['privateID', [metadata('privateID', 'Private.mp4', 'video/mp4', movie), movie]],
    ]);
    this.acceptedAccess = new Set([firstAccess]);
    this.refreshResponse = refreshToken => {
      assert.equal(refreshToken, firstRefresh);
      this.acceptedAccess.add('fixture-google-access-renewed');
      return Response.json({
        token_type: 'Bearer', access_token: 'fixture-google-access-renewed',
        refresh_token: 'fixture-google-refresh-renewed', expires_in: 3600,
      });
    };
    this.tokenResponse = () => Response.json({
      scope: DRIVE_SCOPE, token_type: 'Bearer', access_token: firstAccess,
      refresh_token: firstRefresh, expires_in: 3600,
    });
  }

  fetch = async (target, init) => {
    const url = new URL(target);
    const headers = new Headers(init.headers);
    const params = init.body ? Object.fromEntries(init.body) : undefined;
    const call = { url, headers, params, method: init.method ?? 'GET', signal: init.signal };
    this.calls.push(call);
    assert.equal(init.redirect, 'manual', 'credentials must never be forwarded to a redirect');
    if (url.href === 'https://oauth2.googleapis.com/token') {
      assert.equal(call.method, 'POST');
      assert.equal(params.client_id, clientId);
      assert.equal(params.client_secret, clientSecret);
      if (params.grant_type === 'refresh_token') return this.refreshResponse(params.refresh_token);
      assert.equal(params.grant_type, 'authorization_code');
      assert.equal(params.redirect_uri, origin + '/oauth/callback');
      assert.match(params.code_verifier, /^[A-Za-z0-9_-]{43}$/);
      return this.tokenResponse(params.code);
    }

    assert.equal(url.origin, 'https://www.googleapis.com');
    assert.match(url.pathname, /^\/drive\/v3\/files\/[A-Za-z0-9_-]+$/);
    assert.equal(url.searchParams.get('supportsAllDrives'), 'true');
    assert.equal(call.method, 'GET');
    const accessToken = headers.get('Authorization')?.slice(7);
    if (!this.acceptedAccess.has(accessToken)) return new Response(null, { status: 401 });
    const [file, contents] = this.files.get(url.pathname.split('/').pop()) ?? [];
    if (!file) return new Response(null, { status: 404 });
    if (file.resourceKey) assert.equal(headers.get('X-Goog-Drive-Resource-Keys'), file.id + '/' + file.resourceKey);
    if (url.searchParams.get('alt') !== 'media') {
      assert.equal(url.searchParams.get('fields'), 'id,name,size,mimeType,parents,resourceKey,trashed,capabilities(canDownload)');
      return Response.json(file);
    }

    if (this.mediaResponse) return this.mediaResponse(call);
    const range = headers.get('Range');
    if (!range) return new Response(contents, { headers: { 'Content-Length': contents.length } });
    const [, lo, hi] = /^bytes=([0-9]+)-([0-9]+)$/.exec(range);
    return new Response(contents.subarray(Number(lo), Number(hi) + 1), { status: 206, headers: {
      'Content-Length': Number(hi) - Number(lo) + 1,
      'Content-Range': 'bytes ' + lo + '-' + hi + '/' + contents.length,
    } });
  };
}

async function harness(t, google = new GoogleMock()) {
  const directory = await mkdtemp(join(tmpdir(), 'drive-companion-test-'));
  const config = loadConfig({ ...configEnvironment, DRIVE_COMPANION_DB: join(directory, 'data.sqlite') });
  let server;
  let base;
  let time = 2_000_000;
  const internal = [];

  async function stop() {
    if (!server?.listening) return;
    const closed = once(server, 'close');
    server.close();
    server.closeAllConnections();
    await closed;
  }

  async function start() {
    server = createCompanion(config, {
      fetcher: google.fetch,
      now: () => time,
      reportError: () => internal.push('internal request error'),
    });
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    base = 'http://127.0.0.1:' + server.address().port;
  }

  t.after(async () => {
    await stop();
    await rm(directory, { recursive: true, force: true });
    assert.deepEqual(internal, [], 'expected safe handling of protocol errors');
  });
  await start();
  return {
    config, google, directory,
    advance: seconds => { time += seconds; },
    request: (path, options) => fetch(base + path, { redirect: 'manual', ...options }),
    restart: async () => { await stop(); await start(); },
  };
}

function cookies(response, name) {
  return response.headers.getSetCookie().find(value => value.startsWith(name + '='))?.split(';')[0];
}

function pairingPath(pair) {
  return '/v1/pairings/' + pair.id;
}

async function pair(h) {
  const response = await h.request('/v1/pairings', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}',
  });
  assert.equal(response.status, 201);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  const result = await response.json();
  assert.match(result.id, /^[A-Za-z0-9_-]{24}$/);
  assert.match(result.secret, /^[A-Za-z0-9_-]{43}$/);
  assert.match(result.code, /^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$/);
  assert.equal(result.expiresIn, 600);
  assert.equal(result.verificationUrl, origin + '/pair');
  return result;
}

async function poll(h, pairing, secret = pairing.secret) {
  return h.request(pairingPath(pairing), { headers: authorization(secret) });
}

async function enterCode(h, pairing, browserOrigin = origin) {
  return h.request('/pair/start', {
    method: 'POST',
    headers: { Origin: browserOrigin, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ code: pairing.code.toLowerCase() }),
  });
}

function callbackPath(auth, code = 'fixture_auth/code') {
  const state = new URL(auth.headers.get('Location')).searchParams.get('state');
  return '/oauth/callback?' + new URLSearchParams({ code, state });
}

async function phone(h, pairing) {
  const auth = await enterCode(h, pairing);
  assert.equal(auth.status, 303);
  const flow = cookies(auth, '__Host-drive-flow');
  const response = await h.request(callbackPath(auth), { headers: { Cookie: flow } });
  assert.equal(response.status, 303);
  assert.equal(response.headers.get('Location'), '/pair/select');
  return cookies(response, '__Host-drive-stage');
}

async function select(h, stage, files, browserOrigin = origin) {
  return h.request('/browser/selection', {
    method: 'POST',
    headers: { Origin: browserOrigin, Cookie: stage, 'Content-Type': 'application/json' },
    body: JSON.stringify({ files }),
  });
}

async function grant(h) {
  const pairing = await pair(h);
  const stage = await phone(h, pairing);
  const selected = await select(h, stage, [
    { id: 'MovieID', resourceKey: 'key_1' }, { id: 'captionID' }, { id: 'photoID' },
  ]);
  assert.equal(selected.status, 200);
  assert.deepEqual(await selected.json(), { ok: true });
  const approved = await poll(h, pairing);
  assert.equal(approved.status, 200);
  return { pairing, stage, ...await approved.json() };
}

test('requires a canonical HTTPS origin and a 256-bit storage key', () => {
  const env = { ...configEnvironment, DRIVE_COMPANION_DB: 'test.sqlite' };
  assert.throws(() => loadConfig({ ...env, DRIVE_COMPANION_ORIGIN: 'http://drive.example.test' }));
  assert.throws(() => loadConfig({ ...env, DRIVE_COMPANION_ORIGIN: origin + '/pair' }));
  assert.throws(() => loadConfig({ ...env, DRIVE_COMPANION_STORAGE_KEY: 'short-invalid-secret' }));
  assert.throws(() => loadConfig({ ...env, GOOGLE_APP_ID: 'unregistered' }));
  assert.equal(loadConfig(env).host, '127.0.0.1');
});

test('binds separate TV and browser credentials, uses S256 PKCE, and consumes state once', async t => {
  const h = await harness(t);
  const page = await h.request('/pair');
  assert.equal(page.status, 200);
  assert.match(await page.text(), /action="\/pair\/start"/);
  assert.equal(page.headers.get('Cache-Control'), 'no-store');
  assert.match(page.headers.get('Content-Security-Policy'), /frame-ancestors 'none'/);
  assert.equal((await h.request('/pair/select')).status, 303);
  const pairing = await pair(h);
  assert.equal((await poll(h, pairing, pairing.code)).status, 404);
  assert.deepEqual(await (await poll(h, pairing)).json(), { status: 'pending' });
  assert.equal((await enterCode(h, pairing, 'https://unrelated.example.test')).status, 403);

  const auth = await enterCode(h, pairing);
  const url = new URL(auth.headers.get('Location'));
  assert.equal(url.origin + url.pathname, 'https://accounts.google.com/o/oauth2/v2/auth');
  assert.equal(url.searchParams.get('scope'), DRIVE_SCOPE);
  assert.equal(url.searchParams.get('access_type'), 'offline');
  assert.equal(url.searchParams.get('include_granted_scopes'), 'false');
  assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(url.searchParams.get('redirect_uri'), origin + '/oauth/callback');
  assert.ok(!url.href.includes(pairing.secret) && !url.href.includes(clientSecret));

  const flow = cookies(auth, '__Host-drive-flow');
  const protectedFlow = auth.headers.getSetCookie()[0];
  for (const attr of ['Secure', 'HttpOnly', 'SameSite=Lax', 'Path=/']) assert.match(protectedFlow, new RegExp(attr));
  assert.equal((await h.request(callbackPath(auth), { headers: {
    Cookie: '__Host-drive-flow=' + 'x'.repeat(43),
  } })).status, 400);
  assert.equal(h.google.calls.length, 0);
  const response = await h.request(callbackPath(auth), { headers: { Cookie: flow } });
  assert.equal(response.status, 303);
  assert.equal(response.headers.get('Referrer-Policy'), 'no-referrer');
  const verifier = h.google.calls[0].params.code_verifier;
  assert.equal(createHash('sha256').update(verifier).digest('base64url'), url.searchParams.get('code_challenge'));
  assert.equal((await h.request(callbackPath(auth), { headers: { Cookie: flow } })).status, 400);
  assert.equal(h.google.calls.length, 1);

  const stage = cookies(response, '__Host-drive-stage');
  assert.equal((await h.request('/pair/select', { headers: { Cookie: stage } })).status, 200);
  assert.equal((await h.request('/browser/session')).status, 401);
  const session = await h.request('/browser/session', { headers: { Cookie: stage } });
  assert.equal(session.headers.get('Cache-Control'), 'no-store');
  assert.deepEqual(await session.json(), {
    accessToken: firstAccess, pickerApiKey: configEnvironment.GOOGLE_PICKER_API_KEY, googleAppId: '123456789',
  });
  assert.equal((await poll(h, pairing, stage.split('=')[1])).status, 404);
  assert.equal((await select(h, stage, [{ id: 'photoID' }], 'https://unrelated.example.test')).status, 403);
});

test('approves the exact server-validated catalog, performs ranged reads, and never reads outside the grant', async t => {
  const h = await harness(t);
  const { pairing, stage, status, connection } = await grant(h);
  assert.equal(status, 'approved');
  assert.match(connection.token, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(connection.token, pairing.secret);
  assert.deepEqual(connection.files, [
    { id: 'MovieID', name: 'Family Film.mp4', size: movie.length, mimeType: 'video/mp4', parentId: 'folderA' },
    { id: 'captionID', name: 'Family Film.en.vtt', size: captions.length, mimeType: 'text/vtt', parentId: 'folderA' },
    { id: 'photoID', name: 'Trip.jpg', size: photo.length, mimeType: 'image/jpeg' },
  ]);
  assert.deepEqual(await (await poll(h, pairing)).json(), { status, connection });
  assert.equal((await h.request('/browser/session', { headers: { Cookie: stage } })).status, 401);
  const headers = authorization(connection.token);
  const catalog = await h.request('/v1/connection', { headers });
  assert.deepEqual(await catalog.json(), { files: connection.files });

  const response = await h.request('/v1/files/MovieID', { headers: { ...headers, Range: 'bytes=7-12' } });
  assert.equal(response.status, 206);
  assert.equal(response.headers.get('Content-Range'), 'bytes 7-12/' + movie.length);
  assert.equal(response.headers.get('Content-Length'), '6');
  assert.equal(response.headers.get('Content-Type'), 'video/mp4');
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), movie.subarray(7, 13));
  const suffix = await h.request('/v1/files/MovieID', { headers: { ...headers, Range: 'bytes=-3' } });
  assert.equal(suffix.status, 206);
  assert.deepEqual(Buffer.from(await suffix.arrayBuffer()), movie.subarray(-3));
  const whole = await h.request('/v1/files/photoID', { headers });
  assert.deepEqual(Buffer.from(await whole.arrayBuffer()), photo);

  const before = h.google.calls.length;
  for (const id of ['privateID', 'movieid', 'MovieID%2F..', 'https:%2F%2Fexample.test']) {
    assert.equal((await h.request('/v1/files/' + id, { headers })).status, 404);
  }
  for (const value of ['bytes=1-2,5-6', 'bytes=-0', 'bytes=5-1', 'bytes=36-', 'bytes=9007199254740992-', 'items=2-3']) {
    const invalid = await h.request('/v1/files/MovieID', { headers: { ...headers, Range: value } });
    assert.equal(invalid.status, 416);
    assert.equal(invalid.headers.get('Content-Range'), 'bytes */' + movie.length);
  }
  assert.equal((await h.request('/v1/files/MovieID', { headers: authorization(pairing.secret) })).status, 401);
  assert.equal(h.google.calls.length, before);
});

test('rejects unauthorized, unsafe, and partial selections before granting any file', async t => {
  const h = await harness(t);
  const pairing = await pair(h);
  const stage = await phone(h, pairing);
  const baseline = h.google.calls.length;
  for (const selection of [
    [], [{ id: 'MovieID' }, { id: 'MovieID' }], [{ id: 'https://private.example.test/movie' }],
    [{ id: 'MovieID', resourceKey: '../a' }], [{ id: 'MovieID', url: 'https://private.example.test/movie' }],
  ]) {
    assert.equal((await select(h, stage, selection)).status, 400);
  }
  assert.equal(h.google.calls.length, baseline);
  h.google.files.set('notAllowed', [metadata('notAllowed', 'Denied.mp4', 'video/mp4', movie, {
    capabilities: { canDownload: false },
  }), movie]);
  const invalid = await select(h, stage, [{ id: 'photoID' }, { id: 'notAllowed' }]);
  assert.equal(invalid.status, 422);
  assert.deepEqual(await invalid.json(), { error: 'selection_unavailable' });
  assert.deepEqual(await (await poll(h, pairing)).json(), { status: 'pending' });
  assert.equal((await select(h, stage, [{ id: 'photoID' }])).status, 200);

  const file = metadata('same', 'Sample.mp4', 'video/mp4', movie);
  for (const overrides of [
    { name: '../Sample.mp4' }, { name: '..' }, { name: 'folder\\clip.mp4' }, { name: 'x\u0085.mp4' },
    { name: 'é'.repeat(128) }, { id: 'SAME' }, { parents: ['one', 'two'] }, { parents: ['../other'] },
    { resourceKey: 'bad/key' }, { resourceKey: 'different' }, { trashed: true },
    { mimeType: 'application/vnd.google-apps.shortcut' }, { mimeType: 'audio/mpeg' }, { size: '9007199254740992' },
  ]) {
    assert.throws(() => validateMetadata({ ...file, ...overrides }, { id: 'same', resourceKey: 'picker-key' }), {
      code: 'selection_unavailable',
    });
  }
});

test('handles provider range, permission, and redirect failures safely', async t => {
  const h = await harness(t);
  const { connection } = await grant(h);
  const options = { headers: { ...authorization(connection.token), Range: 'bytes=0-2' } };
  const verify = async (upstream, code) => {
    h.google.mediaResponse = () => upstream;
    const response = await h.request('/v1/files/MovieID', options);
    assert.equal(response.status, code);
    assert.equal(response.headers.get('Location'), null);
    return response;
  };
  await verify(new Response('012', { status: 206, headers: { 'Content-Range': 'bytes 1-3/36' } }), 502);
  await verify(new Response('012', { status: 206, headers: {
    'Content-Range': 'bytes 0-2/36', 'Content-Length': '4',
  } }), 502);
  await verify(new Response('012', { status: 206, headers: {
    'Content-Range': 'bytes 0-2/36', 'Content-Encoding': 'gzip',
  } }), 502);
  await verify(new Response(null, { status: 302, headers: { Location: 'https://unrelated.example.test/grab' } }), 502);
  await verify(new Response(null, { status: 404 }), 403);
  assert.ok(h.google.calls.every(call => call.url.hostname !== 'unrelated.example.test'));
});

test('persists grants across restart, encrypts stored credentials, refreshes once, and revokes an invalid grant', async t => {
  const h = await harness(t);
  const pairing = await pair(h);
  const stage = await phone(h, pairing);
  await h.restart();
  assert.equal((await select(h, stage, [
    { id: 'photoID' }, { id: 'MovieID', resourceKey: 'key_1' },
  ])).status, 200);
  const { connection } = await (await poll(h, pairing)).json();
  await h.restart();
  assert.deepEqual(await (await poll(h, pairing)).json(), { status: 'approved', connection });

  const persisted = Buffer.concat(await Promise.all([
    readFile(h.config.dbPath), readFile(h.config.dbPath + '-wal').catch(() => Buffer.alloc(0)),
  ]));
  assert.equal((await stat(h.config.dbPath)).mode & 0o777, 0o600);
  for (const value of [firstAccess, firstRefresh, clientSecret, connection.token, pairing.secret, pairing.code, 'key_1']) {
    assert.equal(persisted.includes(value), false, 'credential is absent from database bytes');
  }

  const headers = authorization(connection.token);
  h.advance(3700);
  const [catalog1, catalog2] = await Promise.all([
    h.request('/v1/connection', { headers }), h.request('/v1/connection', { headers }),
  ]);
  assert.equal(catalog1.status, 200);
  assert.equal(catalog2.status, 200);
  assert.equal(h.google.calls.filter(call => call.params?.grant_type === 'refresh_token').length, 1);
  await pair(h); // Sweep an expired, claimed pairing while preserving its connection.
  assert.equal((await poll(h, pairing)).status, 404);
  assert.equal((await h.request('/v1/connection', { headers })).status, 200);

  h.advance(3700);
  h.google.refreshResponse = refreshToken => {
    assert.equal(refreshToken, 'fixture-google-refresh-renewed');
    return Response.json({ error: 'invalid_grant' }, { status: 400 });
  };
  assert.equal((await h.request('/v1/connection', { headers })).status, 401);
  assert.equal((await h.request('/v1/files/photoID', { headers })).status, 401);
  assert.equal((await h.request('/v1/connection', { method: 'DELETE', headers })).status, 401);
});

test('rejects canceled and expired pairing, and a stale exchange cannot replace a newer authorization', async t => {
  const h = await harness(t);
  const expired = await pair(h);
  h.advance(601);
  assert.equal((await poll(h, expired)).status, 410);
  assert.equal((await enterCode(h, expired)).status, 404);
  const canceled = await pair(h);
  const canceledAuth = await enterCode(h, canceled);
  assert.equal((await h.request(pairingPath(canceled), {
    method: 'DELETE', headers: authorization(canceled.secret),
  })).status, 204);
  assert.equal((await poll(h, canceled)).status, 404);
  assert.equal((await h.request(callbackPath(canceledAuth), {
    headers: { Cookie: cookies(canceledAuth, '__Host-drive-flow') },
  })).status, 400);

  const pairing = await pair(h);
  const original = await enterCode(h, pairing);
  const respond = h.google.tokenResponse;
  const started = Promise.withResolvers();
  const finish = Promise.withResolvers();
  h.google.tokenResponse = async googleCode => {
    if (googleCode === 'original') {
      started.resolve();
      await finish.promise;
    }
    return respond();
  };
  const stale = h.request(callbackPath(original, 'original'), {
    headers: { Cookie: cookies(original, '__Host-drive-flow') },
  });
  await started.promise;
  const stage = await phone(h, pairing);
  finish.resolve();
  assert.equal((await stale).status, 410);
  assert.equal((await h.request('/browser/session', { headers: { Cookie: stage } })).status, 200);
  assert.equal((await select(h, stage, [{ id: 'photoID' }])).status, 200);
});

test('sign-out atomically disables playback, including a selected file already streaming', async t => {
  const h = await harness(t);
  const { pairing, connection } = await grant(h);
  const headers = authorization(connection.token);
  const aborted = Promise.withResolvers();
  h.google.mediaResponse = ({ signal }) => new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(Buffer.from('012'));
      signal.addEventListener('abort', () => {
        aborted.resolve();
        controller.error(new Error('closed synthetic upstream'));
      }, { once: true });
    },
  }), { status: 206, headers: { 'Content-Range': 'bytes 0-11/' + movie.length, 'Content-Length': '12' } });
  const response = await h.request('/v1/files/MovieID', { headers: { ...headers, Range: 'bytes=0-11' } });
  assert.equal(response.status, 206);
  const reader = response.body.getReader();
  assert.deepEqual(Buffer.from((await reader.read()).value), Buffer.from('012'));
  assert.equal((await h.request('/v1/connection', { method: 'DELETE', headers })).status, 204);
  await aborted.promise;
  await assert.rejects(() => reader.read());
  assert.equal((await h.request('/v1/files/MovieID', { headers })).status, 401);
  assert.equal((await poll(h, pairing)).status, 404);
  assert.ok(h.google.calls.every(call => !call.url.pathname.includes('revoke')));
});
