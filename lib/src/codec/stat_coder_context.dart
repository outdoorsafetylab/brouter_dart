// Port of btools.codec.StatCoderContext (BRouter v1.7.10, MIT), decoding side.
import 'dart:typed_data';

import '../util/bit_coder_context.dart';
import '../util/int32.dart';

class StatCoderContext extends BitCoderContext {
  static final Int32List _noisyBits = () {
    final t = Int32List(1024);
    for (var i = 0; i < 1024; i++) {
      var p = i;
      var noisybits = 0;
      while (p > 2) {
        noisybits++;
        p >>= 1;
      }
      t[i] = noisybits;
    }
    return t;
  }();

  StatCoderContext(super.ab);

  /// An unsigned integer whose [noisybits] least significant bits are
  /// stored as they are.
  int decodeNoisyNumber(int noisybits) {
    final value = decodeBits(noisybits);
    return i32(value | shl(decodeVarBits(), noisybits));
  }

  /// A signed integer whose [noisybits] least significant bits are stored
  /// as they are.
  int decodeNoisyDiff(int noisybits) {
    var value = 0;
    if (noisybits > 0) {
      value = i32(decodeBits(noisybits) - shl(1, noisybits - 1));
    }
    var val2 = shl(decodeVarBits(), noisybits);
    if (val2 != 0) {
      if (decodeBit()) {
        val2 = i32(-val2);
      }
    }
    return i32(value + val2);
  }

  /// A signed integer whose typical range and median come from [predictor].
  int decodePredictedValue(int predictor) {
    var p = predictor < 0 ? i32(-predictor) : predictor;
    var noisybits = 0;
    while (p > 1023) {
      noisybits++;
      p = sar(p, 1);
    }
    return i32(predictor + decodeNoisyDiff(noisybits + _noisyBits[p]));
  }

  /// Decodes a sorted array, most significant bit first, by recursively
  /// reading how many values have the current bit 0.
  void decodeSortedArray(Int32List values, int offset, int subsize, int nextbitpos, int value) {
    if (subsize == 1) {
      // last-choice shortcut
      if (nextbitpos >= 0) {
        value = i32(value | decodeBitsReverse(nextbitpos + 1));
      }
      values[offset] = value;
      return;
    }
    if (nextbitpos < 0) {
      while (subsize-- > 0) {
        values[offset++] = value;
      }
      return;
    }

    final size1 = decodeBounded(subsize);
    final size2 = subsize - size1;

    if (size1 > 0) {
      decodeSortedArray(values, offset, size1, nextbitpos - 1, value);
    }
    if (size2 > 0) {
      decodeSortedArray(values, offset + size1, size2, nextbitpos - 1, i32(value | shl(1, nextbitpos)));
    }
  }
}
