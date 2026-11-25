import Native from './MediaVaultNative';
import {CancellationSignal, DirectoryEntry, MediaItem, PlaybackResource, Source, SourceClient} from '../domain/model';
import {contains, safePath} from '../domain/paths';
import {utf8Length} from '../domain/metadata';
import {URL} from 'react-native-url-polyfill';
import {PlatformServices} from '../services/contracts';
import {HTTPRequest, HTTPResponse, httpMessage, listWebDAV} from '../sources/http';

function cancelled(signal?: CancellationSignal): void {
  if (signal?.aborted) { throw new Error('This operation was cancelled.'); }
}
function parse<T>(value: string): T { return JSON.parse(value) as T; }
function boolean(value: string): boolean {
  const result: unknown = JSON.parse(value);
  if (typeof result !== 'boolean') { throw new Error('The protected profile response was invalid.'); }
  return result;
}
function bytes(encoded: string): Uint8Array {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  if (encoded.length > 1_398_104 || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) {
    throw new Error('The native source returned invalid bytes.');
  }
  const size = encoded.length / 4 * 3 - (encoded.endsWith('==') ? 2 : encoded.endsWith('=') ? 1 : 0);
  const result = new Uint8Array(size); let out = 0;
  for (let i = 0; i < encoded.length; i += 4) {
    const value = (alphabet.indexOf(encoded[i]!) << 18) | (alphabet.indexOf(encoded[i + 1]!) << 12)
      | (Math.max(0, alphabet.indexOf(encoded[i + 2]!)) << 6) | Math.max(0, alphabet.indexOf(encoded[i + 3]!));
    if (out < size) { result[out++] = value >> 16 & 255; }
    if (out < size) { result[out++] = value >> 8 & 255; }
    if (out < size) { result[out++] = value & 255; }
  }
  return result;
}
function utf8(value: Uint8Array): string {
  // decodeURIComponent rejects malformed and overlong UTF-8, including surrogate encodings.
  const chunks: string[] = [];
  for (let i = 0; i < value.length; i += 4096) {
    chunks.push(Array.from(value.subarray(i, i + 4096), byte => '%' + byte.toString(16).padStart(2, '0')).join(''));
  }
  try { return decodeURIComponent(chunks.join('')).replace(/^\uFEFF/, ''); }
  catch { throw new Error('This metadata or subtitle file is not valid UTF-8.'); }
}
const http = async (sourceId: string, request: HTTPRequest): Promise<HTTPResponse> => {
  const result = parse<HTTPResponse>(await Native.request(sourceId, JSON.stringify(request)));
  if (!Number.isInteger(result.status) || result.status < 100 || result.status > 599 || typeof result.body !== 'string'
    || utf8Length(result.body) > request.maximumBytes || !result.headers || typeof result.headers !== 'object') {
    throw new Error('The server returned an invalid response.');
  }
  return result;
};

async function resource(source: Source, path: string, query: Record<string, string> = {}): Promise<PlaybackResource> {
  safePath(path);
  return checkedResource(await Native.acquirePlaybackTicket(source.id, path, JSON.stringify(query)));
}
function checkedResource(raw: string): PlaybackResource {
  const result = parse<PlaybackResource>(raw);
  const url = new URL(result.uri);
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port || url.username || url.password || url.search || url.hash || result.headers) {
    throw new Error('The source did not provide a protected local media link.');
  }
  return {...result, release: async () => { await Native.revokeResource(result.uri); }};
}
function itemID(item: MediaItem): string {
  if (!item.jellyfinId || !/^[a-z0-9_-]{1,128}$/i.test(item.jellyfinId)) { throw new Error('This Jellyfin item is unavailable.'); }
  return item.jellyfinId;
}
async function playback(source: Source, item: MediaItem): Promise<PlaybackResource> {
  if (item.sourceId !== source.id) { throw new Error('This media belongs to a different source.'); }
  if (source.kind === 'jellyfin') {
    return resource(source, `${item.kind === 'music' ? 'Audio' : 'Videos'}/${itemID(item)}/stream`, {static: 'true'});
  }
  return resource(source, item.path);
}
function client(source: Source): SourceClient {
  return {
    async list(path, signal): Promise<DirectoryEntry[]> {
      cancelled(signal); safePath(path);
      const result = source.kind === 'webdav' ? await listWebDAV(source, path, http)
        : source.kind === 'smb' ? parse<DirectoryEntry[]>(await Native.listDirectory(source.id, path))
          : (() => { throw new Error('Use the Jellyfin library browser.'); })();
      cancelled(signal); return result;
    },
    async readText(path, maximumBytes, signal): Promise<string> {
      cancelled(signal); safePath(path);
      if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 0 || maximumBytes > 2 * 1024 * 1024) {
        throw new Error('This text file exceeds the supported limit.');
      }
      if (!contains(path, source.root)) { throw new Error('This file is outside the selected media folder.'); }
      if (source.kind === 'webdav') {
        const response = await http(source.id, {path, method: 'GET', maximumBytes}); cancelled(signal);
        if (response.status !== 200) { throw new Error(httpMessage(response.status)); }
        return response.body.replace(/^\uFEFF/, '');
      }
      const stat = parse<{size: number; directory: boolean}>(await Native.stat(source.id, path));
      cancelled(signal);
      if (stat.directory || !Number.isSafeInteger(stat.size) || stat.size < 0 || stat.size > maximumBytes) { throw new Error('This text file is too large.'); }
      if (!stat.size) { return ''; }
      const content = new Uint8Array(stat.size);
      for (let offset = 0; offset < stat.size; offset += 1024 * 1024) {
        const count = Math.min(1024 * 1024, stat.size - offset);
        const part = bytes(await Native.readRange(source.id, path, String(offset), count)); cancelled(signal);
        if (part.length !== count) { throw new Error('The file changed while it was being read.'); }
        content.set(part, offset);
      }
      return utf8(content);
    },
    async playback(item, signal): Promise<PlaybackResource> {
      cancelled(signal); const result = await playback(source, item);
      if (signal?.aborted) { await Native.revokeResource(result.uri); cancelled(signal); }
      return result;
    },
  };
}
export const platformServices: PlatformServices = {
  async connect(source, username, password) {
    const operation = source.kind === 'jellyfin' ? Native.authenticateJellyfin.bind(Native) : Native.configureSource.bind(Native);
    return parse<{userId?: string; userName?: string}>(await operation(JSON.stringify(source), username, password));
  },
  async updateSource(source) { await Native.updateSource(JSON.stringify(source)); },
  async forget(sourceId) { await Native.removeSource(sourceId); },
  client, http, playback,
  async image(source, item, path) {
    if (item.sourceId !== source.id) { throw new Error('This image belongs to a different source.'); }
    const imagePath = source.kind === 'jellyfin' ? `Items/${itemID(item)}/Images/Primary` : safePath(path);
    const query = source.kind === 'jellyfin' ? {maxWidth: item.kind === 'photo' ? '2560' : '480'} : {};
    return checkedResource(await Native.acquireImageTicket(source.id, imagePath, JSON.stringify(query)));
  },
  async revokeAll() { await Native.revokeAll(); },
  async revokeResource(uri) { await Native.revokeResource(uri); },
  async hasProfilePIN(profileId) { return boolean(await Native.hasProfilePIN(profileId)); },
  async setProfilePIN(profileId, pin) { await Native.setProfilePIN(profileId, pin); },
  async verifyProfilePIN(profileId, pin) { return boolean(await Native.verifyProfilePIN(profileId, pin)); },
  async removeProfilePIN(profileId) { await Native.removeProfilePIN(profileId); },
};
