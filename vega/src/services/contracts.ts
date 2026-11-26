import {DirectoryEntry, MediaItem, PlaybackResource, Source, SourceClient} from '../domain/model';
import {NativeHTTP} from '../sources/http';

/** Application contract, implemented by MediaVault's real native bridge, not an SDK substitute. */
export interface PlatformServices {
  connect(source: Source, username: string, password: string): Promise<{userId?: string; userName?: string}>;
  updateSource(source: Source): Promise<void>;
  forget(sourceId: string): Promise<void>;
  client(source: Source): SourceClient;
  http: NativeHTTP;
  image(source: Source, item: MediaItem, path: string): Promise<PlaybackResource>;
  playback(source: Source, item: MediaItem): Promise<PlaybackResource>;
  revokeAll(): Promise<void>;
  revokeResource(uri: string): Promise<void>;
  hasProfilePIN(profileId: string): Promise<boolean>;
  setProfilePIN(profileId: string, pin: string): Promise<void>;
  verifyProfilePIN(profileId: string, pin: string): Promise<boolean>;
  removeProfilePIN(profileId: string): Promise<void>;
}
export interface FolderChoice { directory: string; entries: DirectoryEntry[] }
