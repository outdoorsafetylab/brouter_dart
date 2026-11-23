// Port of btools.expressions.BExpressionContextWay (BRouter v1.7.10, MIT).
part of 'expressions.dart';

/// The rules of the way context; also the decoder's way validator.
final class BExpressionContextWay extends BExpressionContext implements TagValueValidator {
  bool _decodeForbidden = true;

  static const _buildInVariables = [
    'costfactor', 'turncost', 'uphillcostfactor', 'downhillcostfactor', 'initialcost', //
    'nodeaccessgranted', 'initialclassifier', 'trafficsourcedensity', 'istrafficbackbone', //
    'priorityclassifier', 'classifiermask', 'maxspeed', 'uphillcost', 'downhillcost', //
    'uphillcutoff', 'downhillcutoff', 'uphillmaxslope', 'downhillmaxslope', //
    'uphillmaxslopecost', 'downhillmaxslopecost',
  ];

  /// The build-in variable names, in [getBuildInVariable] order.
  static List<String> get buildInVariableNames => _buildInVariables;

  @override
  List<String> get _buildInVariableNames => _buildInVariables;

  double getCostfactor() => getBuildInVariable(0);
  double getTurncost() => getBuildInVariable(1);
  double getUphillCostfactor() => getBuildInVariable(2);
  double getDownhillCostfactor() => getBuildInVariable(3);
  double getInitialcost() => getBuildInVariable(4);
  double getNodeAccessGranted() => getBuildInVariable(5);
  double getInitialClassifier() => getBuildInVariable(6);
  double getTrafficSourceDensity() => getBuildInVariable(7);
  double getIsTrafficBackbone() => getBuildInVariable(8);
  double getPriorityClassifier() => getBuildInVariable(9);
  double getClassifierMask() => getBuildInVariable(10);
  double getMaxspeed() => getBuildInVariable(11);
  double getUphillcost() => getBuildInVariable(12);
  double getDownhillcost() => getBuildInVariable(13);
  double getUphillcutoff() => getBuildInVariable(14);
  double getDownhillcutoff() => getBuildInVariable(15);
  double getUphillmaxslope() => getBuildInVariable(16);
  double getDownhillmaxslope() => getBuildInVariable(17);
  double getUphillmaxslopecost() => getBuildInVariable(18);
  double getDownhillmaxslopecost() => getBuildInVariable(19);

  BExpressionContextWay(BExpressionMetaData? meta) : super('way', 4096, meta);

  /// [hashSize] is the size of the result cache; 0 turns it off.
  BExpressionContextWay.withHashSize(int hashSize, BExpressionMetaData? meta) : super('way', hashSize, meta);

  @override
  int accessType(Uint8List description) {
    evaluate(false, description);
    var minCostFactor = getCostfactor();
    if (minCostFactor >= 9999.0) {
      _setInverseVars();
      final reverseCostFactor = getCostfactor();
      if (reverseCostFactor < minCostFactor) {
        minCostFactor = reverseCostFactor;
      }
    }
    return minCostFactor < 9999.0
        ? 2
        : _decodeForbidden
            ? (minCostFactor < 10000.0 ? 1 : 0)
            : 0;
  }

  @override
  void setDecodeForbidden(bool decodeForbidden) {
    _decodeForbidden = decodeForbidden;
  }
}
