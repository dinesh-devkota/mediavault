import assert from 'node:assert/strict';
import {mkdir, writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';

// Real Appium/Vega automation, using Amazon's documented W3C endpoints and JSON-RPC D-pad API.
// https://developer.amazon.com/docs/vega/2.0/appium-sessions
// https://developer.amazon.com/docs/vega/2.0/appium-commands
const server = process.env.APPIUM_URL ?? 'http://127.0.0.1:4723';
const endpoint = process.env.MEDIA_VAULT_E2E_NAS_ENDPOINT;
assert(endpoint?.startsWith('smb://') && endpoint.endsWith('/MEDIALIBRARY'), 'Set a device-accessible synthetic MEDIALIBRARY SMB endpoint.');
assert.equal(process.env.MEDIA_VAULT_E2E_FIXTURE_ONLY, '1', 'Run only on a fresh disposable app installation with synthetic fixtures.');
const output = resolve(process.env.MEDIA_VAULT_E2E_OUTPUT ?? '.artifacts/vega-ui');
await mkdir(output, {recursive: true});
let session;
const results = [];
const sleep = ms => new Promise(done => setTimeout(done, ms));
const elementKey = 'element-6066-11e4-a52e-4f735466cecf';
async function command(method, path, body) {
  const response = await fetch(server + path, {method, headers: {'Content-Type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(45_000)});
  const payload = await response.json();
  if (!response.ok || payload.value?.error) { throw new Error(payload.value?.message ?? `Appium command failed (${response.status}).`); }
  return payload.value;
}
const call = (method, path, body) => command(method, `/session/${session}${path}`, body);
const literal = value => { assert(!value.includes("'"), 'Test selectors use fixed synthetic values.'); return `'${value}'`; };
const byID = id => `//*[@test_id=${literal(id)}]`;
const exists = async xpath => (await call('POST', '/elements', {using: 'xpath', value: xpath})).length > 0;
async function waitFor(check, message, timeout = 30_000) {
  const deadline = Date.now() + timeout;
  do { if (await check()) { return; } await sleep(250); } while (Date.now() < deadline);
  throw new Error(message);
}
async function element(xpath) {
  await waitFor(() => exists(xpath), `Missing UI element: ${xpath}`);
  return (await call('POST', '/element', {using: 'xpath', value: xpath}))[elementKey];
}
async function click(id) { await clickXPath(byID(id)); }
async function clickXPath(xpath) {
  const id = await element(xpath);
  assert(await call('GET', `/element/${id}/enabled`), 'Target action must be enabled.');
  await call('POST', `/element/${id}/click`, {});
}
async function key(code) {
  await call('POST', '/execute/sync', {script: 'jsonrpc: injectInputKeyEvent', args: [[{inputKeyEvent: String(code), holdDuration: 30}]]});
}
async function enter(id, value, previous = '') {
  const target = await element(byID(id));
  await call('POST', `/element/${target}/click`, {});
  // Use documented Linux key events for editing; the Vega command reference does not promise element.clear().
  if (previous) { await key(107); for (let i = 0; i < previous.length; i++) { await key(14); } }
  await call('POST', `/element/${target}/value`, {text: value, value: [...value]});
  if (!/password|pin/.test(id)) { await waitFor(async () => (await text(id)) === value, `The text field did not acknowledge the complete input: ${id}`); }
}
async function text(id) { return call('GET', `/element/${await element(byID(id))}/text`); }
async function addSource(name, address) {
  await click('action-sources'); await click('action-add-source'); await click('action-nas-smb');
  await enter('source-name', name); await enter('source-address', address);
  await enter('source-username', 'cinevault'); await enter('source-password', 'fixture-only');
  await click('source-connect'); await click('source-save');
  await waitFor(async () => {
    const page = await call('GET', '/source'); return page.includes('Last scan:') && !page.includes('Last scan: Never');
  }, 'The first scan must complete without pressing Scan again.', 120_000);
  await click('action-back');
}
async function position() {
  if (await exists(byID('player-error'))) { throw new Error(await text('player-error')); }
  const match = (await text('player-position')).match(/(\d+):(\d+)\s*\//);
  assert(match, 'The player must expose an actual elapsed position.');
  return Number(match[1]) * 60 + Number(match[2]);
}
async function capture(name) {
  if (await exists('//*[starts-with(@test_id,"field-") and contains(@test_id,"pin")]') || await exists(byID('source-password'))) {
    await writeFile(resolve(output, `${name}.capture-skipped.txt`), 'Visual and hierarchy evidence omitted while protected entry fields were on screen.');
    return;
  }
  const source = await call('GET', '/source');
  await writeFile(resolve(output, `${name}.xml`), source);
  const screenshot = await call('GET', '/screenshot');
  await writeFile(resolve(output, `${name}.png`), Buffer.from(screenshot, 'base64'));
}
async function step(name, run) {
  const started = Date.now();
  try { await run(); await capture(name); results.push({name, passed: true, durationMs: Date.now() - started}); }
  catch (error) {
    const sanitized = String(error).replace(/482619|000000|fixture-only/g, '[fixture credential]');
    results.push({name, passed: false, error: sanitized, durationMs: Date.now() - started});
    await capture(name + '-failure').catch(() => {}); throw new Error(sanitized);
  }
}
const feature = 'media-group-tmdb:910001', sequel = 'media-group-tmdb:910002';
try {
  const created = await command('POST', '/session', {capabilities: {alwaysMatch: {
    platformName: 'Kepler', 'appium:automationName': 'automation-toolkit/JSON-RPC',
    'kepler:device': process.env.VEGA_DEVICE ?? 'vda://default', 'appium:appURL': 'com.dineshdevkota.cinevault.main',
  }}});
  session = created.sessionId;
  assert(session, 'Appium must return a real device session.');
  await step('01-connect-and-scan', async () => {
    await addSource('Fixture NAS', endpoint); await element(byID(feature)); await element(byID(sequel));
    assert.equal((await call('POST', '/elements', {using: 'xpath', value: '//*[starts-with(@test_id,"media-group-")]'})).length, 5,
      'Five visible grouped titles: two movies, one show, one invalid-metadata movie, one standalone photo. Sidecar artwork must be suppressed.');
  });
  await step('02-edition-detail', async () => {
    await click(feature);
    await clickXPath('//*[starts-with(@test_id,"item-open-") and contains(@test_id,"Directors Cut.mp4")]');
    assert.equal(await text('detail-title'), 'Library Feature');
    assert.match(await text('detail-file-name'), /Directors Cut\.mp4/);
    await element(byID('action-play'));
  });
  await step('03-create-edit-collection', async () => {
    await click('action-back'); await click('action-back'); await click('action-select-titles');
    await click(feature); await click(sequel); await click('action-mark-watched'); await click('action-add-to-collection');
    await enter('field-new-collection-name', 'Weekend'); await click('action-create-collection');
    await click('action-weekend-2-titles'); // Finish adding the selected titles and return to the library.
    await click('action-collections'); await click('action-weekend-2-titles');
    await enter('field-collection-name', 'Movie Night', 'Weekend'); await click('action-save-name');
    await click('action-manage-titles'); await click('action-library-sequel'); await click('action-done');
    await element(byID(feature)); assert.equal(await exists(byID(sequel)), false, 'Removing a title must immediately update the collection.');
    await click('action-back'); await click('action-back'); await click('action-done-selecting');
  });
  await step('04-show-season-episode', async () => {
    await click('action-tv-shows');
    await clickXPath('//*[starts-with(@test_id,"media-group-show:") and contains(@test_id,":tmdb:920001")]');
    await click('action-season-1');
    await clickXPath('//*[starts-with(@test_id,"item-open-") and contains(@test_id,"Library Show.S01E01.mp4")]');
    assert.equal(await text('detail-title'), 'The Local Episode');
    await click('action-back'); await click('action-back'); await click('action-back');
  });
  await step('05-standalone-photo', async () => {
    await click('action-photos');
    await clickXPath('//*[starts-with(@test_id,"media-group-") and contains(@test_id,":Photos/poster.png")]');
    await element(byID('action-start-slideshow')); await element(byID('photo-loaded'));
    assert(!(await call('GET', '/source')).includes('could not be'), 'The actual photo must load without an error.');
    await click('action-back'); await click('action-all-media');
  });
  await step('06-mkv-remote-playback', async () => {
    await addSource('Formats NAS', endpoint.replace(/MEDIALIBRARY$/, 'FORMATPLAYBACK'));
    await clickXPath('//*[starts-with(@test_id,"media-group-") and contains(@test_id,":Controls.mkv")]'); await click('action-play');
    await waitFor(async () => await position() >= 1, 'The real MKV decoder must advance.', 40_000);
    await key(164); await element(byID('action-play')); // Linux KEY_PLAYPAUSE, while an ordinary control has focus.
    const paused = await position(); await sleep(1500); assert(Math.abs(await position() - paused) <= 1, 'Pause must stop the clock.');
    await key(208); await waitFor(async () => await position() >= paused + 25, 'Remote fast-forward must seek.');
    const advanced = await position(); await key(168); await waitFor(async () => await position() <= advanced - 7, 'Remote rewind must seek.');
    await key(164); await element(byID('action-pause')); await capture('06-mkv-playing');
    await key(158); await element(byID('detail-title')); await element(byID('action-resume'));
    await click('action-back');
  });
  await step('07-continuous-television', async () => {
    await addSource('Playback NAS', endpoint.replace(/MEDIALIBRARY$/, 'MEDIAPLAYBACK'));
    await click('action-tv-shows'); await click('media-group-show:fixture show|'); await click('action-season-1');
    await clickXPath('//*[starts-with(@test_id,"item-open-") and contains(@test_id,"Fixture Show.S01E01.mp4")]');
    await click('action-play'); await click('action-auto-play-next-episode-off');
    await waitFor(() => exists(byID('action-stop-after-this-episode')), 'Episode completion must offer a cancellable countdown.', 40_000);
    await click('action-stop-after-this-episode'); await element(byID('action-play-next-fixture-show'));
    await sleep(11000); assert.match(await text('player-file-name'), /S01E01/, 'Stopping the countdown must leave the current episode.');
    await click('action-play-next-fixture-show');
    await waitFor(async () => (await call('GET', '/source')).includes('Fixture Show.S01E02.mp4'), 'Manual Play Next must open episode two.');
    await waitFor(async () => (await call('GET', '/source')).includes('Fixture Show.S01E04.mp4'), 'Automatic next episode must advance across the missing episode three.', 55_000);
    await capture('07-next-episode-playing'); await key(158);
    await click('action-back'); await click('action-back'); await click('action-back'); await click('action-all-media');
  });
  await step('08-household-filtering', async () => {
    await click('action-sources'); await click('action-set-up-household-profiles');
    await enter('field-administrator-pin', '482619'); await enter('field-confirm-administrator-pin', '482619');
    await enter('field-profile-name', 'Kids'); await click('action-fixture-nas'); await click('action-save-profile');
    await click('action-everyone'); await click('action-kids'); await click('action-continue');
    await element(byID(feature));
    assert.equal(await exists('//*[starts-with(@test_id,"media-group-") and contains(@test_id,"Invalid Metadata.mp4")]'), false,
      'A restricted profile must not receive a title with malformed/unknown rating.');
    assert.equal(await exists(byID('action-sources')), false, 'A viewer cannot manage credentials or household permissions.');
    await click('action-collections');
    assert.equal(await exists(byID('action-movie-night-1-title')), false, 'Collections belong to the creating profile.');
  });
  await step('09-pin-rejection-and-unlock', async () => {
    await click('action-back'); await click('action-kids'); await click('action-everyone-pin-protected');
    await enter('field-profile-pin', '000000'); await click('action-continue');
    await waitFor(async () => (await call('GET', '/source')).includes('That PIN did not match'), 'An incorrect PIN must be rejected.');
    assert.equal(await exists(byID('library-grid')), false, 'Failed PIN entry must not reveal the library.');
    await enter('field-profile-pin', '482619', '000000'); await click('action-continue');
    await element(byID(feature));
    await element(byID('action-sources'));
    // Capture only after the app has cleared the PIN field and restored the library.
  });
  await step('10-keystore-and-source-persistence', async () => {
    await call('POST', '/appium/device/terminate_app', {appId: 'com.dineshdevkota.cinevault'});
    await call('POST', '/appium/device/activate_app', {appId: 'com.dineshdevkota.cinevault.main'});
    await element(byID('action-everyone-pin-protected'));
    assert.equal(await exists(byID('library-grid')), false, 'Restart must keep the protected household locked.');
    await click('action-everyone-pin-protected'); await enter('field-profile-pin', '482619'); await click('action-continue');
    await element(byID(feature)); await click('action-sources');
    const scan = await element(byID('action-scan-fixture-nas'));
    const before = await text('source-scan-Fixture NAS');
    await click('action-scan-fixture-nas');
    await waitFor(async () => !await call('GET', `/element/${scan}/enabled`), 'The saved NAS scan must begin.');
    await waitFor(() => call('GET', `/element/${scan}/enabled`), 'The saved NAS scan must finish.', 120_000);
    const after = await call('GET', '/source');
    assert.notEqual(await text('source-scan-Fixture NAS'), before, 'The completed scan must update its saved timestamp.');
    assert(!after.includes('Reconnect this source') && !after.includes('rejected this account'), 'Saved source credentials must still work.');
    await click('action-back'); await element(byID(feature));
  });
} finally {
  await writeFile(resolve(output, 'results.json'), JSON.stringify({executedOnDevice: Boolean(session), results}, null, 2));
  if (session) { await call('DELETE', '').catch(() => {}); }
}
