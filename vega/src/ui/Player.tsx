import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {AppState, BackHandler, ScrollView, StyleSheet, Text, View} from 'react-native';
import {useTVEventHandler} from '@amazon-devices/react-native-kepler';
import {AudioTrack, AudioTrackList, KeplerCaptionsView, KeplerVideoSurfaceView, TextTrack, TextTrackList, VideoPlayer, VTTCue} from '@amazon-devices/react-native-w3cmedia';
import {MediaItem, PlaybackResource, ViewingState} from '../domain/model';
import {SubtitleCue, subtitleLanguageName} from '../domain/subtitles';
import {Action, colors, shared} from './Controls';
import {PlayerSession} from './PlayerSession';
import {SubtitleSelection} from './PlaybackTracks';

export interface LoadedSubtitle { label: string; language: string; cues: SubtitleCue[] }
// SDK 2.3 implements numeric access with a Proxy, but omits its index signature from typings.
const textAt = (list: TextTrackList, index: number): TextTrack | undefined => (list as TextTrackList & {[key: number]: TextTrack | undefined})[index];
const textChoices = (list: TextTrackList): (TextTrack | undefined)[] => Array.from({length: list.length}, (_, index) => textAt(list, index));
const audioAt = (list: AudioTrackList, index: number): AudioTrack | undefined => (list as AudioTrackList & {[key: number]: AudioTrack | undefined})[index];
interface SubtitleChoice { id: string; label: string; selected: boolean }

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
  const [seekWarning, setSeekWarning] = useState<string>();
  const [paused, setPaused] = useState(false);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const [trackChoices, setTrackChoices] = useState<SubtitleChoice[]>([]);
  const [subtitleMenuOpen, setSubtitleMenuOpen] = useState(false);
  const [returnToSubtitles, setReturnToSubtitles] = useState(false);
  const [audioLabels, setAudioLabels] = useState<string[]>([]);
  const [countdown, setCountdown] = useState<number>();
  const [controlsVisible, setControlsVisible] = useState(true);
  const [interaction, setInteraction] = useState(0);
  const subtitleSelection = useRef(new SubtitleSelection());
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
    // The SDK player session already handles play/pause, stop (pause), and
    // 10-second remote seeks. Raw TV events only reveal controls; handling the
    // commands here too would apply the same physical press twice.
  });
  useEffect(() => {
    if (paused || status || error || seekWarning || subtitleMenuOpen || countdown !== undefined) { setControlsVisible(true); return; }
    const timer = setTimeout(() => setControlsVisible(false), 6000);
    return () => clearTimeout(timer);
  }, [paused, status, error, seekWarning, subtitleMenuOpen, countdown, interaction]);
  const closeSubtitleMenu = useCallback(() => {
    setSubtitleMenuOpen(false); setReturnToSubtitles(true);
    setInteraction(value => value + 1);
  }, []);
  useEffect(() => {
    if (!subtitleMenuOpen) { return; }
    const handler = BackHandler.addEventListener('hardwareBackPress', () => { closeSubtitleMenu(); return true; });
    return () => handler.remove();
  }, [closeSubtitleMenu, subtitleMenuOpen]);
  const chooseSubtitle = (id: string | null): void => {
    if (!player) { return; }
    const choices = textChoices(player.textTracks);
    if (id !== null && !choices.some(track => track?.id === id && track.mode != null)) { return; }
    subtitleSelection.current.select(choices, id);
    const showing = new Set(choices.filter(track => track?.mode === 'showing').map(track => track!.id));
    setTrackChoices(current => current.map(option => ({...option, selected: showing.has(option.id)})));
    closeSubtitleMenu();
  };
  useEffect(() => {
    const configuration = startConfiguration.current;
    const video = new VideoPlayer();
    const tracks = (): void => {
      const nativeTracks = textChoices(video.textTracks);
      subtitleSelection.current.reconcile(nativeTracks);
      const text = nativeTracks.flatMap((track, index): SubtitleChoice[] => {
        const mode = track?.mode;
        if (!track || mode == null) { return []; }
        const language = track.language ?? '';
        const label = track.label?.trim();
        const title = label && label.toLowerCase() !== language.toLowerCase() ? label : subtitleLanguageName(language);
        return [{id: track.id, label: title || `Track ${index + 1}`, selected: mode === 'showing'}];
      });
      const audio = Array.from({length: video.audioTracks.length}, (_, i) => {
        const track = audioAt(video.audioTracks, i);
        return track?.label || track?.language || `Audio ${i + 1}`;
      });
      setTrackChoices(current => current.length === text.length && current.every((option, i) =>
        option.id === text[i]!.id && option.label === text[i]!.label && option.selected === text[i]!.selected) ? current : text);
      setAudioLabels(current => current.length === audio.length && current.every((label, i) => label === audio[i]) ? current : audio);
    };
    const session = new PlayerSession(video, {
      ...configuration,
      initialized: () => setBinding({video, session}),
      sourceStarted: () => {
        // Subtitle failure must never stop valid media playback.
        Promise.resolve().then(configuration.subtitles).then(files => {
          if (!session.active) { return; }
          let firstLocalTrack: string | undefined;
          for (const file of files) {
            const track = video.addTextTrack('subtitles', file.label, file.language);
            firstLocalTrack ??= track.id;
            for (const cue of file.cues) { track.addCue(new VTTCue(cue.start, cue.end, cue.text)); }
          }
          if (firstLocalTrack !== undefined) { subtitleSelection.current.preferLocal(textChoices(video.textTracks), firstLocalTrack); }
          tracks();
        }).catch(() => {});
      },
      state: value => {
        setPosition(value.position); setDuration(value.duration); setPaused(value.paused); setReady(value.ready);
        setSeekWarning(value.seekWarning);
        if (value.ended) { setStatus('Finished'); }
        else if (value.started) { setStatus(''); }
        tracks();
      },
      progress: (current, total, ended) => callbacks.current.onProgress(current, total, ended),
      ended: () => { if (callbacks.current.next && callbacks.current.autoNext) { setCountdown(10); } },
      failed: message => { setError(message); setReady(false); setTrackChoices([]); setSubtitleMenuOpen(false); setAudioLabels([]); },
    });
    const trackChanges = (): void => { if (session.active) { tracks(); } };
    video.textTracks.addEventListener('addtrack', trackChanges);
    video.textTracks.addEventListener('removetrack', trackChanges);
    session.start(previousPlayerRelease);
    const lifecycle = AppState.addEventListener('change', state => { if (state !== 'active' && session.active) { callbacks.current.onClose(); } });
    return () => {
      lifecycle.remove();
      video.textTracks.removeEventListener('addtrack', trackChanges);
      video.textTracks.removeEventListener('removetrack', trackChanges);
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
  const subtitleOptions = useMemo(() => {
    const counts = new Map<string, number>();
    for (const choice of trackChoices) { counts.set(choice.label, (counts.get(choice.label) ?? 0) + 1); }
    const labels = new Map<string, number>();
    return trackChoices.map(choice => {
      if (counts.get(choice.label) === 1) { return choice; }
      const index = (labels.get(choice.label) ?? 0) + 1;
      labels.set(choice.label, index);
      return {...choice, label: `${choice.label} (${index})`};
    });
  }, [trackChoices]);
  const selectedSubtitle = subtitleOptions.find(choice => choice.selected);
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
      {!!seekWarning && <Text style={shared.subtitle} testID="player-seek-warning">{seekWarning}</Text>}
      <Text style={shared.text} testID="player-position">{time(position)} / {time(duration)}</Text>
      <View style={shared.row}>
        <Action label="Back" preferred={!ready || !!error} onPress={onClose}/>
        <Action label={paused ? 'Play' : 'Pause'} preferred={ready && !error && !subtitleMenuOpen && (!returnToSubtitles || !trackChoices.length)} disabled={!ready || !!error} onPress={togglePlayback}/>
        <Action label="Back 10 seconds" disabled={!ready || !!error} onPress={() => seek(-10)}/>
        <Action label="Forward 30 seconds" disabled={!ready || !!error} onPress={() => seek(30)}/>
        {!!trackChoices.length && <Action testID="player-subtitles" label={`Subtitles · ${selectedSubtitle?.label ?? 'Off'}`}
          preferred={returnToSubtitles && !subtitleMenuOpen} onPress={() => { setReturnToSubtitles(false); setSubtitleMenuOpen(true); }}/>}
      </View>
      {subtitleMenuOpen && <ScrollView style={styles.trackMenu} testID="subtitle-menu">
        <View style={shared.row}>
          <Action label="Off" testID="subtitle-off" selected={!selectedSubtitle} preferred={!selectedSubtitle} onPress={() => chooseSubtitle(null)}/>
          {subtitleOptions.map(choice => <Action key={choice.id} label={choice.label} testID={`subtitle-track-${choice.id}`}
            selected={choice.selected} preferred={choice.id === selectedSubtitle?.id} onPress={() => chooseSubtitle(choice.id)}/>)}
          <Action label="Done" testID="subtitle-done" onPress={closeSubtitleMenu}/>
        </View>
      </ScrollView>}
      {audioLabels.length > 1 && <View style={shared.row}>{audioLabels.map((label, index) => <Action key={index} label={label} onPress={() => { if (player) { for (let i = 0; i < player.audioTracks.length; i++) { const track = audioAt(player.audioTracks, i); if (track) { track.enabled = i === index; } } } }}/>)}</View>}
      {item.kind === 'episode' && <Action label={autoNext ? 'Auto-play next episode: On' : 'Auto-play next episode: Off'} selected={autoNext} onPress={() => { onAutoNext(!autoNext); if (autoNext) { setCountdown(undefined); } }}/ >}
      {next && countdown === undefined && status === 'Finished' && <Action label={`Play next: ${next.title}`} onPress={onNext}/>}
      {countdown !== undefined && <View style={shared.row}><Text style={shared.text}>Next: {next?.title} in {countdown}s</Text>
        <Action label="Play next now" onPress={onNext}/><Action label="Stop after this episode" onPress={() => setCountdown(undefined)}/></View>}
    </View>}
  </View>;
}
const styles = StyleSheet.create({page: {flex: 1, backgroundColor: '#000'}, heading: {position: 'absolute', top: 20, left: 40, right: 40, padding: 14, backgroundColor: '#000b'},
  trackMenu: {maxHeight: 240, marginVertical: 8}, fileName: {fontSize: 18, color: colors.secondary}, controls: {position: 'absolute', left: 40, right: 40, bottom: 20, padding: 20, backgroundColor: '#10131ae8'}});
