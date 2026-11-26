/* global globalThis */
import React, {useLayoutEffect} from 'react';
import {create, ReactTestRenderer} from 'react-test-renderer';
import {useCatalog, useFilteredCatalog} from '../src/ui/useCatalog';
import {itemFromFile} from '../src/domain/library';
import {HouseholdProfile, LibrarySnapshot, MediaItem, MediaKind, Source} from '../src/domain/model';

type Props = {library?: LibrarySnapshot; profileId?: string; unlocked: boolean; query?: string; sections?: MediaKind[]; genres?: string[]; watchlistOnly?: boolean};
type Catalog = ReturnType<typeof useCatalog> & ReturnType<typeof useFilteredCatalog>;
const noSections: MediaKind[] = [];
const noGenres: string[] = [];
const noWatchlist: string[] = [];
const mounted: ReactTestRenderer[] = [];
const source: Source = {id: 'fixture', name: 'Synthetic NAS', kind: 'webdav', endpoint: 'https://fixture.invalid/', root: 'Media', revision: 1, ignoredFolders: [], ignoredFiles: []};
const admin: HouseholdProfile = {id: 'admin', name: 'Adult', admin: true, folders: []};
const child: HouseholdProfile = {id: 'child', name: 'Child', admin: false, folders: [{sourceId: source.id, path: 'Media/Family'}], maximumMovieRating: 'PG', maximumTVRating: 'TV-PG'};
const media = (path: string, extras: Partial<MediaItem> = {}): MediaItem => ({...itemFromFile(source.id, path, 100)!, certification: 'PG', ...extras});
const first = media('Media/Family/Feature (2020).mkv', {collection: 'Feature Saga'});
const second = media('Media/Family/Feature (2020) - Extended.mkv', {collection: 'Feature Saga'});
const sequel = media('Media/Family/Sequel (2022).mkv', {collection: 'Feature Saga'});
const adult = media('Media/Private/Adult (2023).mkv', {certification: 'R'});
const photo = media('Media/Family/Trip.jpg');
const episode = media('Media/Family/Show.S01E01.mkv', {certification: 'TV-PG'});
const nextEpisode = media('Media/Family/Show.S01E02.mkv', {certification: 'TV-MA'});
const snapshot = (): LibrarySnapshot => ({schema: 1, items: [first, second, sequel, adult, photo, episode, nextEpisode], sources: [source], profiles: [admin, child],
  profileLibraries: {
    admin: {viewing: {}, watchlist: [], collections: [{id: 'private', name: 'Adult collection', itemIds: [adult.id]}]},
    child: {viewing: {}, watchlist: [], collections: [
      {id: 'weekend', name: 'Weekend', itemIds: [sequel.id, first.id, photo.id, first.id, adult.id, 'missing']},
      {id: 'empty', name: 'Empty', itemIds: []},
    ]},
  }});
function freeze<T>(value: T): T {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    Object.freeze(value); Object.values(value).forEach(freeze);
  }
  return value;
}
async function harness(initial: Props) {
  let catalog!: Catalog;
  function Probe(props: Props) {
    const personal = props.library?.profileLibraries[props.profileId ?? ''];
    const value = useCatalog(props.library?.items, props.library?.sources,
      props.library?.profiles.find(profile => profile.id === props.profileId), props.unlocked,
      personal?.collections);
    const view = useFilteredCatalog(value.available, value.groups, {
      query: props.query ?? '', sections: props.sections ?? noSections, genres: props.genres ?? noGenres,
      watchlist: props.watchlistOnly ? personal?.watchlist ?? noWatchlist : undefined,
    });
    useLayoutEffect(() => { catalog = {...value, ...view}; });
    return null;
  }
  let tree!: ReactTestRenderer;
  const render = (props: Props) => React.createElement(React.StrictMode, null, React.createElement(Probe, props));
  await React.act(async () => { tree = create(render(initial)); }); mounted.push(tree);
  return {get value() { return catalog; }, update: async (props: Props) => { await React.act(async () => { tree.update(render(props)); }); }};
}
beforeAll(() => { (globalThis as typeof globalThis & {IS_REACT_ACT_ENVIRONMENT: boolean}).IS_REACT_ACT_ENVIRONMENT = true; });
afterEach(async () => { await React.act(async () => { mounted.splice(0).forEach(tree => tree.unmount()); }); });

test('viewing-only updates retain all derived references without retaining stale progress state', async () => {
  const library = freeze(snapshot()), value = await harness({library, profileId: child.id, unlocked: true});
  const before = value.value;
  const personal = library.profileLibraries.child!;
  const updated = freeze({...library, profileLibraries: {...library.profileLibraries, child: {...personal, viewing: {[first.id]: {position: 5, duration: 100, watched: false, updatedAt: 2}}}}});
  await value.update({library: updated, profileId: child.id, unlocked: true});
  expect(updated.profileLibraries.child!.viewing[first.id]!.position).toBe(5);
  expect(value.value.available).toBe(before.available); expect(value.value.groups).toBe(before.groups); expect(value.value.collections).toBe(before.collections);
  expect(value.value.filtered).toBe(value.value.available); expect(value.value.homeGroups).toBe(value.value.groups);
  expect(value.value.filtered).toBe(before.filtered); expect(value.value.homeGroups).toBe(before.homeGroups);
});

test('lock, missing profile and household switches never retain private items or collection names', async () => {
  const library = freeze(snapshot()), value = await harness({library, profileId: admin.id, unlocked: true});
  expect(value.value.available).toContain(adult); expect(value.value.collections.map(entry => entry.title)).toContain('Adult collection');
  await value.update({library, profileId: admin.id, unlocked: false});
  expect(value.value).toEqual({available: [], groups: [], collections: [], filtered: [], homeGroups: []});
  await value.update({library, profileId: 'removed', unlocked: true});
  expect(value.value).toEqual({available: [], groups: [], collections: [], filtered: [], homeGroups: []});
  await value.update({library, profileId: child.id, unlocked: true});
  expect(value.value.available).toEqual([first, second, sequel, photo, episode]);
  expect(value.value.collections.map(entry => entry.title)).toEqual(['Empty', 'Feature Saga', 'Weekend']);
  await value.update({library, profileId: admin.id, unlocked: true});
  expect(value.value.available).toContain(adult); expect(value.value.available).toContain(nextEpisode);
});

test('immutable folder grants and movie or television rating limits invalidate visibility immediately', async () => {
  const library = freeze(snapshot()), value = await harness({library, profileId: child.id, unlocked: true});
  const withProfile = (profile: HouseholdProfile) => freeze({...library, profiles: [admin, profile]});
  await value.update({library: withProfile({...child, maximumMovieRating: 'G'}), profileId: child.id, unlocked: true});
  expect(value.value.available).toEqual([photo, episode]);
  await value.update({library: withProfile({...child, maximumTVRating: 'TV-G'}), profileId: child.id, unlocked: true});
  expect(value.value.available).toEqual([first, second, sequel, photo]);
  await value.update({library: withProfile({...child, folders: []}), profileId: child.id, unlocked: true});
  expect(value.value.available).toEqual([]); expect(value.value.groups).toEqual([]);
  expect(value.value.collections.map(entry => [entry.title, entry.count])).toEqual([['Empty', 0], ['Weekend', 0]]);
});

test('source removal, roots and ignored folders/files invalidate groups and counts on the next render', async () => {
  const library = freeze(snapshot()), value = await harness({library, profileId: child.id, unlocked: true});
  for (const sources of [[], [{...source, root: 'Elsewhere'}], [{...source, revision: 2, ignoredFolders: ['Media/Family']}]] as Source[][]) {
    await value.update({library: freeze({...library, sources}), profileId: child.id, unlocked: true});
    expect(value.value.available).toEqual([]); expect(value.value.collections.find(entry => entry.personalId === 'weekend')!.count).toBe(0);
  }
  await value.update({library: freeze({...library, sources: [{...source, revision: 2, ignoredFiles: [first.id.slice(source.id.length + 1), sequel.path]}]}), profileId: child.id, unlocked: true});
  expect(value.value.available).toEqual([second, photo, episode]);
  expect(value.value.collections.find(entry => entry.personalId === 'weekend')!.items).toEqual([]);
  expect(value.value.collections.some(entry => entry.title === 'Feature Saga')).toBe(false);
});

test('rescans update ratings, missing media, artwork and grouped titles without mutating earlier snapshots', async () => {
  const library = freeze(snapshot()), value = await harness({library, profileId: child.id, unlocked: true});
  const before = value.value;
  const rescanned = library.items.map(item => item === first ? {...item, certification: 'R'}
    : item === second ? {...item, missing: true}
      : item === sequel ? {...item, title: 'Renamed sequel', posterPath: 'Media/Family/new-poster.jpg'} : item);
  await value.update({library: freeze({...library, items: rescanned}), profileId: child.id, unlocked: true});
  expect(value.value.available.map(item => item.id)).toEqual([sequel.id, photo.id, episode.id]);
  expect(value.value.groups.find(group => group.items[0]!.id === sequel.id)).toMatchObject({title: 'Renamed sequel', items: [{posterPath: 'Media/Family/new-poster.jpg'}]});
  expect(before.available).toContain(first); expect(before.available).toContain(second);
  expect(before.groups.find(group => group.items[0]!.id === sequel.id)!.title).toBe('Sequel');
});

test('collection edits only replace collections and preserve catalog order, grouped counts and photo exclusion', async () => {
  const library = freeze(snapshot()), value = await harness({library, profileId: child.id, unlocked: true});
  const before = value.value;
  expect(before.collections.find(entry => entry.personalId === 'weekend')!.items).toEqual([first, sequel]);
  const personal = library.profileLibraries.child!;
  const collections = [{id: 'weekend', name: 'Renamed', itemIds: [sequel.id, second.id, photo.id, first.id, second.id, 'missing']}];
  await value.update({library: freeze({...library, profileLibraries: {...library.profileLibraries, child: {...personal, collections}}}), profileId: child.id, unlocked: true});
  expect(value.value.available).toBe(before.available); expect(value.value.groups).toBe(before.groups); expect(value.value.collections).not.toBe(before.collections);
  const changed = value.value.collections.find(entry => entry.personalId === 'weekend')!;
  expect(changed.items).toEqual([first, second, sequel]); expect(changed.count).toBe(2);
  expect(value.value.collections.map(entry => entry.title)).toEqual(['Feature Saga', 'Renamed']);
});

test('empty startup has stable empty results and first scan recomputes normally', async () => {
  const value = await harness({unlocked: false}), before = value.value;
  await value.update({unlocked: false});
  expect(value.value.available).toBe(before.available); expect(value.value.groups).toBe(before.groups); expect(value.value.collections).toBe(before.collections);
  await value.update({library: freeze(snapshot()), profileId: child.id, unlocked: true});
  expect(value.value.available).toEqual([first, second, sequel, photo, episode]);
});

test('Home keeps a filtered grid across playback updates and applies every filter and profile change', async () => {
  const original = snapshot();
  const library = freeze({
    ...original,
    items: original.items.map(item => item === first || item === episode ? {...item, genres: ['Adventure']} : item),
    profileLibraries: {...original.profileLibraries, child: {...original.profileLibraries.child!, watchlist: [first.id, adult.id, episode.id]}},
  });
  const props: Props = {library, profileId: child.id, unlocked: true, query: '  FEATURE ', sections: ['movie'], genres: ['Adventure'], watchlistOnly: true};
  const view = await harness(props), before = view.value;
  const ids = () => view.value.filtered.map(item => item.id);
  expect(ids()).toEqual([first.id]);
  expect(view.value.homeGroups[0]!.items).toEqual(view.value.filtered);
  const childLibrary = library.profileLibraries.child!;
  const viewed = freeze({...library, profileLibraries: {...library.profileLibraries, child: {...childLibrary, viewing: {
    [first.id]: {position: 1, duration: 10, watched: false, updatedAt: 1},
  }}}});
  await view.update({...props, library: viewed, query: 'feature'});
  expect(view.value.filtered).toBe(before.filtered);
  expect(view.value.homeGroups).toBe(before.homeGroups);
  await view.update({...props, genres: ['Drama']});
  expect(ids()).toEqual([]);
  await view.update({...props, query: 'sHoW', sections: ['episode']});
  expect(ids()).toEqual([episode.id]);
  await view.update({...props, library: freeze({...library, profileLibraries: {...library.profileLibraries, child: {...childLibrary, watchlist: []}}})});
  expect(ids()).toEqual([]);
  await view.update({...props, unlocked: false});
  expect(ids()).toEqual([]);
  expect(view.value.homeGroups).toEqual([]);
});
