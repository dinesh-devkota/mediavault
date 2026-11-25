import {XMLParser, XMLValidator} from 'fast-xml-parser';
import {LocalMetadata, MediaItem} from './model';
import {itemFromFile} from './library';
import {joinPath, parentPath, stem} from './paths';

export const MAXIMUM_NFO_BYTES = 1024 * 1024;
export function utf8Length(input: string): number {
  let bytes = 0;
  for (const character of input) {
    const code = character.codePointAt(0)!;
    if (code >= 0xd800 && code <= 0xdfff) { throw new Error('Invalid UTF-8 text.'); }
    bytes += code <= 0x7f ? 1 : code <= 0x7ff ? 2 : code <= 0xffff ? 3 : 4;
  }
  return bytes;
}
type XMLRecord = Record<string, unknown>;
const record = (value: unknown): XMLRecord | undefined => value !== null && typeof value === 'object' && !Array.isArray(value) ? value as XMLRecord : undefined;
const list = (value: unknown): unknown[] => Array.isArray(value) ? value : value === undefined ? [] : [value];
function text(value: unknown, maximum = 500): string | undefined {
  const raw = typeof value === 'string' || typeof value === 'number' ? String(value) : record(value)?.['#text'];
  return typeof raw === 'string' && raw.trim() ? raw.trim().slice(0, maximum) : undefined;
}
function integer(value: unknown, min: number, max: number): number | undefined {
  const raw = text(value);
  if (!raw || !/^\d+$/.test(raw)) { return undefined; }
  const number = Number(raw);
  return Number.isSafeInteger(number) && number >= min && number <= max ? number : undefined;
}

/** Shared with WebDAV: no DTD, custom entities, extreme depth, or unbounded expansion. */
export function parseXML(input: string, maximumBytes: number = MAXIMUM_NFO_BYTES): XMLRecord {
  if (!input || utf8Length(input) > maximumBytes || input.includes('\0')) { throw new Error('The XML file is empty, invalid, or too large.'); }
  if (/<!\s*(?:DOCTYPE|ENTITY)/i.test(input)) {
    throw new Error('XML declarations and custom entities are not supported.');
  }
  let depth = 0, elements = 0;
  // Ignore comments and CDATA for structural bounds; the XML validator verifies their syntax.
  const markup = input.replace(/<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>/g, '');
  if (/&(?!(?:amp|lt|gt|quot|apos);|#(?:x[0-9a-f]+|[0-9]+);)/i.test(markup)) { throw new Error('Custom XML entities are not supported.'); }
  // Quoted > characters must not hide opening tags from the depth bound.
  let cursor = 0;
  while ((cursor = markup.indexOf('<', cursor)) >= 0) {
    const start = ++cursor;
    let quote = '';
    for (; cursor < markup.length; cursor++) {
      const character = markup[cursor];
      if (quote) { if (character === quote) { quote = ''; } }
      else if (character === '"' || character === "'") { quote = character; }
      else if (character === '>') { break; }
    }
    if (cursor === markup.length) { throw new Error('Malformed XML tag.'); }
    const tag = markup.slice(start, cursor++).trim();
    if (tag.startsWith('?') || tag.startsWith('!')) { continue; }
    if (tag.startsWith('/')) { depth--; }
    else { elements++; if (!tag.endsWith('/')) { depth++; } }
    if (depth > 32 || elements > 10_000) { throw new Error('XML structure exceeds the supported limits.'); }
  }
  if (XMLValidator.validate(input, {allowBooleanAttributes: false}) !== true) { throw new Error('The server returned malformed XML.'); }
  const parsed: unknown = new XMLParser({ignoreAttributes: false, attributeNamePrefix: '@_', removeNSPrefix: false,
    parseTagValue: false, parseAttributeValue: false, trimValues: true, processEntities: true}).parse(input);
  const root = record(parsed);
  if (!root) { throw new Error('The XML document is invalid.'); }
  return root;
}
export function normalizedRating(value: unknown): string | undefined {
  const normalized = text(value)?.toUpperCase().replace(/^RATED\s+/, '').replace(/^US:\s*/, '');
  return ['G', 'PG', 'PG-13', 'R', 'NC-17', 'TV-Y', 'TV-Y7', 'TV-Y7-FV', 'TV-G', 'TV-PG', 'TV-14', 'TV-MA'].includes(normalized ?? '') ? normalized : undefined;
}
export function parseNFO(input: string): LocalMetadata {
  const parsed = parseXML(input);
  const keys = Object.keys(parsed).filter(key => !key.startsWith('?'));
  const kind = keys[0] as LocalMetadata['kind'];
  if (keys.length !== 1 || !['movie', 'tvshow', 'season', 'episodedetails'].includes(kind)) { throw new Error('This sidecar is not supported movie or TV metadata.'); }
  const value = record(parsed[kind]) ?? {};
  let tmdbId = integer(value.tmdbid, 1, Number.MAX_SAFE_INTEGER);
  for (const unique of list(value.uniqueid)) {
    if (text(record(unique)?.['@_type'])?.toLowerCase() === 'tmdb') { tmdbId = integer(unique, 1, Number.MAX_SAFE_INTEGER); }
  }
  const ratingPresent = Object.prototype.hasOwnProperty.call(value, 'mpaa') || Object.prototype.hasOwnProperty.call(value, 'certification');
  const genres = [...new Set(list(value.genre).flatMap(genre => (text(genre, 3000) ?? '').split(/[/|]/)).map(genre => genre.trim().slice(0, 100)).filter(Boolean))].slice(0, 30);
  const set = record(value.set);
  const result: LocalMetadata = {
    kind, title: text(value.title), seriesTitle: text(value.showtitle), plot: text(value.plot, 20_000) ?? text(value.outline, 20_000),
    year: integer(value.year, 1800, 2200) ?? integer(text(value.premiered ?? value.aired)?.slice(0, 4), 1800, 2200),
    genres: genres.length ? genres : undefined, runtimeMinutes: integer(value.runtime, 1, 10_000), tmdbId,
    season: integer(value.season, 0, 999), episode: integer(value.episode, 0, 999),
    collection: text(set?.name ?? value.set, 200), edition: text(value.edition, 100),
    certificationPresent: ratingPresent || undefined,
    certification: ratingPresent ? normalizedRating(value.certification ?? value.mpaa) : undefined,
  };
  // Undefined keys must not erase online fields during partial imports.
  return Object.fromEntries(Object.entries(result).filter(([, entry]) => entry !== undefined)) as unknown as LocalMetadata;
}

export function applyLocalMetadata(item: MediaItem, specific?: LocalMetadata, show?: LocalMetadata, invalidSpecific = false): MediaItem {
  if (item.manuallyMatched) { return item; }
  if (invalidSpecific) {
    return {...item, certification: undefined, local: {...(item.local ?? {kind: 'movie'}), certificationPresent: true, certification: undefined}};
  }
  const base = itemFromFile(item.sourceId, item.path, item.size)!;
  const result = {...item};
  const old = item.local;
  if (old) {
    for (const key of ['title', 'plot', 'year', 'genres', 'runtimeMinutes', 'edition', 'collection', 'tmdbId', 'season', 'episode', 'seriesTitle', 'seriesYear'] as const) {
      if (old[key] !== undefined) { (result as unknown as Record<string, unknown>)[key] = base[key]; }
    }
    if (old.certificationPresent) { result.certification = undefined; }
    if (old.collection) { result.collectionId = undefined; }
  }
  const info: LocalMetadata | undefined = specific || show ? {...show, ...specific, kind: specific?.kind ?? show!.kind} : undefined;
  // An explicitly unknown episode rating must override even a valid, permissive show rating.
  if (info && specific?.certificationPresent) { info.certification = specific.certification; }
  if (old?.seriesTitle && !show?.tmdbId) { result.seriesId = undefined; }
  if (show?.kind === 'tvshow') {
    info!.title = specific?.title;
    info!.seriesTitle = specific?.seriesTitle ?? show.title;
    info!.seriesYear = show.year;
    // A show's provider ID identifies the series, never the episode or film.
    if (show.tmdbId) { result.seriesId = 'tmdb:' + show.tmdbId; }
    if (!specific?.tmdbId) { delete info!.tmdbId; }
  }
  if (info) {
    for (const key of ['title', 'plot', 'year', 'genres', 'runtimeMinutes', 'edition', 'collection', 'tmdbId', 'season', 'episode', 'seriesTitle', 'seriesYear'] as const) {
      if (info[key] !== undefined) { (result as unknown as Record<string, unknown>)[key] = info[key]; }
    }
    if (info.certificationPresent) { result.certification = info.certification; }
    if (info.collection) { result.collectionId = undefined; }
    if (info.kind === 'episodedetails' || result.season !== undefined && result.episode !== undefined) { result.kind = 'episode'; }
    else if (result.kind !== 'music' && result.kind !== 'photo') { result.kind = result.genres.some(genre => /documentary/i.test(genre)) ? 'documentary' : 'movie'; }
  } else if (['movie', 'documentary', 'episode'].includes(result.kind)) { result.kind = base.kind; }
  result.local = info;
  return result;
}
export function metadataCandidates(path: string, singleVideo: boolean): string[] {
  return [stem(path) + '.nfo', stem(path) + '.xml', ...(singleVideo ? [joinPath(parentPath(path), 'movie.nfo'), joinPath(parentPath(path), 'movie.xml')] : [])];
}
export function artworkCandidates(path: string, backdrop: boolean, singleVideo: boolean): string[] {
  const names = backdrop ? [stem(path) + '-fanart'] : [stem(path) + '-poster', stem(path)];
  if (singleVideo) { names.push(...(backdrop ? ['fanart', 'backdrop'] : ['poster', 'folder']).map(name => joinPath(parentPath(path), name))); }
  return names.flatMap(name => ['jpg', 'png', 'jpeg', 'webp'].map(ext => name + '.' + ext));
}
