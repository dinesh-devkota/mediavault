import React, {useEffect, useRef, useState} from 'react';
import {ScrollView, Text, View} from 'react-native';
import {DirectoryEntry, Source, SourceKind} from '../domain/model';
import {parentPath, SourceAddress} from '../domain/paths';
import {PlatformServices} from '../services/contracts';
import {Action, Field, shared} from './Controls';

export function SourceEditor({id, services, onSave, onCancel}: {id: string; services: PlatformServices; onSave: (source: Source) => Promise<void>; onCancel: () => void}) {
  const [kind, setKind] = useState<SourceKind>('webdav');
  const [name, setName] = useState('');
  const [endpoint, setEndpoint] = useState('');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [connected, setConnected] = useState<Source>();
  const [directory, setDirectory] = useState('');
  const [entries, setEntries] = useState<DirectoryEntry[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const saved = useRef(false), active = useRef(true);
  useEffect(() => {
    active.current = true;
    return () => { active.current = false; if (!saved.current) { void services.forget(id).catch(() => {}); } };
  }, [id, services]);
  const report = (reason: unknown): void => setError(reason instanceof Error ? reason.message : 'The source could not be connected.');
  const browse = async (source: Source, path: string): Promise<void> => {
    setBusy(true); setError(undefined);
    try { const values = await services.client(source).list(path); if (active.current) { setEntries(values); setDirectory(path); } }
    catch (reason) { if (active.current) { report(reason); } }
    finally { if (active.current) { setBusy(false); } }
  };
  const connect = async (): Promise<void> => {
    setBusy(true); setError(undefined);
    try {
      if (!name.trim()) { throw new Error('Give this source a name, such as Living room NAS.'); }
      const validated = kind === 'smb' ? endpoint.trim() : new SourceAddress(endpoint).endpoint.href;
      if (!validated) { throw new Error('Enter the server address.'); }
      const source: Source = {id, name: name.trim().slice(0, 80), kind, endpoint: validated, root: '', revision: 0, ignoredFolders: [], ignoredFiles: []};
      const account = await services.connect(source, username, password);
      if (!active.current) { await services.forget(id); return; }
      const ready = {...source, userId: account.userId};
      if (kind !== 'jellyfin') { const values = await services.client(ready).list(''); setEntries(values); }
      if (!active.current) { await services.forget(id); return; }
      setPassword(''); setConnected(ready); setDirectory('');
    } catch (reason) { if (active.current) { report(reason); } }
    finally { if (active.current) { setBusy(false); } }
  };
  const save = async (): Promise<void> => {
    if (!connected) { return; }
    setBusy(true); setError(undefined);
    try { saved.current = true; await onSave({...connected, root: directory}); }
    catch (reason) { saved.current = false; report(reason); setBusy(false); }
  };
  return <ScrollView contentContainerStyle={{paddingBottom: 60}}>
    <Text style={shared.title}>{connected ? 'Choose your media folder' : 'Add a source'}</Text>
    <Text style={shared.subtitle}>{connected ? 'MediaVault scans this folder and its subfolders. You can ignore files and folders later.' : 'Connect once, then browse your movies, shows, music, and photos together.'}</Text>
    {!connected ? <View style={{maxWidth: 980}}>
      <View style={shared.row}>{(['webdav', 'jellyfin', 'smb'] as const).map(value => <Action key={value} label={value === 'smb' ? 'NAS / SMB' : value === 'webdav' ? 'WebDAV' : 'Jellyfin'} selected={kind === value} disabled={busy} onPress={() => setKind(value)}/>)}</View>
      <Field label="Source name" value={name} onChange={setName} placeholder="Living room NAS" testID="source-name"/>
      <Field label={kind === 'smb' ? 'NAS address and share' : 'Server address'} value={endpoint} onChange={setEndpoint} placeholder={kind === 'smb' ? 'smb://nas.local/Media' : 'https://nas.example/media/'} testID="source-address"/>
      <Field label="Username" value={username} onChange={setUsername} testID="source-username"/>
      <Field label="Password" value={password} onChange={setPassword} secure testID="source-password"/>
      <View style={shared.row}><Action label={busy ? 'Connecting…' : 'Connect'} disabled={busy} onPress={() => void connect()} testID="source-connect"/><Action label="Cancel" disabled={busy} onPress={onCancel}/></View>
    </View> : <View>
      <Text style={shared.heading}>{connected.name}</Text><Text style={shared.text}>{directory || 'All accessible media'}</Text>
      <View style={shared.row}><Action label={busy ? 'Working…' : 'Add folder & scan'} disabled={busy} preferred onPress={() => void save()} testID="source-save"/>
        {!!directory && <Action label="Parent folder" disabled={busy} onPress={() => void browse(connected, parentPath(directory))}/>}
        <Action label="Cancel" disabled={busy} onPress={onCancel}/></View>
      {connected.kind === 'jellyfin' ? <Text style={shared.subtitle}>Only content available to this Jellyfin account will be imported.</Text> : entries.filter(entry => entry.directory).map(entry => <Action key={entry.path} label={`Folder: ${entry.name}`} disabled={busy} onPress={() => void browse(connected, entry.path)}/>)}
    </View>}
    {error && <Text style={shared.error} aria-live="polite">{error}</Text>}
  </ScrollView>;
}
