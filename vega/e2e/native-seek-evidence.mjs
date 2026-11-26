import assert from 'node:assert/strict';
import {setTimeout as pause} from 'node:timers/promises';

const seekRequest = /W3CMEDIA:\[MSE_EME\] MediaPlayerPipelineImpl::seek: Seek time: (\d+(?:\.\d+)?)s$/;
const unsupportedSeek = /W3CMEDIA:\[MSE_EME\] seek: MPB Call failed with code: 50004\.$/;
const failedSeek = /W3CMEDIA:\[MSE_EME\] MediaPlayerPipelineImpl::seek: Seek failed, time: (\d+(?:\.\d+)?)s$/;
const acceptedSeek = /MEDIA_PLAYERV2:GstPipelineImpl\.cpp\(\d+\) seekWithRate \[0x[\da-f]+\] Successful to \d+:\d{2}:\d{2}\.\d+ \(Requested: (\d+):(\d{2}):(\d{2}\.\d+)\)$/i;

export function nativeSeeks(log, packageId) {
  const seeks = [];
  let pending;
  for (const line of log.split('\n')) {
    const pid = line.split(` ${packageId}[`)[1]?.match(/^(\d+)\]: /)?.[1];
    if (!pid) { continue; }
    const request = line.match(seekRequest);
    if (request) {
      pending = {pid, requested: Number(request[1]), outcome: 'pending'};
      seeks.push(pending);
    } else if (pending?.pid === pid && pending.outcome === 'pending') {
      const rejection = line.match(failedSeek);
      const acceptance = line.match(acceptedSeek);
      if (unsupportedSeek.test(line)) { pending.unsupported = true; }
      if (rejection && Math.abs(Number(rejection[1]) - pending.requested) <= 0.001) {
        pending.outcome = pending.unsupported ? 'rejected-50004' : 'rejected';
      }
      if (acceptance) {
        const target = Number(acceptance[1]) * 3600 + Number(acceptance[2]) * 60 + Number(acceptance[3]);
        if (!pending.unsupported && Math.abs(target - pending.requested) <= 0.001) { pending.outcome = 'accepted'; }
      }
    }
  }
  return seeks.map(({requested, outcome}) => ({requested, outcome}));
}

export function parseElapsedPosition(text) {
  const match = typeof text === 'string' && text.match(/^\s*(\d+):([0-5]\d)\s*\/\s*\d+:[0-5]\d\s*$/);
  return match ? Number(match[1]) * 60 + Number(match[2]) : null;
}

// Native acceptance can precede the real clock change, and the clock may
// temporarily show a target while the app still holds the seek operation.
export function confirmedMp4Seek(requests, expected, {position, paused, controlsReady}) {
  assert(requests.length <= 1, 'Each MP4 action must issue exactly one native seek.');
  const request = requests[0];
  if (!request) { return false; }
  assert(Math.abs(request.requested - expected) <= 2, 'The MP4 native seek must match the requested target.');
  assert(['accepted', 'pending'].includes(request.outcome), 'An MP4 native seek was rejected.');
  return request.outcome === 'accepted' && Number.isFinite(position)
    && Math.abs(position - expected) <= 2 && paused && controlsReady;
}

export async function waitForMp4Seek({observe, onSample, expected, message, timeoutMs = 30_000,
  now = () => performance.now(), wait = pause}) {
  const deadline = now() + timeoutMs;
  do {
    const {positionText, ...state} = await observe();
    const sample = {...state, position: parseElapsedPosition(positionText)};
    onSample(sample);
    const confirmed = confirmedMp4Seek(sample.requests, expected, sample);
    const remaining = deadline - now();
    if (confirmed && remaining >= 0) { return sample.position; }
    if (remaining <= 0) { break; }
    await wait(Math.min(250, remaining));
  } while (now() < deadline);
  throw new Error(message);
}
