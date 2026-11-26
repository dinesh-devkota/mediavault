import React, {useState} from 'react';
import {Image, Pressable, StyleSheet, Text, View} from 'react-native';

const fixture = require('./fixture.png');
const swatch = {width: 140, height: 80, backgroundColor: '#e13741'};
const action = {width: 160, height: 64, justifyContent: 'center' as const, alignItems: 'center' as const,
  backgroundColor: '#273344', borderWidth: 3, borderColor: 'transparent'};

export function App() {
  const [plain, setPlain] = useState('waiting'), [clipped, setClipped] = useState('waiting');
  const [focused, setFocused] = useState('none');
  const imageResult = (id: string, value: string): void => {
    console.log('[render-probe] image', id, value);
    if (id === 'plain') { setPlain(value); } else { setClipped(value); }
  };
  const focus = (id: string): void => { console.log('[render-probe] focus', id); setFocused(id); };
  return <View style={styles.root}>
    <Text testID="probe-banner" style={styles.banner}>VIRTUAL DEVICE RENDER PROBE - no accounts or network</Text>
    <View style={styles.content}>
      <Text style={styles.heading}>Same color, different native paint paths</Text>
      <View style={styles.row}>
        <View style={styles.cell}><Text style={styles.label}>Object / square</Text>
          <View testID="swatch-square-object" style={styles.swatch}/></View>
        <View style={styles.cell}><Text style={styles.label}>Array / square</Text>
          <View testID="swatch-square-array" style={[styles.swatch]}/></View>
        <View style={styles.cell}><Text style={styles.label}>Object / round</Text>
          <View testID="swatch-round-object" style={styles.roundedSwatch}/></View>
        <View style={styles.cell}><Text style={styles.label}>Array / round clip</Text>
          <View testID="swatch-round-array" style={[styles.swatch, styles.roundedClip]}/></View>
      </View>
      <View style={styles.row}>
        <View style={styles.cell}><Text style={styles.label}>Bundled PNG</Text>
          <Image testID="image-plain" source={fixture} style={styles.image} resizeMode="stretch"
            onLoad={() => imageResult('plain', 'loaded')} onError={() => imageResult('plain', 'failed')}/></View>
        <View style={styles.cell}><Text style={styles.label}>Same PNG / clip</Text>
          <View testID="image-clip-parent" style={[styles.image, styles.roundedClip]}>
            <Image testID="image-clipped" source={fixture} style={styles.image} resizeMode="stretch"
              onLoad={() => imageResult('clipped', 'loaded')} onError={() => imageResult('clipped', 'failed')}/></View></View>
        <View style={styles.cell}><Text style={styles.label}>Round focus</Text>
          <Pressable testID="focus-round" role="button" aria-label="Round focus" hasTVPreferredFocus={false}
            onFocus={() => focus('round')} onBlur={() => setFocused('none')} onPress={() => console.log('[render-probe] round selected')}
            style={[styles.action, styles.rounded, focused === 'round' && styles.focused]}>
            <Text style={[styles.buttonText, focused === 'round' && styles.focusedText]}>Round</Text>
          </Pressable></View>
        <View style={styles.cell}><Text style={styles.label}>Square focus</Text>
          <Pressable testID="focus-square" role="button" aria-label="Square focus" hasTVPreferredFocus={false}
            onFocus={() => focus('square')} onBlur={() => setFocused('none')} onPress={() => console.log('[render-probe] square selected')}
            style={[styles.action, focused === 'square' && styles.focused]}>
            <Text style={[styles.buttonText, focused === 'square' && styles.focusedText]}>Square</Text>
          </Pressable></View>
      </View>
      <Text testID="image-status" style={styles.status}>Images: plain {plain}; clipped {clipped}</Text>
      <Text testID="focus-status" style={styles.status}>Focused: {focused}</Text>
    </View>
  </View>;
}
const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: '#10131a'},
  banner: {backgroundColor: '#ffd58a', color: '#231900', padding: 8, fontSize: 18, textAlign: 'center'},
  content: {paddingHorizontal: 28, paddingVertical: 16},
  heading: {fontSize: 26, color: '#f5f5f7', marginBottom: 16},
  row: {flexDirection: 'row', gap: 16, marginBottom: 22},
  cell: {width: 200}, label: {color: '#f5f5f7', fontSize: 20, marginBottom: 10},
  swatch, roundedSwatch: {...swatch, borderRadius: 13},
  rounded: {borderRadius: 13}, roundedClip: {borderRadius: 13, overflow: 'hidden'},
  image: {width: 140, height: 94}, action,
  focused: {backgroundColor: '#ffffff', borderColor: '#ffffff', transform: [{scale: 1.025}]},
  buttonText: {color: '#f5f5f7', fontSize: 23, fontWeight: '600'}, focusedText: {color: '#10131a'},
  status: {color: '#f5f5f7', fontSize: 20, marginVertical: 5},
});
