import React, {useEffect, useState} from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';
import type {VideoPlayer} from '@amazon-devices/react-native-w3cmedia';

type Mode = 'paused' | 'playing';
type Container = 'mkv' | 'mp4';
interface Sample { phase: string; elapsedMs: number; position: number; duration: number; paused: boolean; seeking: boolean; readyState: number }
interface CaseResult {
  id: string; container: Container; mode: Mode; passed: boolean; samples: Sample[];
  events: Array<{name: string; elapsedMs: number; position: number}>; failures: string[];
}
interface Report { diagnosticOnly: true; outcome: 'incomplete' | 'passed' | 'failed'; cases: CaseResult[]; infrastructureError?: string }
type Media = typeof import('@amazon-devices/react-native-w3cmedia');
interface Binding { id: string; video: VideoPlayer; Surface: Media['KeplerVideoSurfaceView']; attached: boolean; handle?: string }
const cases: Array<{container: Container; mode: Mode}> = [
  {container: 'mkv', mode: 'paused'}, {container: 'mkv', mode: 'playing'},
  {container: 'mp4', mode: 'paused'}, {container: 'mp4', mode: 'playing'},
];
const delay = (ms: number): Promise<void> => new Promise(resolve => setTimeout(resolve, ms));
async function bounded<T>(work: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([work, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(label)), ms); })]);
  } finally { if (timer !== undefined) { clearTimeout(timer); } }
}

export function App() {
  const [binding, setBinding] = useState<Binding>();
  const [started, setStarted] = useState(false);
  const [status, setStatus] = useState('Waiting to start the isolated comparison');
  const [report, setReport] = useState<Report>({diagnosticOnly: true, outcome: 'incomplete', cases: []});
  useEffect(() => {
    if (!started) { return; }
    let active = true;
    setStatus('Loading the native media module');
    const results: CaseResult[] = [];
    const publish = (outcome: Report['outcome'], infrastructureError?: string): void => {
      if (active) { setReport({diagnosticOnly: true, outcome, cases: [...results], ...(infrastructureError ? {infrastructureError} : {})}); }
    };
    const checkActive = (): void => { if (!active) { throw new Error('Probe unmounted'); } };
    async function waitFor(check: () => boolean, label: string, ms: number): Promise<void> {
      const deadline = Date.now() + ms;
      do { checkActive(); if (check()) { return; } await delay(100); } while (Date.now() < deadline);
      throw new Error(label);
    }
    async function runCase(media: Media, container: Container, mode: Mode): Promise<void> {
      const id = `${container}-${mode}`, started = Date.now(), video = new media.VideoPlayer();
      const view: Binding = {id, video, Surface: media.KeplerVideoSurfaceView, attached: false};
      const result: CaseResult = {id, container, mode, passed: false, samples: [], events: [], failures: []};
      let initialized = false;
      const sample = (phase: string): void => {
        result.samples.push({phase, elapsedMs: Date.now() - started, position: video.currentTime,
          duration: video.duration, paused: video.paused, seeking: video.seeking, readyState: video.readyState});
      };
      const listeners = ['loadedmetadata', 'canplay', 'playing', 'pause', 'seeking', 'seeked', 'ended', 'error'].map(name => {
        const listener = (): void => {
          if (result.events.length < 64) { result.events.push({name, elapsedMs: Date.now() - started, position: video.currentTime}); }
        };
        video.addEventListener(name, listener); return {name, listener};
      });
      setStatus(`${id}: initialize and attach the video surface`);
      try {
        await bounded(video.initialize(), 15_000, 'Native initialize timed out'); initialized = true; checkActive();
        setBinding(view);
        await waitFor(() => view.attached, 'Video surface was not attached', 8000);
        // Fixed loopback URL is the stock nginx reverse port. No application
        // relay, custom headers, media-session commands, or remote key handling.
        video.src = `http://127.0.0.1:8765/Controls.${container}?case=${id}`;
        // This SDK's src setter loads the URL; a second load would change the experiment.
        await waitFor(() => video.readyState >= 3 && video.duration > 45, 'Media never became ready with a valid duration', 15_000);
        await bounded(video.play(), 8000, 'Initial play timed out');
        await waitFor(() => !video.paused && video.currentTime >= 1, 'Playback clock did not advance', 15_000);
        const initialPosition = video.currentTime; sample('initial-clock');
        await waitFor(() => !video.paused && video.currentTime >= initialPosition + .25, 'Fresh playing clock did not advance', 3000);
        sample('initial-playing');
        if (mode === 'paused') {
          video.pause(); await waitFor(() => video.paused, 'Pause was not acknowledged', 3000);
          const before = video.currentTime; await delay(600);
          if (Math.abs(video.currentTime - before) > .4) { throw new Error('Paused playback clock kept advancing'); }
          sample('initial-paused');
        }
        for (const target of [31, 11]) {
          checkActive(); setStatus(`${id}: direct currentTime = ${target}`); sample(`before-${target}`);
          try {
            video.currentTime = target;
            // The failing SDK emits seeked even when native seek returns50004.
            // Require actual stable clock evidence rather than that event.
            await waitFor(() => !video.seeking && Math.abs(video.currentTime - target) <= 1.5,
              `Direct seek to ${target} never reached the target`, 8000);
            await delay(600);
            const settled = video.currentTime;
            if (mode === 'paused') {
              if (!video.paused || Math.abs(settled - target) > 1.5) { throw new Error('Paused seek did not retain its target and paused state'); }
            } else {
              if (video.paused || settled < target - 1.5 || settled > target + 3) { throw new Error('Playing seek did not retain its target and playing state'); }
              await waitFor(() => video.currentTime >= settled + .25, 'Clock did not advance after the playing seek', 3000);
            }
            sample(`after-${target}`);
          } catch (reason) {
            result.failures.push(String(reason)); sample(`failed-${target}`);
            if (target === 31) {
              result.failures.push('Seek to 11 was not run: forward seek failed, so natural playback could impersonate that target');
              break;
            }
          }
        }
        if (mode === 'paused') {
          const before = video.currentTime; await bounded(video.play(), 8000, 'Resume timed out');
          await waitFor(() => !video.paused && video.currentTime >= before + .25, 'Playback did not resume after paused seeks', 5000);
          sample('resumed');
        }
      } catch (reason) { result.failures.push(String(reason)); }
      finally {
        if (initialized) {
          try { video.pause(); } catch (_) { /* Continue bounded native teardown. */ }
          if (active) { setBinding(undefined); }
          if (view.handle) { try { video.clearSurfaceHandle(view.handle); } catch (_) { /* View callback can detach first. */ } }
        }
        for (const {name, listener} of listeners) { video.removeEventListener(name, listener); }
        try {
          await bounded(video.deinitialize(), 10_000, 'Native teardown timed out; later cases would not be isolated');
        } catch (reason) {
          result.failures.push(String(reason)); results.push(result); publish('failed');
          throw new Error('Native teardown failed; remaining cases were not run');
        }
        result.passed = result.failures.length === 0; results.push(result); publish('incomplete');
      }
    }
    (async () => {
      try {
        // Prove the probe can mount before loading any native media code.
        const media = await import('@amazon-devices/react-native-w3cmedia');
        for (const test of cases) { checkActive(); await runCase(media, test.container, test.mode); }
        const outcome = results.every(value => value.passed) ? 'passed' : 'failed';
        publish(outcome); if (active) { setStatus('Complete'); }
      } catch (reason) { publish('failed', String(reason)); if (active) { setStatus('Complete'); } }
    })();
    return () => { active = false; };
  }, [started]);
  const Surface = binding?.Surface;
  return <View style={styles.root}>
    {binding && Surface && <Surface key={binding.id} scalingmode="fit" style={styles.video}
      onSurfaceViewCreated={handle => { binding.handle = handle; binding.video.setSurfaceHandle(handle); binding.attached = true; }}
      onSurfaceViewDestroyed={handle => { binding.attached = false; try { binding.video.clearSurfaceHandle(handle); } catch (_) { /* Already released. */ } }}/ >}
    <Text style={styles.banner} testID="probe-banner">VIRTUAL DEVICE SEEK PROBE - synthetic media only</Text>
    <View style={styles.panel}>
      <Text style={styles.heading}>Direct W3C seek: stock HTTP, fresh player per case</Text>
      {!started && <Pressable testID="probe-start" role="button" aria-label="Start comparison" hasTVPreferredFocus onPress={() => setStarted(true)} style={styles.start}>
        <Text style={styles.status}>Start comparison</Text>
      </Pressable>}
      <Text style={styles.status} testID="probe-status">{status}</Text>
      {report.cases.map(value => <Text key={value.id} style={styles.status}>{value.id}: {value.passed ? 'PASS' : 'FAIL'} ({value.failures.length} failures)</Text>)}
      <Text testID="probe-report" style={styles.machine} numberOfLines={1}>{JSON.stringify(report)}</Text>
    </View>
  </View>;
}
const styles = StyleSheet.create({root: {flex: 1, backgroundColor: '#10131a'},
  video: {position: 'absolute', top: 45, right: 30, width: 320, height: 180},
  banner: {backgroundColor: '#ffd58a', color: '#231900', padding: 8, fontSize: 18, textAlign: 'center'},
  panel: {margin: 24, marginTop: 200}, heading: {fontSize: 26, color: '#f5f5f7', marginBottom: 10},
  start: {alignSelf: 'flex-start', padding: 12, backgroundColor: '#314665'},
  status: {fontSize: 20, color: '#f5f5f7', marginVertical: 4}, machine: {fontSize: 12, color: '#b6c2d2', marginTop: 12}});
