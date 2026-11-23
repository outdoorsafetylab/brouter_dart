// Java float semantics on Dart's 64-bit double (`docs/design.md` D4). A float-valued
// double rounded with [fround] after every operation gives the same bits as
// Java float arithmetic: + − × ÷ on two floats, done in double and rounded
// once, are exact to Float32. Also Float.parseFloat and Float.toString, which
// a double round trip would get wrong in rare cases.
import 'dart:typed_data';

import 'java_string.dart';

final _f32 = Float32List(1);
final _u32 = Uint32List.view(_f32.buffer);

/// Rounds [x] to the nearest Java float (ties to even).
double fround(double x) {
  _f32[0] = x;
  return _f32[0];
}

/// Java `Float.floatToRawIntBits(x)` as an unsigned 32-bit value.
int floatToRawIntBits(double x) {
  _f32[0] = x;
  return _u32[0];
}

/// Java `Float.floatToIntBits(x)`: like the raw bits, with every NaN as
/// 0x7fc00000. Arrays.equals and Arrays.hashCode on float[] use this.
int floatToIntBits(double x) => x.isNaN ? 0x7fc00000 : floatToRawIntBits(x);

/// Java `Float.intBitsToFloat(bits)`.
double intBitsToFloat(int bits) {
  _u32[0] = bits;
  return _f32[0];
}

final _decimal = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?[fFdD]?$');
final _hex = RegExp(r'^([+-]?)0[xX]([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?[pP]([+-]?\d+)[fFdD]?$');
final _special = RegExp(r'^([+-]?)(NaN|Infinity)$');

/// Java `Float.parseFloat(s)`: the Java grammar (sign, decimal or hex,
/// optional f/F/d/D suffix, NaN, Infinity, surrounding chars <= ' '
/// ignored), rounded once, exactly, from the decimal to float. Throws
/// [FormatException] where Java throws NumberFormatException.
double javaParseFloat(String s) {
  final t = javaTrim(s);
  var m = _special.firstMatch(t);
  if (m != null) {
    if (m[2] == 'NaN') return double.nan;
    return m[1] == '-' ? double.negativeInfinity : double.infinity;
  }
  m = _decimal.firstMatch(t);
  if (m != null) {
    final intPart = m[2]!, frac = m[3] ?? '';
    if (intPart.isEmpty && frac.isEmpty) throw FormatException('not a float', s);
    final exp = _clampedExponent(m[4]);
    final v = _decimalToFloat(BigInt.parse(intPart + frac), exp - frac.length);
    return m[1] == '-' ? -v : v;
  }
  m = _hex.firstMatch(t);
  if (m != null) {
    final intPart = m[2]!, frac = m[3] ?? '';
    if (intPart.isEmpty && frac.isEmpty) throw FormatException('not a float', s);
    final exp = _clampedExponent(m[4]);
    final mant = BigInt.parse('0${intPart + frac}', radix: 16);
    final v = _binaryToFloat(mant, exp - 4 * frac.length);
    return m[1] == '-' ? -v : v;
  }
  throw FormatException('not a float', s);
}

// Exponents this large make the value 0 or infinite whatever the digits are
// (up to a billion of them), so they need not be exact.
int _clampedExponent(String? e) {
  if (e == null) return 0;
  final neg = e.startsWith('-');
  final digits = e.replaceFirst(RegExp(r'^[+-]'), '').replaceFirst(RegExp(r'^0+'), '');
  final v = digits.length > 9 ? 1000000000 : (digits.isEmpty ? 0 : int.parse(digits));
  return neg ? -v : v;
}

final _ten = BigInt.from(10);
final _two24 = BigInt.one << 24;
final _two23 = BigInt.one << 23;

/// mant × 10^exp, mant >= 0, rounded to the nearest float.
double _decimalToFloat(BigInt mant, int exp) {
  if (mant == BigInt.zero) return 0.0;
  final nd = mant.toString().length;
  if (nd + exp > 40) return double.infinity; // >= 1e39
  if (nd + exp < -46) return 0.0; // < 1e-46, under half the least subnormal
  return exp >= 0 ? _ratioToFloat(mant * _ten.pow(exp), BigInt.one) : _ratioToFloat(mant, _ten.pow(-exp));
}

/// mant × 2^exp, mant >= 0, rounded to the nearest float.
double _binaryToFloat(BigInt mant, int exp) {
  if (mant == BigInt.zero) return 0.0;
  final top = mant.bitLength + exp; // value < 2^top
  if (top > 129) return double.infinity;
  if (top < -151) return 0.0;
  return exp >= 0 ? _ratioToFloat(mant << exp, BigInt.one) : _ratioToFloat(mant, BigInt.one << -exp);
}

/// num / den (both > 0) rounded to the nearest float, ties to even.
double _ratioToFloat(BigInt num, BigInt den) {
  // value = q × 2^-s with 2^23 <= q < 2^24, or a subnormal with s = 149
  var s = 23 - (num.bitLength - den.bitLength);
  BigInt quotient(int s) => s >= 0 ? (num << s) ~/ den : num ~/ (den << -s);
  var q = quotient(s);
  while (q >= _two24) {
    s--;
    q = quotient(s);
  }
  while (q < _two23) {
    s++;
    q = quotient(s);
  }
  if (s > 149) {
    s = 149;
    q = quotient(s);
  }
  final scaledNum = s >= 0 ? num << s : num;
  final scaledDen = s >= 0 ? den : den << -s;
  final twiceRem = (scaledNum - q * scaledDen) * BigInt.two;
  if (twiceRem > scaledDen || (twiceRem == scaledDen && q.isOdd)) q += BigInt.one;
  if (q == _two24) {
    q = _two23;
    s--;
  }
  if (23 - s > 127) return double.infinity;
  return q.toInt() * _pow2(-s);
}

final _pow2Bits = ByteData(8);

// 2^n as a double, n in the double's normal range.
double _pow2(int n) {
  _pow2Bits.setUint32(0, (1023 + n) << 20);
  _pow2Bits.setUint32(4, 0);
  return _pow2Bits.getFloat64(0);
}

/// Java `Float.toString(f)` as of JDK 19 and later (the golden side runs
/// JDK 21): the shortest decimal that parses back to [f], the closest one
/// among those (ties to the even digit), with at least two digits when one
/// would do; plain notation for 1e-3 <= |f| < 1e7, otherwise d.dddE±n.
String javaFloatToString(double f) {
  f = fround(f);
  if (f.isNaN) return 'NaN';
  if (f.isInfinite) return f > 0 ? 'Infinity' : '-Infinity';
  if (f == 0) return (1 / f) < 0 ? '-0.0' : '0.0';
  final sign = f < 0 ? '-' : '';
  final v = f.abs();

  // v exactly, as num / den
  final bits = floatToRawIntBits(v);
  final be = (bits >> 23) & 0xff;
  final sig = be == 0 ? bits & 0x7fffff : (bits & 0x7fffff) | 0x800000;
  final e2 = (be == 0 ? 1 : be) - 150;
  final num = e2 >= 0 ? BigInt.from(sig) << e2 : BigInt.from(sig);
  final den = e2 >= 0 ? BigInt.one : BigInt.one << -e2;

  // k = floor(log10(v))
  var k = _floorLog10(v); // an estimate, fixed exactly below
  BigInt p10(int n) => _ten.pow(n);
  bool ge10k(int k) => k >= 0 ? num >= p10(k) * den : num * p10(-k) >= den;
  while (!ge10k(k)) {
    k--;
  }
  while (ge10k(k + 1)) {
    k++;
  }

  for (var n = 2; n <= 9; n++) {
    // candidates c × 10^q with n digits around v
    final q = k - n + 1;
    final sn = q >= 0 ? num : num * p10(-q);
    final sd = q >= 0 ? den * p10(q) : den;
    final lo = sn ~/ sd;
    final rem = sn - lo * sd; // v = (lo + rem/sd) × 10^q
    final hits = <(BigInt, BigInt)>[]; // (c, twice the distance × sd)
    for (final c in rem == BigInt.zero ? [lo] : [lo, lo + BigInt.one]) {
      if (_decimalToFloat(c, q) == v) hits.add((c, ((c * sd) - sn).abs() * BigInt.two));
    }
    if (hits.isEmpty) continue;
    var best = hits[0];
    if (hits.length == 2 && (hits[1].$2 < best.$2 || (hits[1].$2 == best.$2 && hits[1].$1.isEven))) best = hits[1];
    return sign + _format(best.$1, q);
  }
  throw StateError('no shortest decimal for $f'); // 9 digits always suffice
}

int _floorLog10(double v) {
  var k = 0;
  while (v >= 10) {
    v /= 10;
    k++;
  }
  while (v < 1) {
    v *= 10;
    k--;
  }
  return k;
}

// c × 10^q in Java's notation.
String _format(BigInt c, int q) {
  var digits = c.toString();
  while (digits.length > 1 && digits.endsWith('0')) {
    digits = digits.substring(0, digits.length - 1);
    q++;
  }
  final exp10 = q + digits.length - 1; // position of the leading digit
  if (exp10 >= -3 && exp10 < 7) {
    if (exp10 < 0) return '0.${'0' * (-exp10 - 1)}$digits';
    final intLen = exp10 + 1;
    if (digits.length <= intLen) return '${digits.padRight(intLen, '0')}.0';
    return '${digits.substring(0, intLen)}.${digits.substring(intLen)}';
  }
  final frac = digits.length > 1 ? digits.substring(1) : '0';
  return '${digits[0]}.${frac}E$exp10';
}
