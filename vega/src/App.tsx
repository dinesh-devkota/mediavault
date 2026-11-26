import React, {useCallback, useEffect, useRef, useState} from 'react';
import {AppState, BackHandler, ScrollView, StyleSheet, Text, View} from 'react-native';
import {TVFocusGuideView} from '@amazon-devices/react-native-kepler';
import {platformServices} from './native/platform';
import {BUILD_CONFIG} from './generated/buildConfig';
import {collectionGroups, createCollection, groupLibrary, MediaGroup, nextEpisode, progressState, versionLabel, visible} from './domain/library';
import {emptyProfileLibrary, HouseholdProfile, LibrarySnapshot, MediaItem, MediaKind, PlaybackResource, ProfileLibrary, Source} from './domain/model';
import {contains, parentPath} from './domain/paths';
import {loadMatchingSubtitles} from './domain/subtitles';
import {loadLibrary, saveLibrary} from './services/storage';
import {scanJellyfin} from './sources/http';
import {scanSource} from './sources/scanner';
import {Action, Field, Poster, shared} from './ui/Controls';
import {LibraryGrid} from './ui/LibraryGrid';
import {PhotoViewer} from './ui/PhotoViewer';
import {Player} from './ui/Player';
import {SourceEditor} from './ui/SourceEditor';

type Page = 'home' | 'sections' | 'search' | 'sources' | 'source' | 'add-source' | 'ignored' | 'collections' | 'collection' | 'membership' | 'group' | 'season' | 'detail' | 'photo' | 'player' | 'profiles' | 'unlock' | 'add-profile' | 'filters' | 'add-to-collection';
interface Route { page: Page; id?: string; folder?: string; season?: number }
const newID = (): string => Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 12);
const sectionLabels: Record<MediaKind, string> = {movie: 'Movies', documentary: 'Documentaries', episode: 'TV shows', music: 'Music', photo: 'Photos'};

export const App = () => BUILD_CONFIG.fixtureVault
  ? <View style={fixtureStyles.root}>
    <Text testID="fixture-build-banner" style={fixtureStyles.banner}>VIRTUAL DEVICE TEST BUILD · Synthetic credentials only · Secure storage requires hardware verification</Text>
    <MediaVaultApp/>
  </View>
  : <MediaVaultApp/>;

const fixtureStyles = StyleSheet.create({
  root: {flex: 1, backgroundColor: '#10131a'},
  banner: {backgroundColor: '#ffd58a', color: '#231900', fontSize: 18, fontWeight: '700', textAlign: 'center', paddingHorizontal: 40, paddingVertical: 8},
});

const MediaVaultApp = () => {
  const [library, setLibrary] = useState<LibrarySnapshot>();
  const libraryRef = useRef<LibrarySnapshot | undefined>(undefined);
  const [profileId, setProfileId] = useState<string>();
  const profileRef = useRef<string | undefined>(undefined);
  const [unlocked, setUnlocked] = useState(false);
  const unlockedRef = useRef(false);
  const [session, setSession] = useState(0);
  const sessionRef = useRef(0);
  const unlockAttempt = useRef(0);
  const [routes, setRoutes] = useState<Route[]>([{page: 'home'}]);
  const route = routes[routes.length - 1]!;
  const [error, setError] = useState<string>();
  const [initializationAttempt, setInitializationAttempt] = useState(0);
  const [busy, setBusy] = useState<string>();
  const [query, setQuery] = useState('');
  const [sections, setSections] = useState<MediaKind[]>([]);
  const [genres, setGenres] = useState<string[]>([]);
  const [watchlistOnly, setWatchlistOnly] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [selecting, setSelecting] = useState(false);
  const [name, setName] = useState('');
  const [pin, setPin] = useState('');
  const [folderEntries, setFolderEntries] = useState<Array<{path: string; name: string; directory: boolean}>>([]);
  const scanAbort = useRef<AbortController | undefined>(undefined);
  const profile = library?.profiles.find(value => value.id === profileId);
  const personal = library?.profileLibraries[profileId ?? ''] ?? emptyProfileLibrary();
  const available = library?.items.filter(item => visible(item, library.sources.find(source => source.id === item.sourceId), profile, unlocked)) ?? [];
  const canManage = unlocked && profile?.admin === true;
  const collectionList = unlocked ? collectionGroups(available, personal.collections) : [];
  const collection = collectionList.find(value => value.id === route.id || value.personalId === route.id);
  const groups = groupLibrary(available);
  const group = groups.find(value => value.id === route.id);
  const item = available.find(value => value.id === route.id);
  const source = canManage ? library?.sources.find(value => value.id === route.id) : undefined;
  const navigate = (next: Route): void => { unlockAttempt.current++; setError(undefined); setRoutes(current => [...current, next]); };
  const back = useCallback((): void => { unlockAttempt.current++; if (route.page === 'unlock') { setBusy(undefined); } setError(undefined); setPin(''); setRoutes(current => current.length > 1 ? current.slice(0, -1) : current); }, [route.page]);
  const report = useCallback((reason: unknown): void => setError(reason instanceof Error ? reason.message : 'Something went wrong. Please try again.'), []);
  const assertSession = useCallback((token: number, admin = false): LibrarySnapshot => {
    const latest = libraryRef.current;
    if (!latest || token !== sessionRef.current || !unlockedRef.current || (admin && !latest.profiles.find(value => value.id === profileRef.current)?.admin)) {
      throw new Error('Your profile changed. Unlock it and try again.');
    }
    return latest;
  }, []);
  const update = (next: LibrarySnapshot): void => {
    libraryRef.current = next; setLibrary(next); void saveLibrary(next).catch(report);
  };
  const updatePersonal = (transform: (value: ProfileLibrary) => ProfileLibrary, token = sessionRef.current): void => {
    const latest = assertSession(token), id = profileRef.current!;
    update({...latest, profileLibraries: {...latest.profileLibraries, [id]: transform(latest.profileLibraries[id] ?? emptyProfileLibrary())}});
  };
  const lock = useCallback((): void => {
    unlockAttempt.current++;
    sessionRef.current++; setSession(sessionRef.current); unlockedRef.current = false; setUnlocked(false);
    scanAbort.current?.abort(); setBusy(undefined); setSelected(new Set()); setSelecting(false); setQuery(''); setGenres([]); setSections([]); setWatchlistOnly(false);
    setRoutes([{page: 'profiles'}]); setPin(''); void platformServices.revokeAll().catch(report);
  }, [report]);
  useEffect(() => {
    let active = true;
    loadLibrary().then(async value => {
      // Native PIN presence is authoritative if a previous launch stopped between secure and catalog writes.
      const profiles = await Promise.all(value.profiles.map(async entry => ({...entry,
        pinReference: await platformServices.hasProfilePIN(entry.id) ? entry.id : entry.pinReference})));
      value = {...value, profiles};
      if (!active) { return; }
      libraryRef.current = value; setLibrary(value);
      if (value.profiles.length === 1 && !value.profiles[0]!.pinReference) {
        profileRef.current = value.profiles[0]!.id; setProfileId(profileRef.current); unlockedRef.current = true; setUnlocked(true);
      } else { setRoutes([{page: 'profiles'}]); }
    }).catch(reason => { if (active) { report(reason); } });
    return () => { active = false; scanAbort.current?.abort(); void platformServices.revokeAll(); };
  }, [initializationAttempt, report]);
  useEffect(() => {
    const handle = BackHandler.addEventListener('hardwareBackPress', () => { if (routes.length > 1) { back(); return true; } return false; });
    return () => handle.remove();
  }, [back, routes.length]);
  useEffect(() => {
    const handle = AppState.addEventListener('change', state => {
      if (state !== 'active' && libraryRef.current?.profiles.some(value => value.pinReference)) { lock(); }
    });
    return () => handle.remove();
  }, [lock]);
  const scan = async (value: Source): Promise<void> => {
    const token = sessionRef.current;
    const controller = new AbortController(); scanAbort.current?.abort(); scanAbort.current = controller;
    setError(undefined); setBusy('Scanning ' + value.name + '…');
    const check = (): void => {
      const latest = assertSession(token, true);
      if (controller.signal.aborted || latest.sources.find(entry => entry.id === value.id)?.revision !== value.revision) { throw new Error('Scan cancelled because the source changed.'); }
    };
    try {
      let result: MediaItem[];
      if (value.kind === 'jellyfin') {
        const incoming = await scanJellyfin(value, platformServices.http, check, count => setBusy(`Scanning ${value.name} · ${count} files`));
        const latest = assertSession(token, true), ids = new Set(incoming.map(entry => entry.id));
        result = [...latest.items.filter(entry => entry.sourceId !== value.id), ...incoming,
          ...latest.items.filter(entry => entry.sourceId === value.id && !ids.has(entry.id)).map(entry => ({...entry, missing: true}))];
      } else {
        result = await scanSource(value, platformServices.client(value), assertSession(token, true).items, check,
          count => setBusy(`Scanning ${value.name} · ${count.files} files · ${count.folders} folders`), controller.signal);
      }
      check(); const latest = assertSession(token, true);
      update({...latest, items: result, sources: latest.sources.map(entry => entry.id === value.id ? {...entry, lastScan: Date.now()} : entry)});
    } catch (reason) { if (token === sessionRef.current && !controller.signal.aborted) { report(reason); } }
    finally { if (token === sessionRef.current) { setBusy(undefined); } }
  };
  const loadImage = useCallback(async (media: MediaItem, path: string): Promise<PlaybackResource> => {
    const token = sessionRef.current, latest = assertSession(token);
    const currentProfile = latest.profiles.find(value => value.id === profileRef.current), currentSource = latest.sources.find(value => value.id === media.sourceId);
    if (!visible(media, currentSource, currentProfile, true) || !currentSource) { throw new Error('This media is unavailable to your profile.'); }
    if (currentSource.kind !== 'jellyfin' && !contains(path, currentSource.root)) { throw new Error('Artwork is outside this source.'); }
    const resource = await platformServices.image(currentSource, media, path);
    try { assertSession(token); return resource; } catch (reason) { await platformServices.revokeResource(resource.uri); throw reason; }
  }, [assertSession]);
  const toggleSelection = (values: MediaItem[]): void => setSelected(current => {
    const next = new Set(current), remove = values.every(value => next.has(value.id));
    values.forEach(value => remove ? next.delete(value.id) : next.add(value.id)); return next;
  });
  const mark = (values: MediaItem[], watched: boolean): void => {
    const allowed = new Set(available.map(value => value.id));
    updatePersonal(current => ({...current, viewing: {...current.viewing, ...Object.fromEntries(values.filter(value => allowed.has(value.id)).map(value => [value.id,
      {...(current.viewing[value.id] ?? {position: 0, duration: 0}), watched, updatedAt: Date.now()}]))}}));
  };
  const openGroup = (value: MediaGroup): void => {
    if (route.page === 'home' && selecting) { toggleSelection(value.items); return; }
    if (value.items[0]!.kind === 'episode' || value.items.length > 1) { navigate({page: 'group', id: value.id}); }
    else { navigate({page: value.items[0]!.kind === 'photo' ? 'photo' : 'detail', id: value.items[0]!.id}); }
  };
  const create = (): void => {
    updatePersonal(current => createCollection(current, newID(), name, available, [...selected])); setName('');
  };
  const unlock = async (): Promise<void> => {
    const target = libraryRef.current?.profiles.find(value => value.id === route.id);
    if (!target) { return; }
    const intent = sessionRef.current, attempt = ++unlockAttempt.current; setBusy('Unlocking…'); setError(undefined);
    try {
      if (target.pinReference && !await platformServices.verifyProfilePIN(target.id, pin)) { throw new Error('That PIN did not match. Please try again.'); }
      if (intent !== sessionRef.current || attempt !== unlockAttempt.current) { return; }
      await platformServices.revokeAll();
      if (intent !== sessionRef.current || attempt !== unlockAttempt.current) { return; }
      sessionRef.current++; setSession(sessionRef.current); profileRef.current = target.id; setProfileId(target.id); unlockedRef.current = true; setUnlocked(true);
      setPin(''); setRoutes([{page: 'home'}]);
    } catch (reason) { if (attempt === unlockAttempt.current) { report(reason); } }
    finally { if (attempt === unlockAttempt.current) { setBusy(undefined); } }
  };
  const ignore = async (value: Source, path: string, folder: boolean): Promise<void> => {
    const latest = assertSession(sessionRef.current, true);
    const key = folder ? 'ignoredFolders' : 'ignoredFiles';
    const updated = {...value, revision: value.revision + 1, [key]: value[key].includes(path) ? value[key].filter(entry => entry !== path) : [...value[key], path]};
    update({...latest, sources: latest.sources.map(entry => entry.id === value.id ? updated : entry)});
    try { await platformServices.updateSource(updated); } catch (reason) { report(reason); }
  };
  const browseIgnored = async (value: Source, folder: string): Promise<void> => {
    const token = sessionRef.current; setBusy('Opening folder…');
    try {
      const entries = await platformServices.client(value).list(folder); assertSession(token, true); setFolderEntries(entries);
      navigate({page: 'ignored', id: value.id, folder});
    } catch (reason) { report(reason); } finally { setBusy(undefined); }
  };
  if (!library) { return <View style={shared.page}><Text style={shared.title}>MediaVault</Text>
    <Text style={error ? shared.error : shared.subtitle} testID={error ? 'startup-error' : 'startup-status'}>{error ?? 'Opening your library…'}</Text>
    {error && <Action label="Try again" preferred testID="startup-retry" onPress={() => { setError(undefined); setInitializationAttempt(value => value + 1); }}/ >}
  </View>; }
  if (route.page === 'player' && item) {
    const token = session, next = nextEpisode(item, available), currentSource = library.sources.find(value => value.id === item.sourceId)!;
    return <Player key={`${session}|${item.id}`} item={item} resume={personal.viewing[item.id]} next={next}
      load={async () => {
        assertSession(token); const resource = await platformServices.playback(currentSource, item);
        try { assertSession(token); return resource; } catch (reason) { await platformServices.revokeResource(resource.uri); throw reason; }
      }}
      subtitles={async () => {
        if (currentSource.kind === 'jellyfin') { return []; }
        const client = platformServices.client(currentSource), entries = await client.list(parentPath(item.path)); assertSession(token);
        return loadMatchingSubtitles(item, entries.filter(entry => !entry.directory).map(entry => entry.path), client.readText, () => assertSession(token));
      }}
      onProgress={(position, duration, ended) => { if (token === sessionRef.current && unlockedRef.current) { updatePersonal(value => ({...value, viewing: {...value.viewing, [item.id]: progressState(position, duration, value.viewing[item.id], ended)}}), token); } }}
      releaseResource={uri => platformServices.revokeResource(uri)}
      autoNext={personal.continuousTV === true} onAutoNext={enabled => updatePersonal(value => ({...value, continuousTV: enabled}), token)}
      onClose={back} onNext={() => { if (next && token === sessionRef.current) { setRoutes(current => [...current.slice(0, -1), {page: 'player', id: next.id}]); } }}/>;
  }
  if (route.page === 'photo' && item) {
    const photos = available.filter(value => value.kind === 'photo'), index = photos.findIndex(value => value.id === item.id);
    const showPhoto = (id: string): void => setRoutes(current => [...current.slice(0, -1), {page: 'photo', id}]);
    return <PhotoViewer key={session} item={item} load={() => loadImage(item, item.path)} onClose={back}
      previous={index > 0 ? () => showPhoto(photos[index - 1]!.id) : undefined} next={index + 1 < photos.length ? () => showPhoto(photos[index + 1]!.id) : undefined}/>;
  }
  const selectingHome = route.page === 'home' && unlocked && selecting;
  const sectionTitle = watchlistOnly ? 'Watchlist' : sections.length === 1 ? sectionLabels[sections[0]!] : 'All media';
  const header = <View style={[shared.header, route.page === 'home' && {marginBottom: 8}]}>
    <Text style={shared.title}>{selectingHome ? `${selected.size} selected` : 'MediaVault'}</Text><View style={shared.row}>
    {routes.length > 1 && <Action label="Back" onPress={back}/>}
    {selectingHome && <><Action label="Collections" compact onPress={() => navigate({page: 'collections'})}/>
      <Action label="Done selecting" compact onPress={() => { setSelecting(false); setSelected(new Set()); }}/></>}
    {unlocked && <Action label={profile?.name ?? 'Profiles'} onPress={lock}/>}</View></View>;
  const filtered = available.filter(value => (!watchlistOnly || personal.watchlist.includes(value.id)) && (!sections.length || sections.includes(value.kind)) && (!genres.length || genres.some(genre => value.genres.includes(genre)))
    && (!query.trim() || `${value.title} ${value.seriesTitle ?? ''}`.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase())));
  return <TVFocusGuideView style={shared.page} key={session}>
    {header}
    {busy && <Text style={shared.subtitle} aria-live="polite">{busy}</Text>}
    {error && <Text style={shared.error} aria-live="polite">{error}</Text>}
    {route.page === 'home' && unlocked && <>
      {selecting ? <View style={shared.row}>
        <Action label="Select shown" onPress={() => setSelected(new Set(filtered.map(value => value.id)))}/>
        <Action label="Mark watched" disabled={!selected.size} onPress={() => mark(available.filter(value => selected.has(value.id)), true)}/><Action label="Mark unwatched" disabled={!selected.size} onPress={() => mark(available.filter(value => selected.has(value.id)), false)}/>
        <Action label="Add to collection" disabled={!selected.size} onPress={() => navigate({page: 'add-to-collection'})}/>
      </View> : <View style={shared.row}>
        <Action label={sectionTitle} compact testID="library-section" hint="Choose movies, shows, music, photos, or your Watchlist." onPress={() => navigate({page: 'sections'})}/>
        <Action label="Search" compact selected={!!query.trim()} testID="library-search" hint={query.trim() ? 'A search is applied. Open to change or clear it.' : 'Search by movie or show title.'} onPress={() => navigate({page: 'search'})}/>
        <Action label="Filters" compact selected={genres.length > 0} hint={genres.length ? `${genres.length} genre filters applied.` : 'Choose any genres.'} onPress={() => navigate({page: 'filters'})}/>
        <Action label="Collections" compact onPress={() => navigate({page: 'collections'})}/>{canManage && <Action label="Sources" compact onPress={() => navigate({page: 'sources'})}/>}
        <Action label="Select titles" compact onPress={() => { setSelecting(true); setSelected(new Set()); }}/>
      </View>}
      {!library.sources.length && canManage && <View style={shared.panel}><Text style={shared.heading}>Your media, together</Text><Text style={shared.subtitle}>Add a NAS, WebDAV folder, or Jellyfin server to get started.</Text><Action label="Add source" onPress={() => navigate({page: 'add-source', id: newID()})}/></View>}
      <LibraryGrid groups={groupLibrary(filtered)} open={openGroup} loadImage={loadImage} session={session} selecting={selecting} selected={selected} viewing={personal.viewing}/>
    </>}
    {route.page === 'sections' && unlocked && <ScrollView><Text style={shared.heading}>Choose a section</Text>
      <Action label="All media" selected={!sections.length && !watchlistOnly} onPress={() => { setSections([]); setWatchlistOnly(false); back(); }}/>
      {(Object.keys(sectionLabels) as MediaKind[]).map(kind => <Action key={kind} label={sectionLabels[kind]} selected={!watchlistOnly && sections.length === 1 && sections[0] === kind} onPress={() => { setSections([kind]); setWatchlistOnly(false); back(); }}/ >)}
      <Action label="Watchlist" selected={watchlistOnly} onPress={() => { setWatchlistOnly(true); setSections([]); back(); }}/>
      <Text style={shared.subtitle}>Your search and genre filters stay applied.</Text>
    </ScrollView>}
    {route.page === 'search' && unlocked && <ScrollView><Text style={shared.heading}>Find something to watch</Text>
      <Field label="Search your library" value={query} onChange={setQuery} placeholder="Movie, show, or photo"/>
      <View style={shared.row}><Action label="Show results" onPress={back}/><Action label="Clear search" disabled={!query} onPress={() => setQuery('')}/></View>
    </ScrollView>}
    {route.page === 'filters' && unlocked && <ScrollView><Text style={shared.heading}>Choose any genres</Text><View style={shared.row}><Action label="All genres" selected={!genres.length} onPress={() => setGenres([])}/>
      {[...new Set(available.flatMap(value => value.genres))].sort().map(genre => <Action key={genre} label={`${genres.includes(genre) ? '✓ ' : ''}${genre}`} selected={genres.includes(genre)} onPress={() => setGenres(current => current.includes(genre) ? current.filter(value => value !== genre) : [...current, genre])}/>)}</View><Action label="Show results" onPress={back}/></ScrollView>}
    {route.page === 'sources' && canManage && <ScrollView><Text style={shared.heading}>Your sources</Text><Action label="Add source" onPress={() => navigate({page: 'add-source', id: newID()})}/>
      {library.sources.map(value => <View key={value.id} style={shared.panel}><Text style={shared.heading}>{value.name}</Text><Text style={shared.subtitle} testID={`source-scan-${value.name}`}>{value.kind.toUpperCase()} · Last scan: {value.lastScan ? new Date(value.lastScan).toLocaleString() : 'Never'}</Text>
        <View style={shared.row}><Action label={`Scan ${value.name}`} disabled={!!busy} onPress={() => void scan(value)}/><Action label="Edit source" onPress={() => navigate({page: 'source', id: value.id})}/></View></View>)}
      {busy && <Action label="Stop scan" onPress={() => scanAbort.current?.abort()}/>}</ScrollView>}
    {route.page === 'add-source' && canManage && <SourceEditor id={route.id!} services={platformServices} onCancel={back} onSave={async value => {
      await platformServices.updateSource(value);
      const latest = assertSession(session, true); update({...latest, sources: [...latest.sources, value]}); setRoutes([{page: 'home'}, {page: 'sources'}]); void scan(value);
    }}/>}
    {route.page === 'source' && source && <ScrollView><Text style={shared.heading}>{source.name}</Text><Text style={shared.subtitle}>{source.endpoint}</Text><Text style={shared.text}>Folder: {source.root || 'All accessible media'}</Text>
      <View style={shared.row}><Action label="Scan now" disabled={!!busy} onPress={() => void scan(source)}/>{source.kind !== 'jellyfin' && <Action label="Ignore files & folders" onPress={() => void browseIgnored(source, source.root)}/>}
        <Action label="Remove source" destructive onPress={() => { navigate({page: 'source', id: source.id, folder: 'confirm-remove'}); }}/></View>
      {route.folder === 'confirm-remove' && <View style={shared.panel}><Text style={shared.text}>Remove this connection? Media files on your server will be kept.</Text><Action label="Remove connection" destructive onPress={() => {
        const latest = assertSession(session, true); update({...latest, sources: latest.sources.filter(value => value.id !== source.id), items: latest.items.filter(value => value.sourceId !== source.id)}); void platformServices.forget(source.id).catch(report); setRoutes([{page: 'home'}, {page: 'sources'}]);
      }}/></View>}
      <Text style={shared.subtitle}>{source.ignoredFolders.length} ignored folders · {source.ignoredFiles.length} ignored files</Text>
      {[...source.ignoredFolders.map(path => ({path, folder: true})), ...source.ignoredFiles.map(path => ({path, folder: false}))].map(value => <Action key={value.path} label={`Include again: ${value.path}`} onPress={() => ignore(source, value.path, value.folder)}/>)}</ScrollView>}
    {route.page === 'ignored' && source && <ScrollView><Text style={shared.heading}>Choose what stays out</Text><Text style={shared.subtitle}>{route.folder || source.name}</Text>
      {folderEntries.map(entry => <View key={entry.path} style={shared.row}><Text style={[shared.text, {flex: 1}]}>{entry.directory ? 'Folder: ' : ''}{entry.name}</Text>
        {entry.directory && <Action label={`Open ${entry.name}`} onPress={() => void browseIgnored(source, entry.path)}/>}
        <Action label={(entry.directory ? source.ignoredFolders : source.ignoredFiles).includes(entry.path) ? 'Include' : 'Ignore'} onPress={() => ignore(source, entry.path, entry.directory)}/></View>)}</ScrollView>}
    {(route.page === 'collections' || route.page === 'add-to-collection') && unlocked && <ScrollView><Text style={shared.heading}>{route.page === 'add-to-collection' ? 'Add selected titles' : 'Your collections'}</Text>
      <View style={shared.row}><View style={{flex: 1}}><Field label="New collection name" value={name} onChange={setName} placeholder="Weekend movies"/></View><Action label="Create collection" onPress={() => { try { create(); } catch (reason) { report(reason); } }}/></View>
      {collectionList.map(value => <Action key={value.id} label={`${value.title} · ${value.count} ${value.count === 1 ? 'title' : 'titles'}`} onPress={() => {
        if (route.page === 'add-to-collection' && value.personalId) { const allowed = new Set(available.filter(media => media.kind !== 'photo').map(media => media.id));
          updatePersonal(current => ({...current, collections: current.collections.map(entry => entry.id === value.personalId ? {...entry, itemIds: [...new Set([...entry.itemIds, ...[...selected].filter(id => allowed.has(id))])]} : entry)})); back();
        } else { setName(value.title); navigate({page: 'collection', id: value.id}); }
      }}/>)}</ScrollView>}
    {route.page === 'collection' && collection && <><Text style={shared.heading}>{collection.title} · {collection.count} titles</Text>
      {collection.personalId && <View style={shared.row}><Action label="Manage titles" onPress={() => navigate({page: 'membership', id: collection.personalId})}/>
        <View style={{width: 420}}><Field label="Collection name" value={name} onChange={setName}/></View><Action label="Save name" onPress={() => {
          const proposed = name.trim(); if (!proposed || proposed.length > 80 || personal.collections.some(value => value.id !== collection.personalId && value.name.toLowerCase() === proposed.toLowerCase())) { setError('Choose a unique name between 1 and 80 characters.'); return; }
          updatePersonal(current => ({...current, collections: current.collections.map(value => value.id === collection.personalId ? {...value, name: proposed} : value)}));
        }}/><Action label="Delete collection" destructive onPress={() => { updatePersonal(current => ({...current, collections: current.collections.filter(value => value.id !== collection.personalId)})); back(); }}/></View>}
      <LibraryGrid groups={groupLibrary(collection.items)} open={openGroup} loadImage={loadImage} session={session} viewing={personal.viewing}/></>}
    {route.page === 'membership' && collection?.personalId && <ScrollView><Text style={shared.heading}>Titles in {collection.title}</Text>{groups.filter(value => value.items[0]!.kind !== 'photo').map(value => {
      const contained = value.items.every(media => collection.items.some(entry => entry.id === media.id));
      return <Action key={value.id} label={`${contained ? '✓' : '○'} ${value.title}`} selected={contained} onPress={() => updatePersonal(current => ({...current, collections: current.collections.map(entry => entry.id === collection.personalId ? {...entry,
        itemIds: contained ? entry.itemIds.filter(id => !value.items.some(media => media.id === id)) : [...new Set([...entry.itemIds, ...value.items.map(media => media.id)])]} : entry)}))}/>;
    })}<Action label="Done" onPress={back}/></ScrollView>}
    {route.page === 'group' && group?.items[0]!.kind === 'episode' && <ScrollView><Text style={shared.heading}>{group.title}</Text><Text style={shared.subtitle}>Choose a season</Text>
      <View style={[shared.row, {alignItems: 'flex-start'}]}>{[...new Set(group.items.map(value => value.season ?? 0))].sort((a, b) => a - b).map(season => {
        const episodes = group.items.filter(value => (value.season ?? 0) === season), representative = episodes[0]!;
        return <View key={season} style={{width: 240, margin: 12}}><Poster item={{...representative, posterPath: representative.seasonPosterPath ?? representative.posterPath}} load={loadImage} session={session}/>
          <Action label={season === 0 ? 'Specials' : `Season ${season}`} onPress={() => navigate({page: 'season', id: group.id, season})}/><Text style={shared.subtitle}>{episodes.length} episodes</Text></View>;
      })}</View></ScrollView>}
    {((route.page === 'group' && group?.items[0]!.kind !== 'episode') || route.page === 'season') && group && <ScrollView><Text style={shared.heading}>{group.title}{route.page === 'season' ? ` · ${route.season === 0 ? 'Specials' : 'Season ' + route.season}` : ''}</Text><Text style={shared.subtitle}>{route.page === 'season' ? 'Choose an episode' : 'Choose the version you want to watch. Each file keeps its own resume point.'}</Text>
      {[...group.items].filter(value => route.page !== 'season' || (value.season ?? 0) === route.season).sort((a, b) => (a.season ?? 0) - (b.season ?? 0) || (a.episode ?? 0) - (b.episode ?? 0)).map(value => <View key={value.id} style={shared.panel}>
        <Text style={shared.heading}>{value.kind === 'episode' ? `Season ${value.season ?? '?'} · Episode ${value.episode ?? '?'} · ${value.title}` : versionLabel(value)}</Text>
        <Text style={shared.subtitle}>{value.fileName}</Text><Action label={personal.viewing[value.id]?.watched ? 'Watched · Open' : personal.viewing[value.id]?.position ? 'In progress · Open' : 'Open'} testID={`item-open-${value.id}`} onPress={() => navigate({page: 'detail', id: value.id})}/></View>)}</ScrollView>}
    {route.page === 'detail' && item && <ScrollView><View style={[shared.row, {alignItems: 'flex-start'}]}><Poster item={item} load={loadImage} session={session} size="large"/><View style={{flex: 1, paddingLeft: 20}}>
      <Text style={shared.title} testID="detail-title">{item.title}</Text><Text style={shared.subtitle}>{[item.year, ...item.genres, item.certification].filter(Boolean).join(' · ')}</Text><Text style={shared.text}>{versionLabel(item)}</Text><Text style={shared.subtitle} testID="detail-file-name">{item.fileName}</Text>
      <Text style={shared.text}>{item.plot ?? 'No description yet. Add a matching NFO file beside this media to use your own details.'}</Text>
      <View style={shared.row}><Action label={personal.viewing[item.id]?.position && !personal.viewing[item.id]?.watched ? 'Resume' : 'Play'} preferred onPress={() => navigate({page: 'player', id: item.id})}/>
        <Action label={personal.viewing[item.id]?.watched ? 'Mark unwatched' : 'Mark watched'} onPress={() => mark([item], !personal.viewing[item.id]?.watched)}/>
        <Action label="Add to collection" onPress={() => { setSelected(new Set([item.id])); navigate({page: 'add-to-collection'}); }}/>
        <Action label={personal.watchlist.includes(item.id) ? 'Remove from Watchlist' : 'Add to Watchlist'} onPress={() => updatePersonal(current => ({...current, watchlist: current.watchlist.includes(item.id) ? current.watchlist.filter(id => id !== item.id) : [...current.watchlist, item.id]}))}/></View>
    </View></View></ScrollView>}
    {route.page === 'profiles' && <ScrollView><Text style={shared.heading}>Who’s watching?</Text><Text style={shared.subtitle}>Each person has their own collections, watched status, and resume points.</Text>
      {library.profiles.map(value => <Action key={value.id} label={`${value.name}${value.pinReference ? ' · PIN protected' : ''}`} onPress={() => { setPin(''); navigate({page: 'unlock', id: value.id}); }}/>)}</ScrollView>}
    {route.page === 'unlock' && <ScrollView><Text style={shared.heading}>{library.profiles.find(value => value.id === route.id)?.name}</Text>
      {library.profiles.find(value => value.id === route.id)?.pinReference && <Field label="Profile PIN" value={pin} onChange={setPin} secure/>}<Action label={busy ? 'Unlocking…' : 'Continue'} disabled={!!busy} preferred onPress={() => void unlock()}/></ScrollView>}
    {canManage && route.page === 'sources' && <Action label="Set up household profiles" onPress={() => navigate({page: 'add-profile'})}/>}
    {route.page === 'add-profile' && canManage && <ProfileEditor library={library} onSave={async (value, adultPIN, childPIN) => {
      const token = session; assertSession(token, true);
      if (!profile!.pinReference) {
        await platformServices.setProfilePIN(profile!.id, adultPIN);
        // Publish protection immediately, even if the app backgrounded during the native write.
        const secured = {...libraryRef.current!, profiles: libraryRef.current!.profiles.map(entry => entry.id === profile!.id ? {...entry, pinReference: entry.id} : entry)};
        libraryRef.current = secured; setLibrary(secured); await saveLibrary(secured); assertSession(token, true);
      }
      if (childPIN) { await platformServices.setProfilePIN(value.id, childPIN); assertSession(token, true); }
      const latest = assertSession(token, true), saved = {...latest, profiles: [...latest.profiles.map(entry => entry.id === profile!.id ? {...entry, pinReference: entry.id} : entry), value],
        profileLibraries: {...latest.profileLibraries, [value.id]: emptyProfileLibrary()}};
      libraryRef.current = saved; setLibrary(saved); await saveLibrary(saved); assertSession(token, true); back();
    }} needsAdminPIN={!profile?.pinReference}/>}
  </TVFocusGuideView>;
};

function ProfileEditor({library, needsAdminPIN, onSave}: {library: LibrarySnapshot; needsAdminPIN: boolean; onSave: (profile: HouseholdProfile, adultPIN: string, childPIN: string) => Promise<void>}) {
  const [name, setName] = useState(''), [adultPIN, setAdultPIN] = useState(''), [confirmPIN, setConfirmPIN] = useState(''), [childPIN, setChildPIN] = useState('');
  const [folders, setFolders] = useState<string[]>([]), [rating, setRating] = useState('PG'), [tvRating, setTVRating] = useState('TV-PG');
  const [error, setError] = useState<string>(), [busy, setBusy] = useState(false);
  const save = async (): Promise<void> => {
    if (!name.trim() || name.length > 80 || library.profiles.some(value => value.name.toLowerCase() === name.trim().toLowerCase())) { setError('Choose a unique profile name.'); return; }
    if (library.profiles.length >= 20) { setError('The household profile limit has been reached.'); return; }
    if (needsAdminPIN && (!/^\d{6,12}$/.test(adultPIN) || adultPIN !== confirmPIN)) { setError('Choose a 6–12 digit administrator PIN and enter it twice.'); return; }
    if (childPIN && !/^\d{6,12}$/.test(childPIN)) { setError('Use 6–12 digits for the profile PIN, or leave it empty.'); return; }
    setBusy(true); setError(undefined);
    try { const id = newID(); await onSave({id, name: name.trim(), admin: false, folders: library.sources.filter(value => folders.includes(value.id)).map(value => ({sourceId: value.id, path: value.root})),
      maximumMovieRating: rating, maximumTVRating: tvRating, ...(childPIN ? {pinReference: id} : {})}, adultPIN, childPIN); }
    catch (reason) { setError(reason instanceof Error ? reason.message : 'The profile could not be saved.'); setBusy(false); }
  };
  return <ScrollView contentContainerStyle={{paddingBottom: 80}}><Text style={shared.heading}>Add a household profile</Text><Text style={shared.subtitle}>Restricted and unrated titles stay hidden until an authorized profile is unlocked.</Text>
    {needsAdminPIN && <><Field label="Administrator PIN" value={adultPIN} onChange={setAdultPIN} secure/><Field label="Confirm administrator PIN" value={confirmPIN} onChange={setConfirmPIN} secure/></>}
    <Field label="Profile name" value={name} onChange={setName}/><Field label="Profile PIN (optional)" value={childPIN} onChange={setChildPIN} secure/>
    <Text style={shared.heading}>Allowed sources</Text><View style={shared.row}>{library.sources.map(value => <Action key={value.id} label={value.name} selected={folders.includes(value.id)} onPress={() => setFolders(current => current.includes(value.id) ? current.filter(id => id !== value.id) : [...current, value.id])}/>)}</View>
    <Text style={shared.heading}>Highest movie rating</Text><View style={shared.row}>{['G', 'PG', 'PG-13', 'R', 'NC-17'].map(value => <Action key={value} label={value} selected={rating === value} onPress={() => setRating(value)}/>)}</View>
    <Text style={shared.heading}>Highest TV rating</Text><View style={shared.row}>{['TV-Y', 'TV-Y7', 'TV-G', 'TV-PG', 'TV-14', 'TV-MA'].map(value => <Action key={value} label={value} selected={tvRating === value} onPress={() => setTVRating(value)}/>)}</View>
    {error && <Text style={shared.error}>{error}</Text>}<Action label={busy ? 'Saving…' : 'Save profile'} disabled={busy} onPress={() => void save()}/></ScrollView>;
}
