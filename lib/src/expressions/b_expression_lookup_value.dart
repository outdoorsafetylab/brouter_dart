// Port of btools.expressions.BExpressionLookupValue (BRouter v1.7.10, MIT).
part of 'expressions.dart';

/// A lookup value with optional aliases. [toString] gives the primary value,
/// [equalsValue] compares against the primary value only (Java's equals),
/// [matches] also compares the aliases.
final class BExpressionLookupValue {
  String value;
  List<String>? aliases;

  BExpressionLookupValue(this.value);

  @override
  String toString() => value;

  void addAlias(String alias) {
    (aliases ??= []).add(alias);
  }

  /// Java `equals(String)`.
  bool equalsValue(String v) => value == v;

  bool matches(String s) {
    if (value == s) return true;
    final a = aliases;
    if (a != null) {
      for (final alias in a) {
        if (alias == s) return true;
      }
    }
    return false;
  }
}
