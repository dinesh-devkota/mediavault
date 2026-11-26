import {useMemo} from 'react';
import {collectionGroups, groupLibrary, visible} from '../domain/library';
import {HouseholdProfile, MediaItem, PersonalCollection, Source} from '../domain/model';

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
