import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir, readFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';

const harness = fileURLToPath(new URL('./library-journey.mjs', import.meta.url));
const outputs = resolve('.artifacts/vega-startup-probe-contract-' + Date.now());
const unsupported = 'Protected settings are unavailable. Try again. (MV06:not-supported)';
// This transport stub tests the harness only. Its output is not device evidence.
async function runProbe(name, {error, home = false, banner = false, retryEnabled = true, fixturePackage = false, fatalOverlay = false} = {}) {
  const output = resolve(outputs, name);
  await mkdir(output, {recursive: true});
  const requests = [];
  const elements = new Map();
  if (error) { elements.set('startup-error', {text: error}); elements.set('startup-retry', {enabled: retryEnabled}); }
  if (home) { for (const id of ['action-sources', 'library-grid', 'library-section', 'library-search']) { elements.set(id, {}); } }
  if (banner) { elements.set('fixture-build-banner', {text: 'VIRTUAL DEVICE TEST BUILD'}); }
  const server = createServer(async (request, response) => {
    const chunks = []; for await (const chunk of request) { chunks.push(chunk); }
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : undefined;
    requests.push({method: request.method, path: request.url});
    let value;
    if (request.url === '/session' && request.method === 'POST') {
      assert.equal(body.capabilities.alwaysMatch['appium:appURL'], 'com.dineshdevkota.cinevault.main');
      value = {sessionId: 'contract-test'};
    } else if (request.url.endsWith('/elements') || request.url.endsWith('/element')) {
      const id = body.value.match(/@test_id='([^']+)'/)?.[1];
      const found = fatalOverlay && body.value === "//app[@appName='com.dineshdevkota.cinevault']//*[@role='text' and text='Uncaught Error']"
        ? {'element-6066-11e4-a52e-4f735466cecf': 'fatal-heading'}
        : elements.has(id) ? {'element-6066-11e4-a52e-4f735466cecf': id} : undefined;
      value = request.url.endsWith('/elements') ? found ? [found] : [] : found;
    } else if (/\/element\/[^/]+\/text$/.test(request.url)) {
      value = elements.get(request.url.split('/').at(-2))?.text ?? '';
    } else if (/\/element\/[^/]+\/enabled$/.test(request.url)) {
      value = elements.get(request.url.split('/').at(-2))?.enabled ?? true;
    } else if (request.url.endsWith('/source')) { value = '<contract-test-transport />'; }
    else if (request.url.endsWith('/screenshot')) { value = Buffer.from('contract test, not a device screenshot').toString('base64'); }
    else if (request.method === 'DELETE' && request.url === '/session/contract-test') { value = null; }
    else { response.writeHead(500, {'Content-Type': 'application/json'}); response.end(JSON.stringify({value: {error: 'unexpected command', message: request.url}})); return; }
    response.writeHead(200, {'Content-Type': 'application/json'}); response.end(JSON.stringify({value}));
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  try {
    const child = spawn(process.execPath, [harness], {env: {...process.env,
      APPIUM_URL: `http://127.0.0.1:${server.address().port}`, MEDIA_VAULT_E2E_STARTUP_CHECK_ONLY: '1',
      MEDIA_VAULT_E2E_FIXTURE_ONLY: '1', MEDIA_VAULT_E2E_OUTPUT: output,
      MEDIA_VAULT_E2E_PACKAGE_ID: fixturePackage ? 'com.dineshdevkota.mediavault.vvdfixture' : 'com.dineshdevkota.cinevault',
      MEDIA_VAULT_E2E_NAS_ENDPOINT: ''}, stdio: ['ignore', 'pipe', 'pipe']});
    let stderr = ''; child.stderr.on('data', chunk => { stderr += chunk; }); child.stdout.resume();
    const code = await new Promise((done, reject) => { child.once('error', reject); child.once('close', done); });
    const result = await readFile(resolve(output, 'results.json'), 'utf8').then(JSON.parse).catch(() => undefined);
    assert.equal(requests.some(value => /\/(click|value)$/.test(value.path)), false, 'Startup probe must not enter credentials or execute NAS actions.');
    return {code, result, stderr, requests};
  } finally { await new Promise(done => server.close(done)); }
}
function assertProbeReport(result) {
  assert.equal(result.mode, 'production-startup-probe');
  assert.equal(result.packageId, 'com.dineshdevkota.cinevault');
  assert.equal(result.buildKind, 'production');
  assert.equal(result.libraryJourneyCount, 0);
  assert.equal(result.secureStorageVerification, 'not-verified');
  assert.equal(result.results.length, 1);
  assert.equal(result.results[0].name, 'production-startup-probe');
}

test('production startup availability does not claim persistence or NAS verification', async () => {
  const {code, result} = await runProbe('supported', {home: true});
  assert.equal(code, 0); assertProbeReport(result);
  assert.equal(result.startupProbe.outcome, 'native-storage-available');
  assert.equal(result.startupProbe.nativeStorageAvailable, true);
  assert.equal(result.results[0].passed, true);
});
test('exact unsupported keystore state is accepted only while home stays hidden and Retry is enabled', async () => {
  const {code, result} = await runProbe('unsupported', {error: unsupported});
  assert.equal(code, 0); assertProbeReport(result);
  assert.equal(result.startupProbe.outcome, 'unsupported-on-virtual-device');
  assert.equal(result.startupProbe.hardwareRequired, true);
  assert.equal(result.startupProbe.homeExposed, false);
  assert.equal(result.startupProbe.retryEnabled, true);
});
for (const [name, state] of [
  ['different-error', {error: 'Protected settings are unavailable. Try again. (MV06:security)'}],
  ['home-leak', {error: unsupported, home: true}],
  ['disabled-retry', {error: unsupported, retryEnabled: false}],
  ['fixture-banner', {error: unsupported, banner: true}],
]) {
  test(`production startup probe rejects ${name}`, async () => {
    const {code, result} = await runProbe(name, state);
    assert.notEqual(code, 0); assertProbeReport(result);
    assert.equal(result.results[0].passed, false);
    assert.equal(result.startupProbe.outcome, 'not-completed');
  });
}
test('an uncaught error overlay fails even when valid home controls remain behind it', async () => {
  const {code, result, requests} = await runProbe('fatal-overlay', {home: true, fatalOverlay: true});
  assert.notEqual(code, 0); assertProbeReport(result);
  assert.equal(result.results[0].passed, false);
  assert.match(result.results[0].error, /uncaught runtime error overlay/);
  assert.equal(result.startupProbe.outcome, 'not-completed');
  assert.equal(requests.some(request => request.path.includes('/fatal-heading/text')), false, 'Never read the error body.');
});
test('startup-only mode rejects the fixture package before creating an Appium session', async () => {
  const {code, requests, result, stderr} = await runProbe('fixture-package', {fixturePackage: true});
  assert.notEqual(code, 0); assert.equal(requests.length, 0); assert.equal(result, undefined);
  assert.match(stderr, /startup-only probe accepts only the production package/);
});
