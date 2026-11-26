import React, {useEffect, useState} from 'react';
import {Image, StyleSheet, Text, View} from 'react-native';
import {MediaItem, PlaybackResource} from '../domain/model';
import {Action, shared} from './Controls';

export function PhotoViewer({item, load, previous, next, onClose}: {item: MediaItem; load: () => Promise<PlaybackResource>; previous?: () => void; next?: () => void; onClose: () => void}) {
  const [image, setImage] = useState<{id: string; resource: PlaybackResource}>();
  const [error, setError] = useState<string>();
  const [slideshow, setSlideshow] = useState(false);
  const [displayed, setDisplayed] = useState<string>();
  useEffect(() => {
    let active = true, owned: PlaybackResource | undefined; setError(undefined);
    load().then(resource => {
      if (active) { owned = resource; setImage({id: item.id, resource}); }
      else { void resource.release?.().catch(() => {}); }
    }).catch(() => { if (active) { setError('This photo could not be opened. Check the source connection and try again.'); } });
    return () => { active = false; void owned?.release?.().catch(() => {}); };
  }, [item.id, load]);
  useEffect(() => {
    if (!slideshow || !next) { return; }
    const timer = setTimeout(next, 6000);
    return () => clearTimeout(timer);
  }, [slideshow, item.id, next]);
  return <View style={styles.page}>
    {image?.id === item.id && <Image source={{uri: image.resource.uri, headers: image.resource.headers}} style={StyleSheet.absoluteFill} resizeMode="contain" aria-label={item.title}
      testID={displayed === item.id ? 'photo-loaded' : 'photo-loading'} onLoad={() => setDisplayed(item.id)} onError={() => setError('This photo format could not be displayed on this device.')}/>}
    <View style={styles.footer}><Text style={shared.heading}>{item.title}</Text>{error && <Text style={shared.error}>{error}</Text>}
      {!error && displayed !== item.id && <Text style={shared.subtitle}>Opening photo…</Text>}
      <View style={shared.row}><Action label="Back" preferred onPress={onClose}/><Action label="Previous photo" disabled={!previous} onPress={() => previous?.()}/>
        <Action label={slideshow ? 'Pause slideshow' : 'Start slideshow'} onPress={() => setSlideshow(!slideshow)}/><Action label="Next photo" disabled={!next} onPress={() => next?.()}/></View>
    </View>
  </View>;
}
const styles = StyleSheet.create({page: {flex: 1, backgroundColor: '#000'}, footer: {position: 'absolute', left: 40, right: 40, bottom: 20, padding: 20, backgroundColor: '#10131add'}});
