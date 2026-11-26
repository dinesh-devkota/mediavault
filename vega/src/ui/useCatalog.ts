import {useMemo} from 'react';
import {collectionGroups, groupLibrary, MediaGroup, visible} from '../domain/library';
import {HouseholdProfile, MediaItem, MediaKind, PersonalCollection, Source} from '../domain/model';

const emptyCollections: PersonalCollection[] = [];

// Viewing updates retain these catalog/permission references. Keep authorization
// inside the derivation so every immutable source, profile or scan change is
// applied before any title, artwork choice or collection count is exposed.
export function useCatalog(items: MediaItem[] | undefined, sources: Source[] | undefined,
  profile: HouseholdProfile | undefined, unlocked: boolean, personalCollections: PersonalCollection[] | undefined) {
  const available = useMemo(() => {
    if (!unlocked || !profile || !items || !sources) { return []; }
    return items.filter(item => visible(item, sources.find(source => source.id === item.sourceId), profile, unlocked));
  }, [items, sources, profile, unlocked]);
  const groups = useMemo(() => groupLibrary(available), [available]);
  const collections = useMemo(() => unlocked && profile
    ? collectionGroups(available, personalCollections ?? emptyCollections) : [], [available, personalCollections, profile, unlocked]);
  return {available, groups, collections};
}

interface CatalogFilters {
  query: string;
  sections: MediaKind[];
  genres: string[];
  watchlist?: string[];
}

export function useFilteredCatalog(available: MediaItem[], groups: MediaGroup[], filters: CatalogFilters) {
  const {query, sections, genres, watchlist} = filters;
  const term = query.trim().toLocaleLowerCase();
  const filtered = useMemo(() => {
    if (!term && !sections.length && !genres.length && !watchlist) { return available; }
    const included = watchlist && new Set(watchlist);
    return available.filter(item => (!included || included.has(item.id)) && (!sections.length || sections.includes(item.kind))
      && (!genres.length || genres.some(genre => item.genres.includes(genre)))
      && (!term || `${item.title} ${item.seriesTitle ?? ''}`.toLocaleLowerCase().includes(term)));
  }, [available, term, sections, genres, watchlist]);
  const homeGroups = useMemo(() => filtered === available ? groups : groupLibrary(filtered), [available, filtered, groups]);
  return {filtered, homeGroups};
}
