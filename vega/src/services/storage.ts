import AsyncStorage from '@amazon-devices/react-native-async-storage__async-storage';
import {emptyLibrary, emptyProfileLibrary, LibrarySnapshot} from '../domain/model';

const key = 'mediavault.catalog.v1';
let writeQueue: Promise<void> = Promise.resolve();
export async function loadLibrary(): Promise<LibrarySnapshot> {
  const data = await AsyncStorage.getItem(key);
  if (!data) {
    const initial = emptyLibrary();
    initial.profiles = [{id: 'household', name: 'Everyone', admin: true, folders: []}];
    initial.profileLibraries.household = emptyProfileLibrary();
    return initial;
  }
  if (data.length > 24 * 1024 * 1024) { throw new Error('The saved library is too large to open safely.'); }
  const value: unknown = JSON.parse(data);
  if (!value || typeof value !== 'object') { throw new Error('The saved library could not be read.'); }
  const library = value as LibrarySnapshot;
  if (library.schema !== 1 || !Array.isArray(library.sources) || !Array.isArray(library.items) || !Array.isArray(library.profiles)
    || !library.profileLibraries || library.sources.length > 500 || library.items.length > 250_000 || library.profiles.length > 20
    || !library.profiles.some(profile => profile.admin)) { throw new Error('The saved library format is not supported.'); }
  return library;
}
export function saveLibrary(snapshot: LibrarySnapshot): Promise<void> {
  const data = JSON.stringify(snapshot);
  if (data.length > 24 * 1024 * 1024) { return Promise.reject(new Error('The library is full. Remove an unused source first.')); }
  // Keep rapid watched/resume writes ordered, including after a previous disk error.
  const operation = writeQueue.catch(() => {}).then(() => AsyncStorage.setItem(key, data));
  writeQueue = operation;
  return operation;
}
