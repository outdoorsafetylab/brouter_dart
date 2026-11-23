// Port of btools.codec.TagValueWrapper (BRouter v1.7.10, MIT).
import 'dart:typed_data';

/// A way description bitmap with its access type.
class TagValueWrapper {
  Uint8List? data;
  int accessType = 0;
}
