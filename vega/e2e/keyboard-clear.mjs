import assert from 'node:assert/strict';

const elementKey = 'element-6066-11e4-a52e-4f735466cecf';
const keyboardApp = "//app[@appName='com.amazon.silverstone']";
const clearPath = keyboardApp + "//*[@test_id='key_Clear']";
const focusedKeys = keyboardApp + "//*[starts-with(@test_id,'key_') and @focused='true']";

// The system keyboard accepts setFocus RPCs without moving native focus.
// Traverse its actual keys with remote arrows; never read editor contents.
export async function activateKeyboardClear({call, key, nativeDisplayed, windowId,
  now = Date.now, pause = ms => new Promise(done => setTimeout(done, ms))}) {
  const deadline = now() + 25_000;
  const checkDeadline = () => assert(now() < deadline, 'Remote keyboard navigation exceeded its 25-second deadline.');
  const find = xpath => call('POST', '/elements', {using: 'xpath', value: xpath});
  const focused = async id => await call('GET', `/element/${id}/attribute/UiObject:focused`) === 'true';
  async function observe() {
    checkDeadline();
    assert.equal(await nativeDisplayed(windowId), true, 'The system keyboard must remain visibly open while selecting Clear.');
    const clear = await find(clearPath);
    assert.equal(clear.length, 1, 'The system keyboard must expose exactly one Clear control.');
    const clearId = clear[0][elementKey];
    assert.equal(await nativeDisplayed(clearId), true, 'The system Clear control must remain natively visible.');
    const candidates = await find(focusedKeys), active = [];
    for (const candidate of candidates) {
      const id = candidate[elementKey];
      if (await focused(id)) { active.push(id); }
    }
    assert(active.length <= 1, 'The system keyboard reported ambiguous native key focus.');
    return {clearId, focusedId: active[0]};
  }
  async function awaitFocus(previous) {
    const movementDeadline = Math.min(deadline, now() + 1000);
    do {
      const state = await observe();
      if (state.focusedId && state.focusedId !== previous) { return state; }
      await pause(50);
    } while (now() < movementDeadline);
    throw new Error(previous ? 'The remote arrow did not move native keyboard focus.' : 'The system keyboard did not expose one natively focused key.');
  }
  let state = await awaitFocus();
  const traversed = new Set();
  while (now() < deadline) {
    if (state.focusedId === state.clearId) {
      assert.equal(await focused(state.clearId), true, 'Clear must retain native focus before Select.');
      assert.equal(await nativeDisplayed(state.clearId), true, 'Clear must remain visible before Select.');
      assert.equal(await call('GET', `/element/${state.clearId}/enabled`), true, 'The system Clear action must be enabled.');
      checkDeadline();
      await key(96);
      return;
    }
    const current = await call('GET', `/element/${state.focusedId}/rect`);
    const target = await call('GET', `/element/${state.clearId}/rect`);
    for (const rect of [current, target]) {
      assert(['x', 'y', 'width', 'height'].every(name => Number.isFinite(rect[name])) && rect.width > 0 && rect.height > 0,
        'Keyboard navigation requires valid native key bounds.');
    }
    const x = target.x + target.width / 2, y = target.y + target.height / 2;
    const direction = y < current.y ? 103 : y >= current.y + current.height ? 108
      : x < current.x + current.width / 2 ? 105 : 106;
    const edge = `${state.focusedId}:${direction}`;
    assert(!traversed.has(edge), 'Remote keyboard navigation repeated a key without reaching Clear.');
    traversed.add(edge);
    checkDeadline();
    await key(direction);
    state = await awaitFocus(state.focusedId);
  }
  throw new Error('Remote keyboard navigation exceeded its 25-second deadline.');
}
