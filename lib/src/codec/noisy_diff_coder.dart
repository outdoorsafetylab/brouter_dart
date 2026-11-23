// Port of btools.codec.NoisyDiffCoder (BRouter v1.7.10, MIT), decoding side.
import 'stat_coder_context.dart';

/// Decoder for signed integers with a noisy-bit count read up front as a
/// very simple dictionary.
class NoisyDiffCoder {
  final int _noisybits;
  final StatCoderContext _bc;

  /// Reads the noisy-bit count from [bc].
  NoisyDiffCoder(StatCoderContext bc) : _noisybits = bc.decodeVarBits(), _bc = bc;

  int decodeSignedValue() => _bc.decodeNoisyDiff(_noisybits);
}
