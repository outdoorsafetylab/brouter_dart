// Port of btools.expressions.BExpressionContextNode (BRouter v1.7.10, MIT).
part of 'expressions.dart';

/// The rules of the node context.
final class BExpressionContextNode extends BExpressionContext {
  static const _buildInVariables = ['initialcost'];

  @override
  List<String> get _buildInVariableNames => _buildInVariables;

  double getInitialcost() => getBuildInVariable(0);

  BExpressionContextNode(BExpressionMetaData? meta) : super('node', 4096, meta);

  /// [hashSize] is the size of the result cache; 0 turns it off.
  BExpressionContextNode.withHashSize(int hashSize, BExpressionMetaData? meta) : super('node', hashSize, meta);
}
