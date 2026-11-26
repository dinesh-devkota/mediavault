import React, {useEffect, useRef, useState} from 'react';
import {AppState, StyleSheet, Text, View} from 'react-native';
import {useTVEventHandler} from '@amazon-devices/react-native-kepler';
import {AudioTrack, AudioTrackList, KeplerCaptionsView, KeplerVideoSurfaceView, TextTrack, TextTrackList, VideoPlayer, VTTCue} from '@amazon-devices/react-native-w3cmedia';
import {MediaItem, PlaybackResource, ViewingState} from '../domain/model';
import {SubtitleCue} from '../domain/subtitles';
import {Action, colors, shared} from './Controls';
import {PlayerSession} from './PlayerSession';

export interface LoadedSubtitle { label: string; language: string; cues: SubtitleCue[] }
// SDK 2.3 implements numeric access with a Proxy, but omits its index signature from typings.
const textAt = (list: TextTrackList, index: number): TextTrack | undefined => (list as TextTrackList & {[key: number]: TextTrack | undefined})[index];
const audioAt = (list: AudioTrackList, index: number): AudioTrack | undefined => (list as AudioTrackList & {[key: number]: AudioTrack | undefined})[index];
let previousPlayerRelease: Promise<void> = Promise.resolve();
export function Player({item, resume, load, releaseResource, subtitles, onProgress, onClose, next, onNext, autoNext, onAutoNext}: {
  item: MediaItem; resume?: ViewingState; load: () => Promise<PlaybackResource>;
  releaseResource: (uri: string) => Promise<void>;
  subtitles: () => Promise<LoadedSubtitle[]>; onProgress: (position: number, duration: number, ended: boolean) => void;
  onClose: () => void; next?: MediaItem; onNext: () => void; autoNext: boolean; onAutoNext: (enabled: boolean) => void;
}) {
  const [binding, setBinding] = useState<{video: VideoPlayer; session: PlayerSession}>();
  const player = binding?.video;
  const [ready, setReady] = useState(false);
  const [status, setStatus] = useState('Opening media…');
  const [error, setError] = useState<string>();
  const [paused, setPaused] = useState(false);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const [trackLabels, setTrackLabels] = useState<string[]>([]);
  const [audioLabels, setAudioLabels] = useState<string[]>([]);
  const [countdown, setCountdown] = useState<number>();
  const [controlsVisible, setControlsVisible] = useState(true);
  const [interaction, setInteraction] = useState(0);
  const callbacks = useRef({onProgress, onClose, onNext, autoNext, next}); callbacks.current = {onProgress, onClose, onNext, autoNext, next};
  // Progress updates change parent callbacks and resume state. Capture inputs once per media identity,
  // so a five-second progress write cannot restart the active native player.
  const startConfiguration = useRef({load, releaseResource, resume, subtitles});
  startConfiguration.current = {load, releaseResource, resume, subtitles};
  const togglePlayback = (): void => { if (ready && !error) { binding?.session.toggle(); } };
  const seek = (delta: number): void => { if (ready && !error) { binding?.session.seek(delta); } };
  useTVEventHandler(event => {
    if (event.eventKeyAction === 1) { return; }
    setControlsVisible(true); setInteraction(value => value + 1);
    if (event.eventType === 'playpause') { togglePlayback(); }
    else if (event.eventType === 'rewind' || event.eventType === 'skip_backward') { seek(-10); }
    else if (event.eventType === 'forward' || event.eventType === 'fastforward' || event.eventType === 'skip_forward') { seek(30); }
    else if (event.eventType === 'stop') { callbacks.current.onClose(); }
  });
  useEffect(() => {
    if (paused || status || error || countdown !== undefined) { setControlsVisible(true); return; }
    const timer = setTimeout(() => setControlsVisible(false), 6000);
    return () => clearTimeout(timer);
  }, [paused, status, error, countdown, interaction]);
  useEffect(() => {
    const configuration = startConfiguration.current;
    const video = new VideoPlayer();
    const tracks = (): void => {
      const text = Array.from({length: video.textTracks.length}, (_, i) => textAt(video.textTracks, i)?.label || textAt(video.textTracks, i)?.language || `Subtitles ${i + 1}`);
      const audio = Array.from({length: video.audioTracks.length}, (_, i) => audioAt(video.audioTracks, i)?.label || audioAt(video.audioTracks, i)?.language || `Audio ${i + 1}`);
      setTrackLabels(current => JSON.stringify(current) === JSON.stringify(text) ? current : text);
      setAudioLabels(current => JSON.stringify(current) === JSON.stringify(audio) ? current : audio);
    };
    const session = new PlayerSession(video, {
      ...configuration,
      initialized: () => setBinding({video, session}),
      sourceStarted: () => {
        // Subtitle failure must never stop valid media playback.
        Promise.resolve().then(configuration.subtitles).then(files => {
          if (!session.active) { return; }
          for (const [index, file] of files.entries()) {
            const track = video.addTextTrack('subtitles', file.label, file.language);
            for (const cue of file.cues) { track.addCue(new VTTCue(cue.start, cue.end, cue.text)); }
            track.mode = index === 0 ? 'showing' : 'disabled';
          }
          tracks();
        }).catch(() => {});
      },
      state: value => {
        setPosition(value.position); setDuration(value.duration); setPaused(value.paused); setReady(value.ready);
        if (value.ended) { setStatus('Finished'); }
        else if (value.started) { setStatus(''); }
        tracks();
      },
      progress: (current, total, ended) => callbacks.current.onProgress(current, total, ended),
      ended: () => { if (callbacks.current.next && callbacks.current.autoNext) { setCountdown(10); } },
      failed: message => { setError(message); setReady(false); setTrackLabels([]); setAudioLabels([]); },
    });
    session.start(previousPlayerRelease);
    const lifecycle = AppState.addEventListener('change', state => { if (state !== 'active' && session.active) { callbacks.current.onClose(); } });
    return () => {
      lifecycle.remove();
      // The next episode must await pending native initialization and teardown.
      previousPlayerRelease = session.stop();
    };
  }, [item.id]);
  useEffect(() => {
    if (countdown === undefined) { return; }
    if (countdown === 0) { callbacks.current.onNext(); return; }
    const timer = setTimeout(() => setCountdown(countdown - 1), 1000);
    return () => clearTimeout(timer);
  }, [countdown]);
  const time = (seconds: number): string => Number.isFinite(seconds) ? `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}` : '0:00';
  return <View style={styles.page}>
    {binding && <>
      <KeplerVideoSurfaceView key={item.id} scalingmode="fit" style={StyleSheet.absoluteFill}
        onSurfaceViewCreated={handle => binding.session.attachSurface(handle)} onSurfaceViewDestroyed={handle => binding.session.detachSurface(handle)}/>
      <KeplerCaptionsView show style={StyleSheet.absoluteFill}
        onCaptionViewCreated={handle => binding.session.attachCaption(handle)} onCaptionViewDestroyed={handle => binding.session.detachCaption(handle)}/>
    </>}
    {controlsVisible && <View style={styles.heading}><Text style={shared.heading} testID="player-title">{item.title}</Text><Text style={styles.fileName} testID="player-file-name">{item.fileName}</Text></View>}
    {controlsVisible && <View style={styles.controls}>
      {!!status && <Text style={shared.subtitle}>{status}</Text>}
      {!!error && <Text style={shared.error} testID="player-error">{error}</Text>}
      <Text style={shared.text} testID="player-position">{time(position)} / {time(duration)}</Text>
      <View style={shared.row}>
        <Action label="Back" onPress={onClose}/>
        <Action label={paused ? 'Play' : 'Pause'} preferred disabled={!ready || !!error} onPress={togglePlayback}/>
        <Action label="Back 10 seconds" disabled={!ready || !!error} onPress={() => seek(-10)}/>
        <Action label="Forward 30 seconds" disabled={!ready || !!error} onPress={() => seek(30)}/>
      </View>
      {!!trackLabels.length && <View style={shared.row}>
        <Action label="Subtitles off" onPress={() => { if (player) { for (let i = 0; i < player.textTracks.length; i++) { const track = textAt(player.textTracks, i); if (track) { track.mode = 'disabled'; } } } }}/>
        {trackLabels.map((label, index) => <Action key={index} label={label} onPress={() => { if (player) { for (let i = 0; i < player.textTracks.length; i++) { const track = textAt(player.textTracks, i); if (track) { track.mode = i === index ? 'showing' : 'disabled'; } } } }}/>)}</View>}
      {audioLabels.length > 1 && <View style={shared.row}>{audioLabels.map((label, index) => <Action key={index} label={label} onPress={() => { if (player) { for (let i = 0; i < player.audioTracks.length; i++) { const track = audioAt(player.audioTracks, i); if (track) { track.enabled = i === index; } } } }}/>)}</View>}
      {item.kind === 'episode' && <Action label={autoNext ? 'Auto-play next episode: On' : 'Auto-play next episode: Off'} selected={autoNext} onPress={() => { onAutoNext(!autoNext); if (autoNext) { setCountdown(undefined); } }}/ >}
      {next && countdown === undefined && status === 'Finished' && <Action label={`Play next: ${next.title}`} onPress={onNext}/>}
      {countdown !== undefined && <View style={shared.row}><Text style={shared.text}>Next: {next?.title} in {countdown}s</Text>
        <Action label="Play next now" onPress={onNext}/><Action label="Stop after this episode" onPress={() => setCountdown(undefined)}/></View>}
    </View>}
  </View>;
}
const styles = StyleSheet.create({page: {flex: 1, backgroundColor: '#000'}, heading: {position: 'absolute', top: 20, left: 40, right: 40, padding: 14, backgroundColor: '#000b'},
  fileName: {fontSize: 18, color: colors.secondary}, controls: {position: 'absolute', left: 40, right: 40, bottom: 20, padding: 20, borderRadius: 16, backgroundColor: '#10131ae8'}});
