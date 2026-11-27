import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const script = readFileSync(new URL('../web/picker.js', import.meta.url), 'utf8');

function element() {
  return {
    dataset: {},
    addEventListener(name, handler) { this[name] = handler; },
    replaceChildren(...children) { this.children = children; },
    focus() { this.focused = true; },
  };
}

test('pair entry uppercases the TV code before the ordinary form POST', () => {
  const input = element();
  input.value = 'a1b2c3d4';
  runInNewContext(script, { document: { getElementById: id => id === 'pair-code' ? input : null } });
  input.input();
  assert.equal(input.value, 'A1B2C3D4');
});

test('Picker review confirms exact file IDs and safely handles optional resource keys', async () => {
  const ids = ['picker-page', 'open-picker', 'confirm-selection', 'selection-review',
    'review-title', 'selected-files', 'picker-status'];
  const elements = Object.fromEntries(ids.map(id => [id, element()]));
  const requests = [];
  const redirects = [];
  const provided = {};
  let callback;
  let visible;
  const selectionErrors = ['name_collision', 'invalid_filename', 'unsupported_media'];

  class DocsView {
    setIncludeFolders(value) { assert.equal(value, true); return this; }
    setSelectFolderEnabled(value) { assert.equal(value, false); return this; }
    setMode(value) { assert.equal(value, 'list'); return this; }
  }

  class PickerBuilder {
    addView() { return this; }
    enableFeature(value) { assert.equal(value, 'multi'); return this; }
    setMaxItems(value) { assert.equal(value, 100); return this; }
    setAppId(value) { provided.appId = value; return this; }
    setDeveloperKey(value) { provided.key = value; return this; }
    setOAuthToken(value) { provided.token = value; return this; }
    setOrigin(value) { provided.origin = value; return this; }
    setCallback(value) { callback = value; return this; }
    build() { return { setVisible(value) { visible = value; }, dispose() { visible = false; } }; }
  }

  const picker = {
    DocsView, PickerBuilder,
    ViewId: { DOCS: 'docs' },
    DocsViewMode: { LIST: 'list' },
    Feature: { MULTISELECT_ENABLED: 'multi' },
    Response: { ACTION: 'action', DOCUMENTS: 'docs' },
    Action: { PICKED: 'picked', CANCEL: 'cancel' },
    Document: { ID: 'id', RESOURCE_KEY: 'legacyKey', MIME_TYPE: 'mimeType', NAME: 'name' },
  };
  const origin = 'https://companion.fixture.invalid';
  runInNewContext(script, {
    window: { google: { picker }, location: { origin, replace: path => redirects.push(path) } },
    document: { getElementById: id => elements[id] ?? null, createElement: tag => ({ tag }) },
    async fetch(path, options) {
      requests.push([path, options]);
      if (path === '/browser/selection' && selectionErrors.length) {
        const error = selectionErrors.shift();
        return { ok: false, json: async () => ({ error }) };
      }
      const json = path === '/browser/session'
        ? { accessToken: 'temporary-token', googleAppId: '12345', pickerApiKey: 'public-key' }
        : { ok: true };
      return { ok: true, json: async () => json };
    },
  });

  const open = elements['open-picker'];
  const review = elements['selection-review'];
  assert.equal(requests.length, 0);
  await open.click();
  assert.deepEqual(provided, { appId: '12345', key: 'public-key', token: 'temporary-token', origin });
  assert.equal(visible, true);
  callback({ action: 'cancel' });
  assert.equal(visible, false);
  assert.equal(open.disabled, false);

  for (const docs of [
    [{ id: 'folder', mimeType: 'application/vnd.google-apps.folder' }],
    [{ id: 'file', resourceKey: 'invalid/key' }],
    Array.from({ length: 101 }, (_, index) => ({ id: String(index) })),
  ]) {
    await open.click();
    callback({ action: 'picked', docs });
    assert.equal(review.hidden, true);
    assert.match(elements['picker-status'].textContent, /individual/);
  }

  await open.click();
  callback({ action: 'picked', docs: [
    { id: 'Film', resourceKey: 'key-A', name: '<b>Film.mp4</b>', mimeType: 'video/mp4' },
    { id: 'film', legacyKey: 'key-B', name: 'Film.en.srt', mimeType: 'text/plain' },
    { id: 'poster_1', resourceKey: '', name: 'Poster.jpg', mimeType: 'image/jpeg' },
    { id: 'poster_2', legacyKey: null, name: 'Other.png', mimeType: 'image/png' },
  ] });
  assert.equal(elements['selected-files'].children[0].textContent, '<b>Film.mp4</b>');
  assert.equal(elements['review-title'].focused, true);
  assert.equal(review.hidden, false);
  assert.equal(requests.some(([path]) => path === '/browser/selection'), false);

  await elements['confirm-selection'].click();
  assert.match(elements['picker-status'].textContent, /same name.*Rename one/);
  assert.deepEqual(redirects, []);
  assert.equal(open.disabled, false);
  assert.equal(review.hidden, false);

  await elements['confirm-selection'].click();
  assert.match(elements['picker-status'].textContent, /name MediaVault can’t use.*Rename it/);
  assert.deepEqual(redirects, []);

  await elements['confirm-selection'].click();
  assert.match(elements['picker-status'].textContent, /Choose supported videos.*SRT\/VTT/);
  assert.deepEqual(redirects, []);

  await elements['confirm-selection'].click();
  const [path, request] = requests.at(-1);
  assert.equal(path, '/browser/selection');
  assert.equal(request.method, 'POST');
  assert.deepEqual(JSON.parse(request.body), { files: [
    { id: 'Film', resourceKey: 'key-A' }, { id: 'film', resourceKey: 'key-B' },
    { id: 'poster_1' }, { id: 'poster_2' },
  ] });
  for (const [, options] of requests) {
    assert.equal(options.cache, 'no-store');
    assert.equal(options.credentials, 'same-origin');
    assert.equal(options.redirect, 'error');
    assert.equal(JSON.stringify(options).includes('temporary-token'), false);
  }
  assert.deepEqual(redirects, ['/pair/complete']);
});
