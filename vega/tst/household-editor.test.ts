/// <reference types="node" />
/* global globalThis */
import React from 'react';
import {create, ReactTestRenderer} from 'react-test-renderer';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {runInNewContext} from 'node:vm';
import {JsxEmit, ModuleKind, ScriptTarget, transpileModule} from 'typescript';
import {emptyLibrary, emptyProfileLibrary, HouseholdProfile, Source} from '../src/domain/model';

type SaveProfile = (profile: HouseholdProfile, administratorPIN: string, childPIN: string) => Promise<void>;
const binding: Record<string, unknown> = {};
const dependencies: Record<string, unknown> = {
  react: React,
  'react-native': {View: 'View', ScrollView: 'ScrollView', Text: 'Text', StyleSheet: {create: (styles: unknown) => styles}},
  './domain/model': {emptyProfileLibrary},
  './ui/Controls': {Action: 'Action', Field: 'Field', shared: {}},
};
runInNewContext(transpileModule(readFileSync(join(__dirname, '../src/App.tsx'), 'utf8'), {
  compilerOptions: {target: ScriptTarget.ES2022, module: ModuleKind.CommonJS, jsx: JsxEmit.React, esModuleInterop: true},
}).outputText, {exports: binding, require: (name: string) => dependencies[name] ?? {}});
const ProfileEditor = binding.ProfileEditor as React.ComponentType<{
  library: ReturnType<typeof emptyLibrary>; needsAdminPIN: boolean; onSave: SaveProfile;
}>;

const source = (id: string, name: string, root: string): Source =>
  ({id, name, root, revision: 1, kind: 'smb', endpoint: 'smb://fixture.invalid/share', ignoredFolders: [], ignoredFiles: []});
const library = {...emptyLibrary(), sources: [
  source('fixture', 'Fixture NAS', 'Family'), source('formats', 'Formats NAS', ''),
], profiles: [{id: 'admin', name: 'Everyone', admin: true, folders: []}]};
const optionalPIN = 'Profile PIN (optional)';
const administratorPIN = '482619';
const viewerPIN = '274391';

let tree: ReactTestRenderer | undefined;
let saveProfile: jest.MockedFunction<SaveProfile>;
beforeAll(() => {
  (globalThis as typeof globalThis & {IS_REACT_ACT_ENVIRONMENT: boolean}).IS_REACT_ACT_ENVIRONMENT = true;
});
beforeEach(async () => {
  saveProfile = jest.fn<ReturnType<SaveProfile>, Parameters<SaveProfile>>(async () => {});
  await React.act(async () => {
    tree = create(React.createElement(ProfileEditor, {library, needsAdminPIN: true, onSave: saveProfile}));
  });
});
afterEach(async () => { await React.act(async () => { tree?.unmount(); }); });

const node = (type: 'Field' | 'Action', label: string) =>
  tree!.root.findAll(candidate => String(candidate.type) === type && candidate.props.label === label)[0];
const press = async (label: string) => { await React.act(async () => { node('Action', label)!.props.onPress(); }); };
const enter = async (label: string, value: string) => { await React.act(async () => { node('Field', label)!.props.onChange(value); }); };

async function enterProfileAndGrant() {
  await enter('Profile name', 'Kids');
  await press('Fixture NAS');
}

test('optional viewer PIN starts closed, can be added explicitly and is cleared on removal', async () => {
  expect(node('Field', optionalPIN)).toBeUndefined();
  expect(node('Field', 'Administrator PIN')?.props.secure).toBe(true);
  expect(node('Field', 'Confirm administrator PIN')?.props.secure).toBe(true);
  await press('Add profile PIN');
  expect(node('Field', optionalPIN)?.props.secure).toBe(true);
  await enter(optionalPIN, viewerPIN);
  await press('Remove profile PIN');
  expect(node('Field', optionalPIN)).toBeUndefined();
  await press('Add profile PIN');
  expect(node('Field', optionalPIN)?.props.value).toBe('');
});

test('after removing its PIN, the viewer is saved with only the explicit source and no PIN reference', async () => {
  await enterProfileAndGrant();
  expect(node('Action', 'Fixture NAS')?.props).toEqual(expect.objectContaining({
    selected: true, testID: 'profile-source-allowed-fixture',
  }));
  expect(node('Action', 'Formats NAS')?.props.selected).toBe(false);
  await press('Add profile PIN');
  await enter(optionalPIN, viewerPIN);
  await press('Remove profile PIN');
  await enter('Administrator PIN', administratorPIN);
  await enter('Confirm administrator PIN', '123456');
  await press('Save profile');
  expect(saveProfile).not.toHaveBeenCalled();
  await enter('Confirm administrator PIN', administratorPIN);
  await press('Save profile');
  expect(saveProfile).toHaveBeenCalledTimes(1);
  const [profile, adult, viewer] = saveProfile.mock.calls[0]!;
  expect(profile).toMatchObject({name: 'Kids', admin: false, folders: [{sourceId: 'fixture', path: 'Family'}],
    maximumMovieRating: 'PG', maximumTVRating: 'TV-PG'});
  expect(profile).not.toHaveProperty('pinReference');
  expect(adult).toBe(administratorPIN);
  expect(viewer).toBe('');
});

test('an opted-in PIN must be valid and is saved as a verifier reference', async () => {
  await enterProfileAndGrant();
  await enter('Administrator PIN', administratorPIN);
  await enter('Confirm administrator PIN', administratorPIN);
  await press('Add profile PIN');
  await enter(optionalPIN, '12345');
  await press('Save profile');
  expect(saveProfile).not.toHaveBeenCalled();
  await enter(optionalPIN, viewerPIN);
  await press('Save profile');
  expect(saveProfile).toHaveBeenCalledTimes(1);
  const [profile, adult, viewer] = saveProfile.mock.calls[0]!;
  expect(profile.pinReference).toBe(profile.id);
  expect(adult).toBe(administratorPIN);
  expect(viewer).toBe(viewerPIN);
});
