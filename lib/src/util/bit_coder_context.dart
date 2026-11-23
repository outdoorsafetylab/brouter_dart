// Port of btools.util.BitCoderContext (BRouter v1.7.10, MIT).
import 'dart:typed_data';

import 'int32.dart';

/// Bit-level reading and writing on a byte array, least significant bit
/// first. The buffer word [_b] holds Java int semantics (signed 32-bit).
class BitCoderContext {
  Uint8List _ab;
  int _idxMax;
  int _idx = -1;
  int _bits = 0; // bits left in buffer
  int _b = 0; // buffer word

  static final Int32List vlValues = Int32List(4096);
  static final Int32List vlLength = Int32List(4096);
  static final Int32List _vcValues = Int32List(4096);
  static final Int32List _vcLength = Int32List(4096);
  static final Int32List _reverseByte = Int32List(256);

  static bool _tablesReady = false;

  BitCoderContext(Uint8List ab)
      : _ab = ab,
        _idxMax = ab.length - 1 {
    _initTables();
  }

  BitCoderContext._raw(Uint8List ab)
      : _ab = ab,
        _idxMax = ab.length - 1;

  // The Java static initializer, run once.
  static void _initTables() {
    if (_tablesReady) return;
    _tablesReady = true;
    final bc = BitCoderContext._raw(Uint8List(4));
    for (var i = 0; i < 4096; i++) {
      bc.reset();
      bc._bits = 14;
      bc._b = 0x1000 + i;
      final b0 = bc.getReadingBitPosition();
      vlValues[i] = bc.decodeVarBits2();
      vlLength[i] = bc.getReadingBitPosition() - b0;
    }
    for (var i = 0; i < 4096; i++) {
      bc.reset();
      final b0 = bc.getWritingBitPosition();
      bc.encodeVarBits2(i);
      _vcValues[i] = bc._b;
      _vcLength[i] = bc.getWritingBitPosition() - b0;
    }
    for (var i = 0; i < 1024; i++) {
      bc.reset();
      bc._bits = 14;
      bc._b = 0x1000 + i;
      final b0 = bc.getReadingBitPosition();
      vlValues[i] = bc.decodeVarBits2();
      vlLength[i] = bc.getReadingBitPosition() - b0;
    }
    for (var b = 0; b < 256; b++) {
      var r = 0;
      for (var i = 0; i < 8; i++) {
        if ((b & (1 << i)) != 0) r |= 1 << (7 - i);
      }
      _reverseByte[b] = r;
    }
  }

  void resetTo(Uint8List ab) {
    _ab = ab;
    _idxMax = ab.length - 1;
    reset();
  }

  void reset() {
    _idx = -1;
    _bits = 0;
    _b = 0;
  }

  /// Variable bit length: 1 → 0; 01 + 1 bit → 1..2; 001 + 2 bits → 3..6 …
  void encodeVarBits2(int value) {
    var range = 0;
    while (value > range) {
      encodeBit(false);
      value -= range + 1;
      range = 2 * range + 1;
    }
    encodeBit(true);
    encodeBounded(range, value);
  }

  void encodeVarBits(int value) {
    if ((value & 0xfff) == value) {
      _flushBuffer();
      _b = i32(_b | shl(_vcValues[value], _bits));
      _bits += _vcLength[value];
    } else {
      encodeVarBits2(value);
    }
  }

  int decodeVarBits2() {
    var range = 0;
    while (!decodeBit()) {
      range = 2 * range + 1;
    }
    return i32(range + decodeBounded(range));
  }

  int decodeVarBits() {
    _fillBuffer();
    final b12 = _b & 0xfff;
    final len = vlLength[b12];
    if (len <= 12) {
      _b = ushr(_b, len);
      _bits -= len;
      return vlValues[b12];
    }
    if (len <= 23) {
      final len2 = len >> 1;
      _b = ushr(_b, len2 + 1);
      var mask = ushr(0xffffffff, 32 - len2);
      mask = i32(mask + (_b & mask));
      _b = ushr(_b, len2);
      _bits -= len;
      return mask;
    }
    if ((_b & 0xffffff) != 0) {
      _b = ushr(_b, 12);
      final len3 = 1 + (vlLength[_b & 0xfff] >> 1);
      _b = ushr(_b, len3);
      final len2 = 11 + len3;
      _bits -= len2 + 1;
      _fillBuffer();
      var mask = ushr(0xffffffff, 32 - len2);
      mask = i32(mask + (_b & mask));
      _b = ushr(_b, len2);
      _bits -= len2;
      return mask;
    }
    return decodeVarBits2();
  }

  void encodeBit(bool value) {
    if (_bits > 31) {
      _ab[++_idx] = _b & 0xff;
      _b = ushr(_b, 8);
      _bits -= 8;
    }
    if (value) {
      _b = i32(_b | shl(1, _bits));
    }
    _bits++;
  }

  bool decodeBit() {
    if (_bits == 0) {
      _bits = 8;
      _b = _ab[++_idx];
    }
    final value = (_b & 1) != 0;
    _b = ushr(_b, 1);
    _bits--;
    return value;
  }

  /// An integer in 0..max: n bits when max = 2^n − 1, otherwise shorter codes
  /// for the central range.
  void encodeBounded(int max, int value) {
    var im = 1;
    while (im <= max) {
      if ((value & im) != 0) {
        encodeBit(true);
        max -= im;
      } else {
        encodeBit(false);
      }
      im = shl(im, 1);
    }
  }

  int decodeBounded(int max) {
    var value = 0;
    var im = 1;
    while ((value | im) <= max) {
      if (_bits == 0) {
        _bits = 8;
        _b = _ab[++_idx];
      }
      if ((_b & 1) != 0) value |= im;
      _b = ushr(_b, 1);
      _bits--;
      im = shl(im, 1);
    }
    return value;
  }

  int decodeBits(int count) {
    _fillBuffer();
    final mask = ushr(0xffffffff, 32 - count);
    final value = _b & mask;
    _b = ushr(_b, count);
    _bits -= count;
    return i32(value);
  }

  int decodeBitsReverse(int count) {
    _fillBuffer();
    var value = 0;
    while (count > 8) {
      value = i32(shl(value, 8) | _reverseByte[_b & 0xff]);
      _b = sar(_b, 8);
      count -= 8;
      _bits -= 8;
      _fillBuffer();
    }
    value = i32(shl(value, count) | sar(_reverseByte[_b & 0xff], 8 - count));
    _bits -= count;
    _b = sar(_b, count);
    return value;
  }

  void _fillBuffer() {
    while (_bits < 24) {
      if (_idx++ < _idxMax) {
        _b = i32(_b | shl(_ab[_idx], _bits));
      }
      _bits += 8;
    }
  }

  void _flushBuffer() {
    while (_bits > 7) {
      _ab[++_idx] = _b & 0xff;
      _b = ushr(_b, 8);
      _bits -= 8;
    }
  }

  /// Flushes a write-mode context; returns the encoded length in bytes.
  int closeAndGetEncodedLength() {
    _flushBuffer();
    if (_bits > 0) {
      _ab[++_idx] = _b & 0xff;
    }
    return _idx + 1;
  }

  int getWritingBitPosition() => i32(shl(_idx, 3) + 8 + _bits);

  int getReadingBitPosition() => i32(shl(_idx, 3) + 8 - _bits);

  void setReadingBitPosition(int pos) {
    _idx = ushr(pos, 3);
    _bits = (_idx << 3) + 8 - pos;
    _b = _ab[_idx];
    _b = ushr(_b, 8 - _bits);
  }
}
