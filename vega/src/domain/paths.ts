// Vega 0.83 provides the complete global URL API without a legacy NativeModules bridge.
// https://developer.amazon.com/docs/react-native-vega/0.83/global-URL

const unsafe = /\\|%(?:2e|2f|5c|00)/i;
export function safePath(path: string): string {
  if (path === '') { return ''; }
  const parts = path.split('/');
  if (parts.some(part => !part || part === '.' || part === '..' || unsafe.test(part)
    || Array.from(part).some(character => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127))) {
    throw new Error('Choose a file or folder inside this source.');
  }
  return path;
}
export function contains(path: string, root: string, allowRoot = false): boolean {
  try {
    safePath(path); safePath(root);
    return (allowRoot && path === root) || (path !== root && (root === '' || path.startsWith(root + '/')));
  } catch { return false; }
}
export const parentPath = (path: string): string => path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : '';
export const baseName = (path: string): string => path.slice(path.lastIndexOf('/') + 1);
export const stem = (path: string): string => path.replace(/\.[^./]+$/, '');
export const joinPath = (parent: string, child: string): string => safePath(parent ? parent + '/' + child : child);

/** URL paths are encoded component-by-component; a server href never expands the chosen root. */
export class SourceAddress {
  readonly endpoint: URL;
  private readonly rootParts: string[];
  constructor(value: string) {
    const url = new URL(value.trim());
    if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.search || url.hash) {
      throw new Error('Enter the full HTTPS server address without a password, query, or fragment.');
    }
    this.rootParts = this.components(url.pathname);
    url.pathname = '/' + this.rootParts.map(encodeURIComponent).join('/') + (this.rootParts.length ? '/' : '');
    this.endpoint = url;
  }
  url(path: string, directory = false): string {
    safePath(path);
    return this.endpoint.href + path.split('/').filter(Boolean).map(encodeURIComponent).join('/') + (directory && path ? '/' : '');
  }
  relative(href: string, requested: string): string | undefined {
    try {
      const url = new URL(href, requested);
      if (url.origin !== this.endpoint.origin || url.username || url.password || url.search || url.hash) { return undefined; }
      const parts = this.components(url.pathname);
      if (!this.rootParts.every((part, i) => parts[i] === part)) { return undefined; }
      return safePath(parts.slice(this.rootParts.length).join('/'));
    } catch { return undefined; }
  }
  private components(encoded: string): string[] {
    if (!encoded || encoded === '/') { return []; }
    const trimmed = encoded.replace(/^\//, '').replace(/\/$/, '');
    const parts = trimmed.split('/').map(decodeURIComponent);
    if (parts.some(part => part.includes('/'))) { throw new Error('Invalid encoded path.'); }
    safePath(parts.join('/'));
    return parts;
  }
}
