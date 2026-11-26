import type {VideoPlayer} from '@amazon-devices/react-native-w3cmedia';
import type {PlaybackResource, ViewingState} from '../domain/model';

// This is the installed SDK's actual surface, not a browser video or synthetic clock.
// Its implementation initializes error to null although the declaration omits null.
export type NativeVideo = Pick<VideoPlayer, 'initialize' | 'deinitialize' | 'src' | 'currentTime' | 'duration' | 'paused' | 'ended' | 'seeking' | 'defaultSeekIntervalInSec' |
  'play' | 'pause' | 'setSurfaceHandle' | 'clearSurfaceHandle' | 'setCaptionViewHandle' | 'clearCaptionViewHandle' | 'addEventListener' | 'removeEventListener'> & {readonly error: VideoPlayer['error'] | null};
export interface PlaybackState { position: number; duration: number; paused: boolean; started: boolean; ended: boolean; ready: boolean; seekWarning?: string }
const SEEK_TIMEOUT_MS = 10_000;
const SEEK_POSITION_RESOLUTION = 0.25;
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
  private initializing = false;
  private stopped = false;
  private started = false;
  private finished = false;
  private sourceSet = false;
  private resumeChecked = false;
  private pendingSeek?: {target: number; origin: number; requestedAt: number; paused: boolean; resume: boolean};
  private protectedResumePosition?: number;
  private externalSeekOrigin?: {position: number; startedAt: number; paused: boolean};
  private seekWarning?: string;
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
    this.events = Object.fromEntries(['loadedmetadata', 'durationchange', 'canplay', 'play', 'playing', 'pause', 'timeupdate'].map(name => [name, () => this.sample()]));
    this.events.seeking = () => {
      if (!this.stopped && this.sourceSet && !this.pendingSeek && !this.externalSeekOrigin) {
        // The SDK can deliver seeking after the native clock has already jumped.
        this.externalSeekOrigin = {position: this.lastPosition ?? this.video.currentTime, startedAt: Date.now(), paused: this.video.paused};
      }
    };
    this.events.seeked = () => this.sample(false, true);
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
    this.initializing = true;
    try { await this.video.initialize(); this.initialized = true; }
    finally { this.initializing = false; }
    if (this.stopped) { return; }
    // W3C Media's legacy player session owns remote media keys. The public SDK
    // setting applies to both forward and rewind; on-screen buttons are separate.
    this.video.defaultSeekIntervalInSec = 10;
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
    if (this.stopped || !this.sourceSet || this.finished || this.pendingSeek || this.externalSeekOrigin || !Number.isFinite(delta)) { return; }
    try {
      const position = this.video.currentTime, duration = this.video.duration;
      if (!Number.isFinite(position) || !Number.isFinite(duration) || duration <= 0) { return; }
      const target = Math.max(0, Math.min(duration, position + delta));
      if (Math.abs(target - position) < SEEK_POSITION_RESOLUTION) { return; }
      this.resumeChecked = true;
      this.requestSeek(position, target, this.video.paused, false);
      this.sample();
    } catch { this.rejectSeek(); this.sample(); }
  }
  private requestSeek(origin: number, target: number, paused: boolean, resume: boolean): void {
    this.pendingSeek = {origin, target, paused, resume, requestedAt: Date.now()};
    this.seekWarning = undefined;
    try { this.video.currentTime = target; }
    catch { this.rejectSeek(); }
  }
  private rejectSeek(): void {
    const resume = this.pendingSeek?.resume;
    this.pendingSeek = undefined;
    this.externalSeekOrigin = undefined;
    this.lastPosition = undefined;
    this.seekWarning = resume
      ? 'Your saved position could not be reached. It will be kept until playback catches up or you choose another position.'
      : 'That position could not be reached. You can continue from the current position.';
  }
  private canSaveProgress(position: number): boolean {
    return !this.pendingSeek && !this.externalSeekOrigin && !this.video.seeking &&
      (this.protectedResumePosition === undefined || position >= this.protectedResumePosition);
  }
  private sample(endEvent = false, seekCompleted = false): void {
    if (this.stopped || !this.initialized || !this.sourceSet || this.finished) { return; }
    try {
      if (this.video.error) { this.fail('This file could not be played on this device. Try another version or a compatible server stream.'); return; }
      const duration = this.video.duration, position = this.video.currentTime, paused = this.video.paused;
      const validDuration = Number.isFinite(duration) && duration > 0;
      if (!Number.isFinite(position) || position < 0) { return; }
      if (!this.resumeChecked && validDuration) {
        this.resumeChecked = true;
        const saved = this.options.resume;
        if (saved && !saved.watched && saved.position > 5 && saved.position < duration - 10 &&
          Math.abs(saved.position - position) >= SEEK_POSITION_RESOLUTION) {
          this.protectedResumePosition = saved.position;
          this.requestSeek(position, saved.position, paused, true);
          // Native events can complete the seek during the setter. The old sample
          // cannot publish progress after it, even if the operation already ended.
          return;
        }
      }
      if (this.pendingSeek) {
        const pending = this.pendingSeek;
        pending.paused = pending.paused && paused;
        const elapsed = Math.max(0, Date.now() - pending.requestedAt);
        const distance = pending.target - pending.origin;
        const displacement = position - pending.origin;
        const naturalAdvance = pending.paused ? 0 : elapsed / 1000;
        // A nearby target can already be within the normal landing tolerance,
        // or be reached by ordinary playback after native rejected the jump.
        const halfDistance = Math.abs(distance) / 2;
        const landed = Math.abs(position - pending.target) <= Math.min(2, halfDistance) &&
          (distance > 0 ? displacement > naturalAdvance + Math.min(SEEK_POSITION_RESOLUTION, halfDistance) : displacement < 0);
        if (!this.video.seeking && landed) {
          this.lastPosition = position; this.pendingSeek = undefined;
          this.protectedResumePosition = undefined; this.seekWarning = undefined;
        } else if ((seekCompleted && !this.video.seeking) || elapsed >= SEEK_TIMEOUT_MS) {
          // SDK 2.3 can emit seeked even when the native engine rejects the seek.
          // A missing event is bounded too; keep showing native state after either failure.
          this.rejectSeek();
        }
      } else if (this.externalSeekOrigin !== undefined) {
        // A successful SDK-owned remote seek is also an explicit choice. A
        // rejected seek may still allow normal playback to advance. Require a
        // discontinuity beyond that elapsed playback before replacing a saved
        // resume checkpoint; the SDK does not expose its requested seek target.
        const origin = this.externalSeekOrigin;
        origin.paused = origin.paused && paused;
        const elapsed = Math.max(0, Date.now() - origin.startedAt);
        if (seekCompleted && !this.video.seeking) {
          const displacement = position - origin.position;
          const naturalAdvance = origin.paused ? 0 : elapsed / 1000;
          if (Number.isFinite(origin.position) && (displacement < -2 || displacement > naturalAdvance + 2)) {
            this.protectedResumePosition = undefined; this.seekWarning = undefined;
          } else {
            this.seekWarning = 'A new seek position could not be confirmed. You can continue playing.';
          }
          this.lastPosition = position;
          this.externalSeekOrigin = undefined;
        } else if (elapsed >= SEEK_TIMEOUT_MS) {
          this.seekWarning = 'A new seek position could not be confirmed. You can continue playing.';
          this.lastPosition = position;
          this.externalSeekOrigin = undefined;
        }
      } else if (seekCompleted) {
        // An unpaired or duplicate seeked signal is not playback clock evidence.
        this.lastPosition = position;
      }
      if (!this.pendingSeek && !this.externalSeekOrigin && !paused && !this.video.seeking && this.lastPosition !== undefined && position > this.lastPosition) {
        this.started = true; if (this.startupTimer !== undefined) { clearTimeout(this.startupTimer); }
        if (this.protectedResumePosition !== undefined && position >= this.protectedResumePosition) {
          this.protectedResumePosition = undefined; this.seekWarning = undefined;
        }
      }
      this.lastPosition = position;
      // Completion requires the native ended state/event, never a guessed percentage.
      if (endEvent || this.video.ended) {
        this.finished = true; if (this.startupTimer !== undefined) { clearTimeout(this.startupTimer); } if (this.sampleTimer !== undefined) { clearInterval(this.sampleTimer); }
        if (validDuration && this.canSaveProgress(position)) { this.options.progress(position, duration, true); }
        this.options.state({position, duration: validDuration ? duration : 0, paused: true, started: this.started, ended: true, ready: false});
        this.options.ended(); return;
      }
      this.options.state({position, duration: validDuration ? duration : 0, paused, started: this.started, ended: false, ready: validDuration, seekWarning: this.seekWarning});
      if (this.started && validDuration && this.canSaveProgress(position) && Date.now() - this.lastWrite >= 5000) {
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
    // Publish the teardown promise before callbacks can re-enter stop().
    this.releaseTask = Promise.resolve().then(async () => {
      // SDK 2.3 deinitialize() aborts a pending initialize() promise and destroys
      // a native element that arrives later. Waiting for prepare first would
      // deadlock cancellation and every subsequent episode behind that promise.
      let initializationReleased = false;
      if (this.initializing) {
        try { await this.video.deinitialize(); initializationReleased = true; }
        catch { /* If initialization already won the race, release it below. */ }
      }
      // A late source load still owns a ticket that must be revoked exactly once.
      await this.operation.catch(() => {});
      if (this.initialized && !initializationReleased) {
        if (this.surface) { try { this.video.clearSurfaceHandle(this.surface); } catch { /* Still release the decoder. */ } }
        if (this.caption) { try { this.video.clearCaptionViewHandle(this.caption); } catch { /* Still release the decoder. */ } }
        try { await this.video.deinitialize(); } catch { /* Revocation remains mandatory even if native teardown fails. */ }
      }
      this.initialized = false;
      this.surface = undefined; this.caption = undefined;
      if (this.resourceURI) { const uri = this.resourceURI; this.resourceURI = undefined; await this.options.releaseResource(uri).catch(() => {}); }
    });
    for (const [event, listener] of Object.entries(this.events)) { this.video.removeEventListener(event, listener); }
    if (this.initialized) {
      try {
        // A completed episode must never be overwritten by an unfinished cleanup checkpoint.
        if (this.started && !this.finished && this.canSaveProgress(this.video.currentTime) && Number.isFinite(this.video.currentTime) && Number.isFinite(this.video.duration) && this.video.duration > 0) {
          this.options.progress(this.video.currentTime, this.video.duration, false);
        }
        this.video.pause();
      } catch { /* Teardown and capability revocation must still complete. */ }
    }
    return this.releaseTask;
  }
}
