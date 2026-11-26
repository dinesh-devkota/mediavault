import {CancellationSignal, DirectoryEntry, LocalMetadata, MediaItem, Source, SourceClient} from '../domain/model';
import {ignored, itemFromFile} from '../domain/library';
import {applyLocalMetadata, artworkCandidates, InvalidTextFileError, MAXIMUM_NFO_BYTES, metadataCandidates, parseNFO} from '../domain/metadata';
import {contains, joinPath, parentPath} from '../domain/paths';

export interface ScanProgress { folders: number; files: number; directory: string }
interface NFORead { info?: LocalMetadata; invalid?: boolean; unavailable?: boolean }
const artExtensions = ['jpg', 'png', 'jpeg', 'webp'];
const artVariants = (path: string): string[] => artExtensions.map(ext => path + '.' + ext);

/** Scans are atomic: failed directory enumeration never marks unseen files missing. */
export async function scanSource(source: Source, client: SourceClient, previous: MediaItem[], assertCurrent: () => void,
  progress: (value: ScanProgress) => void, signal?: CancellationSignal): Promise<MediaItem[]> {
  const directories = new Map<string, DirectoryEntry[]>();
  const queue = [source.root];
  const files: DirectoryEntry[] = [];
  const check = (): void => { if (signal?.aborted) { throw new Error('Scan cancelled.'); } assertCurrent(); };
  while (queue.length) {
    check();
    const directory = queue.shift()!;
    if (directories.has(directory)) { continue; }
    if (!contains(directory, source.root, true) || directory.split('/').length > 64) { throw new Error('The source has an invalid or excessively deep folder.'); }
    const entries = await client.list(directory, signal); check();
    if (entries.length > 25_000 || directories.size >= 25_000) { throw new Error('Choose a smaller media folder to scan.'); }
    const children = entries.filter(entry => parentPath(entry.path) === directory && contains(entry.path, source.root) && !ignored(source, entry.path));
    directories.set(directory, children);
    for (const entry of children) {
      if (entry.directory) {
        if (!['node_modules', '.git', '.svn', '.hg'].includes(entry.name.toLowerCase())) { queue.push(entry.path); }
      } else { files.push(entry); }
    }
    if (files.length > 250_000) { throw new Error('Choose a smaller media folder to scan.'); }
    progress({folders: directories.size, files: files.length, directory});
  }
  const old = new Map(previous.filter(item => item.sourceId === source.id).map(item => [item.path, item]));
  const items: MediaItem[] = files.flatMap(entry => {
    const parsed = itemFromFile(source.id, entry.path, entry.size);
    if (!parsed) { return []; }
    const existing = old.get(entry.path);
    return [{...parsed, ...existing, size: entry.size, missing: false}];
  });
  const sidecars = new Map<string, Promise<NFORead>>();
  const videoCounts = new Map<string, number>();
  for (const item of items) {
    if (['movie', 'documentary', 'episode'].includes(item.kind)) {
      const directory = parentPath(item.path);
      videoCounts.set(directory, (videoCounts.get(directory) ?? 0) + 1);
    }
  }
  const read = (path: string): Promise<NFORead> => {
    let pending = sidecars.get(path);
    if (!pending) {
      pending = (async () => {
        let data: string;
        try { data = await client.readText(path, MAXIMUM_NFO_BYTES, signal); check(); }
        catch (reason) { check(); return reason instanceof InvalidTextFileError ? {invalid: true} : {unavailable: true}; }
        try { return {info: parseNFO(data)}; } catch { return {invalid: true}; }
      })();
      sidecars.set(path, pending);
    }
    return pending;
  };
  const present = (directory: string, candidates: string[]): string[] => {
    const names = new Set((directories.get(directory) ?? []).filter(entry => !entry.directory).map(entry => entry.path));
    return candidates.filter(path => names.has(path));
  };
  const recognizedArt = new Set<string>();
  for (let index = 0; index < items.length; index++) {
    check();
    let item = items[index]!;
    if (!['movie', 'documentary', 'episode'].includes(item.kind)) { continue; }
    const directory = parentPath(item.path);
    const singleVideo = videoCounts.get(directory) === 1;
    const nfoPaths = present(directory, metadataCandidates(item.path, singleVideo));
    const specific = nfoPaths[0] ? await read(nfoPaths[0]) : {};
    let show: NFORead = {};
    let showDirectory: string | undefined;
    if (item.kind === 'episode' || specific.info?.kind === 'episodedetails') {
      for (const candidate of [directory, parentPath(directory)]) {
        if (!contains(candidate, source.root, true)) { continue; }
        const path = present(candidate, [joinPath(candidate, 'tvshow.nfo'), joinPath(candidate, 'tvshow.xml')])[0];
        if (path) { show = await read(path); showDirectory = candidate; break; }
      }
    }
    // Confirmed corruption makes the rating unknown even when another sidecar
    // is temporarily unavailable. A transport failure alone retains the last import.
    if (specific.invalid || show.invalid || (!specific.unavailable && !show.unavailable)) {
      item = applyLocalMetadata(item, specific.info, show.info, specific.invalid || show.invalid);
    }
    const posters = present(directory, artworkCandidates(item.path, false, singleVideo));
    const backdrops = present(directory, artworkCandidates(item.path, true, singleVideo));
    for (const path of [...posters, ...backdrops]) { recognizedArt.add(path); }
    item.posterPath = posters[0]; item.backdropPath = backdrops[0]; item.seasonPosterPath = undefined;
    if (showDirectory) {
      const showPosters = present(showDirectory, ['poster', 'folder'].flatMap(name => artVariants(joinPath(showDirectory!, name))));
      const showBackdrops = present(showDirectory, ['fanart', 'backdrop'].flatMap(name => artVariants(joinPath(showDirectory!, name))));
      const seasonNames = item.season === undefined ? [] : [`season${String(item.season).padStart(2, '0')}-poster`, `season${item.season}-poster`];
      const seasonPosters = [...present(directory, artVariants(joinPath(directory, 'poster'))),
        ...present(showDirectory, seasonNames.flatMap(name => artVariants(joinPath(showDirectory!, name))))];
      for (const path of [...showPosters, ...showBackdrops, ...seasonPosters]) { recognizedArt.add(path); }
      item.posterPath ??= showPosters[0]; item.backdropPath ??= showBackdrops[0]; item.seasonPosterPath = seasonPosters[0];
    }
    items[index] = item;
  }
  check();
  const currentPaths = new Set(items.map(item => item.path));
  const current = items.map(item => recognizedArt.has(item.path) && item.kind === 'photo' ? {...item, missing: true} : item);
  const removed = previous.filter(item => item.sourceId === source.id && !currentPaths.has(item.path)).map(item => ({...item, missing: true}));
  return [...previous.filter(item => item.sourceId !== source.id), ...current, ...removed];
}
