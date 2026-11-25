import {DirectoryEntry, MediaItem, Source} from '../domain/model';
import {normalizedRating, parseXML, utf8Length} from '../domain/metadata';
import {baseName, parentPath, SourceAddress} from '../domain/paths';

export interface HTTPRequest {
  path: string;
  query?: Record<string, string>;
  method: 'GET' | 'POST' | 'PROPFIND' | 'HEAD';
  body?: string;
  headers?: Record<string, string>;
  maximumBytes: number;
}
export interface HTTPResponse { status: number; body: string; headers: Record<string, string> }
/** The native implementation owns auth, TLS, no-redirect policy, deadlines and streaming limits. */
export type NativeHTTP = (sourceId: string, request: HTTPRequest) => Promise<HTTPResponse>;

type RecordValue = Record<string, unknown>;
function object(value: unknown): RecordValue { return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as RecordValue : {}; }
const array = (value: unknown): unknown[] => Array.isArray(value) ? value : value === undefined ? [] : [value];
const string = (value: unknown): string | undefined => typeof value === 'string' ? value : undefined;
function davTree(name: string, value: unknown, inherited: Record<string, string>): [string, unknown] | undefined {
  const raw = object(value);
  const namespaces = {...inherited};
  for (const [key, entry] of Object.entries(raw)) {
    if (key === '@_xmlns' && typeof entry === 'string') { namespaces[''] = entry; }
    else if (key.startsWith('@_xmlns:') && typeof entry === 'string') { namespaces[key.slice(8)] = entry; }
  }
  const parts = name.split(':');
  const prefix = parts.length === 2 ? parts[0]! : '';
  const local = parts[parts.length - 1]!;
  if (parts.length > 2 || namespaces[prefix] !== 'DAV:') { return undefined; }
  if (typeof value === 'string') { return [local, value]; }
  const result: RecordValue = {};
  if (typeof raw['#text'] === 'string') { result['#text'] = raw['#text']; }
  for (const [key, children] of Object.entries(raw)) {
    if (key.startsWith('@_') || key.startsWith('#')) { continue; }
    for (const child of array(children)) {
      const mapped = davTree(key, child, namespaces);
      if (!mapped) { continue; }
      const [childName, content] = mapped;
      result[childName] = result[childName] === undefined ? content : [...array(result[childName]), content];
    }
  }
  return [local, result];
}
export function parseWebDAVListing(xml: string, address: SourceAddress, directory: string): DirectoryEntry[] {
  const parsed = parseXML(xml, 8 * 1024 * 1024);
  const roots = Object.entries(parsed).filter(([key]) => !key.startsWith('?'));
  if (roots.length !== 1) { throw new Error('The server did not return a valid WebDAV listing.'); }
  const tree = davTree(roots[0]![0], roots[0]![1], {});
  if (tree?.[0] !== 'multistatus') { throw new Error('The server did not return a WebDAV multistatus response.'); }
  const entries = new Map<string, DirectoryEntry>();
  let confirmed = false;
  const success = (status: unknown): boolean => typeof status === 'string' && /^HTTP\/\S+ 200(?: .*)?$/.test(status);
  for (const value of array(object(tree[1]).response)) {
    const response = object(value);
    const href = string(response.href);
    if (!href) { continue; }
    const path = address.relative(href, address.url(directory, true));
    if (path === undefined) { continue; }
    const props = array(response.propstat).map(object).filter(stat => success(stat.status)).map(stat => object(stat.prop));
    const isDirectory = props.some(prop => Object.prototype.hasOwnProperty.call(object(prop.resourcetype), 'collection'));
    const succeeded = props.length > 0 && (response.status === undefined || success(response.status));
    if (path === directory) {
      if (!succeeded || !isDirectory || confirmed) { throw new Error('The WebDAV server did not confirm this folder.'); }
      confirmed = true;
    } else if (parentPath(path) === directory) {
      if (!succeeded) { throw new Error('The server could not read every entry in this folder. Your previous scan has been kept.'); }
      const sizes = props.map(prop => Number(prop.getcontentlength ?? 0));
      if (sizes.some(size => !Number.isSafeInteger(size) || size < 0)) { throw new Error('The server returned an invalid file size.'); }
      const entry = {path, name: baseName(path), directory: isDirectory, size: Math.max(0, ...sizes)};
      const previous = entries.get(path);
      if (previous && (previous.directory !== entry.directory || previous.size !== entry.size)) { throw new Error('The folder changed during scanning. Please try again.'); }
      entries.set(path, entry);
    }
  }
  if (!confirmed) { throw new Error('The WebDAV server did not confirm this folder.'); }
  return [...entries.values()].sort((a, b) => Number(b.directory) - Number(a.directory) || a.name.localeCompare(b.name));
}
export async function listWebDAV(source: Source, directory: string, transport: NativeHTTP): Promise<DirectoryEntry[]> {
  const address = new SourceAddress(source.endpoint);
  const response = await transport(source.id, {path: directory, method: 'PROPFIND', maximumBytes: 8 * 1024 * 1024,
    headers: {Depth: '1', 'Content-Type': 'application/xml; charset=utf-8'},
    body: '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>'});
  if (response.status !== 207) { throw new Error(httpMessage(response.status)); }
  return parseWebDAVListing(response.body, address, directory);
}
export function httpMessage(status: number): string {
  if (status === 401) { return 'Your sign-in was rejected or has expired. Reconnect this source.'; }
  if (status === 403) { return 'This account cannot read the selected folder or media.'; }
  if (status >= 300 && status < 400) { return 'Enter the final server address. Redirects are blocked to protect your sign-in.'; }
  return `The server request failed (HTTP ${status}).`;
}

export interface JellyfinPage { items: MediaItem[]; total: number; start: number }
export function parseJellyfinPage(body: string, source: Source, expectedStart: number): JellyfinPage {
  if (utf8Length(body) > 8 * 1024 * 1024) { throw new Error('The server response is too large.'); }
  const page = object(JSON.parse(body));
  const total = Number(page.TotalRecordCount), start = Number(page.StartIndex ?? expectedStart);
  if (!Array.isArray(page.Items) || !Number.isSafeInteger(total) || total < 0 || total > 250_000 || start !== expectedStart || page.Items.length > 200) {
    throw new Error('Jellyfin returned an invalid or changed library.');
  }
  const items: MediaItem[] = [];
  for (const raw of page.Items) {
    const value = object(raw), id = string(value.Id), title = string(value.Name), type = string(value.Type);
    if (!id || !/^[a-z0-9_-]{1,128}$/i.test(id) || !title || !type) { throw new Error('Jellyfin returned an invalid library item.'); }
    const kind = type === 'Movie' ? 'movie' : type === 'Episode' ? 'episode' : type === 'Audio' || type === 'MusicVideo' ? 'music' : type === 'Photo' ? 'photo' : undefined;
    if (!kind) { continue; }
    const safeNumber = (number: unknown, min: number, max: number): number | undefined => typeof number === 'number' && Number.isSafeInteger(number) && number >= min && number <= max ? number : undefined;
    const genres = Array.isArray(value.Genres) ? value.Genres.filter((genre): genre is string => typeof genre === 'string').slice(0, 30).map(genre => genre.slice(0, 100)) : [];
    const providers = object(value.ProviderIds), images = object(value.ImageTags);
    const tmdb = Number(providers.Tmdb ?? providers.tmdb);
    items.push({id: source.id + ':jellyfin:' + id, sourceId: source.id, path: source.root ? source.root + '/' + id : id,
      fileName: title.slice(0, 500), title: title.slice(0, 500), size: 0, kind: kind === 'movie' && genres.some(genre => /documentary/i.test(genre)) ? 'documentary' : kind,
      genres, year: safeNumber(value.ProductionYear, 1800, 2200), plot: string(value.Overview)?.slice(0, 20_000),
      certification: normalizedRating(value.OfficialRating), tmdbId: Number.isSafeInteger(tmdb) && tmdb > 0 ? tmdb : undefined,
      jellyfinId: id, seriesId: string(value.SeriesId), seriesTitle: string(value.SeriesName)?.slice(0, 500),
      season: safeNumber(value.ParentIndexNumber, 0, 999), episode: safeNumber(value.IndexNumber, 0, 999), imageTag: string(images.Primary),
    });
  }
  return {items, total, start};
}
export async function scanJellyfin(source: Source, transport: NativeHTTP, assertCurrent: () => void, progress: (count: number) => void): Promise<MediaItem[]> {
  if (!source.userId || !/^[a-z0-9_-]{1,128}$/i.test(source.userId)) { throw new Error('Reconnect to your Jellyfin account.'); }
  const result: MediaItem[] = [], ids = new Set<string>();
  let expectedTotal: number | undefined;
  for (let start = 0; ; start += 200) {
    assertCurrent();
    const response = await transport(source.id, {path: `Users/${source.userId}/Items`, method: 'GET', maximumBytes: 8 * 1024 * 1024,
      query: {Recursive: 'true', IncludeItemTypes: 'Movie,Episode,Audio,MusicVideo,Photo', Fields: 'Overview,Genres,ProviderIds,PrimaryImageAspectRatio',
        StartIndex: String(start), Limit: '200', SortBy: 'SortName', SortOrder: 'Ascending', ...(source.root ? {ParentId: source.root} : {})}});
    assertCurrent();
    if (response.status !== 200) { throw new Error(httpMessage(response.status)); }
    const page = parseJellyfinPage(response.body, source, start);
    if (expectedTotal !== undefined && expectedTotal !== page.total) { throw new Error('The library changed during scanning. Try again.'); }
    expectedTotal = page.total;
    for (const item of page.items) {
      if (ids.has(item.id)) { throw new Error('The library changed during scanning. Try again.'); }
      ids.add(item.id); result.push(item);
    }
    progress(result.length);
    if (start + 200 >= page.total) { return result; }
    if (!page.items.length) { throw new Error('Jellyfin returned an incomplete library.'); }
  }
}
