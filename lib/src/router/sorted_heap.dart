// Port of btools.util.SortedHeap (BRouter v1.7.10, MIT): the open set of the
// path search. Ported structure for structure, because the order in which
// equal keys come out decides between equally cheap paths.
part of 'router.dart';

final class SortedHeap<V extends Object> {
  int _size = 0;
  int _peaksize = 0;
  late _SortedBin _first;
  late _SortedBin _second;
  _SortedBin? _firstNonEmpty;

  SortedHeap() {
    clear();
  }

  /// The value with the lowest key, removed; null when empty.
  V? popLowestKeyValue() {
    final bin = _firstNonEmpty;
    if (bin == null) return null;
    _size--;
    return bin.getMinBin().dropLowest() as V?;
  }

  void add(int key, V value) {
    _size++;
    if (_first.lp == 0 && _second.lp == 0) {
      // both full
      _sortUp();
    }
    if (_first.lp > 0) {
      _first.add4(key, value);
      if (!identical(_firstNonEmpty, _first)) {
        _first.nextNonEmpty = _firstNonEmpty;
        _firstNonEmpty = _first;
      }
    } else {
      // second bin not full
      _second.add4(key, value);
      if (!identical(_first.nextNonEmpty, _second)) {
        _second.nextNonEmpty = _first.nextNonEmpty;
        _first.nextNonEmpty = _second;
      }
    }
  }

  void _sortUp() {
    if (_size > _peaksize) _peaksize = _size;

    // determine the wanted target bin
    var cnt = 8; // value count of first 2 bins is always 8
    var tbin = _second; // target bin
    var lastNonEmpty = _second;
    do {
      tbin = tbin.nextBin();
      final nentries = tbin.binsize - tbin.lp;
      if (nentries > 0) {
        cnt += nentries;
        lastNonEmpty = tbin;
      }
    } while (cnt > tbin.binsize);

    final alT = tbin.al;
    final vlaT = tbin.vla;
    var tp = tbin.binsize - cnt; // target pointer

    // unlink any higher, non-empty arrays
    final otherNonEmpty = lastNonEmpty.nextNonEmpty;
    lastNonEmpty.nextNonEmpty = null;

    // now merge the content of these non-empty bins into the target bin
    while (_firstNonEmpty != null) {
      final minBin = _firstNonEmpty!.getMinBin();
      alT[tp] = minBin.lv;
      vlaT[tp++] = minBin.dropLowest();
    }

    tp = tbin.binsize - cnt;
    tbin.lp = tp; // new target low pointer
    tbin.lv = tbin.al[tp];
    tbin.nextNonEmpty = otherNonEmpty;
    _firstNonEmpty = tbin;
  }

  void clear() {
    _size = 0;
    _first = _SortedBin(4, this);
    _second = _SortedBin(4, this);
    _firstNonEmpty = null;
  }

  int getSize() => _size;

  int getPeakSize() => _peaksize;
}

final class _SortedBin {
  final SortedHeap _parent;
  _SortedBin? _next;
  _SortedBin? nextNonEmpty;
  final int binsize;
  final Int32List al; // key array
  final List<Object?> vla; // value array
  int lv = 0; // low value
  int lp; // low pointer

  _SortedBin(this.binsize, this._parent)
      : al = Int32List(binsize),
        vla = List<Object?>.filled(binsize, null),
        lp = binsize;

  _SortedBin nextBin() => _next ??= _SortedBin(binsize << 1, _parent);

  Object? dropLowest() {
    final lpOld = lp;
    if (++lp == binsize) {
      _unlink();
    } else {
      lv = al[lp];
    }
    final res = vla[lpOld];
    vla[lpOld] = null;
    return res;
  }

  void _unlink() {
    var neBin = _parent._firstNonEmpty!;
    if (identical(neBin, this)) {
      _parent._firstNonEmpty = nextNonEmpty;
      return;
    }
    for (;;) {
      final next = neBin.nextNonEmpty!;
      if (identical(next, this)) {
        neBin.nextNonEmpty = nextNonEmpty;
        return;
      }
      neBin = next;
    }
  }

  void add4(int key, Object value) {
    var p = lp--;
    if (p == 4 || key < al[p]) {
      lv = al[p - 1] = key;
      vla[p - 1] = value;
      return;
    }
    lv = al[p - 1] = al[p];
    vla[p - 1] = vla[p];
    p++;
    if (p == 4 || key < al[p]) {
      al[p - 1] = key;
      vla[p - 1] = value;
      return;
    }
    al[p - 1] = al[p];
    vla[p - 1] = vla[p];
    p++;
    if (p == 4 || key < al[p]) {
      al[p - 1] = key;
      vla[p - 1] = value;
      return;
    }
    al[p - 1] = al[p];
    vla[p - 1] = vla[p];
    al[p] = key;
    vla[p] = value;
  }

  // Java unrolls this over the at most 32 bins; the first bin with the
  // strictly lowest low value wins.
  _SortedBin getMinBin() {
    var minBin = this;
    var bin = nextNonEmpty;
    while (bin != null) {
      if (bin.lv < minBin.lv) minBin = bin;
      bin = bin.nextNonEmpty;
    }
    return minBin;
  }
}
