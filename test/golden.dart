// Reads golden/data (FORMAT.md).
import 'dart:io';
import 'dart:typed_data';

/// The lines of a gzipped table in golden/data, split on tabs.
List<List<String>> goldenTable(String name) {
  final file = File('golden/data/$name');
  final text = String.fromCharCodes(gzip.decode(file.readAsBytesSync()));
  return [for (final line in text.split('\n')) if (line.isNotEmpty) line.split('\t')];
}

final _bd = ByteData(8);

/// A double from its 16-hex-digit raw bits.
double dbl(String hex) {
  _bd.setUint32(0, int.parse(hex.substring(0, 8), radix: 16));
  _bd.setUint32(4, int.parse(hex.substring(8), radix: 16));
  return _bd.getFloat64(0);
}

/// The raw bits of [d] as 16 lowercase hex digits.
String bits(double d) {
  _bd.setFloat64(0, d);
  // two halves: a Dart int above 2^63 would print negative
  return _bd.getUint32(0).toRadixString(16).padLeft(8, '0') + _bd.getUint32(4).toRadixString(16).padLeft(8, '0');
}

Uint8List hexBytes(String hex) =>
    Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);

String toHex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

final _checked = <String, File>{};

/// A file of the golden input release (golden/data/INPUT), checked against
/// its SHA-256 there; fails, rather than skips, when it is missing or its
/// sum differs (FORMAT.md "輸入"). The release files are not in git: when
/// `golden/.build/input/<release>/` (where golden/gen.sh puts them) does not
/// exist yet, this downloads the release with `gh release download`.
///
/// `dart test` loads suites in parallel isolates of one process, where file
/// locks do not exclude each other. So the first caller to create a marker
/// file exclusively downloads into a temporary directory and renames it
/// into place; the others wait for the directory to appear.
File goldenInput(String name) {
  final done = _checked[name];
  if (done != null) return done;
  final lines = File('golden/data/INPUT').readAsLinesSync().where((l) => l.isNotEmpty).toList();
  final release = lines.first.split(' ')[1];
  final dir = Directory('golden/.build/input/$release');
  if (!dir.existsSync()) _download(release, dir);
  final file = File('${dir.path}/$name');
  if (!file.existsSync()) throw StateError('${file.path} missing');
  final want = [
    for (final l in lines.skip(1))
      if (l.endsWith('  $name')) l.split(' ').first,
  ];
  if (want.length != 1) throw StateError('no checksum for $name in golden/data/INPUT');
  final got = toHex(sha256(file.readAsBytesSync()));
  if (got != want.single) throw StateError('${file.path}: sha256 $got, golden/data/INPUT says ${want.single}');
  return _checked[name] = file;
}

void _download(String release, Directory dir) {
  dir.parent.createSync(recursive: true);
  final marker = File('${dir.path}.downloading');
  try {
    marker.createSync(exclusive: true);
  } on FileSystemException {
    // Someone else is downloading: wait for the directory.
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (!dir.existsSync()) {
      if (!marker.existsSync() && !dir.existsSync()) {
        throw StateError('the download of $release by another suite failed');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('waited 10 minutes for ${dir.path}; delete ${marker.path} if no download is running');
      }
      sleep(const Duration(milliseconds: 200));
    }
    return;
  }
  try {
    // Another caller may have finished between our check and the marker.
    if (dir.existsSync()) return;
    final tmp = Directory('${dir.path}.tmp');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync();
    final r = Process.runSync(
      'gh',
      ['release', 'download', release, '--repo', 'outdoorsafetylab/brouter_dart', '--dir', tmp.path],
    );
    if (r.exitCode != 0) {
      tmp.deleteSync(recursive: true);
      throw StateError('gh release download $release failed: ${r.stderr}');
    }
    tmp.renameSync(dir.path);
  } finally {
    marker.deleteSync();
  }
}

// SHA-256 (FIPS 180-4), so the tests need no package beyond `test`.

const _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

/// The SHA-256 digest of [data].
Uint8List sha256(List<int> data) {
  final h = Uint32List.fromList([
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ]);
  final bitLen = data.length * 8;
  final padded = Uint8List(((data.length + 9 + 63) ~/ 64) * 64);
  padded.setRange(0, data.length, data);
  padded[data.length] = 0x80;
  final pv = ByteData.sublistView(padded);
  pv.setUint32(padded.length - 8, bitLen ~/ 0x100000000);
  pv.setUint32(padded.length - 4, bitLen & 0xffffffff);
  final w = Uint32List(64);
  for (var off = 0; off < padded.length; off += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = pv.getUint32(off + 4 * t);
    }
    for (var t = 16; t < 64; t++) {
      final x = w[t - 15], y = w[t - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      w[t] = w[t - 16] + s0 + w[t - 7] + s1;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & 0xffffffff & g);
      final t1 = (hh + s1 + ch + _k[t] + w[t]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] += a;
    h[1] += b;
    h[2] += c;
    h[3] += d;
    h[4] += e;
    h[5] += f;
    h[6] += g;
    h[7] += hh;
  }
  final out = Uint8List(32);
  final ov = ByteData.sublistView(out);
  for (var i = 0; i < 8; i++) {
    ov.setUint32(4 * i, h[i]);
  }
  return out;
}
