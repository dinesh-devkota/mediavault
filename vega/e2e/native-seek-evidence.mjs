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
