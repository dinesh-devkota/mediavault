export type MediaKind = 'movie' | 'documentary' | 'episode' | 'music' | 'photo';
export type SourceKind = 'webdav' | 'jellyfin' | 'smb';

/** Catalog records contain no passwords, tokens, PINs, or per-profile viewing state. */
export interface Source {
  id: string;
  name: string;
  kind: SourceKind;
  endpoint: string;
  root: string;
  revision: number;
  ignoredFolders: string[];
  ignoredFiles: string[];
  userId?: string;
  lastScan?: number;
}

export interface LocalMetadata {
  kind: 'movie' | 'tvshow' | 'season' | 'episodedetails';
  title?: string;
  seriesTitle?: string;
  seriesYear?: number;
  plot?: string;
  year?: number;
  genres?: string[];
  runtimeMinutes?: number;
  certificationPresent?: boolean;
  certification?: string;
  tmdbId?: number;
  season?: number;
  episode?: number;
  collection?: string;
  edition?: string;
}

export interface MediaItem {
  id: string;
  sourceId: string;
  path: string;
  fileName: string;
  size: number;
  title: string;
  kind: MediaKind;
  year?: number;
  plot?: string;
  genres: string[];
  certification?: string;
  tmdbId?: number;
  seriesId?: string;
  seriesTitle?: string;
  seriesYear?: number;
  season?: number;
  episode?: number;
  runtimeMinutes?: number;
  collection?: string;
  collectionId?: number;
  edition?: string;
  posterPath?: string;
  backdropPath?: string;
  seasonPosterPath?: string;
  local?: LocalMetadata;
  manuallyMatched?: boolean;
  missing?: boolean;
  hidden?: boolean;
  jellyfinId?: string;
  imageTag?: string;
}

export interface ViewingState { position: number; duration: number; watched: boolean; updatedAt: number }
export interface FolderGrant { sourceId: string; path: string }
export interface HouseholdProfile {
  id: string;
  name: string;
  admin: boolean;
  folders: FolderGrant[];
  maximumMovieRating?: string;
  maximumTVRating?: string;
  /** A verifier reference only. Its secret material belongs in SecureVault. */
  pinReference?: string;
}
export interface PersonalCollection { id: string; name: string; itemIds: string[] }
export interface ProfileLibrary {
  viewing: Record<string, ViewingState>;
  watchlist: string[];
  collections: PersonalCollection[];
  continuousTV?: boolean;
}
export interface LibrarySnapshot {
  schema: 1;
  sources: Source[];
  items: MediaItem[];
  profiles: HouseholdProfile[];
  profileLibraries: Record<string, ProfileLibrary>;
}
export const emptyProfileLibrary = (): ProfileLibrary => ({viewing: {}, watchlist: [], collections: []});
export const emptyLibrary = (): LibrarySnapshot => ({schema: 1, sources: [], items: [], profiles: [], profileLibraries: {}});

export interface DirectoryEntry { path: string; name: string; directory: boolean; size: number }
export type CancellationSignal = AbortController['signal'];
export interface PlaybackResource { uri: string; headers?: Record<string, string>; mime?: string; release?: () => Promise<void> }

export interface SourceClient {
  list(path: string, signal?: CancellationSignal): Promise<DirectoryEntry[]>;
  readText(path: string, maximumBytes: number, signal?: CancellationSignal): Promise<string>;
  playback(item: MediaItem, signal?: CancellationSignal): Promise<PlaybackResource>;
}
