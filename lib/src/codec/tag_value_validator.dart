// Port of btools.codec.TagValueValidator (BRouter v1.7.10, MIT).
import 'dart:typed_data';

/// Decides which way descriptions the decoder keeps. The routing profile's
/// way context implements it.
abstract interface class TagValueValidator {
  /// 0 = nothing, 1 = no matching, 2 = normal.
  int accessType(Uint8List tagValueSet);

  Uint8List unify(Uint8List tagValueSet, int offset, int len);

  bool isLookupIdxUsed(int idx);

  void setDecodeForbidden(bool decodeForbidden);

  bool checkStartWay(Uint8List? ab);
}
