import assert from 'node:assert/strict';
import {performance} from 'node:perf_hooks';

export const keyboardApp = "//app[@appName='com.amazon.silverstone']";
export const keyboardDone = keyboardApp + "//*[@test_id='key_Done']";

const rpcTimeoutMs = 2000;
const pollDelayMs = 250;

// Appium 3.30.0 does not time out its upstream visibility request. A stuck
// read otherwise keeps Appium's session queue occupied after the client aborts.
export function simulatorVisibilityRpc(port, request = fetch) {
  assert(/^\d+$/.test(port) && Number(port) > 1023 && Number(port) < 65536,
    'The simulator visibility port must be a valid loopback port.');
  const endpoint = `http://127.0.0.1:${port}/jsonrpc`;
  return async (id, timeoutMs) => {
    const response = await request(endpoint, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      redirect: 'error',
      body: JSON.stringify({jsonrpc: '2.0', id: '0', method: 'visibilityOf', params: {id}}),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) { throw new Error('Native visibility request failed.'); }
    const envelope = await response.json();
    return envelope?.jsonrpc === '2.0' && envelope.id === '0' ? envelope : null;
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
    // latched window is still visible. A missing Done control cannot pass.
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
  throw new Error(`The same system keyboard window did not become hidden after Back (visibility: ${visibility}, Done: ${done}, attempts: ${attempts}).`);
}
