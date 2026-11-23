// What NodesCache needs from btools.expressions.BExpressionContextWay
// (BRouter v1.7.10). Java passes the way context itself; here it is an
// interface, so the decoding side does not depend on the expressions port.

import '../codec/tag_value_validator.dart';
import '../util/byte_array_unifier.dart';

/// The routing profile's way context as NodesCache uses it: it decides
/// which ways the decoder keeps, unifies their descriptions, and names the
/// lookup version the rd5 files must match.
abstract interface class NodesCacheContext implements TagValueValidator, IByteArrayUnifier {
  /// `meta.lookupVersion` in Java.
  int get lookupVersion;

  /// `meta.lookupMinorVersion` in Java.
  int get lookupMinorVersion;
}
