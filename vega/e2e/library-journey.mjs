import assert from 'node:assert/strict';
import {mkdir, writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';

// Real Appium/Vega automation, using Amazon's documented W3C endpoints and JSON-RPC D-pad API.
// https://developer.amazon.com/docs/vega/2.0/appium-sessions
// https://developer.amazon.com/docs/vega/2.0/appium-commands
const server = process.env.APPIUM_URL ?? 'http://127.0.0.1:4723';
const startupCheckOnly = process.env.MEDIA_VAULT_E2E_STARTUP_CHECK_ONLY === '1';
const endpoint = process.env.MEDIA_VAULT_E2E_NAS_ENDPOINT;
if (!startupCheckOnly) {
  assert(endpoint?.startsWith('smb://') && endpoint.endsWith('/MEDIALIBRARY'), 'Set a device-accessible synthetic MEDIALIBRARY SMB endpoint.');
}
assert.equal(process.env.MEDIA_VAULT_E2E_FIXTURE_ONLY, '1', 'Run only on a fresh disposable app installation with synthetic fixtures.');
const packageId = process.env.MEDIA_VAULT_E2E_PACKAGE_ID ?? 'com.dineshdevkota.cinevault';
assert(['com.dineshdevkota.cinevault', 'com.dineshdevkota.mediavault.vvdfixture'].includes(packageId), 'Use the explicit production or isolated virtual-device fixture package ID.');
const fixtureBuild = packageId === 'com.dineshdevkota.mediavault.vvdfixture';
assert(!startupCheckOnly || !fixtureBuild, 'The startup-only probe accepts only the production package ID.');
const output = resolve(process.env.MEDIA_VAULT_E2E_OUTPUT ?? '.artifacts/vega-ui');
await mkdir(output, {recursive: true});
let session;
let fixtureBannerVerified = false;
let fixtureWarningsDismissed = 0;
let startupProbe = startupCheckOnly ? {outcome: 'not-completed'} : null;
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
async function nativeFocused(xpath) {
  const matches = await call('POST', '/elements', {using: 'xpath', value: xpath});
  if (!matches.length) { return false; }
  // The pinned driver maps UiObject:focused to the native isFocused RPC.
  // Its true value is the string "true"; false is null. The bare "focused"
  // attribute is unrecognized, and XPath reflects serialized publisher state.
  const value = await call('GET', `/element/${matches[0][elementKey]}/attribute/UiObject:focused`);
  return value === 'true';
}
const inputFocusTrace = [];
async function traceInputFocus(phase, target, detail = {}) {
  if (!fixtureBuild || inputFocusTrace.length >= 16) { return; }
  const sample = {phase, target, ...detail, startedAt: new Date().toISOString()};
  inputFocusTrace.push(sample);
  // Read-only, bounded diagnostics for address dismissal -> username reveal.
  // Never request text, descriptions, raw hierarchy or images here. Samples
  // are sequential observations, not an atomic snapshot; retain their duration.
  const app = `//app[@appName=${literal(packageId)}]`;
  const ime = "//app[@appName='com.amazon.silverstone']";
  const find = xpath => call('POST', '/elements', {using: 'xpath', value: xpath});
  const safe = async read => { try { return await read(); } catch { return null; } };
  try {
    sample.donePresent = await exists(byID('key_Done'));
    sample.doneObservedAt = new Date().toISOString();
    const windows = await find(ime + '//window');
    sample.imeWindowCount = windows.length;
    sample.imeWindows = [];
    for (const match of windows.slice(0, 2)) {
      const id = match[elementKey];
      // The pinned driver maps the documented displayed endpoint to native
      // visibilityOf. No UiObject:visible attribute exists. Unsupported window
      // queries remain null, never evidence that the keyboard closed.
      // https://developer.amazon.com/docs/vega/2.0/appium-commands#is_displayed
      sample.imeWindows.push({id, displayed: await safe(() => call('GET', `/element/${id}/displayed`))});
    }
    sample.focus = {};
    for (const [scope, path] of [['app', app], ['ime', ime]]) {
      const candidates = await find(path + "//*[@focused='true']");
      const objects = [];
      for (const match of candidates.slice(0, 4)) {
        const id = match[elementKey];
        const nativeFocused = await safe(async () =>
          await call('GET', `/element/${id}/attribute/UiObject:focused`) === 'true');
        objects.push({id, nativeFocused});
      }
      // Candidates come from publisher state; native RPC independently checks
      // each. No claim that this enumerates every natively focused object.
      sample.focus[scope] = {serializedCount: candidates.length, objects};
    }
    const targets = await find(app + byID(target));
    sample.targetCount = targets.length;
    sample.targetBounds = [];
    for (const match of targets.slice(0, 2)) {
      const id = match[elementKey];
      const rect = await safe(() => call('GET', `/element/${id}/rect`));
      sample.targetBounds.push({id, rect: rect && {x: rect.x, y: rect.y, width: rect.width, height: rect.height}});
    }
  } catch { sample.observationFailed = true; }
  sample.finishedAt = new Date().toISOString();
  await writeFile(resolve(output, 'input-focus-diagnostic.json'), JSON.stringify(inputFocusTrace, null, 2))
    .catch(() => console.log('[Vega journey] Input focus diagnostics unavailable; assertions unchanged.'));
}
async function dismissFixtureWarning() {
  if (!fixtureBuild || await exists(byID('key_Done'))) { return false; }
  const app = `//app[@appName=${literal(packageId)}]`;
  // findObjects returns UI object IDs. The nested <text> XML node has no ID;
  // match its owning text control rather than the serialization-only node.
  const message = app + "//*[@role='text' and text='Open debugger to view warnings.']";
  const dismiss = app + "//*[@clickable='true' and .//text='Dismiss']";
  if (!await exists(message) || !await exists(dismiss)) { return false; }
  // The Debug-only SDK LogBox steals focus asynchronously. Dismiss only its
  // exact observed warning, just as a tester would; never bypass an app error.
  const id = await element(dismiss);
  await call('POST', '/execute/sync', {script: 'jsonrpc: setFocus', args: [[{id: Number(id)}]]});
  await key(96);
  await waitFor(async () => !await exists(dismiss), 'The SDK development warning did not dismiss.', 5000);
  fixtureWarningsDismissed++;
  console.log('[Vega journey] Dismissed SDK development warning overlay');
  return true;
}
async function focusVisible(xpath, openingField = false) {
  const deadline = Date.now() + 25_000;
  const traceReveal = fixtureBuild && xpath === byID('source-username');
  let tracedKeys = 0;
  async function revealKey(code) {
    const observe = traceReveal && tracedKeys++ < 3;
    if (observe) { await traceInputFocus('before-reveal-key', 'source-username', {code, sequence: tracedKeys}); }
    const keyStartedAt = new Date().toISOString();
    await key(code);
    const keyFinishedAt = new Date().toISOString();
    if (observe) { await traceInputFocus('after-reveal-key', 'source-username', {code, sequence: tracedKeys, keyStartedAt, keyFinishedAt}); }
  }
  if (openingField) {
    await waitFor(async () => !await exists(byID('key_Done')),
      'The previous keyboard must close before opening another field.', Math.max(1, deadline - Date.now()));
    if (traceReveal) { await traceInputFocus('reveal-after-done-absence', 'source-username', {absenceObservedAt: new Date().toISOString()}); }
  }
  const window = await call('GET', '/window/rect');
  let direction = 108, previousFocus, unchanged = 0;
  for (let attempt = 0; attempt < 50 && Date.now() < deadline; attempt++) {
    await dismissFixtureWarning();
    const matches = await call('POST', '/elements', {using: 'xpath', value: xpath});
    if (matches.length) {
      const id = matches[0][elementKey];
      const rect = await call('GET', `/element/${id}/rect`);
      const x = rect.x + rect.width / 2, y = rect.y + rect.height / 2;
      if (rect.width > 0 && rect.height > 0 && x >= window.x && x < window.x + window.width && y >= window.y && y < window.y + window.height) {
        const result = await call('POST', '/execute/sync', {script: 'jsonrpc: setFocus', args: [[{id: Number(id)}]]});
        try {
          // A TextInput can open the system keyboard as soon as it receives
          // focus. The keyboard then owns focus, so the field need not retain
          // it. Only field opening accepts this transition; buttons stay strict.
          await waitFor(async () => await nativeFocused(xpath) || (openingField && await exists(byID('key_Done'))),
            `The remote could not focus the target control: ${xpath}`, Math.max(1, Math.min(1000, deadline - Date.now())));
        } catch (error) {
          if (await dismissFixtureWarning()) { continue; }
          // A screen transition may assign its initial focus after setFocus.
          // Retry within the same overall deadline, then use real D-pad input
          // so an unresponsive focus target still fails the bounded journey.
          const native = await nativeFocused(xpath);
          const serialized = await exists(xpath + '[@focused="true"]');
          console.log('[Vega journey] Focus not acknowledged', JSON.stringify({xpath, result, native, serialized}));
          await revealKey(direction); await sleep(100);
          continue;
        }
        return element(xpath);
      }
      direction = y < window.y ? 103 : y >= window.y + window.height ? 108 : x < window.x ? 105 : 106;
    }
    // Vega omits off-screen fields from the tree. D-pad focus moves the actual
    // ScrollView; coordinate clicks cannot reveal those fields. Reverse only
    // after observing focus stop changing at an edge.
    const focused = await call('POST', '/elements', {using: 'xpath', value: '//*[@focused="true"]'});
    const focus = focused.map(value => value[elementKey]).join(',');
    unchanged = focus === previousFocus ? unchanged + 1 : 0; previousFocus = focus;
    if (unchanged >= 2) { direction = direction === 108 ? 103 : 108; unchanged = 0; }
    await revealKey(direction); await sleep(100);
  }
  throw new Error(`The remote could not reveal the target control: ${xpath}`);
}
async function clickXPath(xpath) {
  const id = await focusVisible(xpath);
  assert(await call('GET', `/element/${id}/enabled`), 'Target action must be enabled.');
  await key(96);
}
async function key(code) {
  await call('POST', '/execute/sync', {script: 'jsonrpc: injectInputKeyEvent', args: [[{inputKeyEvent: String(code), holdDuration: 30}]]});
}
async function enter(id, value, previous = '') {
  const editorPath = byID(id) + "//*[@editable='true']";
  // Navigate to the outer TV field, then edit/read its actual native editor.
  // Focusing the inner editor directly may open IME and immediately lose focus.
  await focusVisible(byID(id), true);
  if (!await exists(byID('key_Done'))) { await key(96); }
  await element(byID('key_Done'));
  const target = await element(editorPath);
  // Use documented Linux key events for editing; the Vega command reference does not promise element.clear().
  if (previous) { await key(107); for (let i = 0; i < previous.length; i++) { await key(14); } }
  await call('POST', `/element/${target}/value`, {text: value, value: [...value]});
  if (!/password|pin/.test(id)) {
    await waitFor(async () => {
      // RN Vega puts testID on a focus wrapper. The actual editor is a child;
      // getText(wrapper) returns null even when the full value is visible.
      const editor = await element(editorPath);
      return await call('GET', `/element/${editor}/text`) === value;
    }, `The text field did not acknowledge the complete input: ${id}`);
  }
  // Vega documents Back as keyboard dismissal; controlled onChangeText has
  // already stored the edit. Do not require the IME's Done key to take focus.
  // https://developer.amazon.com/docs/vega/2.0/vega-release-notes#textinput-done-and-back-behavior-will-match-stock-react-native
  const keyboardWindow = "//app[@appName='com.amazon.silverstone']//window";
  if (await exists(byID('key_Done'))) {
    assert(await exists(keyboardWindow), 'Back may dismiss only an observed system keyboard.');
    if (id === 'source-address') { await traceInputFocus('before-back', id); }
    const keyStartedAt = new Date().toISOString();
    await key(158);
    const keyFinishedAt = new Date().toISOString();
    if (id === 'source-address') { await traceInputFocus('after-back', id, {code: 158, keyStartedAt, keyFinishedAt}); }
  } else if (id === 'source-address') {
    await traceInputFocus('back-skipped-done-absent', id);
  }
  // Done disappears when this IME closes. Its window may persist while hidden;
  // window removal is not a verified closed-state signal on the pinned SDK.
  await waitFor(async () => !await exists(byID('key_Done')),
    'The system keyboard did not close after editing.');
  if (id === 'source-address') { await traceInputFocus('after-done-absence', id, {absenceObservedAt: new Date().toISOString()}); }
  assert(await exists(byID(id)), `Dismissing the keyboard must keep the same form field: ${id}`);
  if (!/password|pin/.test(id)) {
    const editor = await element(editorPath);
    assert.equal(await call('GET', `/element/${editor}/text`), value,
      `Dismissing the keyboard must preserve the input: ${id}`);
  }
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
  if (await exists('//*[starts-with(@test_id,"field-") and contains(@test_id,"pin")]') || await exists(byID('source-password'))
    || await exists("//app[@appName='com.amazon.silverstone']//window")) {
    await writeFile(resolve(output, `${name}.capture-skipped.txt`), 'Visual and hierarchy evidence omitted while protected entry fields were on screen.');
    // Keep layout/focus evidence without text, values, descriptions or pixels.
    // This makes an off-screen field diagnosable without retaining credentials.
    const source = await call('GET', '/source');
    const attributes = new Set(['test_id', 'role', 'focused', 'focusable', 'enabled',
      'visible', 'clickable', 'editable', 'bounds', 'x', 'y', 'width', 'height']);
    const structure = [...source.matchAll(/<([A-Za-z_][\w:.-]*)([^<>]*)>/g)].map(match => {
      const safe = {element: match[1]};
      for (const attribute of match[2].matchAll(/([\w:.-]+)="([^"]*)"/g)) {
        if (attributes.has(attribute[1])) { safe[attribute[1]] = attribute[2]; }
      }
      return safe;
    });
    await writeFile(resolve(output, `${name}.layout.json`), JSON.stringify(structure, null, 2));
    return;
  }
  const source = await call('GET', '/source');
  await writeFile(resolve(output, `${name}.xml`), source);
  const screenshot = await call('GET', '/screenshot');
  await writeFile(resolve(output, `${name}.png`), Buffer.from(screenshot, 'base64'));
  // VVD has a reported alternating stale/current screenshot buffer. Retain
  // both consecutive captures for review; neither is a substitute for live
  // native state assertions or a successful library/player journey.
  await sleep(150);
  const nextScreenshot = await call('GET', '/screenshot');
  await writeFile(resolve(output, `${name}.next.png`), Buffer.from(nextScreenshot, 'base64'));
  await writeFile(resolve(output, `${name}.after.xml`), await call('GET', '/source'));
}
async function diagnoseSourcesFocus() {
  const app = `//app[@appName=${literal(packageId)}]`;
  if (!fixtureBuild || !await exists(app + "//*[@role='text' and text='Your sources']")) { return; }
  const add = app + byID('action-add-source');
  const targets = [
    {name: 'header-profile', xpath: app + byID('action-everyone')},
    {name: 'scroll-container', xpath: add + '/ancestor::child[traits/scrollable][1]'},
    {name: 'add-source', xpath: add},
  ];
  const observed = [...targets, {name: 'back', xpath: app + byID('action-back')}];
  async function states() {
    const values = [];
    for (const target of observed) {
      values.push({name: target.name, native: await nativeFocused(target.xpath),
        serialized: await exists(target.xpath + '[@focused="true"]')});
    }
    return values;
  }
  const report = {diagnosticOnly: true, originalFailurePreserved: true, before: await states(), attempts: []};
  // Run only after the failed journey and its original evidence are saved.
  // Focus requests alone distinguish a global trap from a ScrollView boundary;
  // never press Select, enter text, retry the journey, or change its result.
  for (const target of targets) {
    const matches = await call('POST', '/elements', {using: 'xpath', value: target.xpath});
    if (!matches.length) { report.attempts.push({name: target.name, found: false}); continue; }
    try {
      const result = await call('POST', '/execute/sync', {script: 'jsonrpc: setFocus', args: [[{id: Number(matches[0][elementKey])}]]});
      const started = Date.now();
      let observedFocused = await nativeFocused(target.xpath);
      while (!observedFocused && Date.now() - started < 1000) {
        await sleep(Math.min(100, 1000 - (Date.now() - started)));
        observedFocused = await nativeFocused(target.xpath);
      }
      report.attempts.push({name: target.name, found: true, requestAccepted: result?.result === true,
        observedFocused, observationMs: Date.now() - started, states: await states()});
    } catch {
      report.attempts.push({name: target.name, found: true, error: 'The focus diagnostic request failed.'});
    }
  }
  await writeFile(resolve(output, 'sources-focus-diagnostic.json'), JSON.stringify(report, null, 2));
  await capture('sources-focus-diagnostic-after');
}
async function step(name, run) {
  const started = Date.now();
  console.log(`[Vega journey] Starting ${name}`);
  try { await run(); await capture(name); results.push({name, passed: true, status: 'passed', durationMs: Date.now() - started}); }
  catch (error) {
    const sanitized = String(error).replace(/482619|000000|fixture-only/g, '[fixture credential]');
    results.push({name, passed: false, status: 'failed', error: sanitized, durationMs: Date.now() - started});
    await capture(name + '-failure').catch(() => {});
    if (name === '01-connect-and-scan' && sanitized.includes("@test_id='action-add-source'")) {
      await diagnoseSourcesFocus().catch(() => console.log('[Vega journey] Focus diagnostics unavailable; original failure retained.'));
    }
    throw new Error(sanitized);
  }
  console.log(`[Vega journey] Passed ${name}`);
}
async function probeProductionStartup() {
  await waitFor(async () => {
    assert.equal(await exists(byID('fixture-build-banner')), false, 'Production startup must never display the fixture build banner.');
    return await exists(byID('startup-error')) || (await exists(byID('action-sources')) && await exists(byID('library-grid')));
  }, 'Production startup did not reach home or report its secure-storage status.');
  assert.equal(await exists(byID('fixture-build-banner')), false, 'Production startup must never display the fixture build banner.');
  if (await exists(byID('startup-error'))) {
    const message = await text('startup-error');
    assert.equal(message, 'Protected settings are unavailable. Try again. (MV06:not-supported)', 'Only the confirmed virtual-device keystore limitation is an accepted startup failure.');
    for (const id of ['library-grid', 'action-sources', 'action-all-media']) {
      assert.equal(await exists(byID(id)), false, 'Unavailable secure storage must not expose the home library.');
    }
    const retry = await element(byID('startup-retry'));
    assert.equal(await call('GET', `/element/${retry}/enabled`), true, 'The secure startup error must offer an enabled Retry action.');
    startupProbe = {outcome: 'unsupported-on-virtual-device', nativeStorageAvailable: false,
      errorCode: 'MV06:not-supported', hardwareRequired: true, homeExposed: false, retryEnabled: true};
  } else {
    assert(await exists(byID('action-sources')) && await exists(byID('library-grid')), 'The fresh production installation must reach its home library.');
    startupProbe = {outcome: 'native-storage-available', nativeStorageAvailable: true,
      hardwareRequired: false, homeExposed: true,
      limitation: 'Startup availability only; PIN persistence, restart protection, and saved NAS credentials were not tested.'};
  }
}
const feature = 'media-group-tmdb:910001', sequel = 'media-group-tmdb:910002';
try {
  const created = await command('POST', '/session', {capabilities: {alwaysMatch: {
    platformName: 'Kepler', 'appium:automationName': 'automation-toolkit/JSON-RPC',
    'kepler:device': process.env.VEGA_DEVICE ?? 'vda://default', 'appium:appURL': packageId + '.main',
  }}});
  session = created.sessionId;
  assert(session, 'Appium must return a real device session.');
  if (startupCheckOnly) {
    await step('production-startup-probe', probeProductionStartup);
  } else {
  await step('01-connect-and-scan', async () => {
    await waitFor(async () => {
      if (await exists(byID('startup-error'))) { throw new Error('Library startup failed: ' + await text('startup-error')); }
      return exists(byID('action-sources'));
    }, 'The protected library did not finish opening.');
    if (fixtureBuild) {
      await element(byID('fixture-build-banner'));
      assert.match(await text('fixture-build-banner'), /VIRTUAL DEVICE TEST BUILD.*Synthetic credentials only.*Secure storage requires hardware verification/);
      fixtureBannerVerified = true;
    } else {
      assert.equal(await exists(byID('fixture-build-banner')), false, 'A production package must never use the fixture build.');
    }
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
    // Home bulk selection stays active, but collection posters must open their titles.
    await click(feature);
    await clickXPath('//*[starts-with(@test_id,"item-open-") and contains(@test_id,"Directors Cut.mp4")]');
    assert.equal(await text('detail-title'), 'Library Feature');
    await click('action-back'); await click('action-back');
    const collectionName = await element(byID('field-collection-name') + "//*[@editable='true']");
    assert.equal(await call('GET', `/element/${collectionName}/text`), 'Movie Night', 'Back must return to the same collection.');
    await element(byID(feature)); assert.equal(await exists(byID(sequel)), false);
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
    await element(byID('action-en')); await element(byID('action-es'));
    assert.equal(await exists(byID('action-de')), false, 'An oversized subtitle must be skipped while valid language choices remain available.');
    await sleep(11000); assert.match(await text('player-file-name'), /S01E01/, 'Stopping the countdown must leave the current episode.');
    await click('action-play-next-fixture-show');
    await waitFor(async () => (await call('GET', '/source')).includes('Fixture Show.S01E02.mp4'), 'Manual Play Next must open episode two.');
    await waitFor(async () => (await call('GET', '/source')).includes('Fixture Show.S01E04.mp4'), 'Automatic next episode must advance across the missing episode three.', 55_000);
    await waitFor(async () => await position() >= 1, 'The automatically selected episode must actually decode and advance.', 40_000);
    await capture('07-next-episode-playing'); await key(158);
    await click('action-back'); await click('action-back'); await click('action-back'); await click('action-all-media');
  });
  await step('08-household-filtering', async () => {
    await click('action-sources'); await click('action-set-up-household-profiles');
    await enter('field-administrator-pin', '482619'); await enter('field-confirm-administrator-pin', '482619');
    await enter('field-profile-name', 'Kids'); await click('action-fixture-nas'); await click('action-save-profile');
    await waitFor(async () => await exists(byID('action-set-up-household-profiles')) && !await exists(byID('field-profile-name')),
      'The household profile must finish saving before switching profiles.');
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
  if (!fixtureBuild) { await step('10-keystore-and-source-persistence', async () => {
    await call('POST', '/appium/device/terminate_app', {appId: packageId});
    await call('POST', '/appium/device/activate_app', {appId: packageId + '.main'});
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
  }); }
  }
} finally {
  if (fixtureBuild) {
    results.push({name: '10-keystore-and-source-persistence', passed: null,
      status: fixtureBannerVerified ? 'skipped' : 'not-run', hardwareRequired: true,
      reason: fixtureBannerVerified
        ? 'The visibly marked virtual-device fixture uses synthetic in-memory credentials. Production keystore, restart protection, and saved source credentials require physical Vega hardware.'
        : 'The fixture package identity/banner was not verified. Production secure-storage checks require physical Vega hardware.'});
  }
  const secureStorageVerification = !fixtureBuild && results.some(value => value.name === '10-keystore-and-source-persistence' && value.passed === true)
    ? 'verified-on-device' : 'not-verified';
  await writeFile(resolve(output, 'results.json'), JSON.stringify({executedOnDevice: Boolean(session), packageId,
    mode: startupCheckOnly ? 'production-startup-probe' : 'library-journeys', startupProbe,
    libraryJourneyCount: results.filter(value => /^0[1-9]-/.test(value.name)).length,
    buildKind: fixtureBuild ? 'virtual-device-fixture' : 'production', fixtureBannerVerified, fixtureWarningsDismissed, secureStorageVerification, results}, null, 2));
  if (session) { await call('DELETE', '').catch(() => {}); }
}
