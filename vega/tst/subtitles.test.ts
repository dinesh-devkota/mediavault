import {itemFromFile} from '../src/domain/library';
import {InvalidTextFileError} from '../src/domain/metadata';
import {loadMatchingSubtitles} from '../src/domain/subtitles';

const item = itemFromFile('nas', 'Shows/Fixture Show.S01E01.mp4', 100)!;
const path = (language: string) => `Shows/Fixture Show.S01E01.${language}.srt`;
const subtitle = (text: string) => `1\n00:00:00,500 --> 00:00:05,000\n${text}\n`;

test('an oversized and a malformed sidecar do not discard valid sibling languages', async () => {
  const read = jest.fn(async (file: string) => {
    if (file === path('de')) { throw new InvalidTextFileError('File exceeds the two MiB limit'); }
    if (file === path('fr')) { return 'This is deliberately not a subtitle file.'; }
    return subtitle(file === path('en') ? 'English subtitle' : 'Spanish subtitle');
  });
  const result = await loadMatchingSubtitles(item, [path('de'), path('en'), path('fr'), path('es'), 'Shows/Fixture Show.S01E010.en.srt', 'Other/Fixture Show.S01E01.en.srt'], read, () => {});
  expect(result.map(track => track.language)).toEqual(['en', 'es']);
  expect(result.map(track => track.cues[0]!.text)).toEqual(['English subtitle', 'Spanish subtitle']);
  expect(read.mock.calls.map(call => call[0])).toEqual(['de', 'en', 'fr', 'es'].map(path));
  expect(read).toHaveBeenCalledWith(path('en'), 2 * 1024 * 1024);
});

test('a source authorization error rejects the batch instead of reporting partial success', async () => {
  const denied = new Error('Access was revoked');
  const read = jest.fn(async (file: string) => { if (file === path('es')) { throw denied; } return subtitle('English'); });
  await expect(loadMatchingSubtitles(item, ['en', 'es', 'fr'].map(path), read, () => {})).rejects.toBe(denied);
  expect(read).toHaveBeenCalledTimes(2);
});

test.each([false, true])('a profile change while reading invalid=%s aborts before any further access', async invalid => {
  let active = true;
  const cancelled = new Error('Household profile changed');
  const read = jest.fn(async () => {
    active = false;
    if (invalid) { throw new InvalidTextFileError('Bad sidecar'); }
    return subtitle('English');
  });
  await expect(loadMatchingSubtitles(item, ['en', 'es'].map(path), read, () => { if (!active) { throw cancelled; } })).rejects.toBe(cancelled);
  expect(read).toHaveBeenCalledTimes(1);
});
