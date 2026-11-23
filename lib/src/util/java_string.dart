// java.lang.String and java.util.StringTokenizer behaviour that differs from
// Dart's: which characters trim and isWhitespace mean, and split dropping
// trailing empty strings. Parsing lookups.dat and .brf files depends on it.

/// Java `s.trim()`: strips chars <= ' ' at both ends (Dart's trim strips
/// Unicode whitespace instead).
String javaTrim(String s) {
  var a = 0, b = s.length;
  while (a < b && s.codeUnitAt(a) <= 0x20) {
    a++;
  }
  while (b > a && s.codeUnitAt(b - 1) <= 0x20) {
    b--;
  }
  return s.substring(a, b);
}

/// Java `Character.isWhitespace(c)` for one UTF-16 code unit: Unicode space,
/// line and paragraph separators except the non-breaking ones, plus
/// \t \n \u000B \f \r and \u001C to \u001F.
bool javaIsWhitespace(int c) =>
    (c >= 0x09 && c <= 0x0d) ||
    (c >= 0x1c && c <= 0x20) ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x2006) ||
    (c >= 0x2008 && c <= 0x200a) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x205f ||
    c == 0x3000;

/// Java `s.split(sep)` for a separator with no regex meaning (or quoted):
/// no match gives `[s]`, otherwise trailing empty strings are dropped.
List<String> javaSplit(String s, String sep) {
  if (!s.contains(sep)) return [s];
  final parts = s.split(sep);
  while (parts.isNotEmpty && parts.last.isEmpty) {
    parts.removeLast();
  }
  return parts;
}

/// The tokens `new StringTokenizer(s, delims)` yields: maximal runs of
/// characters not in [delims], empty runs skipped.
List<String> stringTokens(String s, String delims) {
  final out = <String>[];
  var start = -1;
  for (var i = 0; i < s.length; i++) {
    final isDelim = delims.contains(s[i]);
    if (isDelim) {
      if (start >= 0) out.add(s.substring(start, i));
      start = -1;
    } else if (start < 0) {
      start = i;
    }
  }
  if (start >= 0) out.add(s.substring(start));
  return out;
}
