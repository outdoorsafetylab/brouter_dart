// The two util classes with no numeric output to compare against Java:
// their contract is checked directly.
import 'dart:typed_data';

import 'package:brouter/src/util/byte_array_unifier.dart';
import 'package:brouter/src/util/lru_map.dart';
import 'package:test/test.dart';

class _Node extends LruMapNode {
  final int key;
  _Node(this.key) {
    hash = key * 31;
  }
  @override
  bool operator ==(Object other) => other is _Node && other.key == key;
  @override
  int get hashCode => hash;
}

void main() {
  test('LruMap evicts least recently used first, touch refreshes', () {
    final m = LruMap(4, 3); // 4 bins, one key in each
    final nodes = [for (var k = 0; k < 3; k++) _Node(k)];
    expect(
      {
        for (final n in [...nodes, _Node(7)]) (n.hash & 0xfffffff) % 4,
      }.length,
      4,
      reason: 'this case spreads over bins',
    );
    for (final n in nodes) {
      expect(m.removeLru(), isNull, reason: 'not full yet');
      m.put(n);
    }
    m.touch(nodes[0]); // order now 1, 2, 0
    expect(m.get(_Node(1)), same(nodes[1]));
    expect(identical(m.removeLru(), nodes[1]), isTrue);
    expect(m.get(_Node(1)), isNull, reason: 'evicted entry left its bin');
    m.put(_Node(7));
    expect(identical(m.removeLru(), nodes[2]), isTrue);
    expect(m.get(_Node(0)), same(nodes[0]));
    expect(m.get(_Node(7)), isNotNull);
  });

  test('LruMap finds and removes entries deep in a shared bin', () {
    final m = LruMap(4, 3);
    final nodes = [_Node(0), _Node(4), _Node(8)]; // 31·k: all in bin 0
    expect({for (final n in nodes) (n.hash & 0xfffffff) % 4}, {0});
    for (final n in nodes) {
      m.put(n);
    }
    // the bin chain is 8 → 4 → 0, so the lru (0) is its last node
    for (final n in nodes) {
      expect(m.get(_Node(n.key)), same(n));
    }
    m.touch(nodes[0]); // lru order now 4, 8, 0: 4 is in the middle of the chain
    expect(identical(m.removeLru(), nodes[1]), isTrue);
    expect(m.get(_Node(4)), isNull);
    expect(m.get(_Node(8)), same(nodes[2]));
    expect(m.get(_Node(0)), same(nodes[0]));
    m.put(_Node(12)); // bin 0 again, at the head
    expect(identical(m.removeLru(), nodes[2]), isTrue);
    expect(m.get(_Node(0)), same(nodes[0]));
    expect(m.get(_Node(12)), isNotNull);
  });

  test('ByteArrayUnifier returns equal content and reuses the instance', () {
    final u = ByteArrayUnifier(16, true);
    final src = Uint8List.fromList([9, 1, 2, 3, 9]);
    final a = u.unify(src, 1, 3);
    expect(a, [1, 2, 3]);
    final b = u.unify(Uint8List.fromList([1, 2, 3]), 0, 3);
    expect(identical(a, b), isTrue);
    src[2] = 7; // the source may change; the unified copy may not
    expect(a, [1, 2, 3]);
    a[0] = 5; // mutating a cached array is caught on the next miss in its bin
    var detected = false;
    for (var i = 0; i < 200 && !detected; i++) {
      try {
        u.unify(Uint8List.fromList([i, i, i, i]), 0, 4);
      } on ArgumentError {
        detected = true;
      }
    }
    expect(detected, isTrue);
  });
}
