// Port of btools.expressions.BExpression (BRouter v1.7.10, MIT).
part of 'expressions.dart';

/// Deepest nesting a profile expression may have, the top-level `assign`
/// being level 0. BRouter's own profiles (v1.7.10 misc/profiles2) reach 36.
/// BRouter has no limit. Parsing and evaluating recurse once per level; in
/// a spawned isolate they overflow the stack at about 2,250 levels on macOS,
/// 2,420 on a Pixel 6 (Android 16) and 2,440 on an iPhone 13 (iOS 27), in
/// release builds on the phones. Hence 200.
const maxProfileNesting = 200;

/// One node of a parsed rule. Values are Java floats: every result is
/// rounded with [fround], so it carries the bits Java computes.
final class BExpression {
  static const _orExp = 10;
  static const _andExp = 11;
  static const _notExp = 12;

  static const _addExp = 20;
  static const _multiplyExp = 21;
  static const _divideExp = 22;
  static const _maxExp = 23;
  static const _equalExp = 24;
  static const _greaterExp = 25;
  static const _minExp = 26;

  static const _subExp = 27;
  static const _lesserExp = 28;
  static const _xorExp = 29;

  static const _switchExp = 30;
  static const _assignExp = 31;
  static const _lookupExp = 32;
  static const _numberExp = 33;
  static const _variableExp = 34;
  static const _foreignVariableExp = 35;
  static const _variableGetExp = 36;

  int _typ = 0;
  BExpression? _op1;
  BExpression? _op2;
  BExpression? _op3;
  double _numberValue = 0.0; // a float value
  int _variableIdx = 0;
  int _lookupNameIdx = -1;
  Int32List? _lookupValueIdxArray;
  bool _doNotChange = false;

  /// Parses the expression and all subexpressions.
  static BExpression? parse(BExpressionContext ctx, int level) => _parse(ctx, level, null);

  static BExpression? _parse(BExpressionContext ctx, int level, String? optionalToken) {
    var e = _parseRaw(ctx, level, optionalToken);
    if (e == null) return null;

    final lastAssigned = ctx._lastAssignedExpression!;
    if (_assignExp == e._typ) {
      // manage assigned and injected values
      final assignedBefore = lastAssigned[e._variableIdx];
      if (assignedBefore != null && assignedBefore._doNotChange) {
        e._op1 = assignedBefore; // was injected as key-value
        e._op1!._doNotChange = false; // protect just once, can be changed in second assignment
      }
      lastAssigned[e._variableIdx] = e._op1;
    } else if (!ctx._skipConstantExpressionOptimizations) {
      // try to simplify the expression
      if (_variableExp == e._typ) {
        final ae = lastAssigned[e._variableIdx];
        if (ae != null && ae._typ == _numberExp) {
          e = ae;
        }
      } else {
        e = e._tryCollapse();
        e = e._tryEvaluateConstant();
      }
    }
    if (level == 0) {
      // mark the used lookups after the expression is collapsed, so lookups
      // de-activated by constant expressions are not marked
      final nodeCount = e._markLookupIdxUsed(ctx);
      ctx._expressionNodeCount = i32(ctx._expressionNodeCount + nodeCount);
    }
    return e;
  }

  int _markLookupIdxUsed(BExpressionContext ctx) {
    var nodeCount = 1;
    if (_lookupNameIdx >= 0) {
      ctx.markLookupIdxUsed(_lookupNameIdx);
    }
    if (_op1 != null) nodeCount += _op1!._markLookupIdxUsed(ctx);
    if (_op2 != null) nodeCount += _op2!._markLookupIdxUsed(ctx);
    if (_op3 != null) nodeCount += _op3!._markLookupIdxUsed(ctx);
    return nodeCount;
  }

  static BExpression? _parseRaw(BExpressionContext ctx, int level, String? optionalToken) {
    if (level > maxProfileNesting) {
      throw ArgumentError('expression nested deeper than $maxProfileNesting levels');
    }
    var brackets = false;
    var operator = ctx._parseToken();
    if (optionalToken != null && optionalToken == operator) {
      operator = ctx._parseToken();
    }
    if ('(' == operator) {
      brackets = true;
      operator = ctx._parseToken();
    }

    if (operator == null) {
      if (level == 0) return null;
      throw ArgumentError('unexpected end of file');
    }

    if (level == 0) {
      if ('assign' != operator) {
        throw ArgumentError("operator $operator is invalid on toplevel (only 'assign' allowed)");
      }
    }

    final exp = BExpression();
    var nops = 3;
    var ifThenElse = false;

    if ('switch' == operator) {
      exp._typ = _switchExp;
    } else if ('if' == operator) {
      exp._typ = _switchExp;
      ifThenElse = true;
    } else {
      nops = 2; // check binary expressions
      switch (operator) {
        case 'or':
          exp._typ = _orExp;
        case 'and':
          exp._typ = _andExp;
        case 'multiply':
          exp._typ = _multiplyExp;
        case 'divide':
          exp._typ = _divideExp;
        case 'add':
          exp._typ = _addExp;
        case 'max':
          exp._typ = _maxExp;
        case 'min':
          exp._typ = _minExp;
        case 'equal':
          exp._typ = _equalExp;
        case 'greater':
          exp._typ = _greaterExp;
        case 'sub':
          exp._typ = _subExp;
        case 'lesser':
          exp._typ = _lesserExp;
        case 'xor':
          exp._typ = _xorExp;
        default:
          nops = 1; // check unary expressions
          if ('assign' == operator) {
            if (level > 0) throw ArgumentError('assign operator within expression');
            exp._typ = _assignExp;
            final variable = ctx._parseToken();
            if (variable == null) throw ArgumentError('unexpected end of file');
            if (variable.contains('=')) throw ArgumentError("variable name cannot contain '=': $variable");
            if (variable.contains(':')) throw ArgumentError('cannot assign context-prefixed variable: $variable');
            exp._variableIdx = ctx._getVariableIdx(variable, true);
            if (exp._variableIdx < ctx._minWriteIdx) throw ArgumentError('cannot assign to readonly variable $variable');
          } else if ('not' == operator) {
            exp._typ = _notExp;
          } else {
            nops = 0; // check elementary expressions
            var idx = operator.indexOf('=');
            if (idx >= 0) {
              exp._typ = _lookupExp;
              final name = operator.substring(0, idx);
              final values = operator.substring(idx + 1);

              exp._lookupNameIdx = ctx.getLookupNameIdx(name);
              if (exp._lookupNameIdx < 0) {
                throw ArgumentError('unknown lookup name: $name');
              }
              final tk = stringTokens(values, '|');
              final nt = tk.length;
              final nt2 = nt == 0 ? 1 : nt;
              final arr = exp._lookupValueIdxArray = Int32List(nt2);
              for (var ti = 0; ti < nt2; ti++) {
                final value = ti < nt ? tk[ti] : '';
                arr[ti] = ctx._getLookupValueIdx(exp._lookupNameIdx, value);
                if (arr[ti] < 0) {
                  throw ArgumentError('unknown lookup value: $value');
                }
              }
            } else if ((idx = operator.indexOf(':')) >= 0) {
              // use of variable values, e.g.
              //   assign no_height
              //      switch and not maxheight=
              //               lesser v:maxheight my_height true
              //      false
              if (operator.startsWith('v:')) {
                final name = operator.substring(2);
                exp._typ = _variableGetExp;
                exp._lookupNameIdx = ctx.getLookupNameIdx(name);
              } else {
                final context = operator.substring(0, idx);
                final varname = operator.substring(idx + 1);
                exp._typ = _foreignVariableExp;
                exp._variableIdx = ctx.getForeignVariableIdx(context, varname);
              }
            } else if ((idx = ctx._getVariableIdx(operator, false)) >= 0) {
              exp._typ = _variableExp;
              exp._variableIdx = idx;
            } else if ('true' == operator) {
              exp._numberValue = 1.0;
              exp._typ = _numberExp;
            } else if ('false' == operator) {
              exp._numberValue = 0.0;
              exp._typ = _numberExp;
            } else {
              try {
                exp._numberValue = javaParseFloat(operator);
                exp._typ = _numberExp;
              } on FormatException {
                throw ArgumentError('unknown expression: $operator');
              }
            }
          }
      }
    }
    // parse operands
    if (nops > 0) {
      exp._op1 = _parse(ctx, level + 1, exp._typ == _assignExp ? '=' : null);
    }
    if (nops > 1) {
      if (ifThenElse) _checkExpectedToken(ctx, 'then');
      exp._op2 = _parse(ctx, level + 1, null);
    }
    if (nops > 2) {
      if (ifThenElse) _checkExpectedToken(ctx, 'else');
      exp._op3 = _parse(ctx, level + 1, null);
    }
    if (brackets) {
      _checkExpectedToken(ctx, ')');
    }
    return exp;
  }

  static void _checkExpectedToken(BExpressionContext ctx, String expected) {
    final token = ctx._parseToken();
    if (expected != token) {
      throw ArgumentError('unexpected token: $token, expected: $expected');
    }
  }

  /// Evaluates the expression; [ctx] is null only for constant folding.
  double evaluate(BExpressionContext? ctx) {
    switch (_typ) {
      case _orExp:
        return _op1!.evaluate(ctx) != 0.0 ? 1.0 : (_op2!.evaluate(ctx) != 0.0 ? 1.0 : 0.0);
      case _xorExp:
        return ((_op1!.evaluate(ctx) != 0.0) != (_op2!.evaluate(ctx) != 0.0)) ? 1.0 : 0.0;
      case _andExp:
        return _op1!.evaluate(ctx) != 0.0 ? (_op2!.evaluate(ctx) != 0.0 ? 1.0 : 0.0) : 0.0;
      case _addExp:
        return fround(_op1!.evaluate(ctx) + _op2!.evaluate(ctx));
      case _subExp:
        return fround(_op1!.evaluate(ctx) - _op2!.evaluate(ctx));
      case _multiplyExp:
        return fround(_op1!.evaluate(ctx) * _op2!.evaluate(ctx));
      case _divideExp:
        return _divide(_op1!.evaluate(ctx), _op2!.evaluate(ctx));
      case _maxExp:
        return _max(_op1!.evaluate(ctx), _op2!.evaluate(ctx));
      case _minExp:
        return _min(_op1!.evaluate(ctx), _op2!.evaluate(ctx));
      case _equalExp:
        return _op1!.evaluate(ctx) == _op2!.evaluate(ctx) ? 1.0 : 0.0;
      case _greaterExp:
        return _op1!.evaluate(ctx) > _op2!.evaluate(ctx) ? 1.0 : 0.0;
      case _lesserExp:
        return _op1!.evaluate(ctx) < _op2!.evaluate(ctx) ? 1.0 : 0.0;
      case _switchExp:
        return _op1!.evaluate(ctx) != 0.0 ? _op2!.evaluate(ctx) : _op3!.evaluate(ctx);
      case _assignExp:
        return ctx!._assign(_variableIdx, _op1!.evaluate(ctx));
      case _lookupExp:
        return ctx!._getLookupMatch(_lookupNameIdx, _lookupValueIdxArray!);
      case _numberExp:
        return _numberValue;
      case _variableExp:
        return ctx!._getVariableValue(_variableIdx);
      case _foreignVariableExp:
        return ctx!.getForeignVariableValue(_variableIdx);
      case _variableGetExp:
        return ctx!.getLookupValue(_lookupNameIdx);
      case _notExp:
        return _op1!.evaluate(ctx) == 0.0 ? 1.0 : 0.0;
      default:
        throw ArgumentError('unknown op-code: $_typ');
    }
  }

  // Collapses the expression if logically possible.
  BExpression _tryCollapse() {
    final op1 = _op1, op2 = _op2;
    switch (_typ) {
      case _orExp:
        return _numberExp == op1!._typ
            ? (op1._numberValue != 0.0 ? op1 : op2!)
            : (_numberExp == op2!._typ ? (op2._numberValue != 0.0 ? op2 : op1) : this);
      case _andExp:
        return _numberExp == op1!._typ
            ? (op1._numberValue == 0.0 ? op1 : op2!)
            : (_numberExp == op2!._typ ? (op2._numberValue == 0.0 ? op2 : op1) : this);
      case _addExp:
        return _numberExp == op1!._typ
            ? (op1._numberValue == 0.0 ? op2! : this)
            : (_numberExp == op2!._typ ? (op2._numberValue == 0.0 ? op1 : this) : this);
      case _switchExp:
        return _numberExp == op1!._typ ? (op1._numberValue == 0.0 ? _op3! : op2!) : this;
      default:
        return this;
    }
  }

  // Evaluates the expression if all operands are constant.
  BExpression _tryEvaluateConstant() {
    if (_op1 != null &&
        _numberExp == _op1!._typ &&
        (_op2 == null || _numberExp == _op2!._typ) &&
        (_op3 == null || _numberExp == _op3!._typ)) {
      final exp = BExpression();
      exp._typ = _numberExp;
      exp._numberValue = evaluate(null);
      return exp;
    }
    return this;
  }

  double _max(double v1, double v2) => v1 > v2 ? v1 : v2;

  double _min(double v1, double v2) => v1 < v2 ? v1 : v2;

  double _divide(double v1, double v2) {
    if (v2 == 0.0) throw ArgumentError('div by zero');
    return fround(v1 / v2);
  }

  @override
  String toString() {
    if (_typ == _numberExp) return javaFloatToString(_numberValue);
    if (_typ == _variableExp) return 'vidx=$_variableIdx';
    final sb = StringBuffer('typ=$_typ ops=(');
    for (final e in [_op1, _op2, _op3]) {
      if (e != null) sb.write('[$e]');
    }
    sb.write(')');
    return sb.toString();
  }

  static BExpression _createAssignExpressionFromKeyValue(BExpressionContext ctx, String key, String value) {
    final e = BExpression();
    e._typ = _assignExp;
    e._variableIdx = ctx._getVariableIdx(key, true);
    final op1 = e._op1 = BExpression();
    op1._typ = _numberExp;
    try {
      op1._numberValue = javaParseFloat(value);
    } on FormatException {
      // NumberFormatException is an IllegalArgumentException in Java
      throw ArgumentError('For input string: "$value"');
    }
    op1._doNotChange = true;
    ctx._lastAssignedExpression![e._variableIdx] = op1;
    return e;
  }
}
