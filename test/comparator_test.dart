import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portable_goldens/portable_goldens.dart';
import 'package:portable_goldens/src/compare/notices.dart';

import 'support/repo.dart';

/// An 8x8 white png with a black pixel at ([x], 0): one [x] from another is
/// a one-pixel change.
Future<Uint8List> dot(int x) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = Colors.white)
    ..drawRect(
      Rect.fromLTWH(x.toDouble(), 0, 1, 1),
      Paint()..color = Colors.black,
    );
  final image = await recorder.endRecording().toImage(8, 8);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestRepo repo;
  late Directory cache;
  // The png the other machine committed, and what this machine renders from
  // the same commit: a pixel apart, as on the two Macs.
  late Uint8List committed;
  late Uint8List renderedHere;
  late Uint8List onePixelOff;
  final golden = Uri.parse('goldens/a.png');

  setUp(() async {
    committed = await dot(0);
    renderedHere = await dot(1);
    onePixelOff = await dot(2);
    repo = await TestRepo.create();
    File('${repo.dir}/test/goldens/a.png').writeAsBytesSync(committed);
    await repo.commit('a is drawn');
    cache = Directory.systemTemp.createTempSync('portable_goldens_cache');
  });

  tearDown(() {
    repo.delete();
    cache.deleteSync(recursive: true);
  });

  PortableGoldenComparator comparator({
    FakeFlutter? flutter,
    String? packageDir,
    Map<String, String> environment = const {'FLUTTER_ROOT': '/fake/flutter'},
  }) {
    final dir = packageDir ?? repo.dir;
    final fake =
        flutter ??
        FakeFlutter(
          renders: ['test/goldens/a.png'],
          draw: (_, _) => renderedHere,
        );
    return PortableGoldenComparator(
      Uri.file('$dir/test/a_test.dart'),
      goldens: MachineGoldens(
        packageDir: dir,
        environment: environment,
        key: fakeKey(),
        cacheRoot: cache.path,
        runProcess: fake.call,
      ),
      report: GoldenReport(dir),
    );
  }

  test(
    "this machine's render passes, where the committed image would fail",
    () async {
      final plain = LocalFileComparator(
        Uri.file('${repo.dir}/test/a_test.dart'),
      );
      await expectLater(
        plain.compare(renderedHere, golden),
        throwsFlutterError,
      );

      expect(await comparator().compare(renderedHere, golden), isTrue);
    },
  );

  test('one pixel off fails, writes the diff images to failures/ and names '
      'the baseline', () async {
    final head = await repo.git(['rev-parse', 'HEAD']);
    final machine = comparator();

    await expectLater(
      machine.compare(onePixelOff, golden),
      throwsA(
        isA<FlutterError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Pixel test failed'),
            contains(
              "this machine's baseline, rendered from commit "
              '${head.substring(0, 10)}',
            ),
            contains(
              '`dart run portable_goldens:verify` checks whether '
              '${head.substring(0, 10)} can draw it.',
            ),
          ),
        ),
      ),
    );
    final diff = File(
      nativePath('${repo.dir}/test/failures/a_isolatedDiff.png'),
    );
    expect(diff.existsSync(), isTrue);
    final entry = machine.report.read().single;
    expect(entry.golden, 'test/goldens/a.png');
    expect(entry.outcome, GoldenOutcome.failed);
    expect(entry.diffs, contains(diff.path));

    // Fixed, the next pass clears it.
    expect(await machine.compare(renderedHere, golden), isTrue);
    expect(machine.report.read(), isEmpty);
  });

  group('a golden this branch changed', () {
    // What the branch's commit renders on this machine, where it moved a.
    late Uint8List moved;
    late String branchPoint;
    late String branchCommit;

    setUp(() async {
      moved = await dot(3);
      branchPoint = await repo.git(['rev-parse', 'HEAD']);
      await repo.git(['checkout', '--quiet', '-b', 'feature']);
      File('${repo.dir}/test/goldens/a.png').writeAsBytesSync(moved);
      branchCommit = await repo.commit('a moves');
    });

    FakeFlutter drawing() => FakeFlutter(
      renders: ['test/goldens/a.png'],
      draw: (_, commit) => commit == branchCommit ? moved : renderedHere,
    );

    test("committed, one pixel off its commit's render fails", () async {
      await expectLater(
        comparator(flutter: drawing()).compare(onePixelOff, golden),
        throwsA(
          isA<FlutterError>().having(
            (e) => e.message,
            'message',
            contains(
              "this machine's baseline, rendered from commit "
              '${branchCommit.substring(0, 10)}',
            ),
          ),
        ),
      );
    });

    test("committed, its commit's render passes and is reported with its "
        "diff against this machine's render from before the branch", () async {
      final machine = comparator(flutter: drawing());

      expect(await machine.compare(moved, golden), isTrue);

      final entry = machine.report.read().single;
      expect(entry.outcome, GoldenOutcome.changed);
      expect(
        entry.baseline,
        contains("this machine's render of ${branchPoint.substring(0, 10)}"),
      );
      expect(
        entry.diffs,
        contains(
          nativePath('${repo.dir}/test/failures/a_isolatedDiff_branch.png'),
        ),
      );
      expect(File(entry.diffs.first).existsSync(), isTrue);
    });

    test(
      'that renders as it did before the branch is reported with no diff',
      () async {
        final machine = comparator();

        expect(await machine.compare(renderedHere, golden), isTrue);

        final entry = machine.report.read().single;
        expect(entry.outcome, GoldenOutcome.changed);
        expect(entry.diffs, isEmpty);
      },
    );

    test(
      'uncommitted, it is compared exactly with the working tree png',
      () async {
        File('${repo.dir}/test/goldens/a.png').writeAsBytesSync(onePixelOff);
        final flutter = drawing();
        final machine = comparator(flutter: flutter);

        expect(await machine.compare(onePixelOff, golden), isTrue);
        await expectLater(
          machine.compare(moved, golden),
          throwsA(
            isA<FlutterError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('the png in the working tree'),
                // verify checks a commit's png, not the working tree's.
                isNot(contains('portable_goldens:verify')),
              ),
            ),
          ),
        );
        expect(machine.report.read().single.outcome, GoldenOutcome.failed);
      },
    );
  });

  test(
    'a baseline build that fails fails the golden, naming the command',
    () async {
      final failing = FakeFlutter(
        renders: ['test/goldens/a.png'],
        draw: (_, _) => renderedHere,
        testExitCode: 1,
      );

      await expectLater(
        comparator(flutter: failing).compare(renderedHere, golden),
        throwsA(
          isA<FlutterError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('could not build the baselines of commit'),
              contains('test --update-goldens test/a_test.dart'),
            ),
          ),
        ),
      );
    },
  );

  test('--update-goldens writes the committed png and leaves the machine '
      'baseline alone', () async {
    final machine = comparator();
    await machine.compare(renderedHere, golden);
    final head = await repo.git(['rev-parse', 'HEAD']);
    final baseline = File(
      '${cache.path}/${fakeKey().id}/$head/root/test/goldens/a.png',
    );

    await machine.update(golden, onePixelOff);

    expect(
      File('${repo.dir}/test/goldens/a.png').readAsBytesSync(),
      onePixelOff,
    );
    expect(baseline.readAsBytesSync(), renderedHere);
    // Now uncommitted, the png in the working tree is its baseline, exactly.
    expect(await comparator().compare(onePixelOff, golden), isTrue);
    await expectLater(
      comparator().compare(renderedHere, golden),
      throwsFlutterError,
    );
  });

  test(
    'a Git LFS pointer where the png should be is said, not compared',
    () async {
      final plain = Directory.systemTemp.createTempSync(
        'portable_goldens_plain',
      );
      addTearDown(() => plain.deleteSync(recursive: true));
      File('${plain.path}/test/goldens/a.png')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'version https://git-lfs.github.com/spec/v1\n'
          'oid sha256:${'0' * 64}\nsize 99\n',
        );
      final machine = comparator(packageDir: plain.path);

      await expectLater(
        machine.compare(committed, golden),
        throwsA(
          isA<FlutterError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('the committed image, because '),
              contains('is unknown here, because it is a Git LFS pointer'),
              contains('git lfs pull'),
            ),
          ),
        ),
      );
      expect(
        Directory('${plain.path}/test/failures').existsSync(),
        isFalse,
        reason: 'no compare ran, so no diff images',
      );
    },
  );

  test('outside a git repository it is a plain comparator against the '
      'committed image', () async {
    final plain = Directory.systemTemp.createTempSync('portable_goldens_plain');
    addTearDown(() => plain.deleteSync(recursive: true));
    File('${plain.path}/test/goldens/a.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(committed);
    final machine = comparator(packageDir: plain.path);

    expect(await machine.compare(committed, golden), isTrue);
    await expectLater(
      machine.compare(renderedHere, golden),
      throwsFlutterError,
    );
    // Recorded like any other failure, so `report` lists it.
    final entry = machine.report.read().single;
    expect(entry.outcome, GoldenOutcome.failed);
    expect(entry.baseline, contains('the committed image'));
    expect(
      entry.diffs,
      contains(nativePath('${plain.path}/test/failures/a_isolatedDiff.png')),
    );
  });

  group('the notice of a committed-image compare', () {
    late Notices processNotices;
    late StringBuffer said;

    setUp(() {
      processNotices = Notices.process;
      said = StringBuffer();
      Notices.process = Notices(said);
    });

    tearDown(() => Notices.process = processNotices);

    test('is not said inside a build, which compares with the committed '
        'image by design', () async {
      final flutter = FakeFlutter();
      final child = comparator(
        flutter: flutter,
        environment: const {
          'FLUTTER_ROOT': '/fake/flutter',
          childEnvironmentVariable: '1',
        },
      );

      expect(await child.compare(committed, golden), isTrue);
      expect(flutter.testRuns, isEmpty);
      expect('$said', isEmpty);
    });

    test('is said once, with its reason, anywhere else', () async {
      final plain = Directory.systemTemp.createTempSync(
        'portable_goldens_plain',
      );
      addTearDown(() => plain.deleteSync(recursive: true));
      File('${plain.path}/test/goldens/a.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(committed);
      final machine = comparator(packageDir: plain.path);

      expect(await machine.compare(committed, golden), isTrue);
      expect(await machine.compare(committed, golden), isTrue);
      expect(
        '$said',
        'portable_goldens: comparing with the committed images, because '
            'the package is not in a git repository.\n',
      );
    });
  });

  test(
    'a configuration it cannot read fails the golden, never passes it',
    () async {
      repo.write('pubspec.yaml', 'portable_goldens: [make gen]\n');

      await expectLater(
        comparator().compare(renderedHere, golden),
        throwsA(
          isA<FlutterError>().having(
            (e) => e.message,
            'message',
            allOf(
              startsWith(
                'Golden "goldens/a.png": portable_goldens cannot read',
              ),
              contains('`portable_goldens` is not a map'),
            ),
          ),
        ),
      );
    },
  );
}
