import assert from 'node:assert/strict';
import {mkdir, readFile, stat, writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {activateKeyboardClear} from './keyboard-clear.mjs';
import {nativeSeeks, parseElapsedPosition, waitForMp4Seek} from './native-seek-evidence.mjs';
import {keyboardApp, keyboardDone, keyboardDonePresenceReader, keyboardVisibilityReader, simulatorKeyboardRpc, waitForKeyboardDismissal}
  from './keyboard-observation.mjs';

// Real Appium/Vega automation, using Amazon's documented W3C endpoints and JSON-RPC D-pad API.
// https://developer.amazon.com/docs/vega/2.0/appium-sessions
// https://developer.amazon.com/docs/vega/2.0/appium-commands
const server = process.env.APPIUM_URL ?? 'http://127.0.0.1:4723';
const startupCheckOnly = process.env.MEDIA_VAULT_E2E_STARTUP_CHECK_ONLY === '1';
const endpoint = process.env.MEDIA_VAULT_E2E_NAS_ENDPOINT;
const nativeLog = process.env.MEDIA_VAULT_E2E_NATIVE_LOG;
if (!startupCheckOnly) {
  assert(endpoint?.startsWith('smb://') && endpoint.endsWith('/MEDIALIBRARY'), 'Set a device-accessible synthetic MEDIALIBRARY SMB endpoint.');
  assert(nativeLog, 'Supply the live native log for the disposable app package.');
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
async function command(method, path, body, timeoutMs = 45_000) {
  const response = await fetch(server + path, {method, headers: {'Content-Type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs)});
  const payload = await response.json();
  if (!response.ok || payload.value?.error) { throw new Error(payload.value?.message ?? `Appium command failed (${response.status}).`); }
  return payload.value;
}
const call = (method, path, body, timeoutMs) => command(method, `/session/${session}${path}`, body, timeoutMs);
const literal = value => { assert(!value.includes("'"), 'Test selectors use fixed synthetic values.'); return `'${value}'`; };
const byID = id => `//*[@test_id=${literal(id)}]`;
const exists = async (xpath, timeoutMs) => (await call('POST', '/elements', {using: 'xpath', value: xpath}, timeoutMs)).length > 0;
const homeToolbar = ['library-section', 'library-search'];
const posterGroups = '//*[starts-with(@test_id,"media-group-")]';
async function homePresent() {
  for (const id of homeToolbar) { if (!await exists(byID(id))) { return false; } }
  return true;
}
async function assertLibraryHidden(message) {
  // FlatList's library-grid testID is absent from the actual native publisher.
  // Assert real toolbar controls and poster groups cannot leak behind a lock.
  for (const id of [...homeToolbar, 'action-filters', 'action-collections', 'action-sources', 'action-select-titles']) {
    assert.equal(await exists(byID(id)), false, message);
  }
  assert.equal(await exists(posterGroups), false, message);
}

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
const keyboardRpcPort = process.env.MEDIA_VAULT_E2E_KEYBOARD_RPC_PORT;
assert(!keyboardRpcPort || fixtureBuild, 'Direct native keyboard observations are reserved for the disposable simulator fixture.');
const keyboardRpc = keyboardRpcPort
  ? simulatorKeyboardRpc(keyboardRpcPort)
  : (method, params, timeoutMs) => call('POST', '/execute/sync', {script: `jsonrpc: ${method}`, args: [[params]]}, timeoutMs);
const readKeyboardVisibility = keyboardVisibilityReader((id, timeoutMs) => keyboardRpc('visibilityOf', {id}, timeoutMs));
const nativeDisplayed = async id => (await readKeyboardVisibility(id)).displayed;
async function displayedKeyboardWindow() {
  if (!await exists(keyboardDone)) { return null; }
  const windows = await call('POST', '/elements', {using: 'xpath', value: keyboardApp + '//window'});
  for (const window of windows) {
    const id = window[elementKey];
    if (await nativeDisplayed(id) === true) { return id; }
  }
  return null;
}
const inputFocusTrace = [];
async function traceInputFocus(phase, target, detail = {}) {
  if (!fixtureBuild || inputFocusTrace.length >= 16) { return; }
  // Record the observations the journey already made. Extra native reads
  // around Back previously stalled the Appium queue and delayed validation.
  inputFocusTrace.push({phase, target, ...detail, observedAt: new Date().toISOString()});
  await writeFile(resolve(output, 'input-focus-diagnostic.json'), JSON.stringify(inputFocusTrace, null, 2))
    .catch(() => console.log('[Vega journey] Input focus diagnostics unavailable; assertions unchanged.'));
}
async function assertNoFatalOverlay() {
  const app = `//app[@appName=${literal(packageId)}]`;
  // The actual SDK LogBox renders this heading above an uncaught error. The
  // underlying app can still answer focus/text queries while this window covers
  // it, so those assertions alone cannot mark a journey passed. Never read or
  // dismiss the error body, which may include protected application values.
  assert.equal(await exists(app + "//*[@role='text' and text='Uncaught Error']"), false,
    'The app displayed an uncaught runtime error overlay.');
}
async function dismissFixtureWarning() {
  await assertNoFatalOverlay();
  if (!fixtureBuild || await exists(keyboardDone)) { return false; }
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
    await waitFor(async () => !await exists(keyboardDone),
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
          await waitFor(async () => await nativeFocused(xpath) || (openingField && await exists(keyboardDone)),
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
  if (!await exists(keyboardDone)) { await key(96); }
  await element(keyboardDone);
  const target = await element(editorPath);
  const secret = /password|pin/.test(id);
  const replacementTrace = [];
  async function recordReplacement(phase, actual) {
    if (!fixtureBuild || secret || !previous) { return; }
    replacementTrace.push({field: id, phase, observedAt: new Date().toISOString(),
      expectedLength: value.length, previousLength: previous.length,
      actualLength: typeof actual === 'string' ? actual.length : null,
      empty: actual === '', equalsPrevious: actual === previous, equalsExpected: actual === value});
    await writeFile(resolve(output, 'input-replacement-diagnostic.json'), JSON.stringify(replacementTrace, null, 2))
      .catch(() => console.log('[Vega journey] Replacement diagnostics unavailable; assertions unchanged.'));
  }
  if (previous) {
    let actual;
    if (secret) {
      // PIN/password replacement never reads the previous or cleared text.
      // The later unlock/connect journey must prove that the new value works.
      await waitFor(() => nativeFocused(editorPath), `The protected replacement editor must have native focus: ${id}`);
    } else {
      try {
        await waitFor(async () => {
          actual = await call('GET', `/element/${target}/text`);
          return actual === previous && await nativeFocused(editorPath);
        }, `The replacement field must retain its expected prior value and native focus: ${id}`);
      } finally { await recordReplacement('before-clear', actual); }
    }
    // The pinned driver's clear/setText('') left the old value unchanged on
    // device. Use the observed IME Clear control as a real remote action.
    let clearWindow;
    await waitFor(async () => Boolean(clearWindow = await displayedKeyboardWindow()),
      'The system keyboard must be visibly open before selecting Clear.');
    await activateKeyboardClear({call, key, nativeDisplayed, windowId: clearWindow});
    // Nonsecret edits must acknowledge an empty editor before replacement.
    // Protected fields instead rely on the later unlock/connect assertion.
    if (!secret) {
      try {
        await waitFor(async () => {
          const editor = await element(editorPath);
          actual = await call('GET', `/element/${editor}/text`);
          return actual === '';
        }, `The text field did not acknowledge clearing before replacement: ${id}`);
      } finally { await recordReplacement('after-clear', actual); }
    }
  }
  const writeTarget = previous ? await element(editorPath) : target;
  await call('POST', `/element/${writeTarget}/value`, {text: value, value: [...value]});
  if (!secret) {
    let actual;
    try {
      await waitFor(async () => {
        // RN Vega puts testID on a focus wrapper. The actual editor is a child;
        // getText(wrapper) returns null even when the full value is visible.
        const editor = await element(editorPath);
        actual = await call('GET', `/element/${editor}/text`);
        return actual === value;
      }, `The text field did not acknowledge the complete input: ${id}`);
    } finally { await recordReplacement('after-replacement', actual); }
  }
  // Vega documents Back as keyboard dismissal; controlled onChangeText has
  // already stored the edit. Do not require the IME's Done key to take focus.
  // https://developer.amazon.com/docs/vega/2.0/vega-release-notes#textinput-done-and-back-behavior-will-match-stock-react-native
  const traceDismissal = id === 'source-name' || id === 'source-address';
  let activeKeyboardWindow;
  // The publisher temporarily omitted Done and its window before the next
  // remote key. Absence must not skip the one Back required for this edit.
  await waitFor(async () => Boolean(activeKeyboardWindow = await displayedKeyboardWindow()),
    'The edited field did not expose a displayed system keyboard for dismissal.');
  if (traceDismissal) { await traceInputFocus('before-back', id, {activeKeyboardWindow, activeWindowDisplayed: true}); }
  const keyStartedAt = new Date().toISOString();
  await key(158);
  const keyFinishedAt = new Date().toISOString();
  if (traceDismissal) {
    await traceInputFocus('after-back', id, {code: 158, keyStartedAt, keyFinishedAt, activeKeyboardWindow});
  }
  const observations = [];
  let doneOutcome = 'unobserved';
  try {
    await waitForKeyboardDismissal({
      windowId: activeKeyboardWindow,
      readVisibility: readKeyboardVisibility,
      isDonePresent: keyboardDonePresenceReader(keyboardRpc, {
        packageId, fieldId: id, onOutcome: outcome => { doneOutcome = outcome; },
      }),
      onObservation: observation => {
        if (traceDismissal && observations.length < 8) { observations.push(observation); }
      },
    });
  } catch (error) {
    throw new Error(`${error.message} Field: ${id}. Native Done observation: ${doneOutcome}.`, {cause: error});
  } finally {
    if (traceDismissal) {
      await traceInputFocus('keyboard-closure-observations', id, {activeKeyboardWindow, observations, doneOutcome});
    }
  }
  assert(await exists(byID(id)), `Dismissing the keyboard must keep the same form field: ${id}`);
  if (!/password|pin/.test(id)) {
    const editor = await element(editorPath);
    assert.equal(await call('GET', `/element/${editor}/text`), value,
      `Dismissing the keyboard must preserve the input: ${id}`);
  }
}
async function text(id) { return call('GET', `/element/${await element(byID(id))}/text`); }
const sourcesHeading = "//*[@role='text' and text='Your sources']";
async function requirePlaybackHome(message, section) {
  const sectionAction = section === undefined ? null : byID('library-section') + `[@description=${literal(section)}]`;
  await waitFor(async () => await homePresent() && await exists(byID('action-sources'))
    && !await exists(sourcesHeading) && !await exists(byID('action-add-source')) && !await exists(byID('source-name'))
    && (!sectionAction || await exists(sectionAction)), message);
}
async function addSource(name, address) {
  await requirePlaybackHome(`Home must be active before opening Sources to add ${name}.`);
  await click('action-sources'); await element(sourcesHeading);
  await click('action-add-source'); await click('action-nas-smb');
  await enter('source-name', name); await enter('source-address', address);
  await enter('source-username', 'cinevault'); await enter('source-password', 'fixture-only');
  await click('source-connect'); await click('source-save');
  const scanStatus = byID(`source-scan-${name}`);
  await waitFor(async () => {
    if (!await exists(sourcesHeading) || await exists(byID('source-name'))) { return false; }
    const matches = await call('POST', '/elements', {using: 'xpath', value: scanStatus});
    if (matches.length !== 1) { return false; }
    const status = await call('GET', `/element/${matches[0][elementKey]}/text`);
    return typeof status === 'string' && /^SMB · Last scan: (?!Never\s*$)\S/.test(status)
      && !await exists(byID('action-stop-scan'));
  }, `The new ${name} source must finish its first scan on Sources without pressing Scan again.`, 120_000);
  // Back leaves the verified Sources route without retargeting a focusable header button.
  await key(158);
  await requirePlaybackHome(`Back from the finished ${name} scan must return to Home and close Sources.`);
  console.log(`[Vega journey] Verified the ${name} scan and return to Home`);
}
async function playFixtureDetail(title, filename) {
  const detailMatches = async () => await exists(byID('detail-title')) && await exists(byID('detail-file-name'))
    && await text('detail-title') === title && await text('detail-file-name') === filename;
  await waitFor(detailMatches, `The exact ${filename} detail must be open before selecting Play.`);
  const play = await focusVisible(byID('action-play'));
  assert(await detailMatches(), `Focusing Play must keep the exact ${filename} detail active.`);
  assert.equal(await call('GET', `/element/${play}/enabled`), true, `Play must be enabled for ${filename}.`);
  assert.equal(await call('GET', `/element/${play}/attribute/UiObject:focused`), 'true',
    `Play for ${filename} must own native focus immediately before Select.`);
  console.log(`[Vega journey] Selecting focused Play for ${filename}`);
  await key(96);
  assert.equal(await text('player-file-name'), filename, `Select must open the real player for ${filename}.`);
}
async function assertNoPlayerError() {
  if (await exists(byID('player-error'))) { throw new Error(await text('player-error')); }
}
async function position() {
  await assertNoPlayerError();
  const elapsed = parseElapsedPosition(await text('player-position'));
  assert(elapsed !== null, 'The player must expose an actual elapsed position.');
  return elapsed;
}
async function seekPositionText() {
  await assertNoPlayerError();
  try {
    // The driver can briefly return a stale or incomplete text observation
    // while publishing a new position. The bounded seek poll needs fresh text.
    const matches = await call('POST', '/elements', {using: 'xpath', value: byID('player-position')}, 2000);
    if (matches.length !== 1) { return null; }
    return await call('GET', `/element/${matches[0][elementKey]}/text`, undefined, 2000);
  } catch {
    return null;
  }
}
async function seekEvidenceSince(mark) {
  const log = await readFile(nativeLog);
  assert(log.length >= mark, 'Native player log was truncated during the seek regression.');
  return nativeSeeks(log.subarray(mark).toString('utf8'), packageId);
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
  try {
    await assertNoFatalOverlay(); await run(); await assertNoFatalOverlay();
    await capture(name); await assertNoFatalOverlay();
    results.push({name, passed: true, status: 'passed', durationMs: Date.now() - started});
  }
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
    return await exists(byID('startup-error')) || (await exists(byID('action-sources')) && await homePresent());
  }, 'Production startup did not reach home or report its secure-storage status.');
  assert.equal(await exists(byID('fixture-build-banner')), false, 'Production startup must never display the fixture build banner.');
  if (await exists(byID('startup-error'))) {
    const message = await text('startup-error');
    assert.equal(message, 'Protected settings are unavailable. Try again. (MV06:not-supported)', 'Only the confirmed virtual-device keystore limitation is an accepted startup failure.');
    await assertLibraryHidden('Unavailable secure storage must not expose the home library.');
    const retry = await element(byID('startup-retry'));
    assert.equal(await call('GET', `/element/${retry}/enabled`), true, 'The secure startup error must offer an enabled Retry action.');
    startupProbe = {outcome: 'unsupported-on-virtual-device', nativeStorageAvailable: false,
      errorCode: 'MV06:not-supported', hardwareRequired: true, homeExposed: false, retryEnabled: true};
  } else {
    assert(await exists(byID('action-sources')) && await homePresent(), 'The fresh production installation must reach its home library.');
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
    // This cold-start check must precede every focus-setting navigation helper.
    // Observe native focus, then use only real Select/Back input for this flow.
    await waitFor(() => nativeFocused(byID('action-add-source')),
      'Cold start must give the empty library Add source action native focus.');
    await capture('01-cold-start-focus');
    await key(96); await element(byID('source-name'));
    assert.equal(await exists(keyboardDone), false, 'Opening the source form must not start text entry.');
    await key(158);
    await waitFor(async () => await homePresent() && !await exists(byID('source-name')),
      'Back from the unused source form must return to the Home toolbar.');
    await waitFor(() => nativeFocused(byID('action-add-source')),
      'Back from the unused source form must restore the empty library action focus.');
    await addSource('Fixture NAS', endpoint); await element(byID(feature)); await element(byID(sequel));
    assert.equal((await call('POST', '/elements', {using: 'xpath', value: '//*[starts-with(@test_id,"media-group-")]'})).length, 5,
      'Five visible grouped titles: two movies, one show, one invalid-metadata movie, one standalone photo. Sidecar artwork must be suppressed.');
  });
  await step('02-edition-detail', async () => {
    // Do not call focusVisible/click here: directional navigation and restoration
    // must succeed before any helper can assign native focus to a target.
    const firstPoster = '//*[starts-with(@test_id,"media-group-") and contains(@test_id,":Invalid/Invalid Metadata.mp4")]';
    await waitFor(() => nativeFocused(firstPoster), 'The newly scanned library must focus its first poster.');
    await key(106);
    await waitFor(() => nativeFocused(byID(feature)), 'Right must move native focus to Library Feature.');
    await key(106);
    await waitFor(() => nativeFocused(byID(sequel)), 'Right must move native focus to Library Sequel.');
    await key(96); await element(byID('detail-title'));
    assert.equal(await text('detail-title'), 'Library Sequel', 'Select must open the natively focused sequel.');
    await key(158);
    await waitFor(async () => await homePresent() && !await exists(byID('detail-title')),
      'Back from the sequel detail must return to the Home toolbar.');
    await waitFor(() => nativeFocused(byID(sequel)), 'Back must restore native focus to the same non-first poster.');
    await capture('02-native-back-focus');
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
    await capture('03-collection-before-edit');
    await click('action-manage-collection');
    await enter('field-collection-name', 'Movie Night', 'Weekend'); await click('action-save-name');
    await click('action-back');
    await click('action-manage-titles'); await click('action-library-sequel'); await click('action-done');
    await element(byID(feature)); assert.equal(await exists(byID(sequel)), false, 'Removing a title must immediately update the collection.');
    // Home bulk selection stays active, but collection posters must open their titles.
    await click(feature);
    await clickXPath('//*[starts-with(@test_id,"item-open-") and contains(@test_id,"Directors Cut.mp4")]');
    assert.equal(await text('detail-title'), 'Library Feature');
    await click('action-add-to-collection'); await element(byID('field-new-collection-name'));
    await click('action-back'); // Cancelling a detail action must preserve the Home bulk selection.
    assert.equal(await text('detail-title'), 'Library Feature');
    await click('action-back'); await click('action-back');
    await click('action-manage-collection');
    const collectionName = await element(byID('field-collection-name') + "//*[@editable='true']");
    assert.equal(await call('GET', `/element/${collectionName}/text`), 'Movie Night', 'Back must return to the same collection.');
    await click('action-back');
    await element(byID(feature)); assert.equal(await exists(byID(sequel)), false);
    await click('action-back'); await click('action-back');
    await waitFor(async () => await exists(byID('action-done-selecting'))
      && await exists("//*[@role='text' and text='3 selected']") && !await exists(byID('field-new-collection-name'))
      && await exists(byID(feature) + "[starts-with(@description,'Selected, ')]")
      && await exists(byID(sequel) + "[starts-with(@description,'Selected, ')]"),
      'Returning from collections must restore selecting Home with all three selected files and both selected groups.');
    assert(await exists("//*[@role='text' and text='3 selected']"), 'Detail collection actions must preserve all three selected Home files.');
    for (const id of [feature, sequel]) {
      assert(await exists(byID(id) + "[starts-with(@description,'Selected, ')]"), 'Both original Home title groups must remain selected.');
    }
    await capture('03-bulk-selection-restored');
    await click('action-done-selecting');
  });
  await step('04-show-season-episode', async () => {
    await click('library-section'); await click('action-tv-shows');
    await clickXPath('//*[starts-with(@test_id,"media-group-show:") and contains(@test_id,":tmdb:920001")]');
    await click('action-season-1');
    await clickXPath('//*[starts-with(@test_id,"item-open-") and contains(@test_id,"Library Show.S01E01.mp4")]');
    assert.equal(await text('detail-title'), 'The Local Episode');
    await click('action-back'); await click('action-back'); await click('action-back');
  });
  await step('05-standalone-photo', async () => {
    await click('library-section'); await click('action-photos');
    await clickXPath('//*[starts-with(@test_id,"media-group-") and contains(@test_id,":Photos/poster.png")]');
    await element(byID('action-start-slideshow')); await element(byID('photo-loaded'));
    assert(!(await call('GET', '/source')).includes('could not be'), 'The actual photo must load without an error.');
    await click('action-back'); await click('library-section'); await click('action-all-media');
  });
  await step('06-mp4-remote-playback', async () => {
    await addSource('Formats NAS', endpoint.replace(/MEDIALIBRARY$/, 'FORMATPLAYBACK'));
    await clickXPath('//*[starts-with(@test_id,"media-group-") and contains(@test_id,":Seek Controls.mp4")]');
    await playFixtureDetail('Seek Controls', 'Seek Controls.mp4');
    await waitFor(async () => await position() >= 1, 'The real MP4 decoder must advance.', 40_000);
    await waitFor(() => nativeFocused(byID('action-pause')),
      'The ready player must give Pause native focus before any helper assigns it.');
    await key(164); await element(byID('action-play'));
    await click('player-subtitles');
    await clickXPath('//*[starts-with(@test_id,"subtitle-track-") and @description="English"]');
    const activeCaptions = byID('player-subtitles') + "[@description='Subtitles · English']";
    await element(activeCaptions);
    const paused = await position(); await sleep(1500); assert(Math.abs(await position() - paused) <= 1, 'Pause must stop the clock.');
    const seekActions = [];
    const allSeekMark = (await stat(nativeLog)).size;
    async function seekControlsReady() {
      for (const id of ['action-back-10-seconds', 'action-forward-30-seconds']) {
        const matches = await call('POST', '/elements', {using: 'xpath', value: byID(id)});
        if (matches.length !== 1 || await call('GET', `/element/${matches[0][elementKey]}/enabled`) !== true) { return false; }
      }
      return true;
    }
    async function performSeek(before, delta, focusId, code, message) {
      const trace = {focusId, code, before, expected: Math.max(0, before + delta), preparedAt: new Date().toISOString()};
      seekActions.push(trace);
      try {
        await waitFor(seekControlsReady, 'The prior seek must settle before dispatching another MP4 action.');
        const target = await focusVisible(byID(focusId));
        trace.ready = await seekControlsReady() && await call('GET', `/element/${target}/enabled`) === true;
        trace.nativeFocused = await nativeFocused(byID(focusId));
        assert(trace.ready && trace.nativeFocused, 'The MP4 seek action must be enabled and natively focused before dispatch.');
        const mark = (await stat(nativeLog)).size;
        trace.dispatchedAt = new Date().toISOString();
        console.log('[Vega MP4 seek] Dispatch', JSON.stringify(trace));
        await key(code);
        trace.rpcReturnedAt = new Date().toISOString();
        const confirmedPosition = await waitForMp4Seek({
          expected: trace.expected, message,
          observe: async () => ({
            positionText: await seekPositionText(), requests: await seekEvidenceSince(mark),
            paused: await exists(byID('action-play')), controlsReady: await seekControlsReady(),
          }),
          onSample: sample => {
            trace.observed = sample;
            if (sample.position === null) { trace.unavailablePositionSamples = (trace.unavailablePositionSamples ?? 0) + 1; }
          },
        });
        trace.confirmedAt = new Date().toISOString();
        return confirmedPosition;
      } finally {
        console.log('[Vega MP4 seek] Evidence', JSON.stringify(trace));
        await writeFile(resolve(output, 'mp4-seek-actions.json'), JSON.stringify(seekActions, null, 2) + '\n');
      }
    }
    const advanced = await performSeek(paused, 10, 'action-play', 208, 'Remote fast-forward must seek once by 10 seconds.');
    const buttonAdvanced = await performSeek(advanced, 30, 'action-forward-30-seconds', 96,
      'The Forward 30 seconds button must advance 30 seconds.');
    // Rewind away from zero so a duplicated action cannot hide behind clamping.
    const rewound = await performSeek(buttonAdvanced, -10, 'action-play', 168, 'Remote rewind must seek once by 10 seconds.');
    const buttonRewound = await performSeek(rewound, -10, 'action-back-10-seconds', 96,
      'The Back 10 seconds button must rewind 10 seconds.');
    await sleep(1500); assert(Math.abs(await position() - buttonRewound) <= 1, 'Seeking while paused must leave the clock stopped.');
    assert.deepEqual(await seekEvidenceSince(allSeekMark), seekActions.flatMap(action => action.observed.requests),
      'The MP4 actions must produce only their four matched native requests, without delayed duplicates.');
    await focusVisible(byID('action-play'));
    await key(164); await element(byID('action-pause'));
    await waitFor(async () => await position() >= buttonRewound + 1, 'Resume after seeking must advance the actual decoder clock.');
    await element(activeCaptions);
    await capture('06-mp4-playing');
    await key(158); await element(byID('detail-title')); await element(byID('action-resume'));
    await click('action-back');
  });
  await step('06-mkv-seek-constraint', async () => {
    await clickXPath('//*[starts-with(@test_id,"media-group-") and contains(@test_id,":Controls.mkv")]');
    await click('action-play');
    assert.equal(await text('player-file-name'), 'Controls.mkv');
    await waitFor(async () => await position() >= 1, 'The real MKV decoder must advance before seeking.', 40_000);
    await click('action-pause'); await element(byID('action-play'));
    const origin = await position();
    const target = origin + 30;
    assert(target < 58, 'The MKV test must request a seek within the media, away from end clamping.');
    await sleep(1500);
    assert(Math.abs(await position() - origin) <= 1, 'The MKV playback clock must remain paused before the seek.');
    assert.equal(await exists(byID('player-seek-warning')), false, 'A stale seek warning cannot satisfy this regression.');
    const mark = (await stat(nativeLog)).size;
    await click('action-forward-30-seconds');

    let evidence;
    await waitFor(async () => {
      const clock = await position(); // A generic player error always fails immediately.
      const requests = await seekEvidenceSince(mark);
      assert(requests.length <= 1, 'The MKV seek button must issue exactly one native request.');
      evidence = requests[0];
      if (!evidence) { return false; }
      assert(Math.abs(evidence.requested - target) <= 2, 'The native MKV request must match the tested forward target.');
      if (evidence.outcome === 'accepted') { return Math.abs(clock - target) <= 2; }
      assert.notEqual(evidence.outcome, 'rejected', 'An unrelated native seek error cannot satisfy the MKV constraint.');
      if (evidence.outcome !== 'rejected-50004') { return false; }
      assert(Math.abs(clock - origin) <= 1, 'A rejected seek must not publish a fabricated MKV position.');
      return await exists(byID('player-seek-warning'));
    }, 'Require an accepted MKV seek and actual target clock, or a native 50004 rejection and the matching app warning.', 20_000);

    const expected = evidence.outcome === 'accepted' ? target : origin;
    if (evidence.outcome === 'rejected-50004') {
      assert.equal(await text('player-seek-warning'), 'That position could not be reached. You can continue from the current position.');
    } else {
      assert.equal(await exists(byID('player-seek-warning')), false, 'A confirmed MKV seek must clear the warning.');
    }
    await sleep(1500);
    const paused = await position();
    assert(Math.abs(paused - expected) <= (evidence.outcome === 'accepted' ? 2 : 1), 'The paused MKV clock must stay at the confirmed position.');
    assert.deepEqual(await seekEvidenceSince(mark), [evidence], 'No delayed duplicate or retry may move the MKV clock.');
    await capture('06-mkv-seek-outcome');

    await click('action-play'); await element(byID('action-pause'));
    await waitFor(async () => await position() >= paused + 1, 'MKV must continue decoding from its actual position.');
    await click('action-pause'); await element(byID('action-play'));
    const saved = await position();
    if (evidence.outcome === 'rejected-50004') {
      assert(saved < target - 2, 'Recovered playback must not jump to the rejected target.');
    }
    await key(158); await element(byID('detail-title')); await element(byID('action-resume'));
    const resumeMark = (await stat(nativeLog)).size;
    await click('action-resume');
    await waitFor(async () => await position() >= 1, 'Reopening the MKV must render and advance.');
    if (evidence.outcome === 'rejected-50004') {
      await click('action-pause'); await element(byID('action-play'));
      const reopened = await position();
      const resumeRequests = await seekEvidenceSince(resumeMark);
      assert(reopened <= saved + 2, 'Reopened MKV playback must stay at or before the verified checkpoint.');
      assert(resumeRequests.every(request => request.requested <= saved + 2),
        'The saved MKV checkpoint must never request the fabricated seek target on reopen.');
    }
    await writeFile(resolve(output, 'mkv-seek-outcome.json'), JSON.stringify({container: 'mkv', origin, target,
      native: evidence, confirmedPausedPosition: paused, verifiedCheckpoint: saved}, null, 2) + '\n');
    await key(158); await element(byID('detail-title')); await click('action-back');
  });
  await step('07-continuous-television', async () => {
    await addSource('Playback NAS', endpoint.replace(/MEDIALIBRARY$/, 'MEDIAPLAYBACK'));
    await click('library-section'); await element("//*[@role='text' and text='Choose a section']");
    await click('action-tv-shows'); await requirePlaybackHome('The TV shows section must reopen Home.', 'TV shows');
    await click('media-group-show:fixture show|');
    await waitFor(async () => await exists("//*[@role='text' and text='Fixture Show']")
      && await exists("//*[@role='text' and text='Choose a season']"), 'The exact Fixture Show must open its season picker.');
    await click('action-season-1');
    await element("//*[@role='text' and text='Fixture Show · Season 1']");
    await clickXPath('//*[starts-with(@test_id,"item-open-") and contains(@test_id,"Fixture Show.S01E01.mp4")]');
    await playFixtureDetail('Fixture Show', 'Fixture Show.S01E01.mp4');
    await click('action-auto-play-next-episode-off');
    await waitFor(() => exists(byID('action-stop-after-this-episode')), 'Episode completion must offer a cancellable countdown.', 40_000);
    await click('action-stop-after-this-episode'); await element(byID('action-play-next-fixture-show'));
    await click('player-subtitles');
    const subtitleChoice = label => `//*[starts-with(@test_id,'subtitle-track-') and @description='${label}']`;
    await element(subtitleChoice('English'));
    assert.equal(await exists(subtitleChoice('German')), false, 'An oversized subtitle must be skipped while valid language choices remain available.');
    await clickXPath(subtitleChoice('Spanish'));
    await element(byID('player-subtitles') + "[@description='Subtitles · Spanish']");
    await click('player-subtitles'); await click('subtitle-off');
    await element(byID('player-subtitles') + "[@description='Subtitles · Off']");
    await sleep(11000); assert.match(await text('player-file-name'), /S01E01/, 'Stopping the countdown must leave the current episode.');
    await click('action-play-next-fixture-show');
    await waitFor(async () => (await call('GET', '/source')).includes('Fixture Show.S01E02.mp4'), 'Manual Play Next must open episode two.');
    await waitFor(async () => (await call('GET', '/source')).includes('Fixture Show.S01E04.mp4'), 'Automatic next episode must advance across the missing episode three.', 55_000);
    await waitFor(async () => await position() >= 1, 'The automatically selected episode must actually decode and advance.', 40_000);
    await capture('07-next-episode-playing'); await key(158);
    await click('action-back'); await click('action-back'); await click('action-back'); await click('library-section'); await click('action-all-media');
  });
  await step('08-household-filtering', async () => {
    await click('action-sources'); await click('action-set-up-household-profiles');
    await enter('field-administrator-pin', '482619'); await enter('field-confirm-administrator-pin', '482619');
    await enter('field-profile-name', 'Kids');
    await focusVisible(byID('action-add-profile-pin'));
    assert.equal(await exists(byID('field-profile-pin-optional')), false, 'A new viewer must have no open optional PIN editor.');
    assert.equal(await exists(keyboardDone), false, 'Focusing the Add PIN action must leave the keyboard closed.');
    await click('action-fixture-nas');
    const granted = '//*[starts-with(@test_id,"profile-source-allowed-")]';
    await waitFor(async () => {
      const matches = await call('POST', '/elements', {using: 'xpath', value: granted});
      return matches.length === 1 && await exists(granted + "[@description='Fixture NAS']");
    }, 'Only the exact Fixture NAS grant must be selected before saving.');
    await click('action-save-profile');
    await waitFor(async () => await exists(byID('action-set-up-household-profiles')) && !await exists(byID('field-profile-name')),
      'The household profile must finish saving before switching profiles.');
    await click('action-everyone'); await click('action-kids'); await click('action-continue');
    await element(byID(feature));
    assert.equal(await exists('//*[starts-with(@test_id,"media-group-") and contains(@test_id,":Seek Controls.mp4")]'), false,
      'The viewer must not receive a title from the ungranted Formats NAS.');
    assert.equal(await exists('//*[starts-with(@test_id,"media-group-") and contains(@test_id,"Invalid Metadata.mp4")]'), false,
      'A restricted profile must not receive a title with malformed/unknown rating.');
    assert.equal(await exists(byID('action-sources')), false, 'A viewer cannot manage credentials or household permissions.');
    await click('action-collections');
    await waitFor(async () => await exists("//*[@role='text' and text='Your collections']")
      && await exists(byID('field-new-collection-name')), 'The restricted profile must reach its collections before checking isolation.');
    assert.equal(await exists(byID('action-movie-night-1-title')), false, 'Collections belong to the creating profile.');
  });
  await step('09-pin-rejection-and-unlock', async () => {
    await click('action-back'); await click('action-kids'); await click('action-everyone-pin-protected');
    await enter('field-profile-pin', '000000'); await click('action-continue');
    await waitFor(async () => (await call('GET', '/source')).includes('That PIN did not match'), 'An incorrect PIN must be rejected.');
    await assertLibraryHidden('Failed PIN entry must not reveal the library.');
    await enter('field-profile-pin', '482619', '000000'); await click('action-continue');
    await waitFor(async () => await homePresent() && await exists(byID('action-everyone'))
      && await exists(byID('action-sources')) && !await exists(byID('field-profile-pin')),
      'The correct PIN must clear the editor and reopen the Everyone administrator library.');

    // The unlocked poster grid may initially publish only other sources' cards.
    const featureTitle = 'Library Feature';
    await click('library-search');
    await enter('field-search-your-library', featureTitle);
    await click('action-show-results');
    await click(feature);
    await clickXPath('//*[starts-with(@test_id,"item-open-") and contains(@test_id,"Directors Cut.mp4")]');
    assert.equal(await text('detail-title'), featureTitle, 'The unlocked library search must open the exact fixture movie.');
    await element(byID('action-play'));
    // The journey capture now shows the playable detail after the PIN editor closed.
  });
  if (!fixtureBuild) { await step('10-keystore-and-source-persistence', async () => {
    await call('POST', '/appium/device/terminate_app', {appId: packageId});
    await call('POST', '/appium/device/activate_app', {appId: packageId + '.main'});
    await element(byID('action-everyone-pin-protected'));
    await assertLibraryHidden('Restart must keep the protected household locked.');
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
