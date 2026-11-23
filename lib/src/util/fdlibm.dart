// Ported from fdlibm 5.3 (e_exp.c, s_sin.c, s_cos.c, k_sin.c, k_cos.c,
// e_rem_pio2.c, s_atan.c, e_atan2.c):
//
// ====================================================
// Copyright (C) 1993, 2004 by Sun Microsystems, Inc. All rights reserved.
//
// Permission to use, copy, modify, and distribute this
// software is freely granted, provided that this notice
// is preserved.
// ====================================================
//
// `docs/design.md` D4: Java's StrictMath is specified to give fdlibm's results, and these
// functions use only IEEE arithmetic and bit operations, so they give the same
// bits on every platform. dart:math would call each platform's libm instead.

import 'dart:typed_data';

final _bits = ByteData(8);

int _hi(double x) {
  _bits.setFloat64(0, x);
  return _bits.getInt32(0);
}

int _lo(double x) {
  _bits.setFloat64(0, x);
  return _bits.getUint32(4);
}

double _withHi(double x, int hi) {
  _bits.setFloat64(0, x);
  _bits.setInt32(0, hi.toSigned(32));
  return _bits.getFloat64(0);
}

double _fromWords(int hi, int lo) {
  _bits.setInt32(0, hi.toSigned(32));
  _bits.setUint32(4, lo & 0xffffffff);
  return _bits.getFloat64(0);
}

// --- exp -------------------------------------------------------------------

const _halF = [0.5, -0.5];
const _huge = 1.0e+300;
const _twom1000 = 9.33263618503218878990e-302;
const _oThreshold = 7.09782712893383973096e+02;
const _uThreshold = -7.45133219101941108420e+02;
const _ln2HI = [6.93147180369123816490e-01, -6.93147180369123816490e-01];
const _ln2LO = [1.90821492927058770002e-10, -1.90821492927058770002e-10];
const _invln2 = 1.44269504088896338700e+00;
const _p1 = 1.66666666666666019037e-01;
const _p2 = -2.77777777770155933842e-03;
const _p3 = 6.61375632143793436117e-05;
const _p4 = -1.65339022054652515390e-06;
const _p5 = 4.13813679705723846039e-08;

/// fdlibm `__ieee754_exp`, the result of Java's `StrictMath.exp`.
double exp(double x) {
  double hi = 0, lo = 0;
  int k = 0;
  int hx = _hi(x);
  final xsb = (hx >> 31) & 1;
  hx &= 0x7fffffff;

  if (hx >= 0x40862E42) {
    if (hx >= 0x7ff00000) {
      if (((hx & 0xfffff) | _lo(x)) != 0) return x + x; // NaN
      return xsb == 0 ? x : 0.0; // exp(+-inf) = {inf, 0}
    }
    if (x > _oThreshold) return _huge * _huge;
    if (x < _uThreshold) return _twom1000 * _twom1000;
  }

  if (hx > 0x3fd62e42) {
    if (hx < 0x3FF0A2B2) {
      hi = x - _ln2HI[xsb];
      lo = _ln2LO[xsb];
      k = 1 - xsb - xsb;
    } else {
      k = (_invln2 * x + _halF[xsb]).truncate();
      final t = k.toDouble();
      hi = x - t * _ln2HI[0];
      lo = t * _ln2LO[0];
    }
    x = hi - lo;
  } else if (hx < 0x3e300000) {
    if (_huge + x > 1.0) return 1.0 + x;
  } else {
    k = 0;
  }

  final t = x * x;
  final c = x - t * (_p1 + t * (_p2 + t * (_p3 + t * (_p4 + t * _p5))));
  if (k == 0) return 1.0 - ((x * c) / (c - 2.0) - x);
  final y = 1.0 - ((lo - (x * c) / (2.0 - c)) - hi);
  if (k >= -1021) {
    return _withHi(y, _hi(y) + (k << 20));
  }
  return _withHi(y, _hi(y) + ((k + 1000) << 20)) * _twom1000;
}

// --- sin, cos --------------------------------------------------------------

const _s1 = -1.66666666666666324348e-01;
const _s2 = 8.33333333332248946124e-03;
const _s3 = -1.98412698298579493134e-04;
const _s4 = 2.75573137070700676789e-06;
const _s5 = -2.50507602534068634195e-08;
const _s6 = 1.58969099521155010221e-10;

double _kernelSin(double x, double y, int iy) {
  final ix = _hi(x) & 0x7fffffff;
  if (ix < 0x3e400000) {
    if (x.truncate() == 0) return x;
  }
  final z = x * x;
  final v = z * x;
  final r = _s2 + z * (_s3 + z * (_s4 + z * (_s5 + z * _s6)));
  if (iy == 0) return x + v * (_s1 + z * r);
  return x - ((z * (0.5 * y - v * r) - y) - v * _s1);
}

const _c1 = 4.16666666666666019037e-02;
const _c2 = -1.38888888888741095749e-03;
const _c3 = 2.48015872894767294178e-05;
const _c4 = -2.75573143513906633035e-07;
const _c5 = 2.08757232129817482790e-09;
const _c6 = -1.13596475577881948265e-11;

double _kernelCos(double x, double y) {
  final ix = _hi(x) & 0x7fffffff;
  if (ix < 0x3e400000) {
    if (x.truncate() == 0) return 1.0;
  }
  final z = x * x;
  final r = z * (_c1 + z * (_c2 + z * (_c3 + z * (_c4 + z * (_c5 + z * _c6)))));
  if (ix < 0x3FD33333) return 1.0 - (0.5 * z - (z * r - x * y));
  final double qx;
  if (ix > 0x3fe90000) {
    qx = 0.28125;
  } else {
    qx = _fromWords(ix - 0x00200000, 0);
  }
  final hz = 0.5 * z - qx;
  final a = 1.0 - qx;
  return a - (hz - (z * r - x * y));
}

const _npio2hw = [
  0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C, //
  0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C,
  0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A,
  0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
  0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB,
  0x404858EB, 0x404921FB,
];

const _invpio2 = 6.36619772367581382433e-01;
const _pio2_1 = 1.57079632673412561417e+00;
const _pio2_1t = 6.07710050650619224932e-11;
const _pio2_2 = 6.07710050630396597660e-11;
const _pio2_2t = 2.02226624879595063154e-21;
const _pio2_3 = 2.02226624871116645580e-21;
const _pio2_3t = 8.47842766036889956997e-32;

/// fdlibm `__ieee754_rem_pio2` up to high word 0x413921fb, |x| about 1.65e6
/// (fdlibm's comment calls it 2^19·π/2). Larger arguments need
/// `__kernel_rem_pio2`, which is not ported: the routing engine only takes
/// the sine or cosine of latitudes and of angles of at most a few turns.
int _remPio2(double x, Float64List y) {
  final hx = _hi(x);
  final ix = hx & 0x7fffffff;
  if (ix <= 0x3fe921fb) {
    y[0] = x;
    y[1] = 0;
    return 0;
  }
  if (ix < 0x4002d97c) {
    if (hx > 0) {
      var z = x - _pio2_1;
      if (ix != 0x3ff921fb) {
        y[0] = z - _pio2_1t;
        y[1] = (z - y[0]) - _pio2_1t;
      } else {
        z -= _pio2_2;
        y[0] = z - _pio2_2t;
        y[1] = (z - y[0]) - _pio2_2t;
      }
      return 1;
    } else {
      var z = x + _pio2_1;
      if (ix != 0x3ff921fb) {
        y[0] = z + _pio2_1t;
        y[1] = (z - y[0]) + _pio2_1t;
      } else {
        z += _pio2_2;
        y[0] = z + _pio2_2t;
        y[1] = (z - y[0]) + _pio2_2t;
      }
      return -1;
    }
  }
  if (ix <= 0x413921fb) {
    var t = x.abs();
    final n = (t * _invpio2 + 0.5).truncate();
    final fn = n.toDouble();
    var r = t - fn * _pio2_1;
    var w = fn * _pio2_1t;
    if (n < 32 && ix != _npio2hw[n - 1]) {
      y[0] = r - w;
    } else {
      final j = ix >> 20;
      y[0] = r - w;
      var i = j - ((_hi(y[0]) >> 20) & 0x7ff);
      if (i > 16) {
        t = r;
        w = fn * _pio2_2;
        r = t - w;
        w = fn * _pio2_2t - ((t - r) - w);
        y[0] = r - w;
        i = j - ((_hi(y[0]) >> 20) & 0x7ff);
        if (i > 49) {
          t = r;
          w = fn * _pio2_3;
          r = t - w;
          w = fn * _pio2_3t - ((t - r) - w);
          y[0] = r - w;
        }
      }
    }
    y[1] = (r - y[0]) - w;
    if (hx < 0) {
      y[0] = -y[0];
      y[1] = -y[1];
      return -n;
    }
    return n;
  }
  if (ix >= 0x7ff00000) {
    y[0] = y[1] = x - x;
    return 0;
  }
  throw ArgumentError.value(x, 'x', 'beyond about 1.65e6, not supported');
}

final _y = Float64List(2);

/// fdlibm `sin`, the result of Java's `StrictMath.sin`.
double sin(double x) {
  final ix = _hi(x) & 0x7fffffff;
  if (ix <= 0x3fe921fb) return _kernelSin(x, 0.0, 0);
  if (ix >= 0x7ff00000) return x - x;
  final n = _remPio2(x, _y);
  switch (n & 3) {
    case 0:
      return _kernelSin(_y[0], _y[1], 1);
    case 1:
      return _kernelCos(_y[0], _y[1]);
    case 2:
      return -_kernelSin(_y[0], _y[1], 1);
    default:
      return -_kernelCos(_y[0], _y[1]);
  }
}

/// fdlibm `cos`, the result of Java's `StrictMath.cos`.
double cos(double x) {
  final ix = _hi(x) & 0x7fffffff;
  if (ix <= 0x3fe921fb) return _kernelCos(x, 0.0);
  if (ix >= 0x7ff00000) return x - x;
  final n = _remPio2(x, _y);
  switch (n & 3) {
    case 0:
      return _kernelCos(_y[0], _y[1]);
    case 1:
      return -_kernelSin(_y[0], _y[1], 1);
    case 2:
      return -_kernelCos(_y[0], _y[1]);
    default:
      return _kernelSin(_y[0], _y[1], 1);
  }
}

// --- atan, atan2 -----------------------------------------------------------

const _atanhi = [
  4.63647609000806093515e-01,
  7.85398163397448278999e-01,
  9.82793723247329054082e-01,
  1.57079632679489655800e+00,
];
const _atanlo = [
  2.26987774529616870924e-17,
  3.06161699786838301793e-17,
  1.39033110312309984516e-17,
  6.12323399573676603587e-17,
];
const _aT = [
  3.33333333333329318027e-01,
  -1.99999999998764832476e-01,
  1.42857142725034663711e-01,
  -1.11111104054623557880e-01,
  9.09088713343650656196e-02,
  -7.69187620504482999495e-02,
  6.66107313738753120669e-02,
  -5.83357013379057348645e-02,
  4.97687799461593236017e-02,
  -3.65315727442169155270e-02,
  1.62858201153657823623e-02,
];

double _atan(double x) {
  final hx = _hi(x);
  final ix = hx & 0x7fffffff;
  int id;
  if (ix >= 0x44100000) {
    if (ix > 0x7ff00000 || (ix == 0x7ff00000 && _lo(x) != 0)) return x + x;
    if (hx > 0) return _atanhi[3] + _atanlo[3];
    return -_atanhi[3] - _atanlo[3];
  }
  if (ix < 0x3fdc0000) {
    if (ix < 0x3e200000) {
      if (_huge + x > 1.0) return x;
    }
    id = -1;
  } else {
    x = x.abs();
    if (ix < 0x3ff30000) {
      if (ix < 0x3fe60000) {
        id = 0;
        x = (2.0 * x - 1.0) / (2.0 + x);
      } else {
        id = 1;
        x = (x - 1.0) / (x + 1.0);
      }
    } else {
      if (ix < 0x40038000) {
        id = 2;
        x = (x - 1.5) / (1.0 + 1.5 * x);
      } else {
        id = 3;
        x = -1.0 / x;
      }
    }
  }
  final z = x * x;
  final w = z * z;
  final s1 = z * (_aT[0] + w * (_aT[2] + w * (_aT[4] + w * (_aT[6] + w * (_aT[8] + w * _aT[10])))));
  final s2 = w * (_aT[1] + w * (_aT[3] + w * (_aT[5] + w * (_aT[7] + w * _aT[9]))));
  if (id < 0) return x - x * (s1 + s2);
  final r = _atanhi[id] - ((x * (s1 + s2) - _atanlo[id]) - x);
  return hx < 0 ? -r : r;
}

const _tiny = 1.0e-300;
const _piO4 = 7.8539816339744827900E-01;
const _piO2 = 1.5707963267948965580E+00;
const _pi = 3.1415926535897931160E+00;
const _piLo = 1.2246467991473531772E-16;

/// fdlibm `__ieee754_atan2`, the result of Java's `StrictMath.atan2`.
double atan2(double y, double x) {
  final hx = _hi(x);
  final ix = hx & 0x7fffffff;
  final lx = _lo(x);
  final hy = _hi(y);
  final iy = hy & 0x7fffffff;
  final ly = _lo(y);
  // (l | -l) >> 31 on an unsigned 32-bit l: 1 when l != 0.
  if ((ix | (lx != 0 ? 1 : 0)) > 0x7ff00000 || (iy | (ly != 0 ? 1 : 0)) > 0x7ff00000) {
    return x + y; // NaN
  }
  if (((hx - 0x3ff00000) | lx) == 0) return _atan(y); // x = 1.0
  final m = ((hy >> 31) & 1) | ((hx >> 30) & 2);

  if ((iy | ly) == 0) {
    switch (m) {
      case 0:
      case 1:
        return y;
      case 2:
        return _pi + _tiny;
      default:
        return -_pi - _tiny;
    }
  }
  if ((ix | lx) == 0) return hy < 0 ? -_piO2 - _tiny : _piO2 + _tiny;

  if (ix == 0x7ff00000) {
    if (iy == 0x7ff00000) {
      switch (m) {
        case 0:
          return _piO4 + _tiny;
        case 1:
          return -_piO4 - _tiny;
        case 2:
          return 3.0 * _piO4 + _tiny;
        default:
          return -3.0 * _piO4 - _tiny;
      }
    } else {
      switch (m) {
        case 0:
          return 0.0;
        case 1:
          return -0.0;
        case 2:
          return _pi + _tiny;
        default:
          return -_pi - _tiny;
      }
    }
  }
  if (iy == 0x7ff00000) return hy < 0 ? -_piO2 - _tiny : _piO2 + _tiny;

  final k = (iy - ix) >> 20;
  double z;
  if (k > 60) {
    z = _piO2 + 0.5 * _piLo;
  } else if (hx < 0 && k < -60) {
    z = 0.0;
  } else {
    z = _atan((y / x).abs());
  }
  switch (m) {
    case 0:
      return z;
    case 1:
      return _withHi(z, _hi(z) ^ 0x80000000);
    case 2:
      return _pi - (z - _piLo);
    default:
      return (z - _piLo) - _pi;
  }
}
