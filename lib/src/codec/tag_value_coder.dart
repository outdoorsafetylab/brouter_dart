// Port of btools.codec.TagValueCoder (BRouter v1.7.10, MIT), decoding side.
import 'dart:typed_data';

import '../util/bit_coder_context.dart';
import 'data_buffers.dart';
import 'tag_value_validator.dart';
import 'tag_value_wrapper.dart';

/// Deepest tag tree accepted, counted in inner nodes from the root; the
/// golden segments reach 14. BRouter has no limit, and a deeper tree would
/// only take more stack.
const maxTagTreeDepth = 256;

/// Decoder for way and node descriptions, stored as a huffman tree sorted
/// by frequency.
class TagValueCoder {
  final Object? _tree; // _TreeNode, TagValueWrapper or null
  final BitCoderContext _bc;

  TagValueCoder(BitCoderContext bc, DataBuffers buffers, TagValueValidator? validator)
    : _tree = _decodeTree(bc, buffers, validator, 0),
      _bc = bc;

  TagValueWrapper? decodeTagValueSet() {
    var node = _tree;
    while (node is _TreeNode) {
      final nextBit = _bc.decodeBit();
      node = nextBit ? node.child2 : node.child1;
    }
    return node as TagValueWrapper?;
  }

  static Object? _decodeTree(BitCoderContext bc, DataBuffers buffers, TagValueValidator? validator, int depth) {
    final isNode = bc.decodeBit();
    if (isNode) {
      if (depth >= maxTagTreeDepth) {
        throw FormatException('tag tree deeper than $maxTagTreeDepth');
      }
      final child1 = _decodeTree(bc, buffers, validator, depth + 1);
      final child2 = _decodeTree(bc, buffers, validator, depth + 1);
      return _TreeNode(child1, child2);
    }

    final buffer = buffers.tagbuf1;
    final ctx = buffers.bctx1;
    ctx.resetTo(buffer);

    var inum = 0;
    var lastEncodedInum = 0;

    var hasdata = false;
    for (;;) {
      final delta = bc.decodeVarBits();
      if (!hasdata) {
        if (delta == 0) {
          return null;
        }
      }
      if (delta == 0) {
        ctx.encodeVarBits(0);
        break;
      }
      inum += delta;

      final data = bc.decodeVarBits();

      if (validator == null || validator.isLookupIdxUsed(inum)) {
        hasdata = true;
        ctx.encodeVarBits(inum - lastEncodedInum);
        ctx.encodeVarBits(data);
        lastEncodedInum = inum;
      }
    }

    Uint8List res;
    final len = ctx.closeAndGetEncodedLength();
    if (validator == null) {
      res = Uint8List.fromList(buffer.sublist(0, len));
    } else {
      res = validator.unify(buffer, 0, len);
    }

    final accessType = validator == null ? 2 : validator.accessType(res);
    if (accessType > 0) {
      return TagValueWrapper()
        ..data = res
        ..accessType = accessType;
    }
    return null;
  }
}

class _TreeNode {
  final Object? child1;
  final Object? child2;
  _TreeNode(this.child1, this.child2);
}
