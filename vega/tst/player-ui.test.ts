/// <reference types="node" />
/* global globalThis */
import React from 'react';
import {create, ReactTestRenderer} from 'react-test-renderer';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {runInNewContext} from 'node:vm';
import {JsxEmit, ModuleKind, ScriptTarget, transpileModule} from 'typescript';
import {PlayerSession} from '../src/ui/PlayerSession';
import {SubtitleSelection} from '../src/ui/PlaybackTracks';

// Run the actual component with React, replacing only the native view/decoder
// boundary. Native focus acknowledgement remains a separate device assertion.
test('loading controls gain preference only when enabled and raw media keys never duplicate SDK commands', async () => {
  (globalThis as typeof globalThis & {IS_REACT_ACT_ENVIRONMENT: boolean}).IS_REACT_ACT_ENVIRONMENT = true;
  jest.useFakeTimers();
  const events = new Map<string, () => void>();
  const video = {src: '', currentTime: 0, duration: NaN, paused: false, seeking: false, ended: false, error: null,
    defaultSeekIntervalInSec: 0, initialize: jest.fn(async () => {}), deinitialize: jest.fn(async () => {}),
    play: jest.fn(async () => {}), pause: jest.fn(), setSurfaceHandle: jest.fn(), clearSurfaceHandle: jest.fn(),
    setCaptionViewHandle: jest.fn(), clearCaptionViewHandle: jest.fn(),
    textTracks: {length: 0, addEventListener: () => {}, removeEventListener: () => {}}, audioTracks: {length: 0},
    addEventListener: (name: string, listener: () => void) => events.set(name, listener), removeEventListener: (name: string) => events.delete(name)};
  let remote!: (event: {eventType: string; eventKeyAction: number}) => void;
  const dependencies: Record<string, unknown> = {
    react: React,
    'react-native': {View: 'View', Text: 'Text', StyleSheet: {create: (value: unknown) => value, absoluteFill: {}},
      AppState: {addEventListener: () => ({remove: () => {}})}},
    '@amazon-devices/react-native-kepler': {useTVEventHandler: (listener: typeof remote) => { remote = listener; }},
    '@amazon-devices/react-native-w3cmedia': {VideoPlayer: function () { return video; }, KeplerVideoSurfaceView: 'VideoSurface', KeplerCaptionsView: 'Captions'},
    './Controls': {Action: 'Action', colors: {}, shared: {}}, './PlayerSession': {PlayerSession}, './PlaybackTracks': {SubtitleSelection},
  };
  const output: Record<string, any> = {};
  runInNewContext(transpileModule(readFileSync(join(__dirname, '../src/ui/Player.tsx'), 'utf8'), {
    compilerOptions: {target: ScriptTarget.ES2022, module: ModuleKind.CommonJS, jsx: JsxEmit.React, esModuleInterop: true},
  }).outputText, {exports: output, require: (name: string) => dependencies[name] ?? {}, setTimeout, clearTimeout});
  const onClose = jest.fn();
  let tree!: ReactTestRenderer;
  const action = (label: string) => tree.root.findAll(node => String(node.type) === 'Action' && node.props.label === label)[0]!;
  try {
    await React.act(async () => {
      tree = create(React.createElement(output.Player, {
        item: {id: 'synthetic', title: 'Fixture', fileName: 'Controls.mkv', kind: 'movie'},
        load: async () => ({uri: 'http://127.0.0.1/fixture', mime: 'video/x-matroska'}), releaseResource: async () => {},
        subtitles: async () => [], onProgress: () => {}, onClose, onNext: () => {}, autoNext: false, onAutoNext: () => {},
      }));
    });
    expect(action('Pause').props.disabled).toBe(true); expect(action('Pause').props.preferred).toBe(false);
    expect(action('Back').props.preferred).toBe(true);
    await React.act(async () => { tree.root.find(node => String(node.type) === 'VideoSurface').props.onSurfaceViewCreated('surface'); });
    expect(video.defaultSeekIntervalInSec).toBe(10);
    await React.act(async () => { video.duration = 60; events.get('loadedmetadata')?.(); });
    expect(action('Pause').props.disabled).toBe(false); expect(action('Pause').props.preferred).toBe(true);
    expect(action('Back').props.preferred).toBe(false);
    const plays = video.play.mock.calls.length, pauses = video.pause.mock.calls.length;
    await React.act(async () => {
      for (const eventType of ['playpause', 'forward', 'fastforward', 'skip_forward', 'rewind', 'skip_backward', 'stop']) {
        remote({eventType, eventKeyAction: 0}); remote({eventType, eventKeyAction: 1});
      }
    });
    expect(video.currentTime).toBe(0); expect(video.play).toHaveBeenCalledTimes(plays);
    expect(video.pause).toHaveBeenCalledTimes(pauses); expect(onClose).not.toHaveBeenCalled();
    await React.act(async () => { action('Forward 30 seconds').props.onPress(); });
    expect(video.currentTime).toBe(30);
    await React.act(async () => { action('Back 10 seconds').props.onPress(); });
    expect(video.currentTime).toBe(20);
    await React.act(async () => { action('Pause').props.onPress(); });
    expect(video.pause).toHaveBeenCalledTimes(pauses + 1);
  } finally {
    await React.act(async () => { tree?.unmount(); });
    jest.useRealTimers();
  }
});
