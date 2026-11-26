import type {VideoPlayer} from '@amazon-devices/react-native-w3cmedia';
import type {PlaybackResource, ViewingState} from '../domain/model';

// This is the installed SDK's actual surface, not a browser video or synthetic clock.
// Its implementation initializes error to null although the declaration omits null.
export type NativeVideo = Pick<VideoPlayer, 'initialize' | 'deinitialize' | 'src' | 'currentTime' | 'duration' | 'paused' | 'ended' | 'seeking' |
  'play' | 'pause' | 'setSurfaceHandle' | 'clearSurfaceHandle' | 'setCaptionViewHandle' | 'clearCaptionViewHandle' | 'addEventListener' | 'removeEventListener'> & {readonly error: VideoPlayer['error'] | null};
export interface PlaybackState { position: number; duration: number; paused: boolean; started: boolean; ended: boolean; ready: boolean }
interface SessionOptions {
  load: () => Promise<PlaybackResource>;
  releaseResource: (uri: string) => Promise<void>;
  resume?: ViewingState;
  initialized: () => void;
  sourceStarted: () => void;
  state: (state: PlaybackState) => void;
  progress: (position: number, duration: number, ended: boolean) => void;
  ended: () => void;
  failed: (message: string) => void;
}
export class PlayerSession {
  private initialized = false;
  private stopped = false;
  private started = false;
  private finished = false;
  private sourceSet = false;
  private resumeChecked = false;
  private resumeTarget?: number;
  private lastPosition?: number;
  private lastWrite = 0;
  private surface?: string;
  private caption?: string;
  private resourceURI?: string;
  private operation: Promise<void> = Promise.resolve();
  private releaseTask?: Promise<void>;
  private startupTimer?: ReturnType<typeof setTimeout>;
  private sampleTimer?: ReturnType<typeof setInterval>;
  private events: Record<string, () => void> = {};

  constructor(private readonly video: NativeVideo, private readonly options: SessionOptions) {}
  get active(): boolean { return !this.stopped; }

  start(predecessor: Promise<void>): void {
    this.events = Object.fromEntries(['loadedmetadata', 'durationchange', 'canplay', 'play', 'playing', 'pause', 'timeupdate', 'seeked'].map(name => [name, () => this.sample()]));
    this.events.ended = () => this.sample(true);
    this.events.error = () => this.fail('This file could not be played on this device. Try another version or a compatible server stream.');
    for (const [event, listener] of Object.entries(this.events)) { this.video.addEventListener(event, listener); }
    this.startupTimer = setTimeout(() => {
      if (!this.started) { this.fail('Playback did not start. Check the source connection or choose another version.'); }
    }, 30_000);
    this.operation = this.prepare(predecessor).catch(reason => {
      this.fail(reason instanceof Error ? reason.message : 'Playback could not start.');
    });
  }
  private async prepare(predecessor: Promise<void>): Promise<void> {
    await predecessor;
    if (this.stopped) { return; }
    const resource = await this.options.load();
    this.resourceURI = resource.uri;
    if (this.stopped) { return; }
    if (resource.headers && Object.keys(resource.headers).length) { throw new Error('This connection needs a protected playback link. Reconnect the source.'); }
    await this.video.initialize();
    this.initialized = true;
    if (this.stopped) { return; }
    this.options.initialized();
    // React can mount later. Only the native surface callback starts URL loading.
    this.startSource();
  }
  attachSurface(handle: string): void {
    if (this.stopped || !handle) { return; }
    this.surface = handle;
    try {
      if (this.initialized && this.sourceSet) { this.video.setSurfaceHandle(handle); }
      this.startSource();
    } catch { this.fail('The video surface could not be attached. Go back and open this media again.'); }
  }
  detachSurface(handle: string): void {
    if (this.surface !== handle) { return; }
    if (this.initialized) { try { this.video.clearSurfaceHandle(handle); } catch { /* Teardown still follows below. */ } }
    this.surface = undefined;
    if (!this.stopped) { this.fail('The video surface closed. Go back and open this media again.'); }
  }
  attachCaption(handle: string): void {
    if (this.stopped || !handle) { return; }
    this.caption = handle;
    if (this.initialized) { try { this.video.setCaptionViewHandle(handle); } catch { this.caption = undefined; } }
  }
  detachCaption(handle: string): void {
    if (this.caption !== handle) { return; }
    if (this.initialized) { try { this.video.clearCaptionViewHandle(handle); } catch { /* Captions must not interrupt media playback. */ } }
    this.caption = undefined;
  }
  private startSource(): void {
    if (this.stopped || !this.initialized || !this.surface || !this.resourceURI || this.sourceSet) { return; }
    try {
      this.video.setSurfaceHandle(this.surface);
      if (this.caption) { try { this.video.setCaptionViewHandle(this.caption); } catch { this.caption = undefined; } }
      this.sourceSet = true;
      this.lastPosition = undefined;
      this.video.src = this.resourceURI;
      this.sampleTimer = setInterval(() => this.sample(), 250);
      // SDK 2.3 play() resolves when the command is issued, before frames advance.
      this.video.play().then(() => { if (!this.stopped) { this.options.sourceStarted(); this.sample(); } })
        .catch(() => this.fail('Playback could not start.'));
    } catch (reason) { this.fail(reason instanceof Error ? reason.message : 'Playback could not start.'); }
  }
  toggle(): void {
    if (this.stopped || !this.sourceSet || this.finished) { return; }
    try {
      if (this.video.paused) { this.video.play().catch(() => this.fail('Playback could not resume.')); }
      else { this.video.pause(); }
      this.sample();
    } catch { this.fail('Playback could not continue.'); }
  }
  seek(delta: number): void {
    if (this.stopped || !this.sourceSet || this.finished || !Number.isFinite(delta)) { return; }
    try {
      const position = this.video.currentTime, duration = this.video.duration;
      if (!Number.isFinite(position) || !Number.isFinite(duration) || duration <= 0) { return; }
      const target = Math.max(0, Math.min(duration, position + delta));
      this.resumeChecked = true; this.resumeTarget = target; this.lastPosition = target;
      this.video.currentTime = target;
      this.sample();
    } catch { this.fail('This file could not seek to that position.'); }
  }
  private sample(endEvent = false): void {
    if (this.stopped || !this.initialized || !this.sourceSet || this.finished) { return; }
    try {
      if (this.video.error) { this.fail('This file could not be played on this device. Try another version or a compatible server stream.'); return; }
      const duration = this.video.duration, position = this.video.currentTime;
      const validDuration = Number.isFinite(duration) && duration > 0;
      if (!Number.isFinite(position) || position < 0) { return; }
      if (!this.resumeChecked && validDuration) {
        this.resumeChecked = true;
        const saved = this.options.resume;
        if (saved && !saved.watched && saved.position > 5 && saved.position < duration - 10) {
          this.resumeTarget = saved.position; this.lastPosition = saved.position;
          this.video.currentTime = saved.position;
          return;
        }
      }
      if (this.resumeTarget !== undefined) {
        if (this.video.seeking || Math.abs(position - this.resumeTarget) > 2) { return; }
        this.lastPosition = position; this.resumeTarget = undefined;
      }
      const paused = this.video.paused;
      if (!paused && !this.video.seeking && this.lastPosition !== undefined && position > this.lastPosition) {
        this.started = true; if (this.startupTimer !== undefined) { clearTimeout(this.startupTimer); }
      }
      this.lastPosition = position;
      // Completion requires the native ended state/event, never a guessed percentage.
      if (endEvent || this.video.ended) {
        this.finished = true; if (this.startupTimer !== undefined) { clearTimeout(this.startupTimer); } if (this.sampleTimer !== undefined) { clearInterval(this.sampleTimer); }
        if (validDuration) { this.options.progress(position, duration, true); }
        this.options.state({position, duration: validDuration ? duration : 0, paused: true, started: this.started, ended: true, ready: false});
        this.options.ended(); return;
      }
      this.options.state({position, duration: validDuration ? duration : 0, paused, started: this.started, ended: false, ready: validDuration});
      if (this.started && validDuration && Date.now() - this.lastWrite >= 5000) {
        this.lastWrite = Date.now(); this.options.progress(position, duration, false);
      }
    } catch { this.fail('Playback state could not be read. Go back and open this media again.'); }
  }
  private fail(message: string): void {
    if (this.stopped) { return; }
    this.options.failed(message);
    this.stop().catch(() => {});
  }
  stop(): Promise<void> {
    if (this.releaseTask) { return this.releaseTask; }
    this.stopped = true; if (this.startupTimer !== undefined) { clearTimeout(this.startupTimer); } if (this.sampleTimer !== undefined) { clearInterval(this.sampleTimer); }
    for (const [event, listener] of Object.entries(this.events)) { this.video.removeEventListener(event, listener); }
    if (this.initialized) {
      try {
        // A completed episode must never be overwritten by an unfinished cleanup checkpoint.
        if (this.started && !this.finished && this.resumeTarget === undefined && Number.isFinite(this.video.currentTime) && Number.isFinite(this.video.duration) && this.video.duration > 0) {
          this.options.progress(this.video.currentTime, this.video.duration, false);
        }
        this.video.pause();
      } catch { /* Teardown and capability revocation must still complete. */ }
    }
    // Await a late initialization/load to revoke the exact capability once; never start it after cancellation.
    this.releaseTask = this.operation.catch(() => {}).then(async () => {
      if (this.initialized) {
        if (this.surface) { try { this.video.clearSurfaceHandle(this.surface); } catch { /* Still release the decoder. */ } }
        if (this.caption) { try { this.video.clearCaptionViewHandle(this.caption); } catch { /* Still release the decoder. */ } }
        try { await this.video.deinitialize(); } catch { /* Revocation remains mandatory even if native teardown fails. */ }
        this.initialized = false;
      }
      this.surface = undefined; this.caption = undefined;
      if (this.resourceURI) { const uri = this.resourceURI; this.resourceURI = undefined; await this.options.releaseResource(uri).catch(() => {}); }
    });
    return this.releaseTask;
  }
}
