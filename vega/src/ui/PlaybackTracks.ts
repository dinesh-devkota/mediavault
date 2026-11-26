import type {TextTrack} from '@amazon-devices/react-native-w3cmedia';

type SubtitleTrack = Pick<TextTrack, 'id' | 'mode'>;

export class SubtitleSelection {
  // Undefined accepts the decoder's initial choice; null is an explicit Off.
  // Track IDs remain stable when late embedded tracks or sidecars are added.
  private selectedID: string | null | undefined;
  private disabled = new WeakSet<SubtitleTrack>();

  select(tracks: readonly (SubtitleTrack | undefined)[], id: string | null): void {
    this.selectedID = id;
    this.reconcile(tracks);
  }

  preferLocal(tracks: readonly (SubtitleTrack | undefined)[], id: string): void {
    if (this.selectedID === undefined) { this.selectedID = id; }
    this.reconcile(tracks);
  }

  reconcile(tracks: readonly (SubtitleTrack | undefined)[]): void {
    if (this.selectedID === undefined) { return; }
    // Stop every other renderer before enabling the chosen track. Native modes
    // are read again because a later SDK addtrack event can choose a default.
    for (const track of tracks) {
      if (!track || track.id === this.selectedID) { continue; }
      const mode = track.mode;
      // A removed native ID can outlive its entry in the JS list until the
      // removetrack event arrives. Keep the preference, but do not command it.
      if (mode == null) { continue; }
      if (mode === 'disabled' || (mode === 'hidden' && this.disabled.has(track))) { continue; }
      // The pinned SDK only forwards "hidden" to its embedded decoder;
      // "disabled" alone changes its JS cache. Local cues also need removal.
      if (mode !== 'hidden') { track.mode = 'hidden'; }
      track.mode = 'disabled';
      this.disabled.add(track);
    }
    const selected = tracks.find(track => track?.id === this.selectedID);
    if (selected) {
      this.disabled.delete(selected);
      const mode = selected.mode;
      if (mode != null && mode !== 'showing') { selected.mode = 'showing'; }
    }
  }
}
