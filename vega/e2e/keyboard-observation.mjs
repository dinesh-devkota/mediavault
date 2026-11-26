import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {performance} from 'node:perf_hooks';
import {fileURLToPath} from 'node:url';

export const keyboardApp = "//app[@appName='com.amazon.silverstone']";
export const keyboardDone = keyboardApp + "//*[@test_id='key_Done']";

const rpcTimeoutMs = 2000;
const pollDelayMs = 250;
const keyboardPageInspector = fileURLToPath(new URL('./check-keyboard-page.py', import.meta.url));

// The Kepler driver does not time out its upstream keyboard requests. A stuck
// read otherwise keeps Appium's session queue occupied after the client aborts.
export function simulatorKeyboardRpc(port, request = fetch) {
  assert(/^\d+$/.test(port) && Number(port) > 1023 && Number(port) < 65536,
    'The simulator keyboard RPC port must be a valid loopback port.');
  const endpoint = `http://127.0.0.1:${port}/jsonrpc`;
  return async (method, params, timeoutMs) => {
    assert(method === 'visibilityOf' || method === 'getPageSource', 'Only keyboard observations can use the direct RPC.');
    const response = await request(endpoint, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      redirect: 'error',
      body: JSON.stringify({jsonrpc: '2.0', id: '0', method, params}),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) { throw new Error('Native keyboard request failed.'); }
    const envelope = await response.json();
    return envelope?.jsonrpc === '2.0' && envelope.id === '0' ? envelope : null;
  };
}

function inspectKeyboardPage(xml, packageId, fieldId, timeoutMs) {
  return new Promise(resolve => {
    // Inspect only structural attributes. Never log or persist the raw page.
    const inspector = spawn('python3', [keyboardPageInspector, packageId, fieldId], {
      timeout: timeoutMs, stdio: ['pipe', 'ignore', 'ignore'],
    });
    inspector.stdin.on('error', () => {});
    inspector.once('error', () => resolve(null));
    inspector.once('close', code => resolve(code === 10 ? true : code === 0 ? false : null));
    inspector.stdin.end(xml);
  });
}

// The pinned driver's /source endpoint uses this same native method. Unlike an
// empty XPath result, a complete page can independently confirm the form is
// still present and the Silverstone Done control is absent after Back.
export function keyboardDonePresenceReader(rpc, {packageId, fieldId, onOutcome = () => {}}) {
  return async timeoutMs => {
    const deadline = performance.now() + timeoutMs;
    try {
      const response = await rpc('getPageSource', {}, timeoutMs);
      if (response?.jsonrpc !== '2.0' || response.id !== '0' || response.error != null || typeof response.result !== 'string') {
        onOutcome('invalid-native-response');
        return null;
      }
      const remaining = Math.floor(deadline - performance.now());
      const present = remaining > 0 ? await inspectKeyboardPage(response.result, packageId, fieldId, remaining) : null;
      onOutcome(present === null ? 'unverified-hierarchy' : present ? 'present' : 'absent');
      return present;
    } catch (error) {
      onOutcome(error?.name === 'TimeoutError' ? 'timeout' : 'unavailable');
      return null;
    }
  };
}

// Preserve three distinct outcomes. The driver's W3C displayed endpoint maps
// empty or unsupported RPC responses to false, which is not closure evidence.
export function keyboardVisibilityReader(rpc) {
  return async (id, budgetMs = rpcTimeoutMs) => {
    const objectId = Number(id);
    if (!/^\d+$/.test(id) || !Number.isSafeInteger(objectId)) {
      return {displayed: null, outcome: 'invalid-id'};
    }
    try {
      const payload = await rpc(objectId, Math.max(1, Math.min(rpcTimeoutMs, Math.floor(budgetMs))));
      const portions = payload?.result?.visiblePortions;
      if (payload?.error || !Array.isArray(portions)) {
        return {displayed: null, outcome: 'unknown'};
      }
      return portions.length ? {displayed: true, outcome: 'visible'} : {displayed: false, outcome: 'hidden'};
    } catch (error) {
      return {displayed: null, outcome: error?.name === 'TimeoutError' ? 'timeout' : 'unavailable'};
    }
  };
}

export async function waitForKeyboardDismissal({windowId, readVisibility, isDonePresent,
  onObservation = () => {}, timeoutMs = 30_000, now = () => performance.now(),
  pause = ms => new Promise(done => setTimeout(done, ms))}) {
  const deadline = now() + timeoutMs;
  let visibility = 'unobserved', done = 'unobserved', attempts = 0;
  while (now() < deadline) {
    const started = now();
    const observation = await readVisibility(windowId, deadline - started);
    visibility = observation.outcome;
    done = 'unobserved';
    // Avoid extra network requests while visibility is indeterminate or the
    // latched window is still visible. Require a verified Done observation.
    if (observation.displayed === false && now() < deadline) {
      try {
        const present = await isDonePresent(Math.max(1, Math.min(rpcTimeoutMs, Math.floor(deadline - now()))));
        done = present === true ? 'present' : present === false ? 'absent' : 'unknown';
      } catch { done = 'unknown'; }
    }
    onObservation({attempt: ++attempts, visibility, done, elapsedMs: Math.round(now() - started)});
    if (observation.displayed === false && done === 'absent' && now() < deadline) { return; }
    const delay = Math.min(pollDelayMs, deadline - now());
    if (delay > 0) { await pause(delay); }
  }
  throw new Error(`Keyboard dismissal could not be confirmed for the same system window after Back (visibility: ${visibility}, Done: ${done}, attempts: ${attempts}).`);
}
