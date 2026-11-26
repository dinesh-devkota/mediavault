import {GridFocusPort, GridFocusRestoration} from '../src/ui/GridFocus';

const groups = Array.from({length: 180}, (_, index) => ({id: `poster-${index}`}));
const port = (): jest.Mocked<GridFocusPort> => ({scrollToOffset: jest.fn(), scrollToRow: jest.fn(), requestFocus: jest.fn()});

describe('remote poster focus restoration', () => {
  beforeEach(() => jest.useFakeTimers());
  afterEach(() => { jest.clearAllTimers(); jest.useRealTimers(); });

  it('restores an offscreen poster at its real saved offset only after it becomes viewable', () => {
    const native = port(), restore = new GridFocusRestoration(groups, {id: 'poster-145', index: 145, offset: 10480});
    restore.start(native);
    expect(native.scrollToOffset).toHaveBeenCalledWith(10480);
    restore.tileReady('poster-145');
    expect(native.requestFocus).not.toHaveBeenCalled();
    restore.viewable(['poster-144', 'poster-145', 'poster-146']);
    expect(native.requestFocus).toHaveBeenCalledWith('poster-145');
    expect(restore.preferredID).toBe('poster-145'); // Request alone does not acknowledge native focus.
    restore.focused('poster-145');
    const count = native.requestFocus.mock.calls.length;
    restore.update(groups.map(group => ({...group})));
    restore.viewable(['poster-144', 'poster-145']); restore.tileReady('poster-145');
    jest.advanceTimersByTime(5000);
    expect(native.requestFocus).toHaveBeenCalledTimes(count);
    expect(restore.preferredID).toBeUndefined();
  });

  it('uses multi-column ROW indices after a reorder and recovers an unmeasured row', () => {
    const reordered = [...groups.slice(12), ...groups.slice(0, 12)];
    const native = port(), restore = new GridFocusRestoration(reordered, {id: 'poster-145', index: 145, offset: 10480});
    restore.start(native);
    expect(native.scrollToRow).toHaveBeenCalledWith(22); // New item133 /6; never item133 as a row.
    expect(native.scrollToOffset).not.toHaveBeenCalled();
    restore.scrollFailed(22, 432);
    expect(native.scrollToOffset).toHaveBeenCalledWith(9504);
    restore.scrollFailed(133, 432); restore.scrollFailed(22, Number.NaN);
    expect(native.scrollToOffset).toHaveBeenCalledTimes(1);
    restore.viewable(['poster-145']); restore.focused('poster-145');
    expect(native.requestFocus).toHaveBeenCalledWith('poster-145');
  });

  it('falls back to the first currently visible group after removal or filtering', () => {
    const remaining = groups.slice(1, 4), native = port();
    const restore = new GridFocusRestoration(remaining, {id: 'poster-145', index: 145, offset: 10480});
    restore.start(native); restore.viewable(remaining.map(group => group.id));
    expect(native.scrollToOffset).toHaveBeenCalledWith(0);
    expect(native.requestFocus).toHaveBeenCalledWith('poster-1');
    expect(native.requestFocus).not.toHaveBeenCalledWith('poster-145');
  });

  it('rechecks visibility when a source is removed while the grid is still mounting', () => {
    const native = port(), restore = new GridFocusRestoration(groups, {id: 'poster-145', index: 145, offset: 10480});
    restore.start(native); restore.update(groups.slice(0, 2));
    restore.viewable(['poster-145']); restore.tileReady('poster-145');
    expect(native.requestFocus).not.toHaveBeenCalled();
    restore.viewable(['poster-0']);
    expect(native.requestFocus).toHaveBeenCalledWith('poster-0');
  });

  it('never resumes a cancelled session or competes with a new remote action', () => {
    const native = port(), restore = new GridFocusRestoration(groups, {id: 'poster-145', index: 145, offset: 10480});
    restore.start(native); restore.cancel();
    restore.start(native); restore.viewable(['poster-145']); restore.tileReady('poster-145');
    restore.scrollFailed(24, 400); restore.update(groups);
    jest.advanceTimersByTime(5000);
    expect(native.requestFocus).not.toHaveBeenCalled();
    expect(native.scrollToOffset).toHaveBeenCalledTimes(1);
    expect(native.scrollToRow).not.toHaveBeenCalled();
    const nextSession = new GridFocusRestoration(groups);
    expect(nextSession.preferredID).toBe('poster-0');
  });

  it('keeps Home and collection anchors independent and makes no empty-grid requests', () => {
    const home = new GridFocusRestoration(groups, {id: 'poster-145', index: 145, offset: 10480});
    const collection = new GridFocusRestoration(groups.slice(1, 4), {id: 'poster-2', index: 1, offset: 0});
    expect(home.preferredID).toBe('poster-145'); expect(collection.preferredID).toBe('poster-2');
    const native = port(), empty = new GridFocusRestoration([], {id: 'poster-145', index: 145, offset: 10480});
    empty.start(native); jest.advanceTimersByTime(5000);
    expect(native.requestFocus).not.toHaveBeenCalled(); expect(native.scrollToRow).not.toHaveBeenCalled();
    expect(native.scrollToOffset).not.toHaveBeenCalled();
  });

  it('bounds unsuccessful native restoration instead of repeatedly stealing focus', () => {
    const native = port(), restore = new GridFocusRestoration(groups, {id: 'poster-145', index: 145, offset: 10480});
    restore.start(native); jest.advanceTimersByTime(10000);
    expect(native.scrollToRow.mock.calls.length).toBeLessThanOrEqual(19);
    expect(jest.getTimerCount()).toBe(0);
    restore.viewable(['poster-145']);
    expect(native.requestFocus).not.toHaveBeenCalled();
  });

  it('focuses the first poster when a first scan populates the already mounted empty Home', () => {
    const native = port(), restore = new GridFocusRestoration([]);
    restore.start(native); restore.update([]); restore.viewable([]);
    jest.advanceTimersByTime(5000);
    expect(native.scrollToOffset).not.toHaveBeenCalled();
    restore.update(groups); restore.viewable(['poster-0']);
    expect(native.scrollToOffset).toHaveBeenCalledWith(0);
    expect(native.requestFocus).toHaveBeenCalledWith('poster-0');
    restore.focused('poster-0');
    expect(jest.getTimerCount()).toBe(0);
  });

  it('does not steal focus when scan results arrive after a user navigated from empty Home', () => {
    const native = port(), restore = new GridFocusRestoration([]);
    restore.start(native); restore.cancel();
    restore.update(groups); restore.viewable(['poster-0']); restore.tileReady('poster-0');
    jest.advanceTimersByTime(5000);
    expect(native.scrollToOffset).not.toHaveBeenCalled();
    expect(native.requestFocus).not.toHaveBeenCalled();
    expect(restore.preferredID).toBeUndefined();
  });
});
