import Native from '../src/native/MediaVaultNative';
import {platformServices} from '../src/native/platform';
import {itemFromFile} from '../src/domain/library';
import {Source} from '../src/domain/model';

jest.mock('../src/native/MediaVaultNative', () => ({__esModule: true, default: {
  request: jest.fn(), stat: jest.fn(), readRange: jest.fn(), acquirePlaybackTicket: jest.fn(), acquireImageTicket: jest.fn(),
  verifyProfilePIN: jest.fn(), hasProfilePIN: jest.fn(),
  revokeResource: jest.fn(async () => '{}'),
}}));
const native = Native as jest.Mocked<typeof Native>;
const source: Source = {id: 'nas', name: 'NAS', kind: 'webdav', endpoint: 'https://nas.example/media/', root: 'Movies', revision: 0, ignoredFiles: [], ignoredFolders: []};
const uri = 'http://127.0.0.1:49155/media/abcdef123456';
beforeEach(() => jest.clearAllMocks());

describe('actual native facade contract', () => {
  it('never treats malformed PIN replies as authorization', async () => {
    for (const response of ['"false"', '{}', '1', 'null']) {
      native.verifyProfilePIN.mockResolvedValue(response);
      await expect(platformServices.verifyProfilePIN('child', '482619')).rejects.toThrow('invalid');
    }
    native.verifyProfilePIN.mockResolvedValue('false');
    expect(await platformServices.verifyProfilePIN('child', '482619')).toBe(false);
  });
  it('reads bounded WebDAV sidecars without requiring Range support', async () => {
    native.request.mockResolvedValue(JSON.stringify({status: 200, body: '<movie/>', headers: {}}));
    expect(await platformServices.client(source).readText('Movies/Film.nfo', 1024)).toBe('<movie/>');
    expect(JSON.parse(native.request.mock.calls[0]![1])).toEqual({path: 'Movies/Film.nfo', method: 'GET', maximumBytes: 1024});
    expect(native.stat).not.toHaveBeenCalled();
    await expect(platformServices.client(source).readText('Other/Film.nfo', 1024)).rejects.toThrow('outside');
  });
  it('rejects over-limit HTTP data even if a faulty transport returned it', async () => {
    native.request.mockResolvedValue(JSON.stringify({status: 200, body: 'abc', headers: {}}));
    await expect(platformServices.client(source).readText('Movies/Film.nfo', 2)).rejects.toThrow('invalid response');
  });
  it('assembles multi-chunk UTF-8 subtitles and rejects short reads', async () => {
    // UTF-8 é deliberately crosses the one-MiB read boundary; precomputed Base64 avoids host-only Buffer APIs.
    const body = 'x'.repeat(1024 * 1024 - 1) + 'é\n';
    native.stat.mockResolvedValue(JSON.stringify({size: 1024 * 1024 + 2, directory: false}));
    native.readRange.mockImplementation(async (_source, _path, offset) => offset === '0' ? 'eHh4'.repeat(349525) + 'ww==' : 'qQo=');
    expect(await platformServices.client({...source, kind: 'smb'}).readText('Movies/Film.srt', 2 * 1024 * 1024)).toBe(body);
    expect(native.readRange).toHaveBeenCalledTimes(2);
    native.readRange.mockResolvedValue('eA==');
    await expect(platformServices.client({...source, kind: 'smb'}).readText('Movies/Film.srt', 2 * 1024 * 1024)).rejects.toThrow('changed');
  });
  it('releases a playback capability if cancellation arrives during acquisition', async () => {
    const cancel = new AbortController();
    native.acquirePlaybackTicket.mockImplementation(async () => { cancel.abort(); return JSON.stringify({uri}); });
    await expect(platformServices.client(source).playback(itemFromFile('nas', 'Movies/Film.mp4', 10)!, cancel.signal)).rejects.toThrow('cancelled');
    expect(native.revokeResource).toHaveBeenCalledWith(uri);
  });
  it('uses bounded image tickets and never hands server credential URLs to views', async () => {
    const item = {...itemFromFile('nas', 'Movies/Film.mp4', 10)!, jellyfinId: 'film1'};
    native.acquireImageTicket.mockResolvedValue(JSON.stringify({uri, mime: 'image/jpeg'}));
    const picture = await platformServices.image({...source, kind: 'jellyfin'}, item, '');
    expect(native.acquireImageTicket).toHaveBeenCalledWith('nas', 'Items/film1/Images/Primary', JSON.stringify({maxWidth: '480'}));
    await picture.release!(); expect(native.revokeResource).toHaveBeenCalledWith(uri);
    native.acquirePlaybackTicket.mockResolvedValue(JSON.stringify({uri: 'https://user:secret@nas.example/private.mp4'}));
    await expect(platformServices.playback(source, item)).rejects.toThrow('protected local');
  });
});
