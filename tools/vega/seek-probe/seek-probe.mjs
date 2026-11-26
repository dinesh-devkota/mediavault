import assert from 'node:assert/strict';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';

assert.equal(process.env.GITHUB_ACTIONS, 'true', 'Use an isolated GitHub Actions runner.');
assert(process.env.PROBE_DEVICE_INFO, 'Provide freshly captured device identity.');
const device = JSON.parse(await readFile(process.env.PROBE_DEVICE_INFO, 'utf8'));
assert.equal(device.simulated, true, 'This diagnostic cannot attach to physical devices.');
assert.equal(device.architecture, 'x86_64');
const server = process.env.APPIUM_URL ?? 'http://127.0.0.1:4723';
const parsed = new URL(server);
assert(['localhost', '127.0.0.1'].includes(parsed.hostname) && !parsed.username && !parsed.password);
const packageId = 'com.dineshdevkota.mediavault.seekprobe';
const output = resolve(process.env.PROBE_OUTPUT ?? '.artifacts/vega-seek-probe/runtime');
await mkdir(output, {recursive: true});
const app = `//app[@appName='${packageId}']`;
const elementKey = 'element-6066-11e4-a52e-4f735466cecf';
let session;
let result = {diagnosticOnly: true, packageId, outcome: 'incomplete'};
const sleep = ms => new Promise(done => setTimeout(done, ms));
async function command(method, path, body) {
  const response = await fetch(server + path, {method, headers: {'Content-Type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(10_000)});
  const value = await response.json();
  assert(response.ok && !value.value?.error, value.value?.message ?? 'Appium command failed');
  return value.value;
}
const call = (method, path, body) => command(method, `/session/${session}${path}`, body);
async function text(id) {
  assert(/^probe-[a-z]+$/.test(id));
  const found = await call('POST', '/elements', {using: 'xpath', value: `${app}//*[@test_id='${id}']`});
  if (found.length !== 1) { return undefined; }
  return call('GET', `/element/${found[0][elementKey]}/text`);
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
    'kepler:device': 'vda://default', 'appium:appURL': packageId + '.main',
  }}});
  session = created.sessionId; assert(session);
  const deadline = Date.now() + 600_000;
  let bannerVerified = false, complete = false, captured = 0;
  while (Date.now() < deadline) {
    const banner = await text('probe-banner');
    if (banner !== undefined) { assert.equal(banner, 'VIRTUAL DEVICE SEEK PROBE - synthetic media only'); bannerVerified = true; }
    const reportText = await text('probe-report');
    if (reportText) {
      const report = JSON.parse(reportText);
      result = {packageId, ...report};
      await writeFile(resolve(output, 'results.json'), JSON.stringify(result, null, 2));
      if (report.cases.length > captured) { captured = report.cases.length; await capture(`case-${captured}-completed`); }
      if (await text('probe-status') === 'Complete') { complete = true; break; }
    }
    await sleep(500);
  }
  assert(bannerVerified && complete, 'The isolated seek matrix did not complete within its bound');
  await capture('final');
  assert.equal(result.cases.length, 4, 'All four fresh-player cases must execute');
  assert.deepEqual(result.cases.map(value => value.id), ['mkv-paused', 'mkv-playing', 'mp4-paused', 'mp4-playing']);
  assert.equal(result.outcome, 'passed', 'One or more direct seek cases failed; see per-case evidence');
  assert(result.cases.every(value => value.passed && value.failures.length === 0));
} catch (error) {
  result = {...result, outcome: 'failed', harnessError: String(error)}; process.exitCode = 1;
  if (session) { await capture('failure').catch(reason => { result.captureError = String(reason); }); }
} finally {
  await writeFile(resolve(output, 'results.json'), JSON.stringify(result, null, 2));
  if (session) { await call('DELETE', '').catch(() => {}); }
}
console.log(JSON.stringify({outcome: result.outcome, cases: result.cases?.map(value => ({id: value.id, passed: value.passed})), output}));
