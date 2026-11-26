import {NativeVideo, PlayerSession} from '../src/ui/PlayerSession';
import {PlaybackResource} from '../src/domain/model';

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return {promise, resolve};
}
const sessions: PlayerSession[] = [];
const flush = async () => { for (let i = 0; i < 10; i++) { await Promise.resolve(); } };
function make() {
  const raw = {position: 0, duration: 100, paused: true, ended: false, seeking: false, error: null as NativeVideo['error']};
  const order: string[] = [], seeks: number[] = [];
  const listeners = new Map<string, () => void>();
  const video: NativeVideo = {
    src: '',
    get currentTime() { return raw.position; },
    set currentTime(value) { seeks.push(value); raw.position = value; },
    get duration() { return raw.duration; }, get paused() { return raw.paused; },
    get ended() { return raw.ended; }, get seeking() { return raw.seeking; }, get error() { return raw.error; },
    initialize: jest.fn(async () => { order.push('initialize'); }),
    deinitialize: jest.fn(async () => { order.push('deinitialize'); }),
    play: jest.fn(async () => { order.push('play'); raw.paused = false; }),
    pause: jest.fn(() => { order.push('pause'); raw.paused = true; }),
    setSurfaceHandle: jest.fn(handle => { order.push('surface:' + handle); }),
    clearSurfaceHandle: jest.fn(handle => { order.push('clear-surface:' + handle); }),
    setCaptionViewHandle: jest.fn(), clearCaptionViewHandle: jest.fn(),
    addEventListener: jest.fn((name, listener) => { listeners.set(name, listener as () => void); }),
    removeEventListener: jest.fn(name => { listeners.delete(name); }),
  };
  Object.defineProperty(video, 'src', {set: value => { order.push('src:' + value); }, get: () => ''});
  const options = {
    load: jest.fn(async (): Promise<PlaybackResource> => ({uri: 'http://127.0.0.1/ticket', mime: 'video/mp4'})),
    releaseResource: jest.fn(async () => { order.push('revoke'); }),
    initialized: jest.fn(), sourceStarted: jest.fn(), state: jest.fn(), progress: jest.fn(), ended: jest.fn(), failed: jest.fn(),
  };
  const create = (extra = {}) => { const session = new PlayerSession(video, {...options, ...extra}); sessions.push(session); return session; };
  return {raw, order, seeks, video, options, create, emit: (name: string) => listeners.get(name)?.()};
}
beforeEach(() => { jest.useFakeTimers(); jest.setSystemTime(1000); });
afterEach(async () => { await Promise.all(sessions.splice(0).map(session => session.stop())); jest.useRealTimers(); });

test('URL loading waits for native initialization and an actual surface callback in either order', async () => {
  const first = make(), ready = deferred<void>();
  (first.video.initialize as jest.Mock).mockImplementation(() => ready.promise.then(() => { first.order.push('initialize'); }));
  const session = first.create(); session.start(Promise.resolve()); session.attachSurface('early-surface');
  await flush(); expect(first.order).toEqual([]); expect(first.options.initialized).not.toHaveBeenCalled();
  ready.resolve(); await flush();
  expect(first.order.slice(0, 4)).toEqual(['initialize', 'surface:early-surface', 'src:http://127.0.0.1/ticket', 'play']);
  const second = make(), later = second.create(); later.start(Promise.resolve()); await flush();
  expect(second.options.initialized).toHaveBeenCalledTimes(1);
  expect(second.video.play).not.toHaveBeenCalled(); expect(second.order).toEqual(['initialize']);
  later.attachSurface('late-surface'); await flush();
  expect(second.order.slice(0, 4)).toEqual(['initialize', 'surface:late-surface', 'src:http://127.0.0.1/ticket', 'play']);
});

test('resolved play command alone never proves startup and retains the bounded failure', async () => {
  const value = make(), session = value.create(); session.start(Promise.resolve()); await flush(); session.attachSurface('surface'); await flush();
  await jest.advanceTimersByTimeAsync(30_000);
  expect(value.options.failed).toHaveBeenCalledWith(expect.stringContaining('Playback did not start'));
  expect(value.options.progress).not.toHaveBeenCalled(); expect(value.video.deinitialize).toHaveBeenCalledTimes(1);
  expect(value.options.releaseResource).toHaveBeenCalledTimes(1);
});

test('native polling handles missing metadata and playing events and resumes exactly once', async () => {
  const value = make(); value.raw.duration = NaN;
  const session = value.create({resume: {position: 25, duration: 100, watched: false, updatedAt: 1}});
  session.start(Promise.resolve()); await flush(); session.attachSurface('surface'); await flush();
  expect(value.seeks).toEqual([]); expect(value.options.progress).not.toHaveBeenCalled();
  value.raw.duration = 100; await jest.advanceTimersByTimeAsync(250);
  expect(value.seeks).toEqual([25]);
  value.emit('loadedmetadata'); value.emit('loadedmetadata');
  value.raw.position = 25.5; await jest.advanceTimersByTimeAsync(250);
  expect(value.options.state).toHaveBeenLastCalledWith(expect.objectContaining({started: true, duration: 100, position: 25.5}));
  await jest.advanceTimersByTimeAsync(5000);
  expect(value.options.progress).toHaveBeenLastCalledWith(25.5, 100, false);
  expect(value.seeks).toEqual([25]); expect(value.options.failed).not.toHaveBeenCalled();
});

test('manual seek is not evidence of playback and pause state comes from the native player', async () => {
  const value = make(), session = value.create(); session.start(Promise.resolve()); await flush(); session.attachSurface('surface'); await flush();
  session.toggle(); expect(value.raw.paused).toBe(true);
  session.seek(30); await jest.advanceTimersByTimeAsync(250);
  expect(value.options.state).toHaveBeenLastCalledWith(expect.objectContaining({started: false, position: 30, paused: true}));
  session.toggle(); value.raw.position = 30.25; await jest.advanceTimersByTimeAsync(250);
  expect(value.options.state).toHaveBeenLastCalledWith(expect.objectContaining({started: true, paused: false}));
});

test('native ended is handled once without an event and cleanup cannot clear completed status', async () => {
  const value = make(), session = value.create(); session.start(Promise.resolve()); await flush(); session.attachSurface('surface'); await flush();
  value.raw.position = 1; await jest.advanceTimersByTimeAsync(250);
  value.raw.position = 100; value.raw.ended = true; value.raw.paused = true;
  await jest.advanceTimersByTimeAsync(250); value.emit('ended'); value.emit('timeupdate'); await session.stop();
  expect(value.options.ended).toHaveBeenCalledTimes(1);
  expect(value.options.progress).toHaveBeenLastCalledWith(100, 100, true);
  expect(value.options.progress.mock.calls.filter(call => call[2] === true)).toHaveLength(1);
  expect(value.video.clearSurfaceHandle).toHaveBeenCalledWith('surface');
  expect(value.video.deinitialize).toHaveBeenCalledTimes(1); expect(value.options.releaseResource).toHaveBeenCalledTimes(1);
});

test('stopping during initialization prevents source, surface, captions and playback after completion', async () => {
  const value = make(), initialized = deferred<void>();
  (value.video.initialize as jest.Mock).mockReturnValue(initialized.promise);
  const session = value.create(); session.start(Promise.resolve()); await flush();
  const stopped = session.stop(); session.attachSurface('late-surface'); session.attachCaption('late-caption');
  expect(value.video.deinitialize).not.toHaveBeenCalled(); initialized.resolve(); await stopped;
  expect(value.options.initialized).not.toHaveBeenCalled(); expect(value.video.setSurfaceHandle).not.toHaveBeenCalled();
  expect(value.video.setCaptionViewHandle).not.toHaveBeenCalled(); expect(value.video.play).not.toHaveBeenCalled();
  expect(value.video.deinitialize).toHaveBeenCalledTimes(1); expect(value.options.releaseResource).toHaveBeenCalledTimes(1);
});

test('a late playback ticket after cancellation is revoked without initializing the native player', async () => {
  const value = make(), ticket = deferred<PlaybackResource>(); value.options.load.mockReturnValue(ticket.promise);
  const session = value.create(); session.start(Promise.resolve()); await flush(); const stopped = session.stop();
  ticket.resolve({uri: 'http://127.0.0.1/late-ticket', mime: 'video/mp4'}); await stopped; await session.stop();
  expect(value.video.initialize).not.toHaveBeenCalled(); expect(value.video.play).not.toHaveBeenCalled();
  expect(value.options.releaseResource).toHaveBeenCalledTimes(1);
  expect(value.options.releaseResource).toHaveBeenCalledWith('http://127.0.0.1/late-ticket');
});

test('the next episode waits for prior native teardown and ticket revocation', async () => {
  const old = make(), release = deferred<void>(); (old.video.deinitialize as jest.Mock).mockReturnValue(release.promise);
  const previous = old.create(); previous.start(Promise.resolve()); await flush(); previous.attachSurface('old'); await flush();
  const stopped = previous.stop(), next = make(), successor = next.create(); successor.start(stopped); await flush();
  expect(next.options.load).not.toHaveBeenCalled(); expect(next.video.initialize).not.toHaveBeenCalled();
  release.resolve(); await flush();
  expect(old.options.releaseResource).toHaveBeenCalledTimes(1); expect(next.video.initialize).toHaveBeenCalledTimes(1);
});

test('a lost native surface stops playback and revokes its capability', async () => {
  const value = make(), session = value.create(); session.start(Promise.resolve()); await flush(); session.attachSurface('surface'); await flush();
  session.detachSurface('unrelated'); expect(value.options.failed).not.toHaveBeenCalled();
  session.detachSurface('surface'); await flush();
  expect(value.video.pause).toHaveBeenCalled(); expect(value.video.clearSurfaceHandle).toHaveBeenCalledWith('surface');
  expect(value.options.failed).toHaveBeenCalledTimes(1); expect(value.options.releaseResource).toHaveBeenCalledTimes(1);
  session.attachSurface('late-replacement'); expect(value.video.play).toHaveBeenCalledTimes(1);
});

test('surface cleanup failure still deinitializes the decoder and revokes the ticket', async () => {
  const value = make(), session = value.create(); session.start(Promise.resolve()); await flush(); session.attachSurface('surface'); await flush();
  (value.video.clearSurfaceHandle as jest.Mock).mockImplementation(() => { throw new Error('surface already gone'); });
  await session.stop();
  expect(value.video.deinitialize).toHaveBeenCalledTimes(1); expect(value.options.releaseResource).toHaveBeenCalledTimes(1);
});
