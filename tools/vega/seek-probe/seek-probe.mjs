import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {promisify} from 'node:util';

assert.equal(process.env.GITHUB_ACTIONS, 'true', 'Use an isolated GitHub Actions runner.');
assert(process.env.PROBE_DEVICE_INFO, 'Provide freshly captured device identity.');
const device = JSON.parse(await readFile(process.env.PROBE_DEVICE_INFO, 'utf8'));
assert.equal(device.simulated, true, 'This diagnostic cannot attach to physical devices.');
assert.equal(device.architecture, 'x86_64');
const server = process.env.APPIUM_URL ?? 'http://127.0.0.1:4723';
const parsed = new URL(server);
assert(['localhost', '127.0.0.1'].includes(parsed.hostname) && !parsed.username && !parsed.password);
const packageId = 'com.dineshdevkota.mediavault.seekprobe';
const bannerText = 'VIRTUAL DEVICE SEEK PROBE - synthetic media only';
const waitingStatus = 'Waiting to start the isolated comparison';
const output = resolve(process.env.PROBE_OUTPUT ?? '.artifacts/vega-seek-probe/runtime');
await mkdir(output, {recursive: true});
const app = `//app[@appName='${packageId}']`;
const elementKey = 'element-6066-11e4-a52e-4f735466cecf';
let session;
const startup = {stage: 'appium-session'};
let result = {diagnosticOnly: true, packageId, startup, outcome: 'incomplete'};
const sleep = ms => new Promise(done => setTimeout(done, ms));
async function command(method, path, body) {
  const response = await fetch(server + path, {method, headers: {'Content-Type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(10_000)});
  const value = await response.json();
  assert(response.ok && !value.value?.error, value.value?.message ?? 'Appium command failed');
  return value.value;
}
const call = (method, path, body) => command(method, `/session/${session}${path}`, body);
function find(id, focused = false) {
  assert(/^probe-[a-z]+$/.test(id));
  const focus = focused ? "[@focused='true']" : '';
  return call('POST', '/elements', {using: 'xpath', value: `${app}//*[@test_id='${id}']${focus}`});
}
async function text(id) {
  const found = await find(id);
  if (found.length !== 1) { return undefined; }
  return call('GET', `/element/${found[0][elementKey]}/text`);
}
async function waitFor(check, ms, message) {
  const deadline = Date.now() + ms;
  do {
    const value = await check();
    if (value) { return value; }
    await sleep(200);
  } while (Date.now() < deadline);
  throw new Error(message);
}
async function launch() {
  // The SDK CLI owns app activation. The Appium session is already connected,
  // and omits the optional appURL that could request another launch.
  const run = promisify(execFile);
  const args = ['device', 'launch-app', '--device', 'VirtualDevice', '--appName', packageId + '.main'];
  const writeLog = ({stdout = '', stderr = ''}) => writeFile(resolve(output, 'launch.log'), stdout + stderr);
  try {
    await writeLog(await run('vega', args, {timeout: 25_000, maxBuffer: 65_536}));
  } catch (error) {
    await writeLog(error);
    throw error;
  }
}
async function capture(name) {
  const source = await call('GET', '/source');
  await writeFile(resolve(output, name + '.xml'), source);
  assert(!/Uncaught Error|__fbBatchedBridgeConfig|Invariant Violation/.test(source), 'Fatal overlay invalidates the probe');
  await writeFile(resolve(output, name + '.png'), Buffer.from(await call('GET', '/screenshot'), 'base64'));
  await sleep(150);
  await writeFile(resolve(output, name + '.next.png'), Buffer.from(await call('GET', '/screenshot'), 'base64'));
}
try {
  const created = await command('POST', '/session', {capabilities: {alwaysMatch: {
    platformName: 'Kepler', 'appium:automationName': 'automation-toolkit/JSON-RPC',
    'kepler:device': 'vda://default',
  }}});
  session = created.sessionId; assert(session);
  startup.stage = 'launch';
  await launch();
  startup.stage = 'waiting-for-banner';
  const banner = await waitFor(() => text('probe-banner'), 15_000, 'The probe UI did not appear after the SDK launched its component.');
  assert.equal(banner, bannerText);
  await capture('startup');
  startup.stage = 'starting-comparison';
  const start = await find('probe-start');
  assert.equal(start.length, 1, 'Expected one probe start button.');
  await call('POST', '/execute/sync', {script: 'jsonrpc: setFocus', args: [[{id: Number(start[0][elementKey])}]]});
  await waitFor(async () => (await find('probe-start', true)).length === 1, 4000, 'The probe start button did not receive remote focus.');
  await call('POST', '/execute/sync', {script: 'jsonrpc: injectInputKeyEvent', args: [[{inputKeyEvent: '96', holdDuration: 30}]]});
  await waitFor(async () => {
    const status = await text('probe-status');
    return status && status !== waitingStatus;
  }, 4000, 'The comparison did not accept the remote start action.');
  startup.stage = 'matrix';
  const deadline = Date.now() + 600_000;
  let complete = false, captured = 0;
  while (Date.now() < deadline) {
    const reportText = await text('probe-report');
    if (reportText) {
      const report = JSON.parse(reportText);
      result = {packageId, startup, ...report};
      await writeFile(resolve(output, 'results.json'), JSON.stringify(result, null, 2));
      if (report.cases.length > captured) { captured = report.cases.length; await capture(`case-${captured}-completed`); }
      if (await text('probe-status') === 'Complete') { complete = true; break; }
    }
    await sleep(500);
  }
  assert(complete, 'The isolated seek matrix did not complete within its bound');
  await capture('final');
  if (result.infrastructureError) { throw new Error(result.infrastructureError); }
  assert.equal(result.cases.length, 4, 'All four fresh-player cases must execute');
  assert.deepEqual(result.cases.map(value => value.id), ['mkv-paused', 'mkv-playing', 'mp4-paused', 'mp4-playing']);
  assert.equal(result.outcome, 'passed', 'One or more direct seek cases failed; see per-case evidence');
  assert(result.cases.every(value => value.passed && value.failures.length === 0));
  startup.stage = 'finished';
} catch (error) {
  result = {...result, outcome: 'failed', harnessError: String(error)}; process.exitCode = 1;
  if (session) { await capture('failure').catch(reason => { result.captureError = String(reason); }); }
} finally {
  await writeFile(resolve(output, 'results.json'), JSON.stringify(result, null, 2));
  if (session) { await call('DELETE', '').catch(() => {}); }
}
console.log(JSON.stringify({outcome: result.outcome, cases: result.cases?.map(value => ({id: value.id, passed: value.passed})), output}));
