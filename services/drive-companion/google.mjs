import { createHash } from 'node:crypto';

export const DRIVE_SCOPE = 'https://www.googleapis.com/auth/drive.file';
export const isFileId = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,256}$/.test(value);

const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const FILE_URL = 'https://www.googleapis.com/drive/v3/files/';
const FILE_FIELDS = 'id,name,size,mimeType,parents,resourceKey,trashed,capabilities(canDownload)';
const SUBTITLE_EXT = /\.(srt|vtt)$/i;
const MEDIA_EXT = /\.(mp4|m4v|mkv|mov|avi|webm|mpg|mpeg|m2ts|ts|wmv|flv|3gp|jpg|jpeg|png|webp|gif|heic|heif|avif|bmp|tiff?)$/i;

export class GoogleFailure extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function token(value) {
  if (typeof value !== 'string' || !/^[!-~]{1,4096}$/.test(value)) {
    throw new GoogleFailure('protocol_error');
  }
  return value;
}

function seconds(value) {
  if (!Number.isSafeInteger(value) || value < 1 || value > 2_147_483_647) {
    throw new GoogleFailure('protocol_error');
  }
  return value;
}

async function readGoogleJSON(response) {
  let size = 0;
  const parts = [];
  try {
    for await (const part of response.body ?? []) {
      size += part.length;
      if (size > 65_536) throw new GoogleFailure('protocol_error');
      parts.push(part);
    }
  } catch (error) {
    if (error instanceof GoogleFailure) throw error;
    throw new GoogleFailure('temporarily_unavailable');
  }
  try {
    return JSON.parse(Buffer.concat(parts).toString('utf8'));
  } catch {
    throw new GoogleFailure('protocol_error');
  }
}

function fileHeaders(accessToken, id, resourceKey) {
  const headers = { Authorization: 'Bearer ' + accessToken };
  if (resourceKey) headers['X-Goog-Drive-Resource-Keys'] = id + '/' + resourceKey;
  return headers;
}

function fileUrl(fileId) {
  if (!isFileId(fileId)) throw new GoogleFailure('protocol_error');
  return new URL(FILE_URL + fileId);
}

function supportedFile(name, mime) {
  if (mime.startsWith('video/') || mime.startsWith('image/')) return true;
  if (mime === 'application/octet-stream') return MEDIA_EXT.test(name) || SUBTITLE_EXT.test(name);
  return SUBTITLE_EXT.test(name) && (
    mime.startsWith('text/') || mime === 'application/x-subrip'
  );
}

export function validateMetadata(body, selection) {
  if (!body || body.id !== selection.id || !isFileId(body.id) || body.trashed !== false ||
      body.capabilities?.canDownload !== true || typeof body.name !== 'string' ||
      body.name.length < 1 || Buffer.byteLength(body.name, 'utf8') > 255 || body.name === '.' || body.name === '..' ||
      /[\/\\\p{Cc}\p{Cf}\p{Cs}]/u.test(body.name) ||
      typeof body.mimeType !== 'string' || body.mimeType.length > 127 ||
      !/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(body.mimeType) ||
      !supportedFile(body.name, body.mimeType) || typeof body.size !== 'string' ||
      !/^[1-9][0-9]{0,15}$/.test(body.size)) {
    throw new GoogleFailure('selection_unavailable');
  }
  const size = Number(body.size);
  if (!Number.isSafeInteger(size)) throw new GoogleFailure('selection_unavailable');

  const reportedKey = body.resourceKey === '' ? undefined : (body.resourceKey ?? undefined);
  const resourceKey = reportedKey ?? selection.resourceKey;
  if ((resourceKey !== undefined && !isFileId(resourceKey)) ||
      (reportedKey !== undefined && selection.resourceKey !== undefined &&
        reportedKey !== selection.resourceKey)) {
    throw new GoogleFailure('selection_unavailable');
  }
  let parentId;
  if (body.parents !== undefined) {
    if (!Array.isArray(body.parents) || body.parents.length > 1 ||
        (body.parents.length === 1 && !isFileId(body.parents[0]))) {
      throw new GoogleFailure('selection_unavailable');
    }
    parentId = body.parents[0];
  }
  return { id: body.id, name: body.name, size, mimeType: body.mimeType, parentId, resourceKey };
}

export class Google {
  constructor(config, fetcher = fetch) {
    this.config = config;
    this.fetcher = fetcher;
  }

  authorization(state, verifier) {
    const url = new URL(AUTH_URL);
    url.search = new URLSearchParams({
      client_id: this.config.clientId,
      redirect_uri: this.config.origin + '/oauth/callback',
      response_type: 'code',
      scope: DRIVE_SCOPE,
      access_type: 'offline',
      prompt: 'consent',
      include_granted_scopes: 'false',
      state,
      code_challenge: createHash('sha256').update(verifier).digest('base64url'),
      code_challenge_method: 'S256',
    });
    return url.href;
  }

  async request(url, options, signal = AbortSignal.timeout(12_000)) {
    try {
      return await this.fetcher(url, { ...options, redirect: 'manual', signal });
    } catch {
      throw new GoogleFailure('temporarily_unavailable');
    }
  }

  async grant(parameters, now, previous) {
    const response = await this.request(TOKEN_URL, {
      method: 'POST',
      body: new URLSearchParams({
        client_id: this.config.clientId,
        client_secret: this.config.clientSecret,
        ...parameters,
      }),
    });
    if (response.status >= 300 && response.status < 400) {
      await response.body?.cancel();
      throw new GoogleFailure('protocol_error');
    }
    if (response.status === 429 || response.status >= 500) {
      await response.body?.cancel();
      throw new GoogleFailure('temporarily_unavailable');
    }
    const body = await readGoogleJSON(response);
    if (response.status === 400 && body?.error === 'invalid_grant') throw new GoogleFailure('invalid_grant');
    if (!response.ok || typeof body?.token_type !== 'string' || body.token_type.toLowerCase() !== 'bearer' ||
        (body.scope !== undefined && body.scope !== DRIVE_SCOPE)) {
      throw new GoogleFailure('protocol_error');
    }

    const refreshToken = token(body.refresh_token ?? previous?.refreshToken);
    const refreshExpiresAt = body.refresh_token_expires_in === undefined
      ? previous?.refreshExpiresAt
      : now + seconds(body.refresh_token_expires_in);
    return {
      accessToken: token(body.access_token),
      accessExpiresAt: now + Math.min(seconds(body.expires_in), 3_600),
      refreshToken,
      refreshExpiresAt,
    };
  }

  exchange(code, verifier, now) {
    return this.grant({
      grant_type: 'authorization_code',
      redirect_uri: this.config.origin + '/oauth/callback',
      code,
      code_verifier: verifier,
    }, now);
  }

  refresh(previous, now) {
    if (previous.refreshExpiresAt !== undefined && previous.refreshExpiresAt <= now) {
      throw new GoogleFailure('invalid_grant');
    }
    return this.grant({ grant_type: 'refresh_token', refresh_token: previous.refreshToken }, now, previous);
  }

  async metadata(selection, accessToken) {
    const url = fileUrl(selection.id);
    url.search = new URLSearchParams({ supportsAllDrives: 'true', fields: FILE_FIELDS });
    const response = await this.request(url, { headers: fileHeaders(accessToken, selection.id, selection.resourceKey) });
    if (!response.ok) {
      await response.body?.cancel();
      if (response.status === 401) throw new GoogleFailure('authorization_expired');
      if (response.status === 403 || response.status === 404) throw new GoogleFailure('selection_unavailable');
      if (response.status === 429 || response.status >= 500) throw new GoogleFailure('temporarily_unavailable');
      throw new GoogleFailure('protocol_error');
    }
    return validateMetadata(await readGoogleJSON(response), selection);
  }

  media(file, accessToken, range, signal) {
    const url = fileUrl(file.id);
    url.search = new URLSearchParams({ alt: 'media', supportsAllDrives: 'true' });
    const headers = fileHeaders(accessToken, file.id, file.resourceKey);
    headers['Accept-Encoding'] = 'identity';
    if (range) headers.Range = 'bytes=' + range.start + '-' + range.end;
    return this.request(url, { headers }, signal);
  }
}
