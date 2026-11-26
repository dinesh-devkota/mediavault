import {MediaItem, SourceClient} from './model';
import {baseName, parentPath, stem} from './paths';
import {InvalidTextFileError, utf8Length} from './metadata';

export interface SubtitleCue { start: number; end: number; text: string }
export interface SubtitleFile { path: string; language?: string; forced: boolean; hearingImpaired: boolean }
const languageNames: Record<string, string> = {
  ar: 'Arabic', de: 'German', deu: 'German', en: 'English', eng: 'English',
  es: 'Spanish', spa: 'Spanish', fr: 'French', fra: 'French', fre: 'French',
  hi: 'Hindi', it: 'Italian', jpn: 'Japanese', ja: 'Japanese', ko: 'Korean',
  pt: 'Portuguese', por: 'Portuguese', ru: 'Russian', uk: 'Ukrainian',
  zh: 'Chinese', zho: 'Chinese', chi: 'Chinese',
};

export function subtitleLanguageName(code: string): string {
  const [language, region] = code.toLowerCase().split('-');
  const name = language ? languageNames[language] : undefined;
  if (name) { return region ? `${name} (${region.toUpperCase()})` : name; }
  return code.toUpperCase();
}

export function matchingSubtitles(item: MediaItem, paths: string[]): SubtitleFile[] {
  const mediaStem = stem(baseName(item.path)).toLowerCase();
  return paths.filter(path => parentPath(path) === parentPath(item.path) && /\.(srt|vtt)$/i.test(path))
    .flatMap(path => {
      const name = stem(baseName(path)).toLowerCase();
      if (name !== mediaStem && !name.startsWith(mediaStem + '.') && !name.startsWith(mediaStem + ' ')) { return []; }
      const suffix = name.slice(mediaStem.length).replace(/^[. ]+/, '').split(/[. ]+/).filter(Boolean);
      if (suffix.some(part => !['forced', 'sdh', 'hi', 'cc'].includes(part) && !/^[a-z]{2,3}(?:-[a-z]{2})?$/.test(part))) { return []; }
      return [{path, language: suffix.find(part => /^[a-z]{2,3}(?:-[a-z]{2})?$/.test(part) && !['sdh', 'hi', 'cc'].includes(part)), forced: suffix.includes('forced'), hearingImpaired: suffix.includes('sdh') || suffix.includes('hi') || suffix.includes('cc')}];
    });
}
function timestamp(value: string): number | undefined {
  const match = value.trim().match(/^(?:(\d{1,3}):)?(\d{2}):(\d{2})[.,](\d{3})$/);
  if (!match || Number(match[2]) >= 60 || Number(match[3]) >= 60) { return undefined; }
  return Number(match[1] ?? 0) * 3600 + Number(match[2]) * 60 + Number(match[3]) + Number(match[4]) / 1000;
}
export function parseSubtitles(value: string): SubtitleCue[] {
  if (utf8Length(value) > 2 * 1024 * 1024) { throw new InvalidTextFileError('The subtitle file is too large.'); }
  const cues: SubtitleCue[] = [];
  for (const block of value.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n').split(/\n\s*\n/)) {
    const lines = block.split('\n');
    const index = lines.findIndex(line => line.includes('-->'));
    if (index < 0) { continue; }
    const [from, to] = lines[index]!.split('-->');
    const start = timestamp(from ?? ''), end = timestamp((to ?? '').trim().split(/\s/)[0] ?? '');
    if (start === undefined || end === undefined || end <= start) { continue; }
    const text = lines.slice(index + 1).join('\n').replace(/<[^>]*>/g, '').replace(/\{\\[^}]*\}/g, '').slice(0, 4096).trim();
    if (text) { cues.push({start, end, text}); }
    if (cues.length > 20_000) { throw new InvalidTextFileError('The subtitle file contains too many cues.'); }
  }
  return cues.sort((a, b) => a.start - b.start);
}


export async function loadMatchingSubtitles(item: MediaItem, paths: string[], readText: SourceClient['readText'], assertActive: () => void): Promise<{label: string; language: string; cues: SubtitleCue[]}[]> {
  const result: {label: string; language: string; cues: SubtitleCue[]}[] = [];
  for (const match of matchingSubtitles(item, paths).slice(0, 8)) {
    assertActive();
    try {
      const value = await readText(match.path, 2 * 1024 * 1024); assertActive();
      const cues = parseSubtitles(value);
      if (cues.length) {
        const name = match.language ? subtitleLanguageName(match.language) : 'Subtitle file';
        const labels = [name, ...(match.forced ? ['Forced'] : []), ...(match.hearingImpaired ? ['SDH'] : [])];
        result.push({label: labels.join(' · '), language: match.language ?? '', cues});
      }
    } catch (reason) {
      // A confirmed bad file can be skipped; permission, transport and profile changes cannot.
      assertActive();
      if (!(reason instanceof InvalidTextFileError)) { throw reason; }
    }
  }
  assertActive();
  return result;
}
