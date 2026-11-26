import assert from 'node:assert/strict';
import test from 'node:test';
import {confirmedMp4Seek, nativeSeeks, waitForMp4Seek} from './native-seek-evidence.mjs';

const fixtureId = 'com.dineshdevkota.mediavault.vvdfixture';
const line = (record, pid = 3801, id = fixtureId) =>
  `Nov 26 07:43:30.259111 device local0.err ${id}[${pid}]: 337 E ${record}`;
const request = line('W3CMEDIA:[MSE_EME] MediaPlayerPipelineImpl::seek: Seek time: 31.245000s');
const refusal = 'W3CMEDIA:[MSE_EME] seek: MPB Call failed with code: 50004.';
const failed = line('W3CMEDIA:[MSE_EME] MediaPlayerPipelineImpl::seek: Seek failed, time: 31.245000s');
const successful = line('MEDIA_PLAYERV2:GstPipelineImpl.cpp(1338) seekWithRate [0x7f90d4052c00] Successful to 0:00:01.390000000 (Requested: 0:00:31.245000000)');

test('requires a matched native command and its decoder rejection', () => {
  assert.deepEqual(nativeSeeks([request, line(refusal), failed].join('\n'), fixtureId),
    [{requested: 31.245, outcome: 'rejected-50004'}]);
  assert.deepEqual(nativeSeeks([request, failed].join('\n'), fixtureId), [{requested: 31.245, outcome: 'rejected'}]);
});

test('an unrelated package, process, code, or premature seeked cannot confirm the refusal', () => {
  const wrongSignals = [
    line(refusal, 3801, 'com.example.other'), line(refusal, 3800),
    line(refusal.replace('50004', '50003')), line('W3CMEDIA:Emitting event: source = HtmlMediaElement name = seeked'),
  ];
  assert.deepEqual(nativeSeeks([request, ...wrongSignals, failed].join('\n'), fixtureId),
    [{requested: 31.245, outcome: 'rejected'}]);
  assert.deepEqual(nativeSeeks([line(refusal), failed].join('\n'), fixtureId), []);
});

test('native success confirms an accepted command, without treating the reported pre-seek clock as a landing', () => {
  assert.deepEqual(nativeSeeks([request, successful].join('\n'), fixtureId), [{requested: 31.245, outcome: 'accepted'}]);
  assert.deepEqual(nativeSeeks([request, successful.replace('Requested: 0:00:31.245', 'Requested: 0:00:11.245')].join('\n'), fixtureId),
    [{requested: 31.245, outcome: 'pending'}]);
  assert.equal(nativeSeeks([request, successful, request, line(refusal), failed].join('\n'), fixtureId).length, 2);
});

test('MP4 requires accepted native evidence, the paused target clock, and enabled seek controls together', () => {
  const target = 31;
  const sample = {position: target, paused: true, controlsReady: true};
  const accepted = [{requested: 31.245, outcome: 'accepted'}];
  assert.equal(confirmedMp4Seek(accepted, target, sample), true);
  assert.equal(confirmedMp4Seek([], target, sample), false);
  assert.equal(confirmedMp4Seek([{requested: target, outcome: 'pending'}], target, sample), false);
  assert.equal(confirmedMp4Seek(accepted, target, {...sample, position: 1}), false);
  assert.equal(confirmedMp4Seek(accepted, target, {...sample, paused: false}), false);
  assert.equal(confirmedMp4Seek(accepted, target, {...sample, controlsReady: false}), false);
});

test('an incorrect, duplicate, or rejected native MP4 seek cannot satisfy the expected action', () => {
  const sample = {position: 31, paused: true, controlsReady: true};
  const accepted = {requested: 31.245, outcome: 'accepted'};
  assert.throws(() => confirmedMp4Seek([accepted, accepted], 31, sample), /exactly one native seek/);
  assert.throws(() => confirmedMp4Seek([{...accepted, requested: 21}], 31, sample), /must match/);
  assert.throws(() => confirmedMp4Seek([{...accepted, outcome: 'rejected-50004'}], 31, sample), /was rejected/);
});

test('MP4 seek retries a malformed clock sample until native acceptance and the paused clock agree', async () => {
  const snapshots = [
    {positionText: '0:31 / 1:00', requests: nativeSeeks(request, fixtureId)},
    {positionText: '0:31 /', requests: nativeSeeks([request, successful].join('\n'), fixtureId)},
    {positionText: '0:31 / 1:00', requests: nativeSeeks([request, successful].join('\n'), fixtureId)},
  ];
  const observed = [];
  let elapsed = 0;
  const position = await waitForMp4Seek({
    expected: 31, message: 'Seek could not be confirmed.', timeoutMs: 750,
    observe: async () => ({...snapshots.shift(), paused: true, controlsReady: true}),
    onSample: sample => observed.push([sample.position, sample.requests[0].outcome]),
    now: () => elapsed, wait: async delay => { elapsed += delay; },
  });
  assert.equal(position, 31);
  assert.deepEqual(observed, [[31, 'pending'], [null, 'accepted'], [31, 'accepted']]);
});

test('MP4 seek times out when the clock remains unavailable despite native success at zero', async () => {
  let elapsed = 0;
  const positions = [];
  await assert.rejects(waitForMp4Seek({
    expected: 0, message: 'Seek could not be confirmed.', timeoutMs: 500,
    observe: async () => ({positionText: null, paused: true, controlsReady: true,
      requests: [{requested: 0, outcome: 'accepted'}]}),
    onSample: sample => positions.push(sample.position),
    now: () => elapsed, wait: async delay => { elapsed += delay; },
  }), /Seek could not be confirmed/);
  assert.equal(elapsed, 500);
  assert.deepEqual(positions, [null, null]);
});

test('MP4 seek fails immediately on an explicit player error', async () => {
  const error = new Error('The player reported a playback failure.');
  await assert.rejects(waitForMp4Seek({
    expected: 31, message: 'Seek could not be confirmed.',
    observe: async () => { throw error; },
    onSample: () => assert.fail('A playback error cannot supply a seek observation.'),
    wait: async () => assert.fail('The player error must fail before retry.'),
  }), error);
});
