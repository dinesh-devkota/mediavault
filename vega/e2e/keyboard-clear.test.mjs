import assert from 'node:assert/strict';
import test from 'node:test';
import {activateKeyboardClear} from './keyboard-clear.mjs';

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
