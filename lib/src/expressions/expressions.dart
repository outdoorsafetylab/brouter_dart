// Port of the package btools.expressions (BRouter v1.7.10, MIT): lookups.dat
// and .brf parsing and evaluation. One part file per Java class, so the
// members Java keeps package-private stay private to this library.
//
// Not ported: the standalone tools IntegrityCheckProfile and
// ProfileComparator.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../codec/tag_value_validator.dart';
import '../util/bit_coder_context.dart';
import '../util/byte_array_unifier.dart';
import '../util/crc32.dart';
import '../util/float32.dart';
import '../util/int32.dart';
import '../util/java_string.dart';
import '../util/lru_map.dart';

part 'b_expression.dart';
part 'b_expression_context.dart';
part 'b_expression_context_node.dart';
part 'b_expression_context_way.dart';
part 'b_expression_lookup_value.dart';
part 'b_expression_meta_data.dart';
part 'cache_node.dart';
part 'var_wrapper.dart';
