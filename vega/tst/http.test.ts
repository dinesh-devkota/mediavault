import {SourceAddress} from '../src/domain/paths';
import {Source} from '../src/domain/model';
import {parseJellyfinPage, parseWebDAVListing, scanJellyfin} from '../src/sources/http';

const source: Source = {id: 'nas', name: 'NAS', kind: 'webdav', endpoint: 'https://nas.example/media/', root: '', revision: 0, ignoredFiles: [], ignoredFolders: []};
const address = new SourceAddress(source.endpoint);
const response = (href: string, properties: string, status = '200 OK'): string => `<d:response><d:href>${href}</d:href><d:propstat><d:prop>${properties}</d:prop><d:status>HTTP/1.1 ${status}</d:status></d:propstat></d:response>`;
const root = response('/media/', '<d:resourcetype><d:collection/></d:resourcetype>');
const listing = (body: string): string => `<d:multistatus xmlns:d="DAV:">${root}${body}</d:multistatus>`;

describe('HTTP library boundaries', () => {
  it('confirms a DAV folder and accepts only its successful direct children', () => {
    const xml = listing(response('/media/Film%20one.mp4', '<d:getcontentlength>24</d:getcontentlength>')
      + response('https://foreign.example/media/secret.mp4', '<d:getcontentlength>200</d:getcontentlength>')
      + response('/media/Folder/deep.mp4', '<d:getcontentlength>99</d:getcontentlength>'));
    expect(parseWebDAVListing(xml, address, '')).toEqual([{path: 'Film one.mp4', name: 'Film one.mp4', directory: false, size: 24}]);
  });
  it('rejects namespace spoofing, missing confirmations, failed children and conflicting duplicate files', () => {
    expect(() => parseWebDAVListing('<multistatus xmlns="evil:">' + root + '</multistatus>', address, '')).toThrow();
    expect(() => parseWebDAVListing('<d:multistatus xmlns:d="DAV:"></d:multistatus>', address, '')).toThrow();
    expect(() => parseWebDAVListing(listing(response('/media/Hidden.mp4', '', '403 Forbidden')), address, '')).toThrow();
    expect(() => parseWebDAVListing(listing(response('/media/Film.mp4', '<d:getcontentlength>24</d:getcontentlength>')
      + response('/media/Film.mp4', '<d:getcontentlength>25</d:getcontentlength>')), address, '')).toThrow();
    expect(() => parseWebDAVListing(listing(response('/media/Film.mp4', '<d:getcontentlength>-1</d:getcontentlength>')), address, '')).toThrow();
  });
  it('maps Jellyfin episodes with server identity and a conservative unknown rating', () => {
    const page = parseJellyfinPage(JSON.stringify({TotalRecordCount: 1, StartIndex: 0, Items: [{Id: 'episode1', Type: 'Episode', Name: 'Pilot',
      SeriesId: 'series1', SeriesName: 'Show', ParentIndexNumber: 1, IndexNumber: 1, OfficialRating: 'Unrated', ImageTags: {Primary: 'image1'}}]}), source, 0);
    expect(page.items[0]).toMatchObject({id: 'nas:jellyfin:episode1', kind: 'episode', seriesId: 'series1', season: 1, episode: 1});
    expect(page.items[0]!.certification).toBeUndefined();
  });
  it('does not commit a changed or partially enumerated Jellyfin library', async () => {
    let calls = 0;
    const server = {...source, kind: 'jellyfin' as const, userId: 'household'};
    const transport = async () => ({status: 200, headers: {}, body: JSON.stringify({TotalRecordCount: calls++ ? 202 : 201,
      StartIndex: calls === 1 ? 0 : 200, Items: Array.from({length: calls === 1 ? 200 : 1}, (_, i) => ({Id: `movie${calls}_${i}`, Name: 'Movie', Type: 'Movie'}))})});
    await expect(scanJellyfin(server, transport, () => {}, () => {})).rejects.toThrow('changed');
    await expect(scanJellyfin(server, async () => ({status: 200, headers: {}, body: JSON.stringify({TotalRecordCount: 201, Items: []})}), () => {}, () => {})).rejects.toThrow('incomplete');
  });
});
