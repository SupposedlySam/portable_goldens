import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/baselines.dart';

import 'support/png.dart';

// Runs the real compare: a generated `flutter test` in this package, which
// has flutter_test, as any package with goldens does. Slow (one Flutter
// test start-up), so every case shares one run.
void main() {
  late Directory dir;
  late List<PixelVerdict> verdicts;
  late List<ImagePair> pairs;
  final runs = <({List<String> args, Map<String, String>? env})>[];

  ImagePair pair(String name, List<int> committed, List<int> rendered) {
    final pairDir = Directory('${dir.path}/$name')..createSync();
    return ImagePair(
      committed: (File(
        '${pairDir.path}/committed.png',
      )..writeAsBytesSync(committed)).path,
      rendered: (File(
        '${pairDir.path}/rendered.png',
      )..writeAsBytesSync(rendered)).path,
      diffDir: pairDir.path,
    );
  }

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('portable_goldens_pixels');
    final white = encodePng(4, 4);
    pairs = [
      pair('same_bytes', white, white),
      // The same pixels, encoded differently: equal for the compare.
      pair('same_pixels', white, encodePng(4, 4, level: 0)),
      pair('one_pixel', white, encodePng(4, 4, at: {(1, 2): 0xff0000ff})),
      pair('other_size', white, encodePng(4, 5)),
    ];
    expect(
      File(pairs[1].committed).readAsBytesSync(),
      isNot(File(pairs[1].rendered).readAsBytesSync()),
      reason: 'the two encodings must differ in bytes',
    );
    verdicts = await FlutterPixelComparer(
      packageDir: Directory.current.path,
      sdk: FlutterSdk.current(),
      environment: Platform.environment,
      runProcess:
          (
            executable,
            arguments, {
            workingDirectory,
            environment,
            includeParentEnvironment = true,
            stdoutEncoding = systemEncoding,
          }) {
            runs.add((args: arguments, env: environment));
            return Process.run(
              executable,
              arguments,
              workingDirectory: workingDirectory,
              environment: environment,
              includeParentEnvironment: includeParentEnvironment,
              stdoutEncoding: stdoutEncoding,
            );
          },
    ).compare(pairs);
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  test('one flutter test run compares every pair', () {
    expect(runs, hasLength(1));
    expect(verdicts, hasLength(pairs.length));
  });

  test('equal bytes, and equal pixels in other bytes, are the same', () {
    expect(verdicts[0].isSame, isTrue, reason: verdicts[0].difference);
    expect(verdicts[1].isSame, isTrue, reason: verdicts[1].difference);
    expect(verdicts[0].diffs, isEmpty);
  });

  test('one different pixel is a difference, with its diff images', () {
    final verdict = verdicts[2];

    expect(verdict.isSame, isFalse);
    expect(verdict.difference, contains('1px diff detected'));
    expect(
      verdict.diffs.map((d) => d.split('/').last),
      containsAll(['isolatedDiff.png', 'maskedDiff.png']),
    );
    for (final diff in verdict.diffs) {
      expect(diff, startsWith(pairs[2].diffDir));
      expect(File(diff).readAsBytesSync().take(4), [0x89, 0x50, 0x4e, 0x47]);
    }
  });

  test('another size is a difference, with both images as Flutter read '
      'them', () {
    expect(verdicts[3].isSame, isFalse);
    expect(verdicts[3].difference, contains('size'));
    expect(
      verdicts[3].diffs.map((d) => d.split('/').last),
      unorderedEquals(['masterImage.png', 'testImage.png']),
    );
  });

  test('the run is marked as inside a build, and is not a nested test', () {
    final env = runs.single.env!;

    expect(env[childEnvironmentVariable], '1');
    expect(env, isNot(contains('FLUTTER_TEST')));
    expect(env[verifyManifestVariable], endsWith('/manifest.json'));
  });

  test('without an SDK, the compare fails rather than answering', () async {
    final comparer = FlutterPixelComparer(
      packageDir: Directory.current.path,
      sdk: null,
      environment: const {},
    );

    await expectLater(
      comparer.compare(pairs.take(1).toList()),
      throwsA(isA<PixelCompareFailure>()),
    );
  });
}
