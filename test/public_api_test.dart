// The public library, package:brouter/brouter.dart, as an app uses it: no
// import of lib/src.
import 'dart:io';

import 'package:brouter/brouter.dart';
import 'package:test/test.dart';

import 'golden.dart';

void main() {
  final segments = goldenInput('E120_N20.rd5').parent;

  test('routes a golden case through the public library', () {
    final route = goldenTable('routes.tsv.gz').firstWhere((r) => r[0] == 'route' && r[7] == 'ok');
    OsmNodeNamed node(String name, int i) => OsmNodeNamed()
      ..name = name
      ..ilon = int.parse(route[i])
      ..ilat = int.parse(route[i + 1]);
    final rc = RoutingContext()..localFunction = '${segments.path}/${route[2]}.brf';
    final re = RoutingEngine(segments, [node('from', 3), node('to', 5)], rc)..doRun(15000);
    expect(re.getErrorMessage(), isNull);
    final OsmTrack track = re.getFoundTrack()!;
    final List<OsmPathElement> points = track.nodes;
    expect('${track.distance}', route[8]);
    expect('${points.length}', route[14]);
  });

  group('verifyLookups', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('brouter_verify'));
    tearDown(() => tmp.deleteSync(recursive: true));

    // A directory with the golden segments (linked, not copied) and the
    // given lookups.dat text.
    Directory withLookups(String lookups) {
      for (final name in ['E120_N20.rd5', 'E120_N25.rd5']) {
        Link('${tmp.path}/$name').createSync('${segments.absolute.path}/$name');
      }
      File('${tmp.path}/lookups.dat').writeAsStringSync(lookups);
      return tmp;
    }

    final lookups = File('${segments.path}/lookups.dat');

    test('passes the golden inputs, every rd5 or the ones named', () {
      expect(verifyLookups(segments), 2);
      expect(verifyLookups(segments, ['E120_N25.rd5']), 1);
    });

    test('refuses segments of another lookup version', () {
      final text = lookups.readAsStringSync();
      final version = RegExp(r'---lookupversion:(\d+)').firstMatch(text)!;
      final other = text.replaceFirst(version.group(0)!, '---lookupversion:${int.parse(version.group(1)!) + 1}');
      expect(
        () => verifyLookups(withLookups(other)),
        throwsA(isA<DataFileException>().having((e) => e.message, 'message', contains('lookup version mismatch'))),
      );
    });

    test('refuses a lookups.dat without a version', () {
      expect(() => verifyLookups(withLookups('---context:way\nhighway;0001 track\n')), throwsFormatException);
    });

    test('refuses a missing segment', () {
      withLookups(lookups.readAsStringSync());
      expect(() => verifyLookups(tmp, ['E125_N25.rd5']), throwsA(isA<FileSystemException>()));
    });

    test('refuses a segment whose header does not read', () {
      withLookups(lookups.readAsStringSync());
      File(
        '${tmp.path}/broken.rd5',
      ).writeAsBytesSync(File('${segments.path}/E120_N25.rd5').readAsBytesSync().sublist(0, 4096));
      expect(() => verifyLookups(tmp, ['broken.rd5']), throwsA(isA<DataFileException>()));
    });
  });
}
