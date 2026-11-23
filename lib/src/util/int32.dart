// Java int arithmetic on Dart's 64-bit int. Java masks shift counts to five
// bits and wraps every result to 32 bits; these helpers do the same, so a
// ported expression keeps its Java meaning.

/// Java `(int) x`: wraps to a signed 32-bit value.
int i32(int x) => x.toSigned(32);

/// Java `x << n` on an int.
int shl(int x, int n) => (x << (n & 31)).toSigned(32);

/// Java `x >> n` on an int.
int sar(int x, int n) => x.toSigned(32) >> (n & 31);

/// Java `x >>> n` on an int.
int ushr(int x, int n) => ((x & 0xffffffff) >> (n & 31)).toSigned(32);

/// Java `(byte) x`.
int i8(int x) => x.toSigned(8);

/// Java `(short) x`.
int i16(int x) => x.toSigned(16);

/// Java `(int) d` on a double: truncates toward zero, NaN gives 0, and
/// values outside the int range saturate. Dart's `toInt` throws instead.
int d2i(double d) {
  if (d.isNaN) return 0;
  if (d >= 2147483647.0) return 2147483647;
  if (d <= -2147483648.0) return -2147483648;
  return d.truncate();
}
