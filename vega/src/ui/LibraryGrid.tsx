import React, {useState} from 'react';
import {FlatList, Pressable, StyleSheet, Text, View} from 'react-native';
import {MediaGroup} from '../domain/library';
import {MediaItem, PlaybackResource, ViewingState} from '../domain/model';
import {colors, Poster, shared} from './Controls';

export function LibraryGrid({groups, open, loadImage, session, selected, selecting, viewing = {}}: {
  groups: MediaGroup[]; open: (group: MediaGroup) => void; loadImage: (item: MediaItem, path: string) => Promise<PlaybackResource>;
  session: number; selected?: Set<string>; selecting?: boolean; viewing?: Record<string, ViewingState>;
}) {
  return <FlatList data={groups} keyExtractor={group => group.id} numColumns={6} initialNumToRender={12} windowSize={5}
    maxToRenderPerBatch={6} updateCellsBatchingPeriod={50} removeClippedSubviews={false}
    contentContainerStyle={styles.grid} columnWrapperStyle={styles.row} testID="library-grid"
    ListEmptyComponent={<View style={shared.panel}><Text style={shared.heading}>Nothing here yet</Text><Text style={shared.subtitle}>Add a source or change your filters to see your media.</Text></View>}
    renderItem={({item, index}) => <GroupTile group={item} open={() => open(item)} loadImage={loadImage} session={session} preferred={index === 0}
      selecting={selecting} selected={item.items.every(media => selected?.has(media.id))}
      status={item.items.every(media => viewing[media.id]?.watched) ? 'Watched' : item.items.some(media => !viewing[media.id]?.watched && (viewing[media.id]?.position ?? 0) > 5) ? 'In progress' : undefined}/>}/>;
}
function GroupTile({group, open, loadImage, session, preferred, selecting, selected, status}: {
  group: MediaGroup; open: () => void; loadImage: (item: MediaItem, path: string) => Promise<PlaybackResource>; session: number;
  preferred: boolean; selecting?: boolean; selected?: boolean; status?: string;
}) {
  const [focused, setFocused] = useState(false);
  const representative = group.items.find(item => item.posterPath || item.imageTag) ?? group.items[0]!;
  const detail = representative.kind === 'episode' ? `${group.items.length} episodes` : group.items.length > 1 ? `${group.items.length} versions` : String(representative.year ?? representative.kind);
  return <Pressable style={[styles.tile, focused && styles.focused, selected && selecting && styles.selected]} onPress={open}
    onFocus={() => setFocused(true)} onBlur={() => setFocused(false)} hasTVPreferredFocus={preferred}
    role="button" aria-label={`${selecting ? selected ? 'Selected, ' : 'Select, ' : ''}${group.title}, ${detail}`}
    accessibilityHint={selecting ? 'Selects or deselects every file in this title.' : representative.kind === 'episode' ? 'Opens this show’s seasons.' : representative.kind === 'photo' ? 'Opens the photo viewer.' : group.items.length > 1 ? 'Opens the available versions.' : 'Opens media details and playback.'} testID={`media-group-${group.id}`}>
    <Poster item={representative} load={loadImage} session={session}/>
    <Text style={styles.title} numberOfLines={2}>{selecting ? selected ? '✓ ' : '○ ' : ''}{group.title}</Text>
    <Text style={styles.detail}>{detail}{status ? ` · ${status}` : ''}</Text>
  </Pressable>;
}
const styles = StyleSheet.create({grid: {padding: 8, paddingBottom: 70}, row: {gap: 20}, tile: {flex: 1, maxWidth: '16%', padding: 8, marginBottom: 24, borderWidth: 3, borderColor: 'transparent'},
  focused: {borderColor: colors.focus, backgroundColor: colors.raised}, selected: {borderColor: colors.accent}, title: {fontSize: 22, color: colors.text, marginTop: 12, fontWeight: '600'}, detail: {fontSize: 18, color: colors.secondary, marginTop: 6}});
