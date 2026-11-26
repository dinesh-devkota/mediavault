import React, {useEffect, useLayoutEffect, useRef, useState} from 'react';
import {FlatList, Pressable, StyleSheet, Text, View, ViewToken} from 'react-native';
import {NativeMethods, useTVEventHandler} from '@amazon-devices/react-native-kepler';
import {MediaGroup} from '../domain/library';
import {MediaItem, PlaybackResource, ViewingState} from '../domain/model';
import {colors, Poster, shared} from './Controls';
import {GridFocusAnchor, GridFocusRestoration} from './GridFocus';

export function LibraryGrid({groups, open, loadImage, session, selected, selecting, viewing = {}, restoreFocus}: {
  groups: MediaGroup[]; open: (group: MediaGroup, anchor: GridFocusAnchor) => void; loadImage: (item: MediaItem, path: string) => Promise<PlaybackResource>;
  session: number; selected?: Set<string>; selecting?: boolean; viewing?: Record<string, ViewingState>;
  restoreFocus?: GridFocusAnchor;
}) {
  const list = useRef<FlatList<MediaGroup>>(null), offset = useRef(0);
  const tiles = useRef(new Map<string, View>());
  const [restoration] = useState(() => new GridFocusRestoration(groups, restoreFocus));
  useLayoutEffect(() => { restoration.update(groups); }, [restoration, groups]);
  const [preferred, setPreferred] = useState(restoreFocus ? undefined : restoration.preferredID);
  const stopRestoring = (): void => { restoration.cancel(); setPreferred(undefined); };
  useEffect(() => () => restoration.cancel(), [restoration]);
  useTVEventHandler(event => {
    // Back/Select may be the event that just mounted this returning screen.
    // A new directional action always wins; item activation also cancels below.
    if (event.eventKeyAction !== 1 && ['up', 'down', 'left', 'right'].includes(event.eventType)) { stopRestoring(); }
  });
  const onViewableItemsChanged = useRef(({viewableItems}: {viewableItems: ViewToken<MediaGroup>[]}) => {
    restoration.viewable(viewableItems.filter(value => value.isViewable).map(value => value.item.id));
  }).current;
  const viewabilityConfig = useRef({itemVisiblePercentThreshold: 50}).current;
  return <FlatList ref={list} data={groups} keyExtractor={group => group.id} numColumns={6} initialNumToRender={12} windowSize={5}
    maxToRenderPerBatch={6} updateCellsBatchingPeriod={50} removeClippedSubviews={false}
    onLayout={() => restoration.start({
      scrollToOffset: value => list.current?.scrollToOffset({offset: value, animated: false}),
      // Multi-column FlatList forwards ROW indices to VirtualizedList.
      scrollToRow: index => list.current?.scrollToIndex({index, animated: false, viewPosition: 0.5}),
      // Generic RN's View typing omits the pinned Vega NativeMethods extension.
      requestFocus: id => (tiles.current.get(id) as (View & Pick<NativeMethods, 'requestTVFocus'>) | undefined)?.requestTVFocus(),
    })}
    onScroll={event => { offset.current = Math.max(0, event.nativeEvent.contentOffset.y); }} scrollEventThrottle={16}
    onScrollToIndexFailed={({index, averageItemLength}) => restoration.scrollFailed(index, averageItemLength)}
    onViewableItemsChanged={onViewableItemsChanged} viewabilityConfig={viewabilityConfig}
    contentContainerStyle={styles.grid} columnWrapperStyle={styles.row} testID="library-grid"
    ListEmptyComponent={<View style={shared.panel}><Text style={shared.heading}>Nothing here yet</Text><Text style={shared.subtitle}>Add a source or change your filters to see your media.</Text></View>}
    renderItem={({item, index}) => <GroupTile group={item}
      open={() => { stopRestoring(); open(item, {id: item.id, index, offset: offset.current}); }}
      loadImage={loadImage} session={session} preferred={preferred === item.id && restoration.preferredID === item.id}
      setRef={value => { if (value) { tiles.current.set(item.id, value); } else { tiles.current.delete(item.id); } }}
      onLayout={() => restoration.tileReady(item.id)} onFocused={() => { restoration.focused(item.id); setPreferred(undefined); }}
      selecting={selecting} selected={item.items.every(media => selected?.has(media.id))}
      status={item.items.every(media => viewing[media.id]?.watched) ? 'Watched' : item.items.some(media => !viewing[media.id]?.watched && (viewing[media.id]?.position ?? 0) > 5) ? 'In progress' : undefined}/>}/>;
}
function GroupTile({group, open, loadImage, session, preferred, selecting, selected, status, setRef, onLayout, onFocused}: {
  group: MediaGroup; open: () => void; loadImage: (item: MediaItem, path: string) => Promise<PlaybackResource>; session: number;
  preferred: boolean; selecting?: boolean; selected?: boolean; status?: string;
  setRef: (value: View | null) => void; onLayout: () => void; onFocused: () => void;
}) {
  const [focused, setFocused] = useState(false);
  const representative = group.items.find(item => item.posterPath || item.imageTag) ?? group.items[0]!;
  const detail = representative.kind === 'episode' ? `${group.items.length} episodes` : group.items.length > 1 ? `${group.items.length} versions` : String(representative.year ?? representative.kind);
  return <Pressable ref={setRef} style={[styles.tile, focused && styles.focused, selected && styles.selected]} onPress={open} onLayout={onLayout}
    onFocus={() => { setFocused(true); onFocused(); }} onBlur={() => setFocused(false)} hasTVPreferredFocus={preferred}
    role="button" aria-label={`${selecting ? selected ? 'Selected, ' : 'Select, ' : ''}${group.title}, ${detail}`}
    accessibilityHint={selecting ? 'Selects or deselects every file in this title.' : representative.kind === 'episode' ? 'Opens this show’s seasons.' : representative.kind === 'photo' ? 'Opens the photo viewer.' : group.items.length > 1 ? 'Opens the available versions.' : 'Opens media details and playback.'} testID={`media-group-${group.id}`}>
    <Poster item={representative} load={loadImage} session={session}/>
    <Text style={styles.title} numberOfLines={2}>{selecting ? selected ? '✓ ' : '○ ' : ''}{group.title}</Text>
    <Text style={styles.detail}>{detail}{status ? ` · ${status}` : ''}</Text>
  </Pressable>;
}
const styles = StyleSheet.create({grid: {padding: 8, paddingBottom: 70}, row: {gap: 20}, tile: {flex: 1, maxWidth: '16%', padding: 8, marginBottom: 24, borderWidth: 3, borderColor: 'transparent'},
  focused: {borderColor: colors.focus, backgroundColor: colors.raised}, selected: {borderColor: colors.accent}, title: {fontSize: 22, color: colors.text, marginTop: 12, fontWeight: '600'}, detail: {fontSize: 18, color: colors.secondary, marginTop: 6}});
