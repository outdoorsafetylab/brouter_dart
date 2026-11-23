// Port of btools.expressions.VarWrapper (BRouter v1.7.10, MIT).
part of 'expressions.dart';

/// A set of result variables, so equal sets share one array.
final class VarWrapper extends LruMapNode {
  Float32List? vars;

  @override
  int get hashCode => hash;

  @override
  bool operator ==(Object other) {
    final n = other as VarWrapper;
    if (hash != n.hash) return false;
    return _floatsEqual(vars, n.vars);
  }
}

// Arrays.equals(float[], float[]): compares floatToIntBits, so NaN equals
// NaN and 0.0 differs from -0.0.
bool _floatsEqual(Float32List? a, Float32List? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (floatToIntBits(a[i]) != floatToIntBits(b[i])) return false;
  }
  return true;
}

// Arrays.hashCode(float[]).
int _floatsHash(Float32List a) {
  var h = 1;
  for (var i = 0; i < a.length; i++) {
    h = i32(31 * h + floatToIntBits(a[i]));
  }
  return h;
}
