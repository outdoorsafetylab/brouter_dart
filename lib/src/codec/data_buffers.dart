// Port of btools.codec.DataBuffers (BRouter v1.7.10, MIT).
import 'dart:typed_data';

import '../util/bit_coder_context.dart';

/// Re-usable buffers for the decoder.
class DataBuffers {
  Uint8List iobuffer;
  final Uint8List tagbuf1 = Uint8List(256);
  late final BitCoderContext bctx1 = BitCoderContext(tagbuf1);
  final Uint8List bbuf1 = Uint8List(65636);
  final Int32List ibuf1 = Int32List(4096);
  final Int32List ibuf2 = Int32List(2048);
  final Int32List ibuf3 = Int32List(2048);
  final Int32List alon = Int32List(2048);
  final Int32List alat = Int32List(2048);

  /// With [iobuffer] given, that array is used for io instead of a new one.
  DataBuffers([Uint8List? iobuffer]) : iobuffer = iobuffer ?? Uint8List(65636);
}
