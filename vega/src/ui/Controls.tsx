import React, {useEffect, useState} from 'react';
import {Image, Pressable, StyleSheet, Text, TextInput, View} from 'react-native';
import {MediaItem, PlaybackResource} from '../domain/model';

export const colors = {background: '#10131a', panel: '#1d2430', raised: '#273344', text: '#f5f5f7', secondary: '#b6c2d2', accent: '#ffb45b', focus: '#ffffff', danger: '#ffb7ad'};
export function Action({label, onPress, preferred = false, disabled = false, selected = false, testID, destructive = false, hint, compact = false}: {
  label: string; onPress: () => void; preferred?: boolean; disabled?: boolean; selected?: boolean; testID?: string; destructive?: boolean; hint?: string; compact?: boolean;
}) {
  const [focused, setFocused] = useState(false);
  return <Pressable role="button" aria-label={label} accessibilityHint={hint ?? (label === 'Back' ? 'Returns to the previous screen.' : undefined)} testID={testID ?? 'action-' + label.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')} hasTVPreferredFocus={preferred}
    disabled={disabled} onPress={onPress} onFocus={() => setFocused(true)} onBlur={() => setFocused(false)}
    style={[styles.action, compact && styles.compactAction, selected && styles.selected, focused && styles.focused, disabled && styles.disabled]}>
    <Text style={[styles.actionText, destructive && {color: colors.danger}, focused && {color: colors.background}]}>{label}</Text>
  </Pressable>;
}
export function Field({label, value, onChange, secure = false, placeholder, testID}: {
  label: string; value: string; onChange: (value: string) => void; secure?: boolean; placeholder?: string; testID?: string;
}) {
  const [focused, setFocused] = useState(false);
  return <View style={styles.fieldGroup}><Text style={styles.label}>{label}</Text>
    <TextInput value={value} onChangeText={onChange} secureTextEntry={secure} autoCapitalize="none" autoCorrect={false}
      placeholder={placeholder} placeholderTextColor="#8999ae" aria-label={label} accessibilityHint={secure ? 'Your entry stays hidden on screen.' : 'Opens the keyboard to edit this field.'} testID={testID ?? 'field-' + label.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-$/, '')}
      onFocus={() => setFocused(true)} onBlur={() => setFocused(false)} style={[styles.field, focused && styles.fieldFocused]}/>
  </View>;
}
export function Poster({item, load, session, size = 'small'}: {item: MediaItem; load: (item: MediaItem, path: string) => Promise<PlaybackResource>; session: number; size?: 'small' | 'large'}) {
  const path = item.kind === 'photo' ? item.path : item.posterPath;
  const key = `${session}|${item.id}|${path ?? item.imageTag ?? ''}`;
  const [image, setImage] = useState<{key: string; resource: PlaybackResource}>();
  useEffect(() => {
    let active = true, owned: PlaybackResource | undefined;
    if (path || item.imageTag) {
      load(item, path ?? '').then(resource => {
        if (active) { owned = resource; setImage({key, resource}); }
        else { void resource.release?.().catch(() => {}); }
      }).catch(() => {});
    }
    return () => { active = false; void owned?.release?.().catch(() => {}); };
  }, [item, key, load, path]); // Tickets are session-scoped; stale responses never reveal the prior profile's artwork.
  return <View style={[styles.poster, size === 'large' && styles.largePoster]}>
    {image?.key === key ? <Image style={StyleSheet.absoluteFill} source={{uri: image.resource.uri, headers: image.resource.headers}} resizeMode="cover" accessible={false} aria-hidden={true} onError={() => setImage(undefined)}/>
      : <View style={styles.placeholder}><Text style={styles.posterLetter}>{item.kind === 'music' ? '♫' : item.kind === 'photo' ? '▧' : item.title.slice(0, 1).toUpperCase()}</Text></View>}
  </View>;
}
// Rectangular Vega surfaces avoid the rounded paint/clip failure measured in tools/vega/render-probe/README.md.
export const shared = StyleSheet.create({
  page: {flex: 1, backgroundColor: colors.background, paddingHorizontal: 56, paddingVertical: 28},
  header: {flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 20},
  title: {fontSize: 42, fontWeight: '700', color: colors.text},
  subtitle: {fontSize: 23, lineHeight: 31, color: colors.secondary, marginVertical: 8},
  heading: {fontSize: 29, fontWeight: '600', color: colors.text, marginBottom: 14},
  text: {fontSize: 22, lineHeight: 30, color: colors.text},
  row: {flexDirection: 'row', flexWrap: 'wrap', gap: 14, alignItems: 'center'},
  section: {marginBottom: 26},
  error: {fontSize: 22, color: colors.danger, marginVertical: 12},
  panel: {backgroundColor: colors.panel, padding: 24, marginVertical: 12},
});
const styles = StyleSheet.create({
  action: {backgroundColor: colors.raised, paddingHorizontal: 24, paddingVertical: 16, borderWidth: 3, borderColor: 'transparent', marginVertical: 4},
  compactAction: {paddingHorizontal: 8, paddingVertical: 8},
  actionText: {color: colors.text, fontSize: 23, fontWeight: '600'},
  focused: {backgroundColor: colors.focus, borderColor: colors.focus, transform: [{scale: 1.025}]},
  selected: {borderColor: colors.accent}, disabled: {opacity: .4},
  fieldGroup: {marginBottom: 18}, label: {fontSize: 22, color: colors.secondary, marginBottom: 8},
  field: {fontSize: 24, color: colors.text, backgroundColor: colors.panel, borderWidth: 3, borderColor: 'transparent', padding: 16, minHeight: 62},
  fieldFocused: {borderColor: colors.accent},
  poster: {width: '100%', aspectRatio: 2 / 3, backgroundColor: colors.panel},
  largePoster: {width: 260}, placeholder: {flex: 1, alignItems: 'center', justifyContent: 'center'},
  posterLetter: {fontSize: 64, fontWeight: '600', color: '#667991'},
});
