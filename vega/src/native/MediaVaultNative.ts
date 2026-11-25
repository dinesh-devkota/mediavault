import type {KeplerTurboModule} from '@amazon-devices/keplerscript-turbomodule-api';
import {TurboModuleRegistry} from '@amazon-devices/keplerscript-turbomodule-api';

/** Secrets are accepted once, consumed natively, and never returned to JavaScript. */
export interface MediaVaultNative extends KeplerTurboModule {
  configureSource(sourceJSON: string, username: string, password: string): Promise<string>;
  authenticateJellyfin(sourceJSON: string, username: string, password: string): Promise<string>;
  removeSource(sourceId: string): Promise<string>;
  updateSource(sourceJSON: string): Promise<string>;
  listDirectory(sourceId: string, path: string): Promise<string>;
  stat(sourceId: string, path: string): Promise<string>;
  readRange(sourceId: string, path: string, offset: string, length: number): Promise<string>;
  request(sourceId: string, requestJSON: string): Promise<string>;
  acquirePlaybackTicket(sourceId: string, path: string, queryJSON: string): Promise<string>;
  acquireImageTicket(sourceId: string, path: string, queryJSON: string): Promise<string>;
  revokeAll(): Promise<string>;
  revokeResource(uri: string): Promise<string>;
  hasProfilePIN(profileId: string): Promise<string>;
  setProfilePIN(profileId: string, pin: string): Promise<string>;
  verifyProfilePIN(profileId: string, pin: string): Promise<string>;
  removeProfilePIN(profileId: string): Promise<string>;
}

export default TurboModuleRegistry.getEnforcing<MediaVaultNative>('MediaVaultNative');
