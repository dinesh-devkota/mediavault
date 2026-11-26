import {collectionGroups, createCollection, groupLibrary, itemFromFile, kindForPath, nextEpisode, progressState, versionKey, versionLabel, visible} from '../src/domain/library';
import {applyLocalMetadata, InvalidTextFileError, parseNFO} from '../src/domain/metadata';
import {emptyProfileLibrary, HouseholdProfile, MediaItem, Source, SourceClient} from '../src/domain/model';
import {SourceAddress} from '../src/domain/paths';
import {matchingSubtitles, parseSubtitles} from '../src/domain/subtitles';
import {scanSource} from '../src/sources/scanner';

const source: Source = {id: 'source', name: 'Family NAS', kind: 'webdav', endpoint: 'https://nas.example/media/', root: '', revision: 0, ignoredFolders: [], ignoredFiles: []};
const movie = (path = 'Movies/Feature (2020).mp4'): MediaItem => itemFromFile(source.id, path, 100)!;
const viewer: HouseholdProfile = {id: 'child', name: 'Child', admin: false, folders: [{sourceId: source.id, path: 'Movies'}], maximumMovieRating: 'PG'};

describe('Vega library contracts', () => {
  it('keeps TypeScript and subtitle/art metadata out of playable media', () => {
    expect(kindForPath('node_modules/fetch.d.ts')).toBeUndefined();
    expect(kindForPath('my-source.ts')).toBeUndefined();
    expect(kindForPath('Feature.nfo')).toBeUndefined();
    expect(kindForPath('Feature.srt')).toBeUndefined();
    expect(movie('Movies/Film.mp4').title).toBe('Film');
    expect(movie('Movies/Feature (2020) - Directors Cut.mkv').title).toBe('Feature');
  });
  it('groups known versions conservatively and retains each file identity', () => {
    const first = movie(), second = movie('Movies/Feature (2020) - Directors Cut.mkv');
    expect(groupLibrary([first, second])).toHaveLength(1);
    expect(first.id).not.toBe(second.id);
    expect(versionKey(movie('Movies/Feature.mp4'))).not.toBe(versionKey(movie('Other/Feature.mkv')));
    expect(versionLabel(movie('Movies/The 4Kings.mp4'))).not.toContain('4K');
    expect(versionLabel({...second, edition: 'Festival edition'})).toContain('Festival edition');
  });
  it('filters hidden titles before collection counts and covers', () => {
    const first = {...movie(), collection: 'Feature Saga', certification: 'PG'};
    const other = {...movie('Movies/Sequel (2022).mp4'), collection: 'Feature Saga', certification: 'R'};
    const allowed = [first, other].filter(item => visible(item, source, viewer, true));
    expect(allowed).toEqual([first]);
    expect(collectionGroups(allowed, [])).toEqual([]);
    expect(visible(first, source, viewer, false)).toBe(false);
    expect(visible({...first, certification: undefined}, source, viewer, true)).toBe(false);
    const personal = createCollection(emptyProfileLibrary(), 'weekend', 'Weekend', allowed, [first.id, other.id]);
    expect(personal.collections[0]!.itemIds).toEqual([first.id]);
    expect(() => createCollection(personal, 'again', 'weekend', [], [])).toThrow();
  });
  it('walks TV seasons in order without crossing shows or inaccessible episodes', () => {
    const episode = movie('Shows/Example.S01E01.mp4');
    const next = movie('Shows/Example.S01E02.mp4');
    const later = movie('Shows/Example.S02E01.mp4');
    const unrelated = movie('Shows/Other.S01E02.mp4');
    expect(nextEpisode(episode, [later, unrelated, next])).toEqual(next);
    expect(nextEpisode(episode, [later, unrelated])).toEqual(later);
    expect(nextEpisode(later, [episode, next])).toBeUndefined();
  });
  it('keeps a completed episode watched when native teardown reports a reset clock', () => {
    const completed = progressState(12, 12, undefined, true);
    expect(progressState(0, 0, completed, false)).toMatchObject({watched: true, duration: 12});
    expect(progressState(Number.NaN, Number.POSITIVE_INFINITY, completed)).toMatchObject({position: 12, duration: 12, watched: true});
  });
  it('accepts local fields without remote URLs or viewing-state imports', () => {
    const local = parseNFO('<movie><title>Local title</title><year>2020</year><genre>Drama/Documentary|Drama</genre><mpaa>US:PG</mpaa><uniqueid type="tmdb">123</uniqueid><set><name>Feature Saga</name></set><thumb>https://other.invalid/poster.jpg</thumb><playcount>3</playcount></movie>');
    expect(local).toMatchObject({title: 'Local title', certification: 'PG', genres: ['Drama', 'Documentary'], tmdbId: 123, collection: 'Feature Saga'});
    expect(local).not.toHaveProperty('thumb');
    expect(local).not.toHaveProperty('playcount');
    expect(applyLocalMetadata(movie(), local).kind).toBe('documentary');
    expect(parseNFO('<movie><certification>unknown</certification></movie>').certificationPresent).toBe(true);
  });
  it('rejects malicious, malformed and unbounded XML', () => {
    for (const content of ['<!DOCTYPE movie [<!ENTITY x SYSTEM "file:///secrets">]><movie><title>&x;</title></movie>', '<movie><title>bad</movie>', '<movie>' + '<a>'.repeat(33) + '</a>'.repeat(33) + '</movie>', '<movie><plot>' + 'x'.repeat(1024 * 1024) + '</plot></movie>']) {
      expect(() => parseNFO(content)).toThrow();
    }
  });
  it('invalidates an invalid specific rating without inheriting a permissive parent', () => {
    const original = applyLocalMetadata(movie('Shows/Example.S01E01.mp4'), parseNFO('<episodedetails><title>Restricted</title><mpaa>TV-MA</mpaa></episodedetails>'));
    const parent = parseNFO('<tvshow><title>Example</title><mpaa>TV-G</mpaa></tvshow>');
    const invalid = applyLocalMetadata(original, undefined, parent, true);
    expect(invalid.certification).toBeUndefined();
    expect(invalid.title).toBe('Restricted');
    expect(applyLocalMetadata(original, undefined, parent).certification).toBe('TV-G');
    expect(applyLocalMetadata(original, parseNFO('<episodedetails><mpaa>unknown</mpaa></episodedetails>'), parent).certification).toBeUndefined();
    expect(applyLocalMetadata({...original, manuallyMatched: true}, undefined, parent, true)).toEqual({...original, manuallyMatched: true});
  });
  it('clears removed local rating and edition while preserving unrelated metadata', () => {
    const original = applyLocalMetadata({...movie(), plot: 'Online plot'}, parseNFO('<movie><title>Local</title><mpaa>PG</mpaa><edition>Extended</edition></movie>'));
    const removed = applyLocalMetadata(original);
    expect(removed.certification).toBeUndefined();
    expect(removed.edition).toBeUndefined();
    expect(removed.title).toBe('Feature');
    expect(removed.plot).toBe('Online plot');
  });
  it('rejects WebDAV escapes and foreign hosts before following server hrefs', () => {
    const address = new SourceAddress('https://nas.example/media/');
    expect(address.relative('/media/Movies/Film%20one.mp4', address.url('Movies', true))).toBe('Movies/Film one.mp4');
    for (const href of ['https://other.example/media/a.mp4', '/media/%2e%2e/secret', '/media/%252e%252e/secret', '/media/Movies%2fsecret', '/other/a.mp4', '/media/a.mp4?token=x']) {
      expect(address.relative(href, address.url('Movies', true))).toBeUndefined();
    }
    expect(() => new SourceAddress('https://user:password@nas.example/media/')).toThrow();
  });
  it('matches only adjacent subtitle files and parses bounded SRT/WebVTT cues', () => {
    const item = movie();
    expect(matchingSubtitles(item, ['Movies/Feature (2020).en.forced.srt', 'Other/Feature (2020).srt', 'Movies/Feature (2020) sequel.srt'])).toHaveLength(1);
    expect(parseSubtitles('1\n00:00:01,000 --> 00:00:03,500\n<i>Hello</i>\n\n2\n00:00:04,000 --> 00:00:03,000\nInvalid')).toEqual([{start: 1, end: 3.5, text: 'Hello'}]);
  });
  it('imports local artwork without consuming unrelated standalone photos', async () => {
    const entries = ['Feature (2020).mp4', 'Feature (2020).nfo', 'Feature (2020)-poster.png', 'poster.jpg'];
    const client: SourceClient = {
      list: async path => path === 'Photos' ? [{path: 'Photos/poster.jpg', name: 'poster.jpg', directory: false, size: 30}]
        : [...entries.map(name => ({path: name, name, directory: false, size: 30})), {path: 'Photos', name: 'Photos', directory: true, size: 0}],
      readText: async () => '<movie><title>Local Feature</title><set>Family Saga</set></movie>',
      playback: async item => ({uri: item.path}),
    };
    const result = await scanSource(source, client, [], () => {}, () => {});
    expect(result.find(item => item.kind === 'movie')?.title).toBe('Local Feature');
    expect(result.find(item => item.path === 'Feature (2020)-poster.png')?.missing).toBe(true);
    // At a single-film directory, generic poster.jpg is correctly artwork too.
    expect(result.find(item => item.path === 'poster.jpg')?.missing).toBe(true);
    expect(result.find(item => item.path === 'Photos/poster.jpg')?.missing).toBe(false);
    const failed: SourceClient = {...client, list: async () => { throw new Error('offline'); }};
    await expect(scanSource(source, failed, result, () => {}, () => {})).rejects.toThrow('offline');
  });
  it('makes confirmed invalid text ratings unknown but retains them during a network outage', async () => {
    const original = applyLocalMetadata(movie('Feature (2020).mp4'), parseNFO('<movie><title>Known title</title><mpaa>PG</mpaa></movie>'));
    const client: SourceClient = {
      list: async () => ['Feature (2020).mp4', 'Feature (2020).nfo'].map(name => ({path: name, name, directory: false, size: 30})),
      readText: async () => { throw new InvalidTextFileError('Confirmed oversized file'); },
      playback: async item => ({uri: item.path}),
    };
    const invalid = (await scanSource(source, client, [original], () => {}, () => {}))[0]!;
    expect(invalid.title).toBe('Known title'); expect(invalid.certification).toBeUndefined();
    expect(invalid.local?.certificationPresent).toBe(true);
    const outage = {...client, readText: async () => { throw new Error('Offline'); }};
    expect((await scanSource(source, outage, [original], () => {}, () => {}))[0]!.certification).toBe('PG');
  });
  it.each(['episode', 'show'] as const)('hides an invalid %s rating when the other sidecar is unavailable, preserving display fields', async invalid => {
    const episodePath = 'Shows/Example.S01E01.mp4';
    const episodeNFO = 'Shows/Example.S01E01.nfo';
    const showNFO = 'Shows/tvshow.nfo';
    const original = applyLocalMetadata(movie(episodePath),
      parseNFO('<episodedetails><title>Known episode</title><plot>Saved episode details</plot><year>2021</year><mpaa>TV-G</mpaa></episodedetails>'),
      parseNFO('<tvshow><title>Known show</title><genre>Family</genre><uniqueid type="tmdb">123</uniqueid><mpaa>TV-G</mpaa></tvshow>'));
    const child: HouseholdProfile = {...viewer, folders: [{sourceId: source.id, path: 'Shows'}], maximumTVRating: 'TV-G'};
    expect(visible(original, source, child, true)).toBe(true);
    const client: SourceClient = {
      list: async path => path === '' ? [{path: 'Shows', name: 'Shows', directory: true, size: 0}]
        : [episodePath, episodeNFO, showNFO].map(value => ({path: value, name: value.slice('Shows/'.length), directory: false, size: 100})),
      readText: async path => {
        if (path === (invalid === 'episode' ? episodeNFO : showNFO)) { return '<movie><title>Corrupt</movie>'; }
        throw new Error('The other sidecar is temporarily unavailable');
      },
      playback: async item => ({uri: item.path}),
    };
    const result = (await scanSource(source, client, [original], () => {}, () => {})).find(item => item.path === episodePath)!;
    expect(result).toMatchObject({title: original.title, plot: original.plot, year: original.year,
      genres: original.genres, seriesTitle: original.seriesTitle, seriesId: original.seriesId,
      season: original.season, episode: original.episode});
    expect(result.certification).toBeUndefined();
    expect(result.local?.certificationPresent).toBe(true);
    expect(visible(result, source, child, true)).toBe(false);

    // A network failure without confirmed invalid data must not discard the last complete import.
    const unavailable = {...client, readText: async () => { throw new Error('Offline'); }};
    const retained = (await scanSource(source, unavailable, [original], () => {}, () => {})).find(item => item.path === episodePath)!;
    expect(retained).toMatchObject({...original, missing: false});
    expect(visible(retained, source, child, true)).toBe(true);
    const corrected = {...original, manuallyMatched: true};
    const manual = (await scanSource(source, client, [corrected], () => {}, () => {})).find(item => item.path === episodePath)!;
    expect(manual).toMatchObject({...corrected, missing: false});
  });
});
