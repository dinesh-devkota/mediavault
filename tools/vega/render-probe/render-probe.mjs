import assert from 'node:assert/strict';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';

assert.equal(process.env.GITHUB_ACTIONS, 'true', 'Use an isolated GitHub Actions runner.');
assert(process.env.PROBE_DEVICE_INFO, 'Provide freshly captured device identity.');
const device = JSON.parse(await readFile(process.env.PROBE_DEVICE_INFO, 'utf8'));
assert.equal(device.simulated, true, 'This diagnostic cannot attach to physical devices.');
assert.equal(device.architecture, 'x86_64');
const server = process.env.APPIUM_URL ?? 'http://127.0.0.1:4723';
const serverURL = new URL(server);
assert(['localhost', '127.0.0.1'].includes(serverURL.hostname) && !serverURL.username && !serverURL.password);
const packageId = 'com.dineshdevkota.mediavault.renderprobe';
const output = resolve(process.env.PROBE_OUTPUT ?? '.artifacts/vega-render-probe/runtime');
await mkdir(output, {recursive: true});
const key = 'element-6066-11e4-a52e-4f735466cecf';
const app = `//app[@appName='${packageId}']`;
const byID = id => { assert(/^[a-z0-9-]+$/.test(id)); return `${app}//*[@test_id='${id}']`; };
const targets = ['swatch-square-object', 'swatch-square-array', 'swatch-round-object', 'swatch-round-array',
  'image-plain', 'image-clip-parent', 'image-clipped', 'focus-round', 'focus-square'];
const report = {diagnosticOnly: true, packageId, outcome: 'incomplete', captures: [], focusRequests: []};
const sleep = ms => new Promise(done => setTimeout(done, ms));
let session;
async function command(method, path, body) {
  const response = await fetch(server + path, {method, headers: {'Content-Type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(10_000)});
  const result = await response.json();
  assert(response.ok && !result.value?.error, result.value?.message ?? 'Appium command failed.');
  return result.value;
}
const call = (method, path, body) => command(method, `/session/${session}${path}`, body);
const find = id => call('POST', '/elements', {using: 'xpath', value: byID(id)});
async function element(id) {
  const values = await find(id); assert.equal(values.length, 1, `Expected one ${id}`); return values[0][key];
}
const text = async id => call('GET', `/element/${await element(id)}/text`);
const focused = async id => await call('GET', `/element/${await element(id)}/attribute/UiObject:focused`) === 'true';
async function waitFor(check, message, ms = 3000) {
  const deadline = Date.now() + ms;
  do { if (await check()) { return; } await sleep(100); } while (Date.now() < deadline);
  throw new Error(message);
}
async function capture(name) {
  const source = await call('GET', '/source');
  assert(!/Uncaught Error|__fbBatchedBridgeConfig|Invariant Violation/.test(source), 'A fatal overlay invalidates the capture.');
  const states = [];
  for (const testID of targets) {
    const id = await element(testID);
    states.push({testID, rect: await call('GET', `/element/${id}/rect`),
      ...(testID.startsWith('focus-') ? {nativeFocused: await focused(testID)} : {})});
  }
  const imageStatus = await text('image-status'), focusStatus = await text('focus-status');
  await writeFile(resolve(output, `${name}.xml`), source);
  await writeFile(resolve(output, `${name}.png`), Buffer.from(await call('GET', '/screenshot'), 'base64'));
  await sleep(150);
  await writeFile(resolve(output, `${name}.next.png`), Buffer.from(await call('GET', '/screenshot'), 'base64'));
  await writeFile(resolve(output, `${name}.after.xml`), await call('GET', '/source'));
  const capture = {name, states, imageStatus, focusStatus};
  report.captures.push(capture);
  await writeFile(resolve(output, `${name}.states.json`), JSON.stringify(capture, null, 2));
}
try {
  const created = await command('POST', '/session', {capabilities: {alwaysMatch: {
    platformName: 'Kepler', 'appium:automationName': 'automation-toolkit/JSON-RPC',
    'kepler:device': 'vda://default', 'appium:appURL': packageId + '.main',
  }}});
  session = created.sessionId; assert(session);
  await waitFor(async () => (await find('probe-banner')).length === 1, 'The isolated probe did not appear.', 10_000);
  assert.equal(await text('probe-banner'), 'VIRTUAL DEVICE RENDER PROBE - no accounts or network');
  await waitFor(async () => !String(await text('image-status')).includes('waiting'), 'Bundled images did not complete loading.', 10_000);
  await capture('00-static');
  assert.equal(await text('image-status'), 'Images: plain loaded; clipped loaded', 'Bundled image load events must succeed.');
  const id = await element('focus-round');
  const rpc = await call('POST', '/execute/sync', {script: 'jsonrpc: setFocus', args: [[{id: Number(id)}]]});
  report.focusRequests.push({testID: 'focus-round', rpc});
  await waitFor(() => focused('focus-round'), 'Round control did not acquire native focus.', 1000);
  await waitFor(async () => await text('focus-status') === 'Focused: round', 'React did not acknowledge round focus.');
  await capture('01-round-focused');
  await call('POST', '/execute/sync', {script: 'jsonrpc: injectInputKeyEvent', args: [[{inputKeyEvent: '106', holdDuration: 30}]]});
  await waitFor(() => focused('focus-square'), 'Right did not move native focus to the square control.', 1000);
  await waitFor(async () => await text('focus-status') === 'Focused: square', 'React did not acknowledge square focus.');
  await capture('02-square-focused');
  report.outcome = 'captured'; // Native focus success is not proof that pixels are visible.
} catch (error) {
  report.outcome = 'failed'; report.error = String(error); process.exitCode = 1;
  if (session) { await capture('failure').catch(reason => { report.captureError = String(reason); }); }
} finally {
  await writeFile(resolve(output, 'results.json'), JSON.stringify(report, null, 2));
  if (session) { await call('DELETE', '').catch(() => {}); }
}
console.log(JSON.stringify({outcome: report.outcome, error: report.error, output}));
