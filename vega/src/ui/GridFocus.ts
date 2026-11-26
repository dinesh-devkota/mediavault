export interface GridFocusAnchor { id: string; index: number; offset: number }
interface FocusTarget { id: string; index: number; offset?: number }
export interface GridFocusPort {
  scrollToOffset: (offset: number) => void;
  scrollToRow: (index: number) => void;
  requestFocus: (id: string) => void;
}

// Route anchors live only in their household session. This helper restores a
// remounted grid; it must not become a permanent preferred-focus loop.
export class GridFocusRestoration {
  private target?: FocusTarget;
  private port?: GridFocusPort;
  private visible = new Set<string>();
  private timer?: ReturnType<typeof setTimeout>;
  private attempts = 0;
  private finished = false;

  constructor(groups: ReadonlyArray<{id: string}>, anchor?: GridFocusAnchor, private readonly columns = 6) {
    const index = anchor ? groups.findIndex(group => group.id === anchor.id) : -1;
    this.target = index >= 0 ? {id: groups[index]!.id, index,
      offset: index === anchor!.index && Number.isFinite(anchor!.offset) ? Math.max(0, anchor!.offset) : undefined}
      : groups[0] ? {id: groups[0].id, index: 0, offset: 0} : undefined;
  }

  get preferredID(): string | undefined { return this.finished ? undefined : this.target?.id; }

  start(port: GridFocusPort): void {
    if (this.port || this.finished) { return; }
    this.port = port; this.restore();
  }

  update(groups: ReadonlyArray<{id: string}>): void {
    if (this.finished) { return; }
    const index = groups.findIndex(group => group.id === this.target?.id);
    if (index < 0) {
      this.target = groups[0] ? {id: groups[0].id, index: 0, offset: 0} : undefined;
      this.attempts = 0;
      this.clearTimer();
      // An initially empty scan may populate this same grid. Waiting for data
      // is different from cancellation after a person has navigated elsewhere.
      if (this.target && this.port) { this.restore(); }
    } else if (this.target && index !== this.target.index) {
      this.target = {...this.target, index, offset: undefined};
      this.clearTimer();
      if (this.port) { this.restore(); }
    }
  }

  viewable(ids: string[]): void { this.visible = new Set(ids); this.requestIfVisible(); }
  tileReady(id: string): void { if (id === this.target?.id) { this.requestIfVisible(); } }
  focused(id: string): void { if (id === this.target?.id) { this.cancel(); } }

  scrollFailed(index: number, averageItemLength: number): void {
    if (this.finished || !this.target || index !== Math.floor(this.target.index / this.columns)
      || !Number.isFinite(averageItemLength) || averageItemLength <= 0) { return; }
    // SDK unmeasured-row recovery; viewability, not mounting alone, permits focus.
    this.port?.scrollToOffset(index * averageItemLength);
  }

  cancel(): void {
    this.finished = true;
    this.clearTimer();
    this.port = undefined; this.visible.clear();
  }

  private clearTimer(): void {
    if (this.timer !== undefined) { clearTimeout(this.timer); this.timer = undefined; }
  }

  private requestIfVisible(): void {
    if (!this.finished && this.target && this.visible.has(this.target.id)) { this.port?.requestFocus(this.target.id); }
  }

  private restore = (): void => {
    this.timer = undefined;
    if (this.finished || !this.target || !this.port) { return; }
    if (this.attempts++ >= 20) { this.cancel(); return; }
    if (!this.visible.has(this.target.id)) {
      if (this.attempts === 1 && this.target.offset !== undefined) { this.port.scrollToOffset(this.target.offset); }
      else { this.port.scrollToRow(Math.floor(this.target.index / this.columns)); }
    }
    this.requestIfVisible();
    // VirtualizedList needs a rendering turn after scrolling an unmeasured row.
    // Remote input, focus acknowledgement, and unmount all cancel this bound.
    if (!this.finished) { this.timer = setTimeout(this.restore, 100); }
  };
}
