// Port of btools.expressions.CacheNode (BRouter v1.7.10, MIT).
part of 'expressions.dart';

/// A result-cache entry: a way description and the build-in variables it
/// evaluates to, forward then reverse.
final class CacheNode extends LruMapNode {
  Uint8List? ab;
  Float32List? vars;

  @override
  int get hashCode => hash;

  @override
  bool operator ==(Object other) {
    final n = other as CacheNode;
    if (hash != n.hash) return false;
    final a = ab;
    if (a == null) return true; // hack: null = crc match only
    return _bytesEqual(a, n.ab);
  }
}

// Arrays.equals(byte[], byte[]).
bool _bytesEqual(Uint8List a, Uint8List? b) {
  if (identical(a, b)) return true;
  if (b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
