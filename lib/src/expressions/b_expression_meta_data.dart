// Port of btools.expressions.BExpressionMetaData (BRouter v1.7.10, MIT).
part of 'expressions.dart';

/// Reads lookups.dat and hands each context's lines to the context
/// registered for it.
final class BExpressionMetaData {
  static const _contextTag = '---context:';
  static const _versionTag = '---lookupversion:';
  static const _minorVersionTag = '---minorversion:';
  static const _varlengthTag = '---readvarlength';
  static const _minAppVersionTag = '---minappversion:';

  int lookupVersion = -1; // Java short
  int lookupMinorVersion = -1;
  int minAppVersion = -1;

  final Map<String, BExpressionContext> _listeners = {};

  void registerListener(String context, BExpressionContext ctx) {
    _listeners[context] = ctx;
  }

  void readMetaData(File lookupsFile) {
    // FileReader decodes with the platform charset, UTF-8 since JDK 18
    readMetaDataText(utf8.decode(lookupsFile.readAsBytesSync(), allowMalformed: true));
  }

  /// [readMetaData] on the file's content.
  void readMetaDataText(String text) {
    BExpressionContext? ctx;
    for (var line in text.split(_lineBreak)) {
      line = javaTrim(line);
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith(_contextTag)) {
        ctx = _listeners[line.substring(_contextTag.length)];
        continue;
      }
      if (line.startsWith(_versionTag)) {
        lookupVersion = _parseShort(line.substring(_versionTag.length));
        continue;
      }
      if (line.startsWith(_minorVersionTag)) {
        lookupMinorVersion = _parseShort(line.substring(_minorVersionTag.length));
        continue;
      }
      if (line.startsWith(_minAppVersionTag)) {
        minAppVersion = _parseShort(line.substring(_minAppVersionTag.length));
        continue;
      }
      if (line.startsWith(_varlengthTag)) continue; // tag removed...
      if (ctx != null) ctx.parseMetaLine(line);
    }
    for (final c in _listeners.values) {
      c.finishMetaParsing();
    }
  }
}

// BufferedReader.readLine ends a line at \n, \r or \r\n.
final _lineBreak = RegExp(r'\r\n|\r|\n');

// Short.parseShort: optional sign and decimal digits only, in range.
int _parseShort(String s) {
  final v = RegExp(r'^[+-]?\d+$').hasMatch(s) ? int.tryParse(s) : null;
  if (v == null || v < -32768 || v > 32767) throw FormatException('For input string: "$s"');
  return v;
}
