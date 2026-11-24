// Port of btools.expressions.BExpressionContext (BRouter v1.7.10, MIT).
part of 'expressions.dart';

/// Context for simple expressions: the local variables, their names, and the
/// lookup input variables.
///
/// Not ported: dumpStatistics and generateRandomValues (map-creator and test
/// tools), the showErrors and disableExpressionCache system properties, and
/// the numeric-value conversion [addLookupValue] does for `*` lookups on an
/// external data array (map creator only; it throws [UnsupportedError]).
abstract class BExpressionContext implements IByteArrayUnifier {
  static const _contextTag = '---context:';
  static const _modelTag = '---model:';

  String _context;
  bool _inOurContext = false;
  String _text = ''; // the profile being parsed (Java: a BufferedReader)
  int _textPos = 0;
  bool _readerDone = false;

  /// Java `_modelClass`: the `---model:` of the profile.
  String? modelClass;

  final Map<String, int> _lookupNumbers = {};
  final List<List<BExpressionLookupValue>> _lookupValues = [];
  final List<String> _lookupNames = [];
  final List<Int32List> _lookupHistograms = [];
  List<bool>? _lookupIdxUsed;

  bool _lookupDataFrozen = false;

  Int32List _lookupData = Int32List(0);

  final Uint8List _abBuf = Uint8List(256);
  late final BitCoderContext _ctxEncode = BitCoderContext(_abBuf);
  final BitCoderContext _ctxDecode = BitCoderContext(Uint8List(0));

  final Map<String, int> _variableNumbers = {};

  List<BExpression?>? _lastAssignedExpression = [];
  final bool _skipConstantExpressionOptimizations = false;
  int _expressionNodeCount = 0;

  Float32List? _variableData;

  // hash-cache for function results
  final CacheNode _probeCacheNode = CacheNode();
  LruMap? _cache;

  final VarWrapper _probeVarSet = VarWrapper();
  LruMap? _resultVarCache;

  List<BExpression>? _expressionList;

  int _minWriteIdx = 0;

  // build-in variable indexes for fast access
  Int32List _buildInVariableIdx = Int32List(0);
  int _nBuildInVars = 0;

  Float32List? _currentVars;
  int _currentVarOffset = 0;

  BExpressionContext? _foreignContext;

  Int32List noStartWays = Int32List(0);

  void _setInverseVars() {
    _currentVarOffset = _nBuildInVars;
  }

  List<String> get _buildInVariableNames;

  double getBuildInVariable(int idx) => _currentVars![idx + _currentVarOffset];

  int _linenr = 0;

  BExpressionMetaData? meta;
  bool _lookupDataValid = false;

  /// [context] is global, way or node; [hashSize] the size of the result
  /// cache, 0 for none.
  BExpressionContext(String context, int hashSize, this.meta) : _context = context {
    meta?.registerListener(context, this);

    // create the expression cache
    if (hashSize > 0) {
      _cache = LruMap(4 * hashSize, hashSize);
      _resultVarCache = LruMap(4096, 4096);
    }
  }

  /// Encodes [ld] (the internal lookup data when null) to a way or node
  /// description; null when every tag is empty.
  Uint8List? encode([Int32List? ld]) {
    if (ld == null) {
      if (!_lookupDataValid) throw ArgumentError('internal error: encoding undefined data?');
      ld = _lookupData;
    }
    final ctx = _ctxEncode;
    ctx.reset();

    var skippedTags = 0;
    var nonNullTags = 0;

    // (skip first bit ("reversedirection") )

    // all others are generic
    for (var inum = 1; inum < _lookupValues.length; inum++) {
      final d = ld[inum];
      if (d == 0) {
        skippedTags++;
        continue;
      }
      ctx.encodeVarBits(skippedTags + 1);
      nonNullTags++;
      skippedTags = 0;

      // 0 excluded already, 1 (=unknown) we rotate up to 8
      // to have the good code space for the popular values
      final dd = d < 2 ? 7 : (d < 9 ? d - 2 : i32(d - 1));
      ctx.encodeVarBits(dd);
    }
    ctx.encodeVarBits(0);

    if (nonNullTags == 0) return null;

    final len = ctx.closeAndGetEncodedLength();
    final ab = Uint8List.fromList(Uint8List.sublistView(_abBuf, 0, len));

    // crosscheck: decode and compare
    final ld2 = Int32List(_lookupValues.length);
    decodeInto(ld2, false, ab);
    for (var inum = 1; inum < _lookupValues.length; inum++) {
      if (ld2[inum] != ld[inum]) {
        throw StateError('assertion failed encoding inum=$inum val=${ld[inum]} ${getKeyValueDescription(false, ab)}');
      }
    }
    return ab;
  }

  /// Decodes [ab] to the internal lookup data.
  void decode(Uint8List ab) {
    decodeInto(_lookupData, false, ab);
    _lookupDataValid = true;
  }

  /// Decodes [ab] into the lookup data array [ld].
  void decodeInto(Int32List ld, bool inverseDirection, Uint8List ab) {
    final ctx = _ctxDecode;
    ctx.resetTo(ab);

    // start with first bit hardwired ("reversedirection")
    ld[0] = inverseDirection ? 2 : 0;

    // all others are generic
    var inum = 1;
    for (;;) {
      var delta = ctx.decodeVarBits();
      if (delta == 0) break;
      if (i32(inum + delta) > ld.length) break; // higher minor version is o.k.

      while (delta-- > 1) {
        ld[inum++] = 0;
      }

      // see encoder for value rotation
      final dd = ctx.decodeVarBits();
      var d = dd == 7 ? 1 : (dd < 7 ? dd + 2 : i32(dd + 1));
      if (d >= _lookupValues[inum].length && d < 1000) d = 1; // map out-of-range to unknown
      ld[inum++] = d;
    }
    while (inum < ld.length) {
      ld[inum++] = 0;
    }
  }

  // Java `(val - 1000) / 100f`.
  static double _encodedNumber(int val) => fround(fround(i32(val - 1000).toDouble()) / 100.0);

  String getKeyValueDescription(bool inverseDirection, Uint8List ab) {
    final sb = StringBuffer();
    decodeInto(_lookupData, inverseDirection, ab);
    for (var inum = 0; inum < _lookupValues.length; inum++) {
      final va = _lookupValues[inum];
      final val = _lookupData[inum];
      final value = (val >= 1000) ? javaFloatToString(_encodedNumber(val)) : va[val].toString();
      if (value.isNotEmpty) {
        if (sb.isNotEmpty) sb.write(' ');
        sb.write('${_lookupNames[inum]}=$value');
      }
    }
    return sb.toString();
  }

  List<String> getKeyValueList(bool inverseDirection, Uint8List ab) {
    final res = <String>[];
    decodeInto(_lookupData, inverseDirection, ab);
    for (var inum = 0; inum < _lookupValues.length; inum++) {
      final va = _lookupValues[inum];
      final val = _lookupData[inum];
      // no negative values
      final value = (val >= 1000) ? javaFloatToString(_encodedNumber(val)) : va[val].toString();
      if (value.isNotEmpty) {
        res.add(_lookupNames[inum]);
        res.add(value);
      }
    }
    return res;
  }

  int getLookupKey(String name) => _lookupNumbers[name] ?? -1;

  double getLookupValue(int key) {
    final val = _lookupData[key];
    if (val == 0) return double.nan;
    if (val < 900) {
      final va = _lookupValues[key];
      try {
        return javaParseFloat(va[val].toString());
      } on FormatException {
        return 0.0;
      }
    }
    return _encodedNumber(val);
  }

  /// Java `getLookupValue(boolean, byte[], int)`.
  double getLookupValueOf(bool inverseDirection, Uint8List ab, int key) {
    decodeInto(_lookupData, inverseDirection, ab);
    final val = _lookupData[key];
    if (val == 0) return double.nan;
    return _encodedNumber(val);
  }

  int _parsedLines = 0;
  bool _fixTagsWritten = false;

  void parseMetaLine(String line) {
    _parsedLines++;
    final tk = stringTokens(line, ' ');
    if (tk.length < 2) throw StateError('NoSuchElementException: $line');
    var name = tk[0];
    final value = tk[1];
    final idx = name.indexOf(';');
    if (idx >= 0) name = name.substring(0, idx);

    if (!_fixTagsWritten) {
      _fixTagsWritten = true;
      if ('way' == _context) {
        addLookupValue('reversedirection', 'yes', null);
      } else if ('node' == _context) {
        addLookupValue('nodeaccessgranted', 'yes', null);
      }
    }
    if ('reversedirection' == name) return; // this is hardcoded
    if ('nodeaccessgranted' == name) return; // this is hardcoded
    final newValue = addLookupValue(name, value, null);

    // add aliases
    if (newValue != null) {
      for (var i = 2; i < tk.length; i++) {
        newValue.addAlias(tk[i]);
      }
    }
  }

  void finishMetaParsing() {
    if (_parsedLines == 0 && 'global' != _context) {
      throw ArgumentError('lookup table does not contain data for context $_context (old version?)');
    }

    // post-process metadata:
    _lookupDataFrozen = true;

    _lookupIdxUsed = List<bool>.filled(_lookupValues.length, false);
  }

  /// Java `evaluate(int[])`: runs the rules on [lookupData2].
  void evaluateData(Int32List lookupData2) {
    _lookupData = lookupData2;
    _evaluate();
  }

  void _evaluate() {
    final list = _expressionList!;
    final n = list.length;
    for (var expidx = 0; expidx < n; expidx++) {
      list[expidx].evaluate(this);
    }
  }

  int _requests = 0;
  int _requests2 = 0;
  int _cachemisses = 0;

  String cacheStats() => 'requests=$_requests requests2=$_requests2 cachemisses=$_cachemisses';

  CacheNode _lastCacheNode = CacheNode();

  @override
  Uint8List unify(Uint8List ab, int offset, int len) {
    _probeCacheNode.ab = null; // crc based cache lookup only
    _probeCacheNode.hash = crc32(ab, offset, len);

    var cn = _cache!.get(_probeCacheNode) as CacheNode?;
    if (cn != null) {
      final cab = cn.ab!;
      if (cab.length == len) {
        for (var i = 0; i < len; i++) {
          if (cab[i] != ab[i + offset]) {
            cn = null;
            break;
          }
        }
        if (cn != null) {
          _lastCacheNode = cn;
          return cn.ab!;
        }
      }
    }
    return Uint8List.fromList(Uint8List.sublistView(ab, offset, offset + len));
  }

  /// Runs the rules on the description [ab]; [getBuildInVariable] then
  /// gives the results for the direction [inverseDirection].
  void evaluate(bool inverseDirection, Uint8List ab) {
    _requests++;
    _lookupDataValid = false; // this is an assertion for a nasty pitfall

    final cache = _cache;
    if (cache == null) {
      decodeInto(_lookupData, inverseDirection, ab);
      var cv = _currentVars;
      if (cv == null || cv.length != _nBuildInVars) {
        cv = _currentVars = Float32List(_nBuildInVars);
      }
      _evaluateInto(cv, 0);
      _currentVarOffset = 0;
      return;
    }

    CacheNode? cn;
    if (identical(_lastCacheNode.ab, ab)) {
      cn = _lastCacheNode;
    } else {
      _probeCacheNode.ab = ab;
      _probeCacheNode.hash = crc32(ab, 0, ab.length);
      cn = cache.get(_probeCacheNode) as CacheNode?;
    }

    if (cn == null) {
      _cachemisses++;

      cn = cache.removeLru() as CacheNode?;
      cn ??= CacheNode();
      cn.hash = _probeCacheNode.hash;
      cn.ab = ab;
      cache.put(cn);

      final probeVars = _probeVarSet.vars ??= Float32List(2 * _nBuildInVars);

      // forward direction
      decodeInto(_lookupData, false, ab);
      _evaluateInto(probeVars, 0);

      // inverse direction
      _lookupData[0] = 2; // inverse shortcut: reuse decoding
      _evaluateInto(probeVars, _nBuildInVars);

      _probeVarSet.hash = _floatsHash(probeVars);

      // unify the result variable set
      final resultVarCache = _resultVarCache!;
      var vw = resultVarCache.get(_probeVarSet) as VarWrapper?;
      if (vw == null) {
        vw = resultVarCache.removeLru() as VarWrapper?;
        vw ??= VarWrapper();
        vw.hash = _probeVarSet.hash;
        vw.vars = probeVars;
        _probeVarSet.vars = null;
        resultVarCache.put(vw);
      }
      cn.vars = vw.vars;
    } else {
      if (identical(ab, cn.ab)) _requests2++;

      cache.touch(cn);
    }

    _currentVars = cn.vars;
    _currentVarOffset = inverseDirection ? _nBuildInVars : 0;
  }

  void _evaluateInto(Float32List vars, int offset) {
    _evaluate();
    final variableData = _variableData!;
    for (var vi = 0; vi < _nBuildInVars; vi++) {
      final idx = _buildInVariableIdx[vi];
      vars[vi + offset] = idx == -1 ? 0.0 : variableData[idx];
    }
  }

  /// A new lookup data array, or null if no metadata is defined.
  Int32List? createNewLookupData() => _lookupDataFrozen ? Int32List(_lookupValues.length) : null;

  void assertAllVariablesEqual(BExpressionContext other) {
    final nv = _variableData!.length;
    final nv2 = other._variableData!.length;
    if (nv != nv2) throw StateError('mismatch in variable-count: $nv<->$nv2');
    for (var i = 0; i < nv; i++) {
      if (_variableData![i] != other._variableData![i]) {
        throw StateError('mismatch in variable ${variableName(i)} ${javaFloatToString(_variableData![i])}'
            '<->${javaFloatToString(other._variableData![i])}\ntags = ${getKeyValueDescription(false, encode()!)}');
      }
    }
  }

  String variableName(int idx) {
    for (final e in _variableNumbers.entries) {
      if (e.value == idx) return e.key;
    }
    throw StateError('no variable for index$idx');
  }

  /// Adds a new lookup value for [name] to [lookupData2]. With no array
  /// (null) the value goes to the context's own array, and unknown names and
  /// values are created. Returns a newly created value, if any, to add
  /// aliases to.
  BExpressionLookupValue? addLookupValue(String name, String value, Int32List? lookupData2) {
    BExpressionLookupValue? newValue;
    var num = _lookupNumbers[name];
    if (num == null) {
      if (lookupData2 != null) {
        // do not create unknown name for external data array
        return newValue;
      }

      // unknown name, create
      num = _lookupValues.length;
      _lookupNumbers[name] = num;
      _lookupNames.add(name);
      _lookupValues.add([BExpressionLookupValue(''), BExpressionLookupValue('unknown')]);
      _lookupHistograms.add(Int32List(2));
      final ndata = Int32List(_lookupData.length + 1);
      ndata.setRange(0, _lookupData.length, _lookupData);
      _lookupData = ndata;
    }

    // look for that value
    var values = _lookupValues[num];
    var histo = _lookupHistograms[num];
    var i = 0;
    var bFoundAsterix = false;
    for (; i < values.length; i++) {
      final v = values[i];
      if (v.equalsValue('*')) bFoundAsterix = true;
      if (v.matches(value)) break;
    }
    if (i == values.length) {
      if (lookupData2 != null) {
        // do not create unknown value for external data array,
        // record as 'unknown' instead
        lookupData2[num] = 1; // 1 == unknown
        if (bFoundAsterix) {
          throw UnsupportedError('numeric values for * lookups (map creator) are not ported: $name=$value');
        }
        return newValue;
      }

      if (i == 500) {
        return newValue;
      }
      // unknown value, create
      final nvalues = [...values, BExpressionLookupValue(value)];
      final nhisto = Int32List(values.length + 1);
      nhisto.setRange(0, histo.length, histo);
      values = nvalues;
      histo = nhisto;
      newValue = values[i];
      _lookupHistograms[num] = histo;
      _lookupValues[num] = values;
    }

    histo[i]++;

    // finally remember the actual data
    if (lookupData2 != null) {
      lookupData2[num] = i;
    } else {
      _lookupData[num] = i;
    }
    return newValue;
  }

  /// Java `addLookupValue(String, int)`: sets a value index (0 = unknown,
  /// 1 = other, 2 = value-x, ...) in the internal array.
  void addLookupValueIndex(String name, int valueIndex) {
    final num = _lookupNumbers[name];
    if (num == null) return;

    // look for that value
    final nvalues = _lookupValues[num].length;
    if (valueIndex < 0 || valueIndex >= nvalues) {
      throw ArgumentError('value index out of range for name $name: $valueIndex');
    }
    _lookupData[num] = valueIndex;
  }

  /// Special hack for yes/proposed relations: adds a lookup value unless a
  /// smaller one > 1 was added, and 2 = yes if [valueIndex] is out of range
  /// (0 = unknown, 1 = other, 2 = yes, 3 = proposed).
  void addSmallestLookupValue(String name, int valueIndex) {
    final num = _lookupNumbers[name];
    if (num == null) return;

    // look for that value
    final nvalues = _lookupValues[num].length;
    final oldValueIndex = _lookupData[num];
    if (oldValueIndex > 1 && oldValueIndex < valueIndex) return;
    if (valueIndex >= nvalues) valueIndex = nvalues - 1;
    if (valueIndex < 0) throw ArgumentError('value index out of range for name $name: $valueIndex');
    _lookupData[num] = valueIndex;
  }

  bool getBooleanLookupValue(String name) {
    final num = _lookupNumbers[name];
    return num != null && _lookupData[num] == 2;
  }

  int getOutputVariableIndex(String name, bool mustExist) {
    final idx = _getVariableIdx(name, false);
    if (idx < 0) {
      if (mustExist) throw ArgumentError('unknown variable: $name');
    } else if (idx < _minWriteIdx) {
      throw ArgumentError('bad access to global variable: $name');
    }
    for (var i = 0; i < _nBuildInVars; i++) {
      if (_buildInVariableIdx[i] == idx) return i;
    }
    final extended = Int32List(_nBuildInVars + 1);
    extended.setRange(0, _nBuildInVars, _buildInVariableIdx);
    extended[_nBuildInVars] = idx;
    _buildInVariableIdx = extended;
    return _nBuildInVars++;
  }

  void setForeignContext(BExpressionContext foreignContext) {
    _foreignContext = foreignContext;
  }

  double getForeignVariableValue(int foreignIndex) => _foreignContext!.getBuildInVariable(foreignIndex);

  int getForeignVariableIdx(String context, String name) {
    final fc = _foreignContext;
    if (fc == null || context != fc._context) {
      throw ArgumentError('unknown foreign context: $context');
    }
    return fc.getOutputVariableIndex(name, true);
  }

  /// Parses the profile [file] for this context, after evaluating its
  /// [readOnlyContext] section (usually "global") once for the read-only
  /// variables. [keyValues] are injected assignments (Java iterates a
  /// HashMap here; Dart keeps the map's order, which only changes variable
  /// numbering, not results).
  void parseFile(File file, String? readOnlyContext, [Map<String, String>? keyValues]) {
    final name = file.uri.pathSegments.last;
    if (!file.existsSync()) throw ArgumentError('profile $name does not exist');
    // FileReader decodes with the platform charset, UTF-8 since JDK 18
    parseProfile(name, utf8.decode(file.readAsBytesSync(), allowMalformed: true), readOnlyContext, keyValues);
  }

  /// [parseFile] on the profile's [text]; [name] is for messages.
  void parseProfile(String name, String text, String? readOnlyContext, [Map<String, String>? keyValues]) {
    try {
      if (readOnlyContext != null) {
        _linenr = 1;
        final realContext = _context;
        _context = readOnlyContext;
        _expressionList = _parseText(text, keyValues);
        _variableData = Float32List(_variableNumbers.length);
        evaluateData(_lookupData); // lookupData is dummy here - evaluate just to create the variables
        _context = realContext;
      }
      _linenr = 1;
      _minWriteIdx = _variableData == null ? 0 : _variableData!.length;
      _expressionList = _parseText(text, null);
      _lastAssignedExpression = null;

      // determine the build-in variable indices
      final varNames = _buildInVariableNames;
      _nBuildInVars = varNames.length;
      _buildInVariableIdx = Int32List(_nBuildInVars);
      for (var vi = 0; vi < varNames.length; vi++) {
        _buildInVariableIdx[vi] = _getVariableIdx(varNames[vi], false);
      }

      final readOnlyData = _variableData;
      final variableData = _variableData = Float32List(_variableNumbers.length);
      for (var i = 0; i < _minWriteIdx; i++) {
        variableData[i] = readOnlyData![i];
      }
    } on ArgumentError catch (e) {
      throw ArgumentError('ParseException $name at line $_linenr: ${e.message}');
    }
    if (_expressionList!.isEmpty) {
      throw ArgumentError('$name does not contain expressions for context $_context (old version?)');
    }
  }

  List<BExpression> _parseText(String text, Map<String, String>? keyValues) {
    _text = text;
    _textPos = 0;
    _readerDone = false;
    final result = <BExpression>[];

    // if injected keyValues are present, create assign expressions for them
    if (keyValues != null) {
      for (final e in keyValues.entries) {
        result.add(BExpression._createAssignExpressionFromKeyValue(this, e.key, e.value));
      }
    }

    for (;;) {
      final exp = BExpression.parse(this, 0);
      if (exp == null) break;
      result.add(exp);
    }
    _text = '';
    return result;
  }

  void setVariableValue(String name, double value, bool create) {
    var num = _variableNumbers[name];
    if (num != null) {
      _variableData![num] = value;
    } else if (create) {
      num = _getVariableIdx(name, create);
      final readOnlyData = _variableData!;
      final minWriteIdx = readOnlyData.length;
      final variableData = _variableData = Float32List(_variableNumbers.length);
      for (var i = 0; i < minWriteIdx; i++) {
        variableData[i] = readOnlyData[i];
      }
      variableData[num] = value;
    }
  }

  double getVariableValue(String name, double defaultValue) {
    final num = _variableNumbers[name];
    return num == null ? fround(defaultValue) : _getVariableValue(num); // Java float parameter
  }

  double _getVariableValue(int variableIdx) => _variableData![variableIdx];

  int _getVariableIdx(String name, bool create) {
    var num = _variableNumbers[name];
    if (num == null) {
      if (create) {
        num = _variableNumbers.length;
        _variableNumbers[name] = num;
        _lastAssignedExpression!.add(null);
      } else {
        return -1;
      }
    }
    return num;
  }

  double _getLookupMatch(int nameIdx, Int32List valueIdxArray) {
    for (var i = 0; i < valueIdxArray.length; i++) {
      if (_lookupData[nameIdx] == valueIdxArray[i]) return 1.0;
    }
    return 0.0;
  }

  int getLookupNameIdx(String name) => _lookupNumbers[name] ?? -1;

  void markLookupIdxUsed(int idx) {
    _lookupIdxUsed![idx] = true;
  }

  bool isLookupIdxUsed(int idx) => idx < _lookupIdxUsed!.length && _lookupIdxUsed![idx];

  void setAllTagsUsed() {
    _lookupIdxUsed!.fillRange(0, _lookupIdxUsed!.length, true);
  }

  String usedTagList() {
    final sb = StringBuffer();
    for (var inum = 0; inum < _lookupValues.length; inum++) {
      if (_lookupIdxUsed![inum]) {
        if (sb.isNotEmpty) sb.write(',');
        sb.write(_lookupNames[inum]);
      }
    }
    return sb.toString();
  }

  int _getLookupValueIdx(int nameIdx, String value) {
    final values = _lookupValues[nameIdx];
    for (var i = 0; i < values.length; i++) {
      if (values[i].equalsValue(value)) return i;
    }
    return -1;
  }

  String? _parseToken() {
    for (;;) {
      final token = _parseRawToken();
      if (token == null) return null;
      if (token.startsWith(_contextTag)) {
        _inOurContext = token.substring(_contextTag.length) == _context;
      } else if (token.startsWith(_modelTag)) {
        modelClass = javaTrim(token.substring(_modelTag.length));
      } else if (_inOurContext) {
        return token;
      }
    }
  }

  // Java _parseToken: one char (UTF-16 code unit) at a time.
  String? _parseRawToken() {
    final sb = StringBuffer();
    final sbcom = StringBuffer();
    var inComment = false;
    for (;;) {
      final ic = _readerDone || _textPos >= _text.length ? -1 : _text.codeUnitAt(_textPos++);
      if (ic < 0) {
        if (sb.isEmpty) return null;
        _readerDone = true;
        return sb.toString();
      }
      final c = ic;
      if (c == 0x0a) _linenr++;

      if (inComment) {
        sbcom.writeCharCode(c);
        if (c == 0x0d || c == 0x0a) inComment = false;
        if (!inComment) {
          _readNoStartWays(sbcom.toString());
          sbcom.clear();
        }
        continue;
      }
      if (javaIsWhitespace(c)) {
        if (sb.isNotEmpty) return sb.toString();
        continue;
      }
      if (c == 0x23 /* # */ && sb.isEmpty) {
        inComment = true;
      } else {
        sb.writeCharCode(c);
      }
    }
  }

  // A finished comment line: picks up the profile's noStartWay list.
  void _readNoStartWays(String comment) {
    final num = _variableNumbers['check_start_way'];
    if (num != null && noStartWays.isEmpty && comment.contains('noStartWay')) {
      var v = javaTrim(comment);
      final savar = javaSplit(v, '|');
      if (savar.length == 4) {
        v = javaTrim(savar[3].substring(savar[3].indexOf('=') + 1));
        final sa = javaSplit(v, ';');
        for (final s in sa) {
          final sa2 = javaSplit(s, ',');
          final name = sa2[0];
          final value = sa2[1];
          final nidx = getLookupNameIdx(name);
          if (nidx == -1) break;
          final vidx = _getLookupValueIdx(nidx, value);
          final tmp = Int32List(noStartWays.length + 2);
          tmp.setRange(0, noStartWays.length, noStartWays);
          noStartWays = tmp;
          noStartWays[noStartWays.length - 2] = nidx;
          noStartWays[noStartWays.length - 1] = vidx;
        }
      }
    }
  }

  double _assign(int variableIdx, double value) {
    _variableData![variableIdx] = value;
    return value;
  }

  final Int32List _ld2 = Int32List(512);

  bool checkStartWay(Uint8List? ab) {
    if (ab == null) return true;
    _ld2.fillRange(0, _ld2.length, 0);
    decodeInto(_ld2, false, ab);
    for (var i = 0; i < noStartWays.length; i += 2) {
      final key = noStartWays[i];
      final value = noStartWays[i + 1];
      if (_ld2[key] == value) return false;
    }
    return true;
  }

  void freeNoWays() {
    noStartWays = Int32List(0);
  }
}
