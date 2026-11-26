import {HouseholdProfile, MediaItem, PersonalCollection, ProfileLibrary, Source, ViewingState} from './model';
import {baseName, contains, stem} from './paths';

const video = new Set(['mp4', 'm4v', 'mov', 'mkv', 'avi', 'webm', 'mpeg', 'mpg', 'm2ts', 'mts', 'flv', 'ogv', '3gp']);
const audio = new Set(['mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wav', 'aif', 'aiff']);
const photos = new Set(['jpg', 'jpeg', 'png', 'gif', 'webp']);
const genericFolders = new Set(['movies', 'films', 'videos', 'media', 'library', 'tv', 'tvshows', 'shows', 'downloads', 'shared']);
export const normalizedTitle = (value: string): string => value.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
export const extension = (path: string): string => path.split('.').pop()?.toLowerCase() ?? '';
export function kindForPath(path: string): MediaItem['kind'] | undefined {
  const ext = extension(path);
  // .ts is deliberately absent until a transport confirms MPEG-TS bytes. TypeScript is never media.
  if (photos.has(ext)) { return 'photo'; }
  if (audio.has(ext)) { return 'music'; }
  if (video.has(ext)) { return /(?:^|[ ._-])s\d{1,3}e\d{1,3}(?:\D|$)|\b\d{1,3}x\d{2,3}\b/i.test(path) ? 'episode' : 'movie'; }
  return undefined;
}
export function itemFromFile(sourceId: string, path: string, size: number): MediaItem | undefined {
  const kind = kindForPath(path);
  if (!kind) { return undefined; }
  const fileName = baseName(path);
  const raw = stem(fileName).replace(/[._]+/g, ' ');
  const episode = raw.match(/\bS(\d{1,3})\s*E(\d{1,3})(?:\D|$)|\b(\d{1,3})x(\d{2,3})(?:\D|$)/i);
  const yearMatch = raw.match(/(?:^|\D)((?:18|19|20|21)\d{2})(?:\D|$)/);
  const year = yearMatch ? Number(yearMatch[1]) : undefined;
  let title = raw.slice(0, episode?.index ?? raw.length).replace(/\s*[([]?(?:18|19|20|21)\d{2}[)\]]?.*$/, '')
    .replace(/\b(?:2160p|1080p|720p|480p|4k|bluray|b[dr]rip|webrip|web[- ]?dl|hdtv|x26[45]|h26[45]|hevc)\b.*$/i, '')
    .replace(/\s*[-([ ]*(?:director'?s? cut|extended(?: edition)?|theatrical|unrated|remastered)\b.*$/i, '').trim();
  if (!title || ['movie', 'film', 'video'].includes(title.toLowerCase())) {
    const parent = path.split('/').slice(-2, -1)[0];
    if (parent && !genericFolders.has(normalizedTitle(parent).replace(/ /g, ''))) { title = parent.replace(/[._]+/g, ' ').replace(/\s*\(\d{4}\)$/, '').trim(); }
  }
  title ||= raw || fileName;
  return {
    id: sourceId + ':' + path, sourceId, path, fileName, size, title, kind, year, genres: [],
    ...(episode ? {seriesTitle: title, season: Number(episode[1] ?? episode[3]), episode: Number(episode[2] ?? episode[4])} : {}),
  };
}
export function ignored(source: Source, path: string): boolean {
  return source.ignoredFiles.includes(path) || source.ignoredFolders.some(folder => contains(path, folder, true));
}
export function visible(item: MediaItem, source: Source | undefined, profile: HouseholdProfile | undefined, unlocked: boolean): boolean {
  if (!unlocked || !profile || !source || item.missing || item.hidden || !contains(item.path, source.root) || ignored(source, item.path)) { return false; }
  if (profile.admin) { return true; }
  if (!profile.folders.some(folder => folder.sourceId === item.sourceId && contains(item.path, folder.path))) { return false; }
  const maximum = item.kind === 'episode' ? profile.maximumTVRating : profile.maximumMovieRating;
  if (item.kind === 'music' || item.kind === 'photo' || !maximum) { return true; }
  const levels = item.kind === 'episode' ? ['TV-Y', 'TV-Y7', 'TV-Y7-FV', 'TV-G', 'TV-PG', 'TV-14', 'TV-MA'] : ['G', 'PG', 'PG-13', 'R', 'NC-17'];
  const actual = levels.indexOf(item.certification ?? '');
  const limit = levels.indexOf(maximum);
  return actual >= 0 && limit >= 0 && actual <= limit;
}
export function versionKey(item: MediaItem): string {
  if (!['movie', 'documentary'].includes(item.kind)) { return item.id; }
  if (item.tmdbId && item.tmdbId > 0) { return 'tmdb:' + item.tmdbId; }
  return item.year && normalizedTitle(item.title) ? `title:${normalizedTitle(item.title)}|${item.year}` : item.id;
}
export function showKey(item: MediaItem): string {
  return item.seriesId ? 'show:' + item.sourceId + ':' + item.seriesId : `show:${normalizedTitle(item.seriesTitle ?? item.title)}|${item.seriesYear ?? ''}`;
}
export interface MediaGroup { id: string; title: string; items: MediaItem[] }
export function groupLibrary(items: MediaItem[]): MediaGroup[] {
  const result = new Map<string, MediaGroup>();
  for (const item of items) {
    const id = item.kind === 'episode' ? showKey(item) : versionKey(item);
    const existing = result.get(id);
    if (existing) { existing.items.push(item); }
    else { result.set(id, {id, title: item.kind === 'episode' ? item.seriesTitle ?? item.title : item.title, items: [item]}); }
  }
  return [...result.values()].sort((a, b) => a.title.localeCompare(b.title));
}
export function versionLabel(item: MediaItem): string {
  const parts = [item.edition];
  if (!item.edition) {
    for (const [pattern, label] of [[/\bdirector/i, 'Director’s cut'], [/\bextended\b/i, 'Extended'], [/\btheatrical\b/i, 'Theatrical'], [/\bunrated\b/i, 'Unrated'], [/\bremaster/i, 'Remastered']] as const) {
      if (pattern.test(item.fileName.replace(/[._-]/g, ' '))) { parts.push(label); break; }
    }
  }
  const resolution = item.fileName.match(/(?:^|[^a-z0-9])(2160p|4k|1080p|720p|480p)(?=$|[^a-z0-9])/i)?.[1];
  if (resolution) { parts.push(/2160p|4k/i.test(resolution) ? '4K' : resolution.toLowerCase()); }
  parts.push(extension(item.path).toUpperCase());
  if (item.size > 0) { parts.push(item.size >= 1024 ** 3 ? `${(item.size / 1024 ** 3).toFixed(1)} GB` : `${(item.size / 1024 ** 2).toFixed(1)} MB`); }
  return parts.filter(Boolean).join(' · ') || 'Original file';
}
export interface CollectionGroup extends MediaGroup { personalId?: string; count: number }
export function collectionGroups(visibleItems: MediaItem[], personal: PersonalCollection[]): CollectionGroup[] {
  const eligible = visibleItems.filter(item => item.kind !== 'photo');
  const groups: CollectionGroup[] = personal.map(collection => {
    const membership = new Set(collection.itemIds);
    const items = eligible.filter(item => membership.has(item.id));
    return {id: 'personal:' + collection.id, personalId: collection.id, title: collection.name, items, count: groupLibrary(items).length};
  });
  const series = new Map<string, MediaItem[]>();
  for (const item of eligible.filter(value => ['movie', 'documentary'].includes(value.kind) && value.collection)) {
    const key = item.collectionId ? 'franchise:' + item.collectionId : 'local:' + normalizedTitle(item.collection!);
    series.set(key, [...(series.get(key) ?? []), item]);
  }
  for (const [id, items] of series) {
    const count = groupLibrary(items).length;
    if (count >= 2) { groups.push({id, personalId: undefined, title: items[0]!.collection!, items, count}); }
  }
  return groups.sort((a, b) => a.title.localeCompare(b.title));
}
export function createCollection(library: ProfileLibrary, id: string, rawName: string, available: MediaItem[], selected: string[]): ProfileLibrary {
  const name = rawName.trim();
  if (!name || name.length > 80 || library.collections.some(item => item.name.toLowerCase() === name.toLowerCase())) { throw new Error('Choose a unique collection name between 1 and 80 characters.'); }
  if (library.collections.length >= 500) { throw new Error('Remove an unused collection before adding another.'); }
  const ids = new Set(available.filter(item => item.kind !== 'photo').map(item => item.id));
  return {...library, collections: [...library.collections, {id, name, itemIds: [...new Set(selected)].filter(item => ids.has(item))}]};
}
export function nextEpisode(current: MediaItem, visibleItems: MediaItem[]): MediaItem | undefined {
  if (current.kind !== 'episode' || current.season === undefined || current.episode === undefined) { return undefined; }
  return visibleItems.filter(item => item.kind === 'episode' && showKey(item) === showKey(current) && item.season !== undefined && item.episode !== undefined
    && (item.season > current.season! || (item.season === current.season && item.episode > current.episode!)))
    .sort((a, b) => a.season! - b.season! || a.episode! - b.episode!)[0];
}
export function progressState(position: number, duration: number, previous?: ViewingState, ended = false): ViewingState {
  const safeDuration = Number.isFinite(duration) && duration > 0 ? duration : previous?.duration ?? 0;
  const safePosition = Number.isFinite(position) ? Math.max(0, Math.min(position, safeDuration || position)) : previous?.position ?? 0;
  return {position: safePosition, duration: safeDuration, watched: ended || previous?.watched === true || (safeDuration > 0 && safePosition / safeDuration >= .95), updatedAt: Date.now()};
}
