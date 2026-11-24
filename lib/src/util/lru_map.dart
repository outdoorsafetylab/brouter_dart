// Port of btools.util.LruMap and LruMapNode (BRouter v1.7.10, MIT).

/// An entry of [LruMap]. Subclasses define `==` and `hashCode` the way the
/// Java subclasses define equals and hashCode; [hash] is what [LruMap.get]
/// bins the probe key by.
abstract class LruMapNode {
  LruMapNode? nextInBin; // next entry in the hash bin
  LruMapNode? next; // next in lru order (towards mru)
  LruMapNode? previous; // previous in lru order (towards lru)
  int hash = 0;
}

/// Something like LinkedHashMap, purpose-built: fixed bins, the caller
/// recycles evicted entries.
class LruMap {
  final int _hashbins;
  final int _maxsize;
  int _size = 0;
  LruMapNode? _lru;
  LruMapNode? _mru;
  final List<LruMapNode?> _binArray;

  LruMap(int bins, int size)
      : _hashbins = bins,
        _maxsize = size,
        _binArray = List<LruMapNode?>.filled(bins, null);

  LruMapNode? get(LruMapNode key) {
    final bin = (key.hash & 0xfffffff) % _hashbins;
    var e = _binArray[bin];
    while (e != null) {
      if (key == e) return e;
      e = e.nextInBin;
    }
    return null;
  }

  /// Moves [e] to the mru end.
  void touch(LruMapNode e) {
    final n = e.next;
    final p = e.previous;
    if (n == null) return; // already at mru
    n.previous = p;
    if (p != null) {
      p.next = n;
    } else {
      _lru = n;
    }
    _mru!.next = e;
    e.previous = _mru;
    e.next = null;
    _mru = e;
  }

  /// The lru entry, unlinked, once the map is full; otherwise null.
  LruMapNode? removeLru() {
    if (_size < _maxsize) return null;
    _size--;
    final lru = _lru!;
    final bin = (lru.hashCode & 0xfffffff) % _hashbins;
    var e = _binArray[bin];
    if (identical(e, lru)) {
      _binArray[bin] = lru.nextInBin;
    } else {
      while (e != null) {
        final prev = e;
        e = e.nextInBin;
        if (identical(e, lru)) {
          prev.nextInBin = lru.nextInBin;
          break;
        }
      }
    }
    _lru = lru.next;
    _lru!.previous = null;
    return lru;
  }

  void put(LruMapNode val) {
    final bin = (val.hashCode & 0xfffffff) % _hashbins;
    val.nextInBin = _binArray[bin];
    _binArray[bin] = val;
    val.previous = _mru;
    val.next = null;
    if (_mru == null) {
      _lru = val;
    } else {
      _mru!.next = val;
    }
    _mru = val;
    _size++;
  }
}
