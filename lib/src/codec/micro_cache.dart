// Port of btools.codec.MicroCache and btools.codec.MicroCache2
// (BRouter v1.7.10, MIT), decoding side.
import 'dart:typed_data';

import '../util/byte_array_unifier.dart';
import '../util/byte_data.dart';
import '../util/int32.dart';
import 'data_buffers.dart';
import 'linked_list_container.dart';
import 'noisy_diff_coder.dart';
import 'stat_coder_context.dart';
import 'tag_value_coder.dart';
import 'tag_value_validator.dart';
import 'waypoint_matcher.dart';

/// Upper bounds on what one micro-cache may claim, checked before its arrays
/// are allocated; BRouter has none. In the golden segments (Taiwan) a
/// micro-cache holds at most 13,291 nodes and 285,486 bytes of decoded data;
/// the limits leave room for dense cities.
const maxMicroCacheNodes = 1 << 20;
const maxMicroCacheDataSize = 16 << 20;

/// Throws [FormatException] for a node count no valid micro-cache has.
void checkMicroCacheNodes(int size) {
  if (size < 0 || size > maxMicroCacheNodes) {
    throw FormatException('micro-cache claims $size nodes');
  }
}

/// Throws [FormatException] for a link to a node outside the micro-cache.
void checkLinkTarget(int nodeIdx, int size) {
  if (nodeIdx < 0 || nodeIdx >= size) {
    throw FormatException('link to node $nodeIdx of $size');
  }
}

/// The data of an area of some square kilometres: the unit of io. Nodes are
/// kept compact and independent of each other, so the ones already consumed
/// can be garbage collected. The format differs from the data files, where
/// a cache is encoded as a whole.
class MicroCache extends ByteDataWriter {
  Int32List? faid;
  Int32List? fapos;
  // Java's field `size`; Dart cannot have a field next to ByteDataWriter's size().
  int _size = 0;

  int _delcount = 0;
  int _delbytes = 0;
  int _p2size = 0; // next power of 2 of size

  // cache control: a virgin cache can be put to ghost state for later
  // recovery
  bool virgin = true;
  bool ghost = false;

  MicroCache._(super.ab);

  static final MicroCache emptyNonVirgin = MicroCache._(null)..virgin = false;

  static MicroCache emptyCache() => MicroCache._(null);

  void init(int size) {
    _size = size;
    _delcount = 0;
    _delbytes = 0;
    _p2size = 0x40000000;
    while (_p2size > size) {
      _p2size >>= 1;
    }
  }

  int getSize() => _size;

  int getDataSize() => ab == null ? 0 : ab!.length;

  /// Points the reader (aboffset, aboffsetEnd) at the body of the node
  /// [id64] and marks it consumed. False if it is not here or was consumed
  /// already.
  bool getAndClear(int id64) {
    if (_size == 0) {
      return false;
    }
    final id = shrinkId(id64);
    final a = faid!;
    final fp = fapos!;
    var offset = _p2size;
    var n = 0;

    while (offset > 0) {
      final nn = n + offset;
      if (nn < _size && a[nn] <= id) {
        n = nn;
      }
      offset >>= 1;
    }
    if (a[n] == id) {
      if ((fp[n] & 0x80000000) == 0) {
        aboffset = startPos(n);
        aboffsetEnd = fp[n];
        fp[n] |= 0x80000000; // mark deleted
        _delbytes += aboffsetEnd - aboffset;
        _delcount++;
        return true;
      }
      // else: marked as deleted, already consumed
    }
    return false;
  }

  int startPos(int n) => n > 0 ? fapos![n - 1] & 0x7fffffff : 0;

  int collect(int threshold) {
    if (_delcount <= threshold) {
      return 0;
    }

    virgin = false;

    final nsize = _size - _delcount;
    if (nsize == 0) {
      faid = null;
      fapos = null;
    } else {
      final nfaid = Int32List(nsize);
      final nfapos = Int32List(nsize);
      var idx = 0;

      final old = ab!;
      final nab = Uint8List(old.length - _delbytes);
      var nabOff = 0;
      for (var i = 0; i < _size; i++) {
        final pos = fapos![i];
        if ((pos & 0x80000000) == 0) {
          final start = startPos(i);
          final end = fapos![i];
          final len = end - start;
          nab.setRange(nabOff, nabOff + len, old, start);
          nfaid[idx] = faid![i];
          nabOff += len;
          nfapos[idx] = nabOff;
          idx++;
        }
      }
      faid = nfaid;
      fapos = nfapos;
      ab = nab;
    }
    final deleted = _delbytes;
    init(nsize);
    return deleted;
  }

  void unGhost() {
    ghost = false;
    _delcount = 0;
    _delbytes = 0;
    for (var i = 0; i < _size; i++) {
      fapos![i] &= 0x7fffffff; // clear deleted flags
    }
  }

  /// The 64-bit global id of cache position [i].
  int getIdForIndex(int i) => expandId(faid![i]);

  /// Expands a 32-bit cache-internal id into a 64-bit (lon|lat) global id.
  int expandId(int id32) => throw ArgumentError('expandId for empty cache');

  /// Shrinks a 64-bit (lon|lat) global id into a 32-bit cache-internal id.
  int shrinkId(int id64) => throw ArgumentError('shrinkId for empty cache');

  /// Whether the position lies inside this micro-cache.
  bool isInternal(int ilon, int ilat) => throw ArgumentError('isInternal for empty cache');
}

/// The statistically encoded format, with access filtering and waypoint
/// matching during decoding.
class MicroCache2 extends MicroCache {
  final int _lonBase;
  final int _latBase;
  final int _cellsize;

  Uint8List readUnified(int len, IByteArrayUnifier u) {
    final b = u.unify(ab!, aboffset, len);
    aboffset += len;
    return b;
  }

  /// Decodes one micro-cache. With a [wayValidator], ways it rejects are
  /// dropped; a [waypointMatcher] sees the geometry of every way it accepts.
  MicroCache2(
    StatCoderContext bc,
    DataBuffers dataBuffers,
    int lonIdx,
    int latIdx,
    int divisor,
    TagValueValidator? wayValidator,
    WaypointMatcher? waypointMatcher,
  ) : _cellsize = 1000000 ~/ divisor,
      _lonBase = i32(lonIdx * (1000000 ~/ divisor)),
      _latBase = i32(latIdx * (1000000 ~/ divisor)),
      super._(null) {
    final wayTagCoder = TagValueCoder(bc, dataBuffers, wayValidator);
    final nodeTagCoder = TagValueCoder(bc, dataBuffers, null);
    final nodeIdxDiff = NoisyDiffCoder(bc);
    final nodeEleDiff = NoisyDiffCoder(bc);
    final extLonDiff = NoisyDiffCoder(bc);
    final extLatDiff = NoisyDiffCoder(bc);
    final transEleDiff = NoisyDiffCoder(bc);

    _size = bc.decodeNoisyNumber(5);
    checkMicroCacheNodes(_size);
    var faid = _size > dataBuffers.ibuf2.length ? Int32List(_size) : dataBuffers.ibuf2;
    var fapos = _size > dataBuffers.ibuf3.length ? Int32List(_size) : dataBuffers.ibuf3;

    final alon = _size > dataBuffers.alon.length ? Int32List(_size) : dataBuffers.alon;
    final alat = _size > dataBuffers.alat.length ? Int32List(_size) : dataBuffers.alat;

    bc.decodeSortedArray(faid, 0, _size, 29, 0);

    for (var n = 0; n < _size; n++) {
      final id64 = expandId(faid[n]);
      alon[n] = i32(id64 >> 32);
      alat[n] = i32(id64 & 0xffffffff);
    }

    final netdatasize = bc.decodeNoisyNumber(10);
    if (netdatasize < 0 || netdatasize > maxMicroCacheDataSize) {
      throw FormatException('micro-cache claims $netdatasize bytes of data');
    }
    ab = netdatasize > dataBuffers.bbuf1.length ? Uint8List(netdatasize) : dataBuffers.bbuf1;
    aboffset = 0;

    final validBits = Int32List((_size + 31) >> 5);

    var finaldatasize = 0;

    final reverseLinks = LinkedListContainer(_size, dataBuffers.ibuf1);

    var selev = 0;
    for (var n = 0; n < _size; n++) {
      // loop over nodes
      final ilon = alon[n];
      final ilat = alat[n];

      // future escapes (turn restrictions?)
      var trExceptions = 0;
      var featureId = bc.decodeVarBits();
      if (featureId == 13) {
        fapos[n] = aboffset;
        validBits[n >> 5] |= shl(1, n); // mark dummy-node valid
        continue; // empty node escape (delta files only)
      }
      while (featureId != 0) {
        final bitsize = bc.decodeNoisyNumber(5);

        if (featureId == 2) {
          // exceptions to turn-restriction
          trExceptions = i16(bc.decodeBounded(1023));
        } else if (featureId == 1) {
          // turn-restriction
          writeBoolean(true);
          writeShort(trExceptions); // exceptions from previous feature
          trExceptions = 0;

          writeBoolean(bc.decodeBit()); // isPositive
          writeInt(ilon + bc.decodeNoisyDiff(10)); // fromLon
          writeInt(ilat + bc.decodeNoisyDiff(10)); // fromLat
          writeInt(ilon + bc.decodeNoisyDiff(10)); // toLon
          writeInt(ilat + bc.decodeNoisyDiff(10)); // toLat
        } else {
          for (var i = 0; i < bitsize; i++) {
            bc.decodeBit(); // unknown feature, just skip
          }
        }
        featureId = bc.decodeVarBits();
      }
      writeBoolean(false);

      selev = i32(selev + nodeEleDiff.decodeSignedValue());
      writeShort(i16(selev));
      final nodeTags = nodeTagCoder.decodeTagValueSet();
      writeVarBytes(nodeTags?.data);

      final links = bc.decodeNoisyNumber(1);
      for (var li = 0; li < links; li++) {
        var sizeoffset = 0;
        final nodeIdx = n + nodeIdxDiff.decodeSignedValue();
        checkLinkTarget(nodeIdx, _size);

        int dlonRemaining;
        int dlatRemaining;

        var isReverse = false;
        if (nodeIdx != n) {
          // internal (forward-) link
          dlonRemaining = i32(alon[nodeIdx] - ilon);
          dlatRemaining = i32(alat[nodeIdx] - ilat);
        } else {
          isReverse = bc.decodeBit();
          dlonRemaining = extLonDiff.decodeSignedValue();
          dlatRemaining = extLatDiff.decodeSignedValue();
        }

        final wayTags = wayTagCoder.decodeTagValueSet();

        final linkValid = wayTags != null || wayValidator == null;
        if (linkValid) {
          final startPointer = aboffset;
          sizeoffset = writeSizePlaceHolder();

          writeVarLengthSigned(dlonRemaining);
          writeVarLengthSigned(dlatRemaining);

          validBits[n >> 5] |= shl(1, n); // mark source-node valid
          if (nodeIdx != n) {
            // valid internal (forward-) link
            reverseLinks.addDataElement(nodeIdx, n); // register reverse link
            finaldatasize += 1 + aboffset - startPointer; // reserve place for reverse
            validBits[nodeIdx >> 5] |= shl(1, nodeIdx); // mark target-node valid
          }
          writeModeAndDesc(isReverse, wayTags?.data);
        }

        if (!isReverse) {
          // write geometry for forward links only
          var matcher = wayTags == null || wayTags.accessType < 2 ? null : waypointMatcher;
          final ilontarget = i32(ilon + dlonRemaining);
          final ilattarget = i32(ilat + dlatRemaining);
          if (matcher != null) {
            final useAsStartWay = wayValidator!.checkStartWay(wayTags!.data);
            if (!matcher.start(ilon, ilat, ilontarget, ilattarget, useAsStartWay)) {
              matcher = null;
            }
          }

          final transcount = bc.decodeVarBits();
          var count = transcount + 1;
          for (var i = 0; i < transcount; i++) {
            final dlon = bc.decodePredictedValue(dlonRemaining ~/ count);
            final dlat = bc.decodePredictedValue(dlatRemaining ~/ count);
            dlonRemaining = i32(dlonRemaining - dlon);
            dlatRemaining = i32(dlatRemaining - dlat);
            count--;
            final elediff = transEleDiff.decodeSignedValue();
            if (wayTags != null) {
              writeVarLengthSigned(dlon);
              writeVarLengthSigned(dlat);
              writeVarLengthSigned(elediff);
            }

            matcher?.transferNode(i32(ilontarget - dlonRemaining), i32(ilattarget - dlatRemaining));
          }
          matcher?.end();
        }
        if (linkValid) {
          injectSize(sizeoffset);
        }
      }
      fapos[n] = aboffset;
    }

    // calculate final data size
    var finalsize = 0;
    var startpos = 0;
    for (var i = 0; i < _size; i++) {
      final endpos = fapos[i];
      if ((validBits[i >> 5] & shl(1, i)) != 0) {
        finaldatasize += endpos - startpos;
        finalsize++;
      }
      startpos = endpos;
    }
    // append the reverse links at the end of each node
    final abOld = ab!;
    final faidOld = faid;
    final faposOld = fapos;
    final sizeOld = _size;
    ab = Uint8List(finaldatasize);
    faid = Int32List(finalsize);
    fapos = Int32List(finalsize);
    this.faid = faid;
    this.fapos = fapos;
    aboffset = 0;
    _size = 0;

    startpos = 0;
    for (var n = 0; n < sizeOld; n++) {
      final endpos = faposOld[n];
      if ((validBits[n >> 5] & shl(1, n)) != 0) {
        final len = endpos - startpos;
        ab!.setRange(aboffset, aboffset + len, abOld, startpos);
        aboffset += len;

        final cnt = reverseLinks.initList(n);

        for (var ri = 0; ri < cnt; ri++) {
          final nodeIdx = reverseLinks.getDataElement();
          final sizeoffset = writeSizePlaceHolder();
          writeVarLengthSigned(i32(alon[nodeIdx] - alon[n]));
          writeVarLengthSigned(i32(alat[nodeIdx] - alat[n]));
          writeModeAndDesc(true, null);
          injectSize(sizeoffset);
        }
        faid[_size] = faidOld[n];
        fapos[_size] = aboffset;
        _size++;
      }
      startpos = endpos;
    }
    init(_size);
  }

  @override
  int expandId(int id32) {
    var dlon = 0;
    var dlat = 0;

    for (var bm = 1; bm < 0x8000; bm <<= 1) {
      if ((id32 & 1) != 0) dlon |= bm;
      if ((id32 & 2) != 0) dlat |= bm;
      id32 = sar(id32, 2);
    }

    final lon32 = i32(_lonBase + dlon);
    final lat32 = i32(_latBase + dlat);

    // Java `((long) lon32) << 32 | lat32`: lat32 is sign-extended, as here
    return (lon32 << 32) | lat32;
  }

  @override
  int shrinkId(int id64) {
    final lon32 = i32(id64 >> 32);
    final lat32 = i32(id64 & 0xffffffff);
    final dlon = i32(lon32 - _lonBase);
    final dlat = i32(lat32 - _latBase);
    var id32 = 0;

    for (var bm = 0x4000; bm > 0; bm >>= 1) {
      id32 = shl(id32, 2);
      if ((dlon & bm) != 0) id32 |= 1;
      if ((dlat & bm) != 0) id32 |= 2;
    }
    return id32;
  }

  @override
  bool isInternal(int ilon, int ilat) =>
      ilon >= _lonBase && ilon < _lonBase + _cellsize && ilat >= _latBase && ilat < _latBase + _cellsize;
}
