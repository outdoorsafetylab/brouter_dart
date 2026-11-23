// Port of btools.codec.LinkedListContainer (BRouter v1.7.10, MIT).
import 'dart:typed_data';

/// A list of lists of integers.
class LinkedListContainer {
  Int32List _ia; // prev, data, prev, data, ...
  int _size = 0;
  final Int32List _startpointer; // 0=void, odd=head-data-cell
  int _listpointer = 0;

  /// A container for [nlists] lists. Without [defaultbuffer], an array of
  /// `nlists * 4` is made, holding 2 entries per list on average; a given
  /// buffer is replaced if it gets too small.
  LinkedListContainer(int nlists, Int32List? defaultbuffer)
    : _ia = defaultbuffer ?? Int32List(nlists * 4),
      _startpointer = Int32List(nlists);

  void addDataElement(int listNr, int data) {
    if (_size + 2 > _ia.length) {
      _resize();
    }
    _ia[_size++] = _startpointer[listNr];
    _startpointer[listNr] = _size;
    _ia[_size++] = data;
  }

  /// Initializes a list for reading and returns its number of entries.
  int initList(int listNr) {
    var cnt = 0;
    var lp = _listpointer = _startpointer[listNr];
    while (lp != 0) {
      lp = _ia[lp - 1];
      cnt++;
    }
    return cnt;
  }

  /// The next element of the list initialized last, in reverse order of
  /// adding (lifo).
  int getDataElement() {
    if (_listpointer == 0) {
      throw ArgumentError('no more element!');
    }
    final data = _ia[_listpointer];
    _listpointer = _ia[_listpointer - 1];
    return data;
  }

  void _resize() {
    final ia2 = Int32List(2 * _ia.length);
    ia2.setRange(0, _ia.length, _ia);
    _ia = ia2;
  }
}
