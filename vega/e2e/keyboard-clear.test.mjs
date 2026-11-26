import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import test from 'node:test';
import {activateKeyboardClear} from './keyboard-clear.mjs';
import {keyboardVisibilityReader, simulatorVisibilityRpc, waitForKeyboardDismissal} from './keyboard-observation.mjs';

const elementKey = 'element-6066-11e4-a52e-4f735466cecf';
// Observed Silverstone geometry, with just the keys on the expected route.
const keys = [
  ['a', 510, 397, 90], ['k', 510, 487, 90], ['u', 510, 577, 90],
  ['shift', 510, 667, 180], ['symbols', 690, 667, 90], ['accent', 780, 667, 90],
  ['space', 870, 667, 180], ['delete', 1050, 667, 180], ['clear', 1230, 667, 180],
].map(([id, x, y, width]) => ({id, rect: {x, y, width, height: 90}}));
function transport({noMovement = false, staleFocus = false, ambiguous = false, disappear = false, unknownVisibility = false, hiddenClear = false} = {}) {
  let index = 0, clock = 0, moved = false;
  const requests = [], events = [];
  const api = {
    windowId: 'keyboard-window', now: () => clock, pause: async ms => { clock += ms; },
    nativeDisplayed: async id => id === 'keyboard-window'
      ? unknownVisibility ? null : !(disappear && moved) : !hiddenClear,
    key: async code => {
      events.push(code);
      if (code === 96) {
        assert.equal(keys[index].id, 'clear', 'Select must never activate another key.');
        return;
      }
      assert.equal(code, index < 3 ? 108 : 106, 'Arrows must follow measured row/column bounds.');
      moved = true;
      if (!noMovement) { index++; }
    },
    call: async (method, path, body) => {
      requests.push({method, path, body});
      if (path === '/execute/sync' && body.script === 'jsonrpc: setFocus') {
        return {result: true}; // The observed false acknowledgement never moves focus.
      }
      if (method === 'POST' && path === '/elements') {
        assert(body.value.startsWith("//app[@appName='com.amazon.silverstone']"));
        const ids = body.value.includes("@test_id='key_Clear'") ? ['clear']
          : ambiguous ? [keys[index].id, 'clear'] : [staleFocus && moved ? 'a' : keys[index].id];
        return ids.map(id => ({[elementKey]: id}));
      }
      const match = path.match(/^\/element\/([^/]+)\/(.+)$/);
      assert(match, `Unexpected transport request: ${method} ${path}`);
      const [, id, attribute] = match;
      if (attribute === 'attribute/UiObject:focused') {
        return (ambiguous || id === keys[index].id) ? 'true' : null;
      }
      if (attribute === 'rect') { return keys.find(key => key.id === id).rect; }
      if (attribute === 'enabled') { return true; }
      throw new Error(`Unexpected key attribute: ${attribute}`);
    },
  };
  return {api, requests, events, current: () => keys[index].id};
}
function assertNoEditorAccess(requests) {
  assert.equal(requests.some(({path}) => /\/(text|value|clear|source|screenshot)$/.test(path)), false,
    'Keyboard navigation must never request protected editor contents or captures.');
}

test('real arrows reach Clear even when direct focus reports success without moving', async () => {
  const {api, requests, events, current} = transport();
  assert.deepEqual(await api.call('POST', '/execute/sync', {script: 'jsonrpc: setFocus', args: [[{id: 'clear'}]]}), {result: true});
  assert.equal(current(), 'a');
  await activateKeyboardClear(api);
  assert.deepEqual(events, [108, 108, 108, 106, 106, 106, 106, 106, 96]);
  assert.equal(requests.filter(({path}) => path === '/execute/sync').length, 1,
    'The helper must not repeat ineffective direct focus requests.');
  assertNoEditorAccess(requests);
});

for (const [name, options, message, expectedArrows] of [
  ['no focus movement', {noMovement: true}, /did not move native keyboard focus/, 1],
  ['stale serialized focus', {staleFocus: true}, /did not move native keyboard focus/, 1],
  ['ambiguous native focus', {ambiguous: true}, /ambiguous native key focus/, 0],
  ['keyboard disappears after an arrow', {disappear: true}, /must remain visibly open/, 1],
  ['unknown keyboard visibility', {unknownVisibility: true}, /must remain visibly open/, 0],
  ['Clear is hidden', {hiddenClear: true}, /Clear control must remain natively visible/, 0],
]) {
  test(`rejects ${name} before Select`, async () => {
    const {api, requests, events} = transport(options);
    await assert.rejects(() => activateKeyboardClear(api), message);
    assert.equal(events.length, expectedArrows);
    assert.equal(events.includes(96), false);
    assert(api.now() <= 25_000);
    assertNoEditorAccess(requests);
  });
}

test('window visibility preserves an unsupported or malformed RPC as unknown', async () => {
  const responses = [
    {result: null},
    {result: {isVisible: false}},
    {result: {visiblePortions: []}, error: {code: -1}},
    {result: {visiblePortions: [{x: 10, y: 20, width: 100, height: 50}]}},
    {result: {visiblePortions: []}},
  ];
  let calls = 0;
  const readVisibility = keyboardVisibilityReader(async (id, timeout) => {
    assert.equal(id, 87);
    assert.equal(timeout, 2000);
    return responses[calls++];
  });
  assert.deepEqual(await readVisibility('wrong-window'), {displayed: null, outcome: 'invalid-id'});
  for (let i = 0; i < 3; i++) {
    assert.deepEqual(await readVisibility('87'), {displayed: null, outcome: 'unknown'});
  }
  assert.deepEqual(await readVisibility('87'), {displayed: true, outcome: 'visible'});
  assert.deepEqual(await readVisibility('87'), {displayed: false, outcome: 'hidden'});
});

test('a timed-out direct visibility request does not block a later observation', {timeout: 5000}, async () => {
  const ids = [];
  const server = createServer(async (request, response) => {
    assert.equal(request.url, '/jsonrpc');
    assert.equal(request.method, 'POST');
    const chunks = [];
    for await (const chunk of request) { chunks.push(chunk); }
    const body = JSON.parse(Buffer.concat(chunks).toString());
    ids.push(body.params.id);
    assert.deepEqual(body, {jsonrpc: '2.0', id: '0', method: 'visibilityOf', params: {id: 87}});
    if (ids.length === 1) { return; } // Native service accepts the request but gives no response.
    response.writeHead(200, {'Content-Type': 'application/json'});
    response.end(JSON.stringify({jsonrpc: '2.0', id: ids.length === 2 ? '0' : 'different', result: {visiblePortions: []}}));
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  try {
    const read = keyboardVisibilityReader(simulatorVisibilityRpc(String(server.address().port)));
    assert.deepEqual(await read('87', 250), {displayed: null, outcome: 'timeout'});
    assert.deepEqual(await read('87'), {displayed: false, outcome: 'hidden'});
    assert.deepEqual(await read('87'), {displayed: null, outcome: 'unknown'});
    assert.deepEqual(ids, [87, 87, 87]);
  } finally {
    await new Promise(done => {
      server.close(done);
      server.closeAllConnections();
    });
  }
});

function observeDismissal(visibility, done, timeoutMs = 1000) {
  let elapsed = 0;
  const windowIds = [], doneCalls = [], observations = [];
  const result = waitForKeyboardDismissal({
    windowId: '87', timeoutMs,
    now: () => elapsed, pause: async delay => { elapsed += delay; },
    readVisibility: async (id, budgetMs) => {
      assert(budgetMs > 0 && budgetMs <= timeoutMs);
      windowIds.push(id);
      const displayed = visibility.shift();
      return {displayed, outcome: displayed === false ? 'hidden' : displayed === true ? 'visible' : 'unknown'};
    },
    isDonePresent: async budgetMs => {
      assert(budgetMs > 0 && budgetMs <= timeoutMs);
      doneCalls.push(elapsed);
      return done.shift();
    },
    onObservation: value => observations.push(value),
  });
  return {result, windowIds, doneCalls, observations, elapsed: () => elapsed};
}

test('dismissal keeps the original window and waits for both positive hidden and Done absent', async () => {
  const {result, windowIds, doneCalls, observations} = observeDismissal([null, true, false, false], [true, false]);
  await result;
  assert.deepEqual(windowIds, ['87', '87', '87', '87']);
  assert.deepEqual(doneCalls, [500, 750]);
  assert.deepEqual(observations.map(value => [value.visibility, value.done]),
    [['unknown', 'unobserved'], ['visible', 'unobserved'], ['hidden', 'present'], ['hidden', 'absent']]);
});

for (const [description, visible, done, expected] of [
  ['unknown native visibility even if Done would be absent', [null], [false], /visibility: unknown, Done: unobserved/],
  ['still present Done with explicitly hidden window', Array(4).fill(false), Array(4).fill(true), /visibility: hidden, Done: present/],
  ['unknown Done state with explicitly hidden window', Array(4).fill(false), [], /visibility: hidden, Done: unknown/],
]) {
  test(`dismissal rejects ${description} at its deadline`, async () => {
    const {result, windowIds, elapsed} = observeDismissal(visible, done);
    await assert.rejects(result, expected);
    assert.deepEqual(windowIds, ['87', '87', '87', '87']);
    assert.equal(elapsed(), 1000);
  });
}
