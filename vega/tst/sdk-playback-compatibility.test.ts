/// <reference types="node" />
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
import {ModuleKind, transpileModule} from 'typescript';
import type {TextTrack} from '@amazon-devices/react-native-w3cmedia';
import {NativeVideo, PlayerSession} from '../src/ui/PlayerSession';
import {SubtitleSelection} from '../src/ui/PlaybackTracks';

// Execute the installed SDK methods, not copies of their implementation. Only
// native calls and unrelated module constructors are replaced at this boundary.
// A pin update must explicitly recheck these compatibility assumptions.
function sdkModule(file: string, dependencies: Record<string, unknown>): Record<string, any> {
  const output: Record<string, any> = {};
  runInNewContext(readFileSync(require.resolve('@amazon-devices/react-native-w3cmedia/dist/' + file), 'utf8'), {
    exports: output,
    require: (name: string) => dependencies[name] ?? {},
  });
  return output;
}
const log = {LogUtil: {debug: () => {}, info: () => {}, warn: () => {}}};
const flush = async () => { for (let i = 0; i < 20; i++) { await Promise.resolve(); } };

test('the installed SDK owns remote transport once with the explicit ten-second interval', () => {
  // These enums are supplied by the system bundle on Vega. Compile their pinned
  // declarations for this native-free boundary instead of inventing enum values.
  const types: Record<string, any> = {};
  const typePath = require.resolve('@amazon-devices/react-native-kepler/Libraries/PlayerSession/api/PlayerSessionTypes.d.ts');
  runInNewContext(transpileModule(readFileSync(typePath, 'utf8').replace(/export declare enum/g, 'export enum'),
    {compilerOptions: {module: ModuleKind.CommonJS}}).outputText, {exports: types});
  const typeDependency = {'@amazon-devices/react-native-kepler/Libraries/PlayerSession/api/PlayerSessionTypes': types};
  const stateUtils = sdkModule('playersessionclient/PlaybackStateUtils.js', typeDependency);
  const defaults = sdkModule('playersessionclient/PlayerSessionClientTypes.js', typeDependency);
  const {PlayerSessionClient} = sdkModule('playersessionclient/PlayerSessionClient.js', {
    ...typeDependency, '../LogUtils': log, './PlaybackStateUtils': stateUtils, './PlayerSessionClientTypes': defaults,
  });
  const native = {getCurrentTime: () => 20, seek: jest.fn()};
  const {MediaPlayer} = sdkModule('MediaPlayer.js', {
    './LogUtils': log, './interface/HTMLMediaElement': {HTMLMediaElement: class {}}, './turbo-modules/W3CMediaTurboModule': native,
  });
  const client = new PlayerSessionClient();
  MediaPlayer.isPlayerSessionEnabled = true; MediaPlayer.playerSessionClient = client;
  const sdk = Object.assign(Object.create(MediaPlayer.prototype), {mediaElement: {id: 1}, play: jest.fn(), pause: jest.fn()});
  client.mediaPlayer = sdk; client.playerState = types.PlayerState.PLAYER_STATE_PAUSED;
  sdk.defaultSeekIntervalInSec = 10;
  expect(sdk.defaultSeekIntervalInSec).toBe(10);
  client.callbacks.onFastForward(-1, -1);
  expect(native.seek).toHaveBeenCalledTimes(1); expect(native.seek).toHaveBeenLastCalledWith(sdk.mediaElement, 30);
  client.callbacks.onRewind(-1, -1);
  expect(native.seek).toHaveBeenCalledTimes(2); expect(native.seek).toHaveBeenLastCalledWith(sdk.mediaElement, 10);
  client.callbacks.onPlay(); expect(sdk.play).toHaveBeenCalledTimes(1);
  client.playerState = types.PlayerState.PLAYER_STATE_PLAYING;
  client.callbacks.onPause(); expect(sdk.pause).toHaveBeenCalledTimes(1);
  client.callbacks.onStop(); expect(sdk.pause).toHaveBeenCalledTimes(2); // Stop is a pause, not app dismissal.
});

test('a pinned SDK seek setter can return without moving and the session recovers on failed seeked', async () => {
  jest.useFakeTimers();
  const boundary = {position: 1, acceptsSeek: false};
  const native = {getCurrentTime: () => boundary.position,
    seek: jest.fn((_element: unknown, position: number) => { if (boundary.acceptsSeek) { boundary.position = position; } })};
  const {MediaPlayer} = sdkModule('MediaPlayer.js', {
    './LogUtils': log, './interface/HTMLMediaElement': {HTMLMediaElement: class {}}, './turbo-modules/W3CMediaTurboModule': native,
  });
  const sdk = Object.assign(Object.create(MediaPlayer.prototype), {mediaElement: {id: 1}});
  const events = new Map<string, () => void>();
  const video = {
    src: '', defaultSeekIntervalInSec: 0, duration: 60, paused: true, seeking: false, ended: false, error: null,
    get currentTime() { return sdk.currentTime; }, set currentTime(position: number) { sdk.currentTime = position; },
    initialize: async () => {}, deinitialize: jest.fn(async () => {}), play: async () => {}, pause: () => {},
    setSurfaceHandle: () => {}, clearSurfaceHandle: () => {}, setCaptionViewHandle: () => {}, clearCaptionViewHandle: () => {},
    addEventListener: (name: string, callback: () => void) => events.set(name, callback), removeEventListener: (name: string) => events.delete(name),
  } as unknown as NativeVideo;
  const state = jest.fn(), failed = jest.fn();
  const session = new PlayerSession(video, {load: async () => ({uri: 'http://127.0.0.1/fixture', mime: 'video/x-matroska'}),
    releaseResource: async () => {}, initialized: () => {}, sourceStarted: () => {}, state, failed, progress: () => {}, ended: () => {}});
  try {
    session.start(Promise.resolve()); await flush(); session.attachSurface('surface'); await flush();
    session.seek(30); events.get('seeked')?.();
    expect(native.seek).toHaveBeenCalledWith(sdk.mediaElement, 31);
    expect(state).toHaveBeenLastCalledWith(expect.objectContaining({position: 1, paused: true, seekWarning: expect.stringContaining('could not be reached')}));
    expect(failed).not.toHaveBeenCalled(); expect(video.deinitialize).not.toHaveBeenCalled();
    boundary.acceptsSeek = true; session.seek(30); events.get('seeked')?.();
    expect(state).toHaveBeenLastCalledWith(expect.objectContaining({position: 31, seekWarning: undefined}));
  } finally { await session.stop(); jest.useRealTimers(); }
});

test('startup timeout aborts the pinned SDK initialization and destroys a late native element', async () => {
  expect(JSON.parse(readFileSync(require.resolve('@amazon-devices/react-native-w3cmedia/package.json'), 'utf8')).version).toBe('2.3.5');
  jest.useFakeTimers();
  let nativeCreated!: (element: {id: number}) => Promise<void>;
  const native = {
    newMediaElementConfig: () => ({}), setWaitForAudioToCompleteSeek: () => {}, setAudioConfig: () => {},
    newMediaElement: (_config: unknown, callback: typeof nativeCreated) => { nativeCreated = callback; },
    destroy: jest.fn((_element: unknown, done: () => void) => done()),
  };
  const {MediaPlayer} = sdkModule('MediaPlayer.js', {
    './LogUtils': log,
    './interface/HTMLMediaElement': {HTMLMediaElement: class {}},
    './turbo-modules/W3CMediaTurboModule': native,
  });
  MediaPlayer.isAppManifestParsed = true;
  const sdk = Object.assign(Object.create(MediaPlayer.prototype), {mediaElement: null, captionViewHandle: null});
  const video = {
    initialize: jest.fn(() => sdk.initialize()), deinitialize: jest.fn(() => sdk.deinitialize()),
    addEventListener: () => {}, removeEventListener: () => {}, play: jest.fn(), pause: jest.fn(),
  } as unknown as NativeVideo;
  const options = {
    load: jest.fn(async () => ({uri: 'http://127.0.0.1/fixture', mime: 'video/mp4'})),
    releaseResource: jest.fn(async () => {}), initialized: jest.fn(), sourceStarted: jest.fn(),
    state: jest.fn(), progress: jest.fn(), ended: jest.fn(), failed: jest.fn(),
  };
  const session = new PlayerSession(video, options);
  let reentrantRelease: Promise<void> | undefined;
  (video.deinitialize as jest.Mock).mockImplementation(() => { reentrantRelease = session.stop(); return sdk.deinitialize(); });
  try {
    session.start(Promise.resolve()); await flush();
    expect(nativeCreated).toBeDefined(); expect(options.initialized).not.toHaveBeenCalled();
    await jest.advanceTimersByTimeAsync(30_000); await session.stop();
    expect(options.failed).toHaveBeenCalledTimes(1);
    expect(options.failed).toHaveBeenCalledWith(expect.stringContaining('Playback did not start'));
    expect(video.deinitialize).toHaveBeenCalledTimes(1);
    expect(reentrantRelease).toBe(session.stop());
    expect(options.releaseResource).toHaveBeenCalledTimes(1);
    expect(video.play).not.toHaveBeenCalled();
    // The SDK owns a callback arriving after abort; it must destroy it without
    // resolving the abandoned session or exposing another playable surface.
    await nativeCreated({id: 42});
    expect(native.destroy).toHaveBeenCalledWith({id: 42}, expect.any(Function));
    expect(options.initialized).not.toHaveBeenCalled(); expect(video.play).not.toHaveBeenCalled();
  } finally { await session.stop(); jest.useRealTimers(); }
});

function tracks() {
  type Mode = TextTrack['mode'];
  const nativeModes = new Map<string, Mode>([['embedded', 'showing']]);
  const operations: string[] = [];
  const boundary = {
    getTextTrackById: (_element: unknown, id: string) => nativeModes.has(id)
      ? {id, mode: nativeModes.get(id), kind: 'subtitles', label: id, language: 'en'} : undefined,
    enableTextTrack: (_element: unknown, id: string) => { nativeModes.set(id, 'showing'); operations.push('show:' + id); },
    disableTextTrack: (_element: unknown, id: string) => { nativeModes.set(id, 'hidden'); operations.push('hide:' + id); },
  };
  const {TextTrackImpl} = sdkModule('TextTrackImpl.js', {
    './LogUtils': log, './turbo-modules/W3CMediaTurboModule': boundary,
    './MediaEventEmitterImpl': {MediaEventEmitterImpl: class {}},
  });
  const embedded = Object.assign(Object.create(TextTrackImpl.prototype), {
    _id: 'NATIVE_embedded', mediaElement: {id: 1}, textTrack: {id: 'embedded', mode: 'showing'},
  }) as TextTrack;
  const cue = {text: 'A local subtitle'};
  const cuePlayer = {addCue: jest.fn(() => operations.push('add:local')), removeCue: jest.fn(() => operations.push('remove:local')),
    runTMOAlgo: jest.fn(), requestCaptionRendererUpdate: jest.fn()};
  const local = Object.assign(Object.create(TextTrackImpl.prototype), {
    _id: 'JS_local', textTrack: null, _mode: 'disabled', textTrackCueList: [cue], _mediaPlayer: cuePlayer,
  }) as TextTrack;
  const {TrackListEventHandler} = sdkModule('TrackListEventHandler.js', {
    './LogUtils': log, './turbo-modules/W3CMediaTurboModule': boundary, './TextTrackImpl': {TextTrackImpl},
  });
  const handler = new TrackListEventHandler();
  const addNativeTrack = (current: TextTrack[], id: string): void => {
    nativeModes.set(id, 'showing');
    handler.handleTextTrackListEvent({name: 'addtrack', track_id: id}, {
      getTrackById: (trackID: string) => current.find(track => track.id === trackID),
      addTrack: (track: TextTrack) => current.push(track), emitEvent: () => {},
    }, {id: 1});
  };
  return {embedded, local, nativeModes, operations, cuePlayer, cue, addNativeTrack};
}

test('subtitle off reaches the actual SDK embedded decoder, unlike disabled alone', () => {
  const value = tracks();
  value.embedded.mode = 'disabled';
  expect(value.nativeModes.get('embedded')).toBe('showing'); expect(value.operations).toEqual([]);
  new SubtitleSelection().select([value.embedded, value.local], null);
  expect(value.nativeModes.get('embedded')).toBe('hidden');
  expect(value.operations).toEqual(['hide:embedded']);
  expect(value.local.mode).toBe('disabled'); expect(value.cuePlayer.addCue).not.toHaveBeenCalled();
});

test('switching between embedded and local subtitles stops the previous renderer before enabling the next', () => {
  const value = tracks();
  const selection = new SubtitleSelection();
  selection.select([value.embedded, value.local], value.local.id);
  expect(value.operations).toEqual(['hide:embedded', 'add:local']);
  expect(value.local.mode).toBe('showing'); expect(value.nativeModes.get('embedded')).toBe('hidden');
  value.operations.length = 0;
  selection.select([value.embedded, value.local], value.embedded.id);
  expect(value.operations).toEqual(['remove:local', 'show:embedded']);
  expect(value.cuePlayer.removeCue).toHaveBeenCalledWith(value.cue);
  expect(value.local.mode).toBe('disabled'); expect(value.nativeModes.get('embedded')).toBe('showing');
});

test('explicit subtitle Off survives delayed sidecar completion without repeated native calls', () => {
  const value = tracks(), selection = new SubtitleSelection();
  selection.select([value.embedded], null);
  // addTextTrack creates local tracks hidden while their cues are being added.
  value.local.mode = 'hidden';
  selection.preferLocal([value.embedded, value.local], value.local.id);
  expect(value.nativeModes.get('embedded')).toBe('hidden'); expect(value.local.mode).toBe('disabled');
  expect(value.cuePlayer.removeCue).toHaveBeenCalledWith(value.cue);
  const operations = [...value.operations];
  selection.reconcile([value.embedded, value.local]); selection.reconcile([value.embedded, value.local]);
  expect(value.operations).toEqual(operations);
});

test('an embedded selection made before sidecars arrive is not replaced by the automatic local default', () => {
  const value = tracks(), selection = new SubtitleSelection();
  selection.select([value.embedded], value.embedded.id);
  value.local.mode = 'hidden';
  selection.preferLocal([value.local, value.embedded], value.local.id);
  expect(value.nativeModes.get('embedded')).toBe('showing'); expect(value.local.mode).toBe('disabled');
  expect(value.operations).not.toContain('hide:embedded');
});

test('a late SDK native addtrack default cannot replace the selected sidecar', () => {
  const value = tracks(), selection = new SubtitleSelection(), current = [value.local];
  selection.preferLocal(current, value.local.id);
  value.addNativeTrack(current, 'late');
  expect(current).toHaveLength(2); expect(current[1]!.mode).toBe('showing');
  selection.reconcile(current);
  expect(value.nativeModes.get('late')).toBe('hidden'); expect(value.local.mode).toBe('showing');
  const operations = [...value.operations];
  selection.reconcile(current); selection.reconcile(current);
  expect(value.operations).toEqual(operations);
});

test('missing native track IDs receive no commands and recover the retained selection when they return', () => {
  const value = tracks(), selection = new SubtitleSelection(), current = [value.embedded, value.local];
  value.nativeModes.delete('embedded');
  expect(value.embedded.mode).toBeUndefined();
  selection.select(current, value.embedded.id); selection.reconcile(current);
  expect(value.operations).toEqual([]);
  value.nativeModes.set('embedded', 'hidden'); selection.reconcile(current);
  expect(value.operations).toEqual(['show:embedded']);

  selection.select(current, value.local.id); value.operations.length = 0;
  value.nativeModes.delete('embedded'); selection.reconcile(current);
  expect(value.operations).toEqual([]); expect(value.local.mode).toBe('showing');
  value.nativeModes.set('embedded', 'showing'); selection.reconcile(current);
  expect(value.operations).toEqual(['hide:embedded']); expect(value.local.mode).toBe('showing');
});
